/**
 * Pi session backend — wraps pi's SDK AgentSession for in-process execution.
 *
 * Events flow through the translatePiEvent pipeline. The AgentEvent shapes
 * from subscribe() match the ServerMessage contract consumed by iOS.
 */

import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  createAgentSession,
  createAgentSessionRuntime,
  createBashToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  createEditToolDefinition,
  type AgentSession,
  type AgentSessionEvent,
  type AgentSessionRuntime,
  type CreateAgentSessionRuntimeFactory,
  type ExtensionFactory,
  SessionManager as PiSessionManager,
  DefaultResourceLoader,
  AuthStorage,
  ModelRegistry,
  SettingsManager,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";

import type { GateServer } from "./gate.js";
import type { ExtensionErrorEvent, PiStateSnapshot, SessionBackendEvent } from "./pi-events.js";
import { isFirstPartyExtensionName, isManagedExtensionName } from "../extensions/first-party.js";
import {
  getReloadableFirstPartyExtensionPaths,
  withReloadableFirstPartyExtensionContext,
  type ReloadableFirstPartyExtensionContext,
} from "./first-party-extension-runtime.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import { SdkUiBridge, type ExtensionUIResponsePayload } from "./sdk-ui-bridge.js";
import { extensionNameFromPath } from "./extension-loader.js";
import { hostMountValidationError, resolveHostPath } from "./host.js";
import type { Session, Workspace } from "./types.js";

/** Parse an oppi model string like "anthropic/claude-sonnet-4-20250514" into { provider, model }. */
function parseModelId(modelId: string): { provider: string; model: string } | null {
  const slash = modelId.indexOf("/");
  if (slash <= 0) return null;
  return { provider: modelId.substring(0, slash), model: modelId.substring(slash + 1) };
}

function resolveRegistryModel(
  modelRegistry: Pick<ModelRegistry, "find">,
  modelId: string,
): ReturnType<ModelRegistry["find"]> {
  const parsed = parseModelId(modelId);
  if (!parsed) {
    return undefined;
  }

  return modelRegistry.find(parsed.provider, parsed.model);
}

function getLoadedExtensionName(ext: { path: string; resolvedPath: string }): string {
  return extensionNameFromPath(ext.resolvedPath || ext.path);
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
    if (workspace?.runtime === "sandbox") {
      // Auto-create a dedicated sandbox directory. Permanent, per-workspace.
      // Slug the name to a safe directory name, fall back to id.
      const slug =
        (workspace.name || workspace.id)
          .toLowerCase()
          .replace(/[^a-z0-9-_]/g, "-")
          .replace(/-+/g, "-")
          .replace(/^-|-$/g, "") || workspace.id;
      const sandboxDir = join(homedir(), "sandbox", slug);
      mkdirSync(sandboxDir, { recursive: true });
      return sandboxDir;
    }
    return homedir();
  }

  return resolveHostPath(rawHostMount);
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
  /** Session-scoped deps for Oppi's reloadable first-party extensions. */
  reloadableFirstPartyExtensionContext?: ReloadableFirstPartyExtensionContext;
  /** Additional extension factories injected for this session. */
  extraExtensionFactories?: ExtensionFactory[];
  /** Operational metrics collector for SDK timing. */
  metrics?: ServerMetricCollector;
}

