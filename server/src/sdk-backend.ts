/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

import {
  createAgentSession,
  type AgentSession,
  type AgentSessionEvent,
  type ExtensionFactory,
  type ExtensionUIDialogOptions,
  type ExtensionUIContext,
  SessionManager as PiSessionManager,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
} from "@mariozechner/pi-coding-agent";
import { getModel, type KnownProvider, type ImageContent } from "@mariozechner/pi-ai";

import type { GateServer } from "./gate.js";
import { ts } from "./log-utils.js";
import type {
  ExtensionErrorEvent,
  ExtensionUIRequestEvent,
  PiStateSnapshot,
  SessionBackendEvent,
} from "./pi-events.js";
import type { Session, Workspace } from "./types.js";

/** Parse an oppi model string like "anthropic/claude-sonnet-4-20250514" into { provider, model }. */
function parseModelId(modelId: string): { provider: string; model: string } | null {
  const slash = modelId.indexOf("/");
  if (slash <= 0) return null;
  return { provider: modelId.substring(0, slash), model: modelId.substring(slash + 1) };
}

/**
 * Resolve workspace host mount into an absolute SDK cwd.
 *
 * Workspace hostMount is stored in display form (commonly "~/...").
 * Node path APIs do not expand "~" and will treat it as a relative path,
 * producing cwd values like "<server-cwd>/~/workspace/...". Normalize here
 * before passing cwd into SDK components.
 */
export function resolveSdkSessionCwd(workspace?: Workspace): string {
  const rawHostMount = workspace?.hostMount?.trim();
  if (!rawHostMount) {
    return homedir();
  }

  const expanded =
    rawHostMount === "~" || rawHostMount.startsWith("~/")
      ? rawHostMount.replace(/^~(?=\/|$)/, homedir())
      : rawHostMount;

  return resolve(expanded);
}

export interface SdkBackendConfig {
  session: Session;
  workspace?: Workspace;
  /** Called for SDK agent events and extension callback events. */
  onEvent: (event: SessionBackendEvent) => void;
  /** Called when the session ends. */
  onEnd: (reason: string) => void;
  /** Gate server for permission checks. */
  gate?: GateServer;
  /** Workspace ID for gate guard registration. */
  workspaceId?: string;
  /** Whether to enable the permission gate. Default: true if gate is provided. */
  permissionGate?: boolean;
  /** Resolved skill directory paths for this workspace. */
  skillPaths?: string[];
}

interface ExtensionUIResponsePayload {
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface PendingExtensionUIResponse {
  resolve: (response: ExtensionUIResponsePayload) => void;
  cancel: () => void;
}

/**
 * Wraps a pi AgentSession for use by SessionManager.
 *
 * Lifecycle:
 *   const backend = await SdkBackend.create(config);
 *   backend.prompt("hello");
 *   backend.abort();
 *   backend.dispose();
 */
export class SdkBackend {
  private piSession: AgentSession;
  private unsub: () => void;
  private readonly emitEvent: (event: SessionBackendEvent) => void;
  private readonly pendingExtensionResponses = new Map<string, PendingExtensionUIResponse>();
  private disposed = false;

  private constructor(
    piSession: AgentSession,
    unsub: () => void,
    emitEvent: (event: SessionBackendEvent) => void,
  ) {
    this.piSession = piSession;
    this.unsub = unsub;
    this.emitEvent = emitEvent;
  }

