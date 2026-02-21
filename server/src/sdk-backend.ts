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
import { join } from "path";

import type { Session, Workspace } from "./types.js";
import type { GateServer } from "./gate.js";

/** Compact HH:MM:SS.mmm timestamp for log lines. */
function ts(): string {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

/** Parse an oppi model string like "anthropic/claude-sonnet-4-20250514" into { provider, model }. */
function parseModelId(modelId: string): { provider: string; model: string } | null {
  const slash = modelId.indexOf("/");
  if (slash <= 0) return null;
  return { provider: modelId.substring(0, slash), model: modelId.substring(slash + 1) };
}

export interface SdkBackendConfig {
  session: Session;
  workspace?: Workspace;
  /** Called for every pi agent event. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi event JSON is untyped
  onEvent: (event: any) => void;
  /** Called when the session ends. */
  onEnd: (reason: string) => void;
  /** Gate server for permission checks. */
  gate?: GateServer;
  /** Workspace ID for gate guard registration. */
  workspaceId?: string;
  /** Whether to enable the permission gate. Default: true if gate is provided. */
  permissionGate?: boolean;
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
    const cwd = workspace?.hostMount || homedir();
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
    const modelRegistry = new ModelRegistry(authStorage, join(agentDir, "models.json"));
    const settingsManager = SettingsManager.create(cwd, agentDir);

    // Resolve the model from the session's model ID
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- getModel requires KnownProvider literal types
    let model: any;
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
    const loader = new DefaultResourceLoader({
      cwd,
      agentDir,
      settingsManager,
      additionalExtensionPaths: [],
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      extensionFactories,
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

    // Subscribe to agent events
    const unsub = piSession.subscribe((event: AgentSessionEvent) => {
      // Filter out session-level events not consumed by iOS
      const type = event.type;
      if (
        type === "auto_compaction_start" ||
        type === "auto_compaction_end" ||
        type === "auto_retry_start" ||
        type === "auto_retry_end"
      ) {
        console.log(`${ts()} [sdk] session event: ${type}`);
        return;
      }

      onEvent(event);
    });

    console.log(
      `${ts()} [sdk] Session created: model=${piSession.model?.name}, thinking=${piSession.thinkingLevel}`,
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

  async setModel(modelId: string): Promise<{ success: boolean; error?: string }> {
    const parsed = parseModelId(modelId);
    if (!parsed) {
      return { success: false, error: `Invalid model ID: ${modelId}` };
    }

    try {
      const model = getModel(parsed.provider as KnownProvider, parsed.model as never);
      await this.piSession.setModel(model);
      return { success: true };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { success: false, error: message };
    }
  }

  setThinkingLevel(level: string): void {
    if (this.disposed) return;
    this.piSession.setThinkingLevel(level as "off" | "low" | "medium" | "high");
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi returns typed objects but we pass through as unknown
  async cycleModel(direction?: string): Promise<any> {
    const result = await this.piSession.cycleModel(
      (direction as "forward" | "backward") || "forward",
    );
    if (!result) return undefined;
    return {
      model: {
        provider: result.model.provider,
        id: result.model.name,
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

  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi messages are typed internally
  getMessages(): any[] {
    return this.piSession.messages;
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi stats object
  getSessionStats(): any {
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
      model: this.piSession.model?.name,
      thinkingLevel: this.piSession.thinkingLevel,
      isStreaming: this.piSession.isStreaming,
      sessionFile: this.piSession.sessionFile,
    };
  }

  /** Full state snapshot for forwardRpcCommand responses. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi state shape is heterogeneous
  getStateSnapshot(): any {
    const m = this.piSession.model;
    return {
      sessionFile: this.piSession.sessionFile,
      sessionId: this.piSession.sessionId,
      sessionName: this.piSession.sessionName,
      model: m ? { provider: m.provider, id: m.name, name: m.name } : undefined,
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
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- ExtensionAPI shape varies across pi versions
  return (pi: any) => {
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