const log = createLogger({ base: { component: "sdk_backend" } });

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
  private static readonly DEFAULT_STEERING_MODE = "all" as const;
  private static readonly DEFAULT_FOLLOW_UP_MODE = "one-at-a-time" as const;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private static _gondolinManager: any;

  private runtime: AgentSessionRuntime;
  private unsub: (() => void) | null = null;
  private readonly emitEvent: (event: SessionBackendEvent) => void;
  private readonly uiBridge: SdkUiBridge;
  private shutdownCleanupPromise: Promise<void> | null = null;
  private shutdownCleanupCompleted = false;
  private readonly shutdownCleanupListeners = new Set<() => void>();
  private disposed = false;

  private constructor(
    runtime: AgentSessionRuntime,
    emitEvent: (event: SessionBackendEvent) => void,
  ) {
    this.runtime = runtime;
    this.emitEvent = emitEvent;
    this.uiBridge = new SdkUiBridge(emitEvent, () => this.disposed);
    this.subscribeToCurrentSession();
  }

  private get piSession(): AgentSession {
    return this.runtime.session;
  }

  private get modelRegistry(): ModelRegistry {
    return this.runtime.services.modelRegistry;
  }

  private static createPiSessionManager(session: Session, cwd: string): PiSessionManager {
    const piSessionFile = session.piSessionFile;
    if (session.ephemeral) {
      return PiSessionManager.inMemory(cwd);
    }
    return piSessionFile ? PiSessionManager.open(piSessionFile) : PiSessionManager.create(cwd);
  }

  static async create(config: SdkBackendConfig): Promise<SdkBackend> {
    const createStartMs = Date.now();
    const { session, workspace, onEvent, onEnd: _onEnd } = config;
    const initialCwd = resolveSdkSessionCwd(workspace);
    const hostMountError = hostMountValidationError(workspace?.hostMount);
    if (hostMountError) {
      throw new Error(hostMountError);
    }
    const agentDir = getAgentDir();
    const initialSessionManager = SdkBackend.createPiSessionManager(session, initialCwd);

    const createRuntimeFactory: CreateAgentSessionRuntimeFactory = async ({
      cwd,
      agentDir: runtimeAgentDir,
      sessionManager,
      sessionStartEvent,
    }) => {
      const authStorage = AuthStorage.create(join(runtimeAgentDir, "auth.json"));
      const modelRegistry = ModelRegistry.create(authStorage, join(runtimeAgentDir, "models.json"));
      const settingsManager = SettingsManager.create(cwd, runtimeAgentDir);

      const shouldSeedFromSessionState = !sessionStartEvent;
      const model =
        shouldSeedFromSessionState && session.model
          ? resolveRegistryModel(modelRegistry, session.model)
          : undefined;
      if (shouldSeedFromSessionState && session.model && !model) {
        log.warn("sdk.model_resolve_defaulted", {
          model: session.model,
        });
      }

      // Build extension factories for in-process tools
      const extensionFactories: ExtensionFactory[] = [];
      const useGate = config.gate && config.permissionGate !== false;
      if (useGate && config.gate) {
        extensionFactories.push(
          createPermissionGateFactory(config.gate, session.id, config.workspaceId || "", cwd),
        );
      }
      if (config.extraExtensionFactories) {
        extensionFactories.push(...config.extraExtensionFactories);
      }

      const firstPartyExtensionPaths = getReloadableFirstPartyExtensionPaths();

      // Resource loader — suppress skill/theme auto-discovery, but keep
      // prompt templates enabled because Oppi exposes them as slash commands.
      // File-based extensions stay enabled so /reload can re-import Oppi's
      // first-party ones. Extension factories (permission gate + temporary
      // pending factories) are still injected here.
      // Pi's auto-discovered permission-gate extension is filtered out since
      // oppi has its own policy engine (GateServer). Without this, both gates
      // run and the pi extension blocks commands it considers "dangerous" with
      // no UI to approve them (ctx.hasUI is false in oppi sessions).
      const loader = new DefaultResourceLoader({
        cwd,
        agentDir: runtimeAgentDir,
        settingsManager,
        additionalExtensionPaths: firstPartyExtensionPaths,
        additionalSkillPaths: config.skillPaths ?? [],
        noSkills: true,
        noThemes: true,
        extensionFactories,
        appendSystemPrompt: workspace?.systemPrompt ? [workspace.systemPrompt] : undefined,
        extensionsOverride: (base) => {
          // 1. Filter out extensions managed directly by oppi-server.
          //    permission-gate is replaced by oppi's own policy engine.
          //    ask, voice, and subagents stay file-based so /reload can re-import them.
          let filtered = base.extensions.filter(
            (ext) => !isManagedExtensionName(getLoadedExtensionName(ext)),
          );

          // 2. If the workspace specifies an extensions allowlist, that allowlist is
          //    authoritative. Always keep inline factory extensions (path "<inline:N>")
          //    because they're injected programmatically by the server.
          const allowedNames = workspace?.extensions;
          if (allowedNames !== undefined) {
            const allowed = new Set(allowedNames);
            filtered = filtered.filter((ext) => {
              if (ext.path.startsWith("<inline:")) return true;
              return allowed.has(getLoadedExtensionName(ext));
            });
          } else {
            // 3. Without an explicit allowlist, keep normal pi discovery intact but
            //    leave Oppi-owned extension names off unless the workspace opted in.
            filtered = filtered.filter((ext) => {
              const name = getLoadedExtensionName(ext);
              if (!isFirstPartyExtensionName(name)) {
                return true;
              }
              return false;
            });
          }

          // Debug: log extension filtering
          const extNames = base.extensions.map(
            (ext) =>
              `${getLoadedExtensionName(ext)}(tools:${[...ext.tools.keys()].join(",") || "none"})`,
          );
          const filteredNames = filtered.map(
            (ext) =>
              `${getLoadedExtensionName(ext)}(tools:${[...ext.tools.keys()].join(",") || "none"})`,
          );
          if (process.env.DEBUG) {
            log.info("sdk.extensions_override_debug", {
              workspace: workspace?.name,
              input: extNames,
              errors: base.errors.map((e) => `${e.path}: ${e.error}`),
              allowlist: allowedNames,
              output: filteredNames,
            });
          }

          return { ...base, extensions: filtered };
        },
      });
      const firstPartyExtensionContext = config.reloadableFirstPartyExtensionContext;
      if (firstPartyExtensionContext) {
        const reloadWithContext = loader.reload.bind(loader);
        loader.reload = () =>
          withReloadableFirstPartyExtensionContext(firstPartyExtensionContext, reloadWithContext);
      }

      await loader.reload();

      // Sandbox mode: create tools backed by Gondolin micro-VM
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let sandboxTools: any[] | undefined;
      if (workspace?.runtime === "sandbox") {
        // Pre-flight: check QEMU availability before attempting VM creation.
        const { isQemuAvailable, GondolinManager } = await import("./gondolin-manager.js");
        if (!(await isQemuAvailable())) {
          throw new Error(
            "Sandbox mode requires QEMU but it is not installed on the server. " +
              "Install with: brew install qemu (macOS) or apt install qemu-system (Linux)",
          );
        }

        const {
          createGondolinBashOps,
          createGondolinReadOps,
          createGondolinWriteOps,
          createGondolinEditOps,
        } = await import("./gondolin-ops.js");

        // Lazy singleton — shared across all sessions for VM reuse.
        if (!SdkBackend._gondolinManager) {
          SdkBackend._gondolinManager = new GondolinManager();
        }
        const manager = SdkBackend._gondolinManager;

        // Extract LLM provider API keys as secrets for host-mediated injection.
        // The VM gets placeholder values; real keys are injected by the host HTTP proxy.
        const secrets: Record<string, { value: string; headerName?: string }> = {};
        try {
          const allCreds = authStorage.getAll();
          for (const [provider, cred] of Object.entries(allCreds)) {
            if (cred.type === "api_key" && cred.key) {
              secrets[`${provider.toUpperCase().replace(/[^A-Z0-9]/g, "_")}_API_KEY`] = {
                value: cred.key,
                headerName: "Authorization",
              };
            }
          }
        } catch {
          // Auth extraction failed — proceed without secrets
        }

        // Mount specific subdirectories read-only so the agent can read
        // SKILL.md files and extensions at the paths referenced in the system prompt.
        // Do NOT mount agentDir itself — it contains auth.json (API keys).
        const readonlyMounts: string[] = [];
        if (config.skillPaths) {
          readonlyMounts.push(...config.skillPaths);
        }
        // Mount only safe subdirectories, not the whole agentDir.
        // skills/ is already covered by skillPaths above.
        // extensions/ is needed for loaded extensions to resolve their own files.
        const extensionsDir = join(runtimeAgentDir, "extensions");
        if (existsSync(extensionsDir)) {
          readonlyMounts.push(extensionsDir);
        }

        const extraEnv = workspace.sandboxConfig?.env;
        const vm = await manager.ensureWorkspaceVm(
          workspace,
          cwd,
          secrets,
          readonlyMounts,
          extraEnv,
        );

        sandboxTools = [
          createReadToolDefinition(cwd, { operations: createGondolinReadOps(vm, cwd) }),
          createBashToolDefinition(cwd, { operations: createGondolinBashOps(vm, cwd) }),
          createEditToolDefinition(cwd, { operations: createGondolinEditOps(vm, cwd) }),
          createWriteToolDefinition(cwd, { operations: createGondolinWriteOps(vm, cwd) }),
        ];
        log.info("sdk.sandbox_vm_ready", { workspaceId: workspace.id || "unknown" });
      }

      const workspaceTools = workspace?.tools?.length ? workspace.tools : undefined;
      const createResult = await createAgentSession({
        cwd,
        agentDir: runtimeAgentDir,
        authStorage,
        modelRegistry,
        model,
        sessionManager,
        settingsManager,
        resourceLoader: loader,
        sessionStartEvent,
        // Sandbox: disable host-backed built-in tools and inject VM-backed
        // implementations as customTools. Do not use `tools: []` here: in pi SDK
        // that is an authoritative allowlist, so it filters out custom and
        // extension tools too, leaving the model with no tool-call capability.
        ...(sandboxTools ? { noTools: "builtin" as const, customTools: sandboxTools } : {}),
        ...(workspaceTools ? { tools: workspaceTools } : {}),
      });

      SdkBackend.applyDefaultQueueModes(createResult.session);

      return {
        ...createResult,
        services: {
          cwd,
          agentDir: runtimeAgentDir,
          authStorage,
          settingsManager,
          modelRegistry,
          resourceLoader: loader,
          diagnostics: [],
        },
        diagnostics: [],
      };
    };

    const runtime = await createAgentSessionRuntime(createRuntimeFactory, {
      cwd: initialCwd,
      agentDir,
      sessionManager: initialSessionManager,
    });

    const backend = new SdkBackend(runtime, onEvent);

    const preBindMs = Date.now() - createStartMs;
    config.metrics?.record("server.session_create_sdk_ms", preBindMs);

    await backend.bindCurrentSessionExtensions();

    const totalMs = Date.now() - createStartMs;
    const bindMs = totalMs - preBindMs;
    config.metrics?.record("server.session_create_bind_ms", bindMs);

    log.info("sdk.session.created", {
      model: backend.piSession.model?.id ?? backend.piSession.model?.name,
      thinking: backend.piSession.thinkingLevel,
      setupMs: preBindMs,
      bindExtensionMs: bindMs,
      totalMs,
    });

    return backend;
  }

  get session(): AgentSession {
    return this.piSession;
  }

  private subscribeToCurrentSession(): void {
    this.unsub?.();
    this.unsub = this.piSession.subscribe((event: AgentSessionEvent) => {
      this.emitEvent(event);
    });
  }

  private async bindCurrentSessionExtensions(): Promise<void> {
    SdkBackend.applyDefaultQueueModes(this.piSession);

    await this.piSession.bindExtensions({
      uiContext: this.createExtensionUIContext(),
      onError: (error) => {
        const event: ExtensionErrorEvent = {
          type: "extension_error",
          extensionPath: error.extensionPath,
          event: error.event,
          error: error.error,
        };
        this.emitEvent(event);
      },
    });
  }

  private async refreshRuntimeSessionBindings(): Promise<void> {
    this.subscribeToCurrentSession();
    await this.bindCurrentSessionExtensions();
  }

  private static applyDefaultQueueModes(
    session: Pick<AgentSession, "setSteeringMode" | "setFollowUpMode">,
  ): void {
    session.setSteeringMode(SdkBackend.DEFAULT_STEERING_MODE);
    session.setFollowUpMode(SdkBackend.DEFAULT_FOLLOW_UP_MODE);
  }

  private createExtensionUIContext(): ReturnType<SdkUiBridge["createContext"]> {
    return this.uiBridge.createContext();
  }

  respondToExtensionUIRequest(response: ExtensionUIResponsePayload): boolean {
    return this.uiBridge.respond(response);
  }

  async reloadResources(): Promise<{ success: true }> {
    if (this.disposed) {
      throw new Error("Session backend is disposed");
    }

    await this.runtime.services.resourceLoader.reload();
    await this.refreshRuntimeSessionBindings();
    return { success: true };
  }

  async newSession(): Promise<{ cancelled: boolean }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const parentSession = this.piSession.sessionFile;
    const result = await this.runtime.newSession({ parentSession });
    if (!result.cancelled) {
      await this.refreshRuntimeSessionBindings();
    }
    return result;
  }

  async switchSession(sessionPath: string): Promise<{ cancelled: boolean }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const result = await this.runtime.switchSession(sessionPath);
    if (!result.cancelled) {
      await this.refreshRuntimeSessionBindings();
    }
    return result;
  }

  async fork(entryId: string): Promise<{ cancelled: boolean; selectedText?: string }> {
    if (this.disposed) {
      return { cancelled: true };
    }

    const result = await this.runtime.fork(entryId);
    if (!result.cancelled) {
      await this.refreshRuntimeSessionBindings();
    }
    return result;
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
        const errorMessage = err instanceof Error ? err.message : String(err);
        log.error("sdk.prompt.failed", { error: safeErrorMessage(err) });
        this.emitEvent({ type: "prompt_error", error: errorMessage });
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
    thinkingLevel?: string;
    error?: string;
  }> {
    const parsed = parseModelId(modelId);
    if (!parsed) {
      return { success: false, error: `Invalid model ID: ${modelId}` };
    }

    const model = this.modelRegistry.find(parsed.provider, parsed.model);
    if (!model) {
      return { success: false, error: `Unknown model: ${modelId}` };
    }

    try {
      await this.piSession.setModel(model);

      const activeModel = this.piSession.model;
      return {
        success: true,
        provider: activeModel?.provider,
        id: activeModel?.id,
        name: activeModel?.name,
        thinkingLevel: this.piSession.thinkingLevel,
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

  onShutdownCleanupComplete(listener: () => void): void {
    if (this.shutdownCleanupCompleted) {
      try {
        listener();
      } catch (err: unknown) {
        log.error("sdk.shutdown_cleanup_listener.failed", {
          sessionId: this.piSession.sessionId,
          error: safeErrorMessage(err),
        });
      }
      return;
    }

    this.shutdownCleanupListeners.add(listener);
  }

  private flushShutdownCleanupListeners(): void {
    if (this.shutdownCleanupCompleted) {
      return;
    }

    this.shutdownCleanupCompleted = true;
    const listeners = [...this.shutdownCleanupListeners];
    this.shutdownCleanupListeners.clear();

    for (const listener of listeners) {
      try {
        listener();
      } catch (err: unknown) {
        log.error("sdk.shutdown_cleanup_listener.failed", {
          sessionId: this.piSession.sessionId,
          error: safeErrorMessage(err),
        });
      }
    }
  }

  private startShutdownCleanup(): Promise<void> {
    if (this.shutdownCleanupPromise) {
      return this.shutdownCleanupPromise;
    }

    this.shutdownCleanupPromise = (async () => {
      try {
        // Runtime dispose emits session_shutdown and tears down the current
        // session lifecycle (extensions + event subscriptions).
        await this.runtime.dispose();
      } catch (err: unknown) {
        log.error("sdk.runtime_dispose.failed", {
          sessionId: this.piSession.sessionId,
          error: safeErrorMessage(err),
        });
      } finally {
        this.flushShutdownCleanupListeners();
      }
    })();

    return this.shutdownCleanupPromise;
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      await this.startShutdownCleanup();
      return;
    }
    this.disposed = true;

    this.uiBridge.dispose();

    this.unsub?.();
    this.unsub = null;

    await this.startShutdownCleanup();
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
  sessionCwd: string,
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
    log.info("sdk.gate_guard.registered", {
      sessionId,
      workspaceId,
    });

    // Gate every tool call through the policy engine
    pi.on(
      "tool_call",
      async (event: { toolName: string; toolCallId: string; input: Record<string, unknown> }) => {
        const result = await gate.checkToolCall(sessionId, {
          tool: event.toolName,
          input: event.input,
          toolCallId: event.toolCallId,
          sessionCwd,
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
      log.info("sdk.gate_guard.destroyed", {
        sessionId,
      });
    });
  };
}