  static async create(config: SdkBackendConfig): Promise<SdkBackend> {
    const { session, workspace, onEvent, onEnd: _onEnd } = config;
    const cwd = resolveSdkSessionCwd(workspace);
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
    const modelRegistry = new ModelRegistry(authStorage, join(agentDir, "models.json"));
    const settingsManager = SettingsManager.create(cwd, agentDir);

    // Resolve the model from the session's model ID
    let model: ReturnType<typeof getModel> | undefined;
    const parsed = session.model ? parseModelId(session.model) : null;
    if (parsed) {
      try {
        model = getModel(parsed.provider as KnownProvider, parsed.model as never);
      } catch {
        console.warn(`${ts()} [sdk] Failed to resolve model ${session.model}, using default`);
      }
    }

    // Use file-based session manager for persistence
    const piSessionFile = (session as { piSessionFile?: string }).piSessionFile;
    const piSessionManager = piSessionFile
      ? PiSessionManager.open(piSessionFile)
      : PiSessionManager.create(cwd);

    // Build extension factories for in-process gate
    const extensionFactories: ExtensionFactory[] = [];
    const useGate = config.gate && config.permissionGate !== false;
    if (useGate && config.gate) {
      extensionFactories.push(
        createPermissionGateFactory(config.gate, session.id, config.workspaceId || ""),
      );
    }

    // Resource loader — suppress auto-discovery, load only what we need.
    // Extension factories (permission gate) are injected here.
    // Pi's auto-discovered permission-gate extension is filtered out since
    // oppi has its own policy engine (GateServer). Without this, both gates
    // run and the pi extension blocks commands it considers "dangerous" with
    // no UI to approve them (ctx.hasUI is false in oppi sessions).
    const loader = new DefaultResourceLoader({
      cwd,
      agentDir,
      settingsManager,
      additionalExtensionPaths: [],
      additionalSkillPaths: config.skillPaths ?? [],
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      extensionFactories,
      extensionsOverride: (base) => ({
        ...base,
        extensions: base.extensions.filter(
          (ext) =>
            !ext.path.includes("permission-gate") && !ext.resolvedPath.includes("permission-gate"),
        ),
      }),
    });
    await loader.reload();

    const { session: piSession } = await createAgentSession({
      cwd,
      agentDir,
      authStorage,
      modelRegistry,
      model,
      thinkingLevel:
        (session.thinkingLevel as "off" | "minimal" | "low" | "medium" | "high" | "xhigh") ||
        "medium",
      sessionManager: piSessionManager,
      settingsManager,
      resourceLoader: loader,
    });

    // Subscribe to agent events — forward everything to the translation layer.
    const unsub = piSession.subscribe((event: AgentSessionEvent) => {
      onEvent(event);
    });

    const backend = new SdkBackend(piSession, unsub, onEvent);

    await piSession.bindExtensions({
      uiContext: backend.createExtensionUIContext(),
      onError: (error) => {
        const event: ExtensionErrorEvent = {
          type: "extension_error",
          extensionPath: error.extensionPath,
          event: error.event,
          error: error.error,
        };
        onEvent(event);
      },
    });

    console.log(
      `${ts()} [sdk] Session created: model=${piSession.model?.id ?? piSession.model?.name}, thinking=${piSession.thinkingLevel}`,
    );

    return backend;
  }

  get session(): AgentSession {
    return this.piSession;
  }

  private emitExtensionUIRequest(request: Omit<ExtensionUIRequestEvent, "type">): void {
    this.emitEvent({
      type: "extension_ui_request",
      ...request,
    });
  }

  private createDialogPromise<T>(
    opts: ExtensionUIDialogOptions | undefined,
    defaultValue: T,
    request: Omit<ExtensionUIRequestEvent, "type" | "id">,
    parseResponse: (response: ExtensionUIResponsePayload) => T,
  ): Promise<T> {
    if (this.disposed || opts?.signal?.aborted) {
      return Promise.resolve(defaultValue);
    }

    const id = randomUUID();

    return new Promise<T>((resolve) => {
      let timeoutId: NodeJS.Timeout | undefined;

      const cleanup = (): void => {
        if (timeoutId) {
          clearTimeout(timeoutId);
        }
        opts?.signal?.removeEventListener("abort", onAbort);
        this.pendingExtensionResponses.delete(id);
      };

      const cancel = (): void => {
        cleanup();
        resolve(defaultValue);
      };

      const onAbort = (): void => {
        cancel();
      };

      opts?.signal?.addEventListener("abort", onAbort, { once: true });

      if (opts?.timeout) {
        timeoutId = setTimeout(() => {
          cancel();
        }, opts.timeout);
      }

      this.pendingExtensionResponses.set(id, {
        resolve: (response) => {
          cleanup();
          resolve(parseResponse(response));
        },
        cancel,
      });

      this.emitExtensionUIRequest({
        id,
        ...request,
        timeout: opts?.timeout,
      });
    });
  }

  private createExtensionUIContext(): ExtensionUIContext {
    return {
      select: (title, options, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "select", title, options },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      confirm: (title, message, opts) =>
        this.createDialogPromise(opts, false, { method: "confirm", title, message }, (response) =>
          response.cancelled ? false : (response.confirmed ?? false),
        ),

      input: (title, placeholder, opts) =>
        this.createDialogPromise(
          opts,
          undefined,
          { method: "input", title, placeholder },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      notify: (message, type) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "notify",
          message,
          notifyType: type,
        });
      },

      onTerminalInput: () => () => {
        // Raw terminal input is not supported in Oppi server sessions.
      },

