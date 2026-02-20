/**
 * SDK-based pi session backend.
 *
 * Replaces the RPC child process approach with in-process AgentSession.
 * Events flow through the same translatePiEvent pipeline as RPC — the
 * AgentEvent shapes are identical between SDK subscribe() and RPC stdout.
 *
 * Used when config.sessionBackend === "sdk".
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
import { homedir } from "os";
import { join } from "path";

import type { Session, Workspace } from "./types.js";

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
  /** Called for every pi event (same shape as RPC stdout JSON). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- pi event JSON is untyped
  onEvent: (event: any) => void;
  /** Called when the session ends (equivalent to process exit). */
  onEnd: (reason: string) => void;
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
    const { session, workspace, onEvent, onEnd } = config;
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

    // Resource loader — suppress auto-discovery, load only what we need
    const loader = new DefaultResourceLoader({
      cwd,
      agentDir,
      settingsManager,
      additionalExtensionPaths: [],
    });
    await loader.reload();

    const { session: piSession } = await createAgentSession({
      cwd,
      agentDir,
      authStorage,
      modelRegistry,
      model,
      thinkingLevel: (session.thinkingLevel as "off" | "low" | "medium" | "high") || "medium",
      sessionManager: piSessionManager,
      settingsManager,
      resourceLoader: loader,
    });

    // Subscribe to events — feed them through the same pipeline as RPC
    const unsub = piSession.subscribe((event: AgentSessionEvent) => {
      // AgentSessionEvent includes core AgentEvent + session-specific events.
      // Filter to only the core event types that RPC would produce.
      const type = event.type;
      if (
        type === "auto_compaction_start" ||
        type === "auto_compaction_end" ||
        type === "auto_retry_start" ||
        type === "auto_retry_end"
      ) {
        // Session-level events — not in RPC. Skip for now.
        console.log(`${ts()} [sdk] session event: ${type}`);
        return;
      }

      // Core AgentEvent — identical shape to RPC stdout JSON
      onEvent(event);
    });

    console.log(
      `${ts()} [sdk] Session created: model=${piSession.model?.name}, thinking=${piSession.thinkingLevel}`,
    );

    return new SdkBackend(piSession, unsub);
  }

  // ─── Commands (SDK equivalents of RPC stdin) ───

  /** Send a prompt. Fire-and-forget like RPC — events come via subscribe. */
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
