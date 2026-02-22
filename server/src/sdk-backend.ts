/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import {
  createAgentSession,
  type AgentSession,
  type AgentSessionEvent,
  SessionManager as PiSessionManager,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
} from "@mariozechner/pi-coding-agent";
import { getModel, type KnownProvider, type ImageContent } from "@mariozechner/pi-ai";
import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import { homedir } from "os";
import { join, resolve } from "path";

import type { Session, Workspace } from "./types.js";
import type { GateServer } from "./gate.js";
import {
  parsePiEvent,
  type PiEvent,
  type PiSessionMessage,
  type PiSessionStats,
  type PiStateSnapshot,
} from "./pi-events.js";
import { ts } from "./log-utils.js";

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
  /** Called for every parsed pi agent event. */
  onEvent: (event: PiEvent) => void;
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
  private disposed = false;

  private constructor(piSession: AgentSession, unsub: () => void) {
    this.piSession = piSession;
    this.unsub = unsub;
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
      const parsed = parsePiEvent(event as unknown);
      if (parsed.type === "unknown") {
        console.warn(
          `${ts()} [sdk] unrecognized pi event (type=${parsed.originalType ?? "<missing>"}, reason=${parsed.reason})`,
        );
      }
      onEvent(parsed);
    });

    console.log(
      `${ts()} [sdk] Session created: model=${piSession.model?.id ?? piSession.model?.name}, thinking=${piSession.thinkingLevel}`,
    );

    return new SdkBackend(piSession, unsub);
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

  setThinkingLevel(level: string): void {
    if (this.disposed) return;
    this.piSession.setThinkingLevel(level as "off" | "low" | "medium" | "high");
  }

  async cycleModel(direction?: string): Promise<
    | {
        model: {
          provider: string;
          id: string;
          name: string;
        };
        thinkingLevel: string;
        isScoped: boolean;
      }
    | undefined
  > {
    const result = await this.piSession.cycleModel(
      (direction as "forward" | "backward") || "forward",
    );
    if (!result) return undefined;
    return {
      model: {
        provider: result.model.provider,
        id: result.model.id,
        name: result.model.name,
      },
      thinkingLevel: result.thinkingLevel,
      isScoped: result.isScoped,
    };
  }

  cycleThinkingLevel(): string | undefined {
    return this.piSession.cycleThinkingLevel();
  }

  setSessionName(name: string): void {
    this.piSession.setSessionName(name);
  }

  getMessages(): PiSessionMessage[] {
    return this.piSession.messages as PiSessionMessage[];
  }

  getSessionStats(): PiSessionStats {
    return this.piSession.getSessionStats();
  }

  async compact(instructions?: string): Promise<unknown> {
    return this.piSession.compact(instructions);
  }

  setAutoCompaction(enabled: boolean): void {
    this.piSession.setAutoCompactionEnabled(enabled);
  }

  async newSession(): Promise<boolean> {
    return this.piSession.newSession();
  }

  async fork(entryId: string): Promise<unknown> {
    return this.piSession.fork(entryId);
  }

  async switchSession(sessionPath: string): Promise<boolean> {
    return this.piSession.switchSession(sessionPath);
  }

  setSteeringMode(mode: string): void {
    this.piSession.setSteeringMode(mode as "all" | "one-at-a-time");
  }

  setFollowUpMode(mode: string): void {
    this.piSession.setFollowUpMode(mode as "all" | "one-at-a-time");
  }

  setAutoRetry(enabled: boolean): void {
    this.piSession.setAutoRetryEnabled(enabled);
  }

  abortRetry(): void {
    this.piSession.abortRetry();
  }

  abortBash(): void {
    this.piSession.abortBash();
  }

  getState(): {
    model: string | undefined;
    thinkingLevel: string;
    isStreaming: boolean;
    sessionFile: string | undefined;
  } {
    return {
      model: this.piSession.model?.id,
      thinkingLevel: this.piSession.thinkingLevel,
      isStreaming: this.piSession.isStreaming,
      sessionFile: this.piSession.sessionFile,
    };
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