      setStatus: (key, text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setStatus",
          statusKey: key,
          statusText: text,
        });
      },

      setWorkingMessage: (_message) => {
        // Working message requires TUI access; unsupported in Oppi sessions.
      },

      setWidget: (key, content, options) => {
        if (content === undefined || Array.isArray(content)) {
          this.emitExtensionUIRequest({
            id: randomUUID(),
            method: "setWidget",
            widgetKey: key,
            widgetLines: content,
            widgetPlacement: options?.placement,
          });
        }
      },

      setFooter: (_factory) => {
        // Custom footer requires TUI access; unsupported in Oppi sessions.
      },

      setHeader: (_factory) => {
        // Custom header requires TUI access; unsupported in Oppi sessions.
      },

      setTitle: (title) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "setTitle",
          title,
        });
      },

      custom: async () => {
        return undefined;
      },

      pasteToEditor: (text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "set_editor_text",
          text,
        });
      },

      setEditorText: (text) => {
        this.emitExtensionUIRequest({
          id: randomUUID(),
          method: "set_editor_text",
          text,
        });
      },

      getEditorText: () => {
        return "";
      },

      editor: (title, prefill) =>
        this.createDialogPromise(
          undefined,
          undefined,
          { method: "editor", title, prefill },
          (response) => (response.cancelled ? undefined : response.value),
        ),

      setEditorComponent: (_factory) => {
        // Custom editor components require TUI access; unsupported in Oppi sessions.
      },

      get theme() {
        return {} as ExtensionUIContext["theme"];
      },

      getAllThemes: () => [],

      getTheme: (_name) => undefined,

      setTheme: (_theme) => ({
        success: false,
        error: "Theme switching not supported in Oppi sessions",
      }),

      getToolsExpanded: () => false,

      setToolsExpanded: (_expanded) => {
        // Tool expansion requires TUI access; unsupported in Oppi sessions.
      },
    } as ExtensionUIContext;
  }

  respondToExtensionUIRequest(response: ExtensionUIResponsePayload): boolean {
    const pending = this.pendingExtensionResponses.get(response.id);
    if (!pending) {
      return false;
    }

    pending.resolve(response);
    return true;
  }

  // ─── Commands ───

  /** Send a prompt. Fire-and-forget — events come via subscribe. */
  prompt(
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
    },
  ): void {
    if (this.disposed) return;

    const images: ImageContent[] | undefined = opts?.images?.map((img) => ({
      type: "image" as const,
      data: img.data,
      mimeType: img.mimeType,
    }));

    this.piSession
      .prompt(message, {
        images,
        streamingBehavior: opts?.streamingBehavior,
      })
      .catch((err) => {
        console.error(`${ts()} [sdk] prompt error:`, err);
      });
  }

  async abort(): Promise<void> {
    if (this.disposed) return;
    await this.piSession.abort();
  }

  async setModel(modelId: string): Promise<{
    success: boolean;
    provider?: string;
    id?: string;
    name?: string;
    error?: string;
  }> {
    const parsed = parseModelId(modelId);
    if (!parsed) {
      return { success: false, error: `Invalid model ID: ${modelId}` };
    }

    try {
      const model = getModel(parsed.provider as KnownProvider, parsed.model as never);
      await this.piSession.setModel(model);

      const activeModel = this.piSession.model;
      return {
        success: true,
        provider: activeModel?.provider,
        id: activeModel?.id,
        name: activeModel?.name,
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { success: false, error: message };
    }
  }

  /** Full state snapshot for client command responses. */
  getStateSnapshot(): PiStateSnapshot {
    const m = this.piSession.model;
    return {
      sessionFile: this.piSession.sessionFile,
      sessionId: this.piSession.sessionId,
      sessionName: this.piSession.sessionName,
      model: m ? { provider: m.provider, id: m.id, name: m.name } : undefined,
      thinkingLevel: this.piSession.thinkingLevel,
      isStreaming: this.piSession.isStreaming,
      autoCompaction: this.piSession.autoCompactionEnabled,
    };
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  get isStreaming(): boolean {
    return this.piSession.isStreaming;
  }

  get sessionFile(): string | undefined {
    return this.piSession.sessionFile;
  }

  get sessionId(): string {
    return this.piSession.sessionId;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;

    for (const pending of this.pendingExtensionResponses.values()) {
      pending.cancel();
    }
    this.pendingExtensionResponses.clear();

    this.unsub();
    this.piSession.dispose();
  }
}

// ─── In-Process Permission Gate Extension Factory ───

/**
 * Create an ExtensionFactory that gates tool calls through GateServer.
 * Runs in-process — every tool call is evaluated by the policy engine.
 */
function createPermissionGateFactory(
  gate: GateServer,
  sessionId: string,
  workspaceId: string,
): ExtensionFactory {
  return (extensionApi: unknown) => {
    const pi = extensionApi as {
      on(
        event: "tool_call",
        handler: (event: {
          toolName: string;
          toolCallId: string;
          input: Record<string, unknown>;
        }) => Promise<{ block: true; reason: string } | void>,
      ): void;
      on(event: "session_shutdown", handler: () => void): void;
    };

    // Register guard for this session.
    gate.createGuard(sessionId, workspaceId);
    console.log(`${ts()} [sdk-gate] Virtual guard registered for ${sessionId}`);

    // Gate every tool call through the policy engine
    pi.on(
      "tool_call",
      async (event: { toolName: string; toolCallId: string; input: Record<string, unknown> }) => {
        const result = await gate.checkToolCall(sessionId, {
          tool: event.toolName,
          input: event.input,
          toolCallId: event.toolCallId,
        });

        if (result.action === "deny") {
          return { block: true, reason: result.reason || "Denied by permission gate" };
        }

        // Allow — return void, tool executes normally
      },
    );

    // Clean up on shutdown
    pi.on("session_shutdown", () => {
      gate.destroySessionGuard(sessionId);
      console.log(`${ts()} [sdk-gate] Guard destroyed for ${sessionId}`);
    });
  };
}
