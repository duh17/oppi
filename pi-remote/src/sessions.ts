/**
 * Session manager — pi agent lifecycle over RPC.
 *
 * Two runtime modes:
 *   host:      pi runs directly on the Mac as a child process.
 *   container: pi runs inside an Apple container via SandboxManager.
 *
 * Both modes use the same RPC protocol (JSON lines on stdin/stdout),
 * permission gate (TCP), and WebSocket bridge. The iOS app sees no
 * difference.
 *
 * Handles:
 * - Session lifecycle (start, stop, idle timeout)
 * - RPC event → simplified WebSocket message translation
 * - extension_ui_request forwarding (for permission gate and other extensions)
 * - Response correlation for RPC commands
 */

import { execSync, spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { EventEmitter } from "node:events";
import { homedir } from "node:os";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Session, SessionMessage, ServerMessage, ServerConfig, Workspace } from "./types.js";
import type { Storage } from "./storage.js";
import type { GateServer } from "./gate.js";
import type { SandboxManager } from "./sandbox.js";
import type { AuthProxy } from "./auth-proxy.js";

// ─── Types ───

interface ActiveSession {
  session: Session;
  process: ChildProcess;
  /** Runtime mode — determines how to stop the process. */
  runtime: "host" | "container";
  subscribers: Set<(msg: ServerMessage) => void>;
  /** Pending RPC response callbacks keyed by request id */
  pendingResponses: Map<string, (data: any) => void>;
  /** Pending extension UI requests keyed by request id */
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  /** Whether the post-first-prompt guard health check has been scheduled. */
  guardCheckScheduled?: boolean;
  /**
   * Tracks last partialResult text per toolCallId for delta computation.
   *
   * Pi RPC tool_execution_update sends partialResult with replace semantics
   * (accumulated output so far). We compute deltas here so the client can
   * use simple append semantics for tool_output events.
   */
  partialResults: Map<string, string>;
}

/** Extension UI request from pi RPC (stdout) */
export interface ExtensionUIRequest {
  type: "extension_ui_request";
  id: string;
  method: string;
  title?: string;
  options?: string[];
  message?: string;
  placeholder?: string;
  prefill?: string;
  notifyType?: "info" | "warning" | "error";
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: string;
  text?: string;
  timeout?: number;
}

/** Extension UI response to send to pi (stdin) */
export interface ExtensionUIResponse {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

/** Fire-and-forget UI methods (no response needed) */
const FIRE_AND_FORGET_METHODS = new Set([
  "notify", "setStatus", "setWidget", "setTitle", "set_editor_text",
]);

// ─── Session Manager ───

export class SessionManager extends EventEmitter {
  private storage: Storage;
  private config: ServerConfig;
  private gate: GateServer;
  private sandbox: SandboxManager;
  private authProxy: AuthProxy | null;
  private active: Map<string, ActiveSession> = new Map();
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  private rpcIdCounter = 0;
  private readonly piExecutable: string;

  // Persist active session metadata in batches to avoid sync I/O on every event.
  private dirtySessions: Set<string> = new Set();
  private saveTimer: NodeJS.Timeout | null = null;
  private readonly saveDebounceMs = 1000;

  // Stop-loop safety: if abort does not settle, force-stop the session.
  private abortFallbackTimers: Map<string, NodeJS.Timeout> = new Map();
  private readonly abortFallbackMs = 5000;

  constructor(storage: Storage, gate: GateServer, sandbox: SandboxManager, authProxy?: AuthProxy) {
    super();
    this.storage = storage;
    this.config = storage.getConfig();
    this.gate = gate;
    this.sandbox = sandbox;
    this.authProxy = authProxy ?? null;
    this.piExecutable = this.resolvePiExecutable();
  }

  // ─── Session Lifecycle ───

  /**
   * Start a new session — spawns pi on the host or in a container.
   */
  async startSession(userId: string, sessionId: string, userName?: string, workspace?: Workspace): Promise<Session> {
    const key = `${userId}/${sessionId}`;

    if (this.active.has(key)) {
      return this.active.get(key)!.session;
    }

    const session = this.storage.getSession(userId, sessionId);
    if (!session) throw new Error(`Session not found: ${sessionId}`);

    const runtime = workspace?.runtime ?? "host";
    const proc = runtime === "host"
      ? await this.spawnPiHost(session, workspace)
      : await this.spawnPiContainer(session, userName, workspace);

    // Validate sandbox (container mode only — host mode has no sandbox to validate)
    if (runtime === "container") {
      const { errors, warnings } = this.sandbox.validateSession(
        userId, sessionId, { memoryEnabled: workspace?.memoryEnabled },
      );

      if (errors.length > 0) {
        for (const e of errors) console.error(`[session:${sessionId}] bootstrap error: ${e}`);
        for (const w of warnings) console.warn(`[session:${sessionId}] bootstrap warning: ${w}`);
        session.status = "error";
        session.warnings = [...errors, ...warnings];
        this.storage.saveSession(session);
        await this.sandbox.stopContainer(sessionId);
        this.gate.destroySessionSocket(sessionId);
        throw new Error(`Session bootstrap failed: ${errors[0]}`);
      }

      if (warnings.length > 0) {
        session.warnings = warnings;
        for (const w of warnings) console.warn(`[session:${sessionId}] bootstrap warning: ${w}`);
      }
    }

    const activeSession: ActiveSession = {
      session,
      process: proc,
      runtime,
      subscribers: new Set(),
      pendingResponses: new Map(),
      pendingUIRequests: new Map(),
      partialResults: new Map(),
    };

    this.active.set(key, activeSession);

    session.status = "ready";
    session.runtime = runtime;
    session.lastActivity = Date.now();
    this.persistSessionNow(key, session);
    this.resetIdleTimer(key);

    // Best-effort: capture pi session file/UUID from get_state so trace
    // loading works for host runtime sessions too.
    void this.bootstrapSessionState(key);

    return session;
  }

  /**
   * Resolve the pi executable path for host runtime sessions.
   *
   * tmux/systemd launches may have a minimal PATH that does not include npm
   * global bins. Prefer an explicit env override, then common install paths.
   */
  private resolvePiExecutable(): string {
    const envPath = process.env.PI_REMOTE_PI_BIN;
    if (envPath && existsSync(envPath)) {
      return envPath;
    }

    try {
      const discovered = execSync("which pi", { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      if (discovered.length > 0) {
        return discovered;
      }
    } catch {
      // Fall through to known locations
    }

    for (const candidate of ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"]) {
      if (existsSync(candidate)) {
        return candidate;
      }
    }

    // Final fallback; spawn will surface ENOENT with actionable logs.
    return "pi";
  }

  /**
   * Spawn pi directly on the host — no container, no sandbox.
   *
   * Pi runs as the current user with full access to the host filesystem.
   * The permission gate is the only security layer.
   */
  private async spawnPiHost(session: Session, workspace?: Workspace): Promise<ChildProcess> {
    const key = `${session.userId}/${session.id}`;

    // Create gate TCP socket (extension connects via localhost)
    const gatePort = await this.gate.createSessionSocket(session.id, session.userId);

    // Build pi args
    const piArgs = ["--mode", "rpc"];
    if (session.model) {
      const slash = session.model.indexOf("/");
      if (slash > 0) {
        piArgs.push("--provider", session.model.slice(0, slash));
        piArgs.push("--model", session.model.slice(slash + 1));
      } else {
        piArgs.push("--model", session.model);
      }
    }

    // Resolve system prompt if workspace provides one
    if (workspace?.systemPrompt) {
      const { mkdirSync, writeFileSync } = await import("node:fs");
      const promptDir = join(homedir(), ".config", "pi-remote", "prompts");
      mkdirSync(promptDir, { recursive: true });
      const promptPath = join(promptDir, `${session.id}.md`);
      writeFileSync(promptPath, workspace.systemPrompt);
      piArgs.push("--append-system-prompt", promptPath);
    }

    // Working directory — workspace hostMount or home
    const cwd = workspace?.hostMount
      ? workspace.hostMount.replace(/^~/, homedir())
      : homedir();

    if (!existsSync(cwd)) {
      throw new Error(`Host workspace path not found: ${cwd}`);
    }

    console.log(`[session:${session.id}] spawning pi (host mode) in ${cwd} via ${this.piExecutable}`);

    const proc = spawn(this.piExecutable, piArgs, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        PI_REMOTE_SESSION: session.id,
        PI_REMOTE_USER: session.userId,
        PI_REMOTE_GATE_HOST: "127.0.0.1",
        PI_REMOTE_GATE_PORT: String(gatePort),
      },
    });

    return this.setupProcHandlers(key, session, proc);
  }

  /**
   * Spawn pi inside a container via SandboxManager.
   */
  private async spawnPiContainer(session: Session, userName?: string, workspace?: Workspace): Promise<ChildProcess> {
    const key = `${session.userId}/${session.id}`;

    // Register session with auth proxy (proxy validates session tokens on API requests)
    this.authProxy?.registerSession(session.id, session.userId);

    // Create gate TCP socket (extension connects from container to host-gateway)
    const gatePort = await this.gate.createSessionSocket(session.id, session.userId);

    // Spawn pi in container
    const proc = this.sandbox.spawnPi({
      sessionId: session.id,
      userId: session.userId,
      userName,
      model: session.model,
      workspace,
      gatePort,
    });

    return this.setupProcHandlers(key, session, proc);
  }

  /**
   * Wire up RPC line handling, stderr logging, exit/error handlers,
   * and wait for pi to be ready. Shared by host and container modes.
   */
  private async setupProcHandlers(key: string, session: Session, proc: ChildProcess): Promise<ChildProcess> {
    // Single readline consumer for stdout — handles all RPC events
    const rl = createInterface({ input: proc.stdout! });
    let readyResolve: (() => void) | null = null;
    let readyReject: ((err: Error) => void) | null = null;

    const settleReady = (err?: Error): void => {
      if (err) {
        const reject = readyReject;
        readyResolve = null;
        readyReject = null;
        reject?.(err);
        return;
      }

      const resolve = readyResolve;
      readyResolve = null;
      readyReject = null;
      resolve?.();
    };

    rl.on("line", (line) => {
      // If waiting for ready, any valid JSON means pi is up
      if (readyResolve || readyReject) {
        try {
          const data = JSON.parse(line);
          if (data.type) {
            settleReady();
          }
        } catch {}
      }
      // Always route to handler (no messages lost)
      this.handleRpcLine(key, line);
    });

    // stderr → log
    proc.stderr?.on("data", (data: Buffer) => {
      console.error(`[pi:${session.id}] ${data.toString().trim()}`);
    });

    // Process exit
    proc.on("exit", (code) => {
      if (readyReject) {
        settleReady(new Error(`pi exited before ready: ${session.id} (${code ?? "null"})`));
      }
      console.log(`[pi:${session.id}] exited (${code})`);
      this.handleSessionEnd(key, code === 0 ? "completed" : "error");
    });

    proc.on("error", (err) => {
      if (readyReject) {
        settleReady(new Error(`pi spawn error before ready: ${session.id} (${err.message})`));
      }
      console.error(`[pi:${session.id}] spawn error:`, err);
      this.handleSessionEnd(key, "error");
    });

    // Wait for pi to be ready (probe with get_state)
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        settleReady(new Error(`Timeout waiting for pi: ${session.id}`));
      }, 30_000);

      readyResolve = () => {
        clearTimeout(timer);
        resolve();
      };
      readyReject = (err) => {
        clearTimeout(timer);
        reject(err);
      };

      // Probe readiness
      setTimeout(() => {
        if (!proc.killed) {
          proc.stdin?.write(JSON.stringify({ type: "get_state" }) + "\n");
        }
      }, 500);
    });

    return proc;
  }

  // ─── RPC Line Handler ───

  /**
   * Handle a single JSON line from pi's stdout.
   * Dispatches to: response handler, extension UI, or event translation.
   */
  private handleRpcLine(key: string, line: string): void {
    const active = this.active.get(key);
    if (!active) return;

    let data: any;
    try {
      data = JSON.parse(line);
    } catch {
      console.warn(`[pi:${active.session.id}] invalid JSON: ${line.slice(0, 100)}`);
      return;
    }

    // 1. RPC response — correlate to pending command
    if (data.type === "response" && data.id) {
      const handler = active.pendingResponses.get(data.id);
      if (handler) {
        active.pendingResponses.delete(data.id);
        handler(data);
      }
      // Still forward errors to subscribers
      if (!data.success) {
        this.broadcast(key, { type: "error", error: `${data.command}: ${data.error}` });
      }
      return;
    }

    // 2. Extension UI request — forward to subscribers (phone handles it)
    if (data.type === "extension_ui_request") {
      this.handleExtensionUIRequest(key, data as ExtensionUIRequest);
      return;
    }

    // 3. Agent event — translate and broadcast
    const messages = this.translateEvent(data, active);
    for (const message of messages) {
      this.broadcast(key, message);
    }

    this.updateSessionFromEvent(key, active.session, data);

    if (
      data.type === "agent_start"
      || data.type === "agent_end"
      || data.type === "message_end"
    ) {
      this.broadcast(key, { type: "state", session: active.session });
    }

    this.resetIdleTimer(key);
  }

  // ─── Extension UI Protocol ───

  /**
   * Handle extension_ui_request from pi.
   * Fire-and-forget methods are forwarded as notifications.
   * Dialog methods (select, confirm, input, editor) are forwarded
   * to the phone and held until respondToUIRequest() is called.
   */
  private handleExtensionUIRequest(key: string, req: ExtensionUIRequest): void {
    const active = this.active.get(key);
    if (!active) return;

    if (FIRE_AND_FORGET_METHODS.has(req.method)) {
      // Forward as notification (pick relevant fields)
      this.broadcast(key, {
        type: "extension_ui_notification",
        method: req.method,
        message: req.message,
        notifyType: req.notifyType,
        statusKey: req.statusKey,
        statusText: req.statusText,
      } as any);
      return;
    }

    // Dialog method — track and forward to phone
    active.pendingUIRequests.set(req.id, req);
    this.broadcast(key, {
      type: "extension_ui_request",
      id: req.id,
      sessionId: active.session.id,
      method: req.method,
      title: req.title,
      options: req.options,
      message: req.message,
      placeholder: req.placeholder,
      prefill: req.prefill,
      timeout: req.timeout,
    } as any);
  }

  /**
   * Send extension_ui_response back to pi on stdin.
   * Called by server.ts when phone responds to a UI dialog.
   */
  respondToUIRequest(userId: string, sessionId: string, response: ExtensionUIResponse): boolean {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) return false;

    const req = active.pendingUIRequests.get(response.id);
    if (!req) return false;

    active.pendingUIRequests.delete(response.id);
    active.process.stdin?.write(JSON.stringify(response) + "\n");
    return true;
  }

  // ─── RPC Commands ───

  /**
   * Keep active in-memory session metadata in sync when server.ts stores
   * a user message directly.
   */
  recordUserMessage(userId: string, sessionId: string, content: string, timestamp: number): void {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) {
      return;
    }

    active.session.messageCount += 1;
    active.session.lastMessage = content.slice(0, 100);
    active.session.lastActivity = timestamp;
  }

  /**
   * Send a prompt to pi. Handles streaming state.
   *
   * RPC rules:
   * - If agent is idle: send as `prompt`
   * - If agent is streaming: must specify behavior
   */
  async sendPrompt(
    userId: string,
    sessionId: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
    },
  ): Promise<void> {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) throw new Error(`Session not active: ${sessionId}`);

    const cmd: Record<string, unknown> = {
      type: "prompt",
      message,
    };

    // RPC image format: {type:"image", data:"base64...", mimeType:"image/png"}
    if (opts?.images?.length) {
      cmd.images = opts.images;
    }

    // If agent is busy, add streaming behavior
    if (active.session.status === "busy" && opts?.streamingBehavior) {
      cmd.streamingBehavior = opts.streamingBehavior;
    }

    // Schedule guard health check after first prompt.
    // Extension connects in before_agent_start (triggered by first prompt),
    // so we can't check earlier.
    if (!active.guardCheckScheduled) {
      active.guardCheckScheduled = true;
      this.scheduleGuardCheck(key, sessionId);
    }

    this.sendRpcCommand(key, cmd);
  }

  /**
   * Send a steer message (interrupt agent after current tool).
   */
  async sendSteer(
    userId: string,
    sessionId: string,
    message: string,
    images?: Array<{ type: "image"; data: string; mimeType: string }>,
  ): Promise<void> {
    const cmd: Record<string, unknown> = { type: "steer", message };
    if (images?.length) cmd.images = images;
    this.sendRpcCommand(`${userId}/${sessionId}`, cmd);
  }

  /**
   * Send a follow-up message (delivered after agent finishes).
   */
  async sendFollowUp(
    userId: string,
    sessionId: string,
    message: string,
    images?: Array<{ type: "image"; data: string; mimeType: string }>,
  ): Promise<void> {
    const cmd: Record<string, unknown> = { type: "follow_up", message };
    if (images?.length) cmd.images = images;
    this.sendRpcCommand(`${userId}/${sessionId}`, cmd);
  }

  /**
   * Best-effort bootstrap of pi session metadata (session file/UUID).
   *
   * Needed so stopped host sessions can still reconstruct trace history.
   */
  private async bootstrapSessionState(key: string): Promise<void> {
    const active = this.active.get(key);
    if (!active) return;

    try {
      const data = await this.sendRpcCommandAsync(key, { type: "get_state" }, 8_000);
      if (this.applyPiStateSnapshot(active.session, data)) {
        this.persistSessionNow(key, active.session);
      }
    } catch {
      // Non-fatal; history falls back to stored SessionMessage list.
    }
  }

  /**
   * Refresh live pi state for an active session and return trace metadata.
   * Used by REST trace endpoint to recover host-session traces.
   */
  async refreshSessionState(
    userId: string,
    sessionId: string,
  ): Promise<{ sessionFile?: string; sessionId?: string } | null> {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) return null;

    try {
      const data = await this.sendRpcCommandAsync(key, { type: "get_state" }, 8_000);
      if (this.applyPiStateSnapshot(active.session, data)) {
        this.persistSessionNow(key, active.session);
      }
      return {
        sessionFile: active.session.piSessionFile,
        sessionId: active.session.piSessionId,
      };
    } catch {
      return null;
    }
  }

  /**
   * Apply fields we care about from pi `get_state` response payload.
   * Returns true if the session object changed.
   */
  private applyPiStateSnapshot(session: Session, state: any): boolean {
    if (!state || typeof state !== "object") {
      return false;
    }

    let changed = false;

    if (typeof state.sessionFile === "string" && state.sessionFile.length > 0) {
      if (session.piSessionFile !== state.sessionFile) {
        session.piSessionFile = state.sessionFile;
        changed = true;
      }

      const knownFiles = new Set(session.piSessionFiles || []);
      if (!knownFiles.has(state.sessionFile)) {
        session.piSessionFiles = [...knownFiles, state.sessionFile];
        changed = true;
      }
    }

    if (typeof state.sessionId === "string" && state.sessionId.length > 0) {
      if (session.piSessionId !== state.sessionId) {
        session.piSessionId = state.sessionId;
        changed = true;
      }
    }

    if (typeof state.sessionName === "string") {
      const nextName = state.sessionName.trim();
      if (nextName.length > 0 && session.name !== nextName) {
        session.name = nextName;
        changed = true;
      }
    }

    const modelId = state.model?.id;
    if (typeof modelId === "string" && modelId.length > 0 && session.model !== modelId) {
      session.model = modelId;
      changed = true;
    }

    return changed;
  }

  // ─── RPC Passthrough ───

  /**
   * Allowlisted RPC commands that can be forwarded from the client.
   * Each maps to the pi RPC command type. Fire-and-forget commands
   * (no response needed) are sent without correlation. Commands that
   * return data are awaited and the result broadcast as rpc_result.
   */
  private static readonly RPC_PASSTHROUGH: ReadonlySet<string> = new Set([
    // State
    "get_state", "get_messages", "get_session_stats",
    // Model
    "set_model", "cycle_model", "get_available_models",
    // Thinking
    "set_thinking_level", "cycle_thinking_level",
    // Session
    "new_session", "set_session_name", "compact", "set_auto_compaction",
    "fork", "get_fork_messages", "switch_session",
    // Queue modes
    "set_steering_mode", "set_follow_up_mode",
    // Retry
    "set_auto_retry", "abort_retry",
    // Bash
    "bash", "abort_bash",
    // Commands
    "get_commands",
  ]);

  /**
   * Forward a client WebSocket message to pi as an RPC command.
   *
   * Used for commands that map 1:1 to pi RPC (model switching,
   * thinking level, session management, etc.). The response is
   * broadcast back as an `rpc_result` ServerMessage.
   */
  async forwardRpcCommand(
    userId: string,
    sessionId: string,
    message: Record<string, unknown>,
    requestId?: string,
  ): Promise<void> {
    const cmdType = message.type as string;
    if (!SessionManager.RPC_PASSTHROUGH.has(cmdType)) {
      throw new Error(`Command not allowed: ${cmdType}`);
    }

    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) throw new Error(`Session not active: ${sessionId}`);

    try {
      const data = await this.sendRpcCommandAsync(key, { ...message }, 30_000);

      if (cmdType === "get_state") {
        if (this.applyPiStateSnapshot(active.session, data)) {
          this.persistSessionNow(key, active.session);
        }
      }

      this.broadcast(key, {
        type: "rpc_result",
        command: cmdType,
        requestId,
        success: true,
        data,
      });
    } catch (err) {
      this.broadcast(key, {
        type: "rpc_result",
        command: cmdType,
        requestId,
        success: false,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  /**
   * Abort the current agent operation.
   *
   * If abort does not settle promptly, force-stop the session to break loops.
   */
  async sendAbort(userId: string, sessionId: string): Promise<void> {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) {
      return;
    }

    this.sendRpcCommand(key, { type: "abort" });

    if (active.session.status === "busy") {
      this.scheduleAbortFallback(key, userId, sessionId);
    }
  }

  private scheduleAbortFallback(key: string, userId: string, sessionId: string): void {
    this.clearAbortFallback(key);

    const timer = setTimeout(() => {
      this.abortFallbackTimers.delete(key);

      const active = this.active.get(key);
      if (!active || active.session.status !== "busy") {
        return;
      }

      console.warn(`[session] abort timeout, force-stopping ${key}`);
      this.broadcast(key, {
        type: "error",
        error: "Stop request timed out. Session was force-stopped.",
      });
      void this.stopSession(userId, sessionId);
    }, this.abortFallbackMs);

    this.abortFallbackTimers.set(key, timer);
  }

  private clearAbortFallback(key: string): void {
    const timer = this.abortFallbackTimers.get(key);
    if (!timer) {
      return;
    }

    clearTimeout(timer);
    this.abortFallbackTimers.delete(key);
  }

  // ─── Guard Health Check ───

  /** Guard check delay — extension should connect within seconds of first prompt. */
  private readonly guardCheckDelayMs = 10_000;

  /**
   * After the first prompt, check that the permission gate extension
   * connected and reached "guarded" state. If not, surface a warning.
   *
   * Why after first prompt: the extension connects in `before_agent_start`
   * which only fires when pi processes its first prompt.
   */
  private scheduleGuardCheck(key: string, sessionId: string): void {
    setTimeout(() => {
      const active = this.active.get(key);
      if (!active) return; // Session already ended

      const state = this.gate.getGuardState(sessionId);
      if (state === "guarded") return; // Healthy

      const warning = `Permission gate not connected (state: ${state}). Tool calls will be blocked.`;
      if (!active.session.warnings) active.session.warnings = [];
      if (!active.session.warnings.includes(warning)) {
        active.session.warnings.push(warning);
        console.warn(`[session:${sessionId}] ${warning}`);
        this.broadcast(key, { type: "state", session: active.session });
        this.persistSessionNow(key, active.session);
      }
    }, this.guardCheckDelayMs);
  }

  // ─── RPC Commands ───

  /**
   * Send a raw RPC command and optionally wait for its response.
   */
  sendRpcCommand(key: string, command: Record<string, unknown>): void {
    const active = this.active.get(key);
    if (!active) return;

    // Assign correlation id if not present
    if (!command.id) {
      command.id = `rpc-${++this.rpcIdCounter}`;
    }

    active.process.stdin?.write(JSON.stringify(command) + "\n");
    this.resetIdleTimer(key);
  }

  /**
   * Send RPC command and await the response.
   */
  sendRpcCommandAsync(key: string, command: Record<string, unknown>, timeoutMs = 10_000): Promise<any> {
    const active = this.active.get(key);
    if (!active) return Promise.reject(new Error("Session not active"));

    const id = `rpc-${++this.rpcIdCounter}`;
    command.id = id;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        active.pendingResponses.delete(id);
        reject(new Error(`RPC timeout: ${command.type}`));
      }, timeoutMs);

      active.pendingResponses.set(id, (data) => {
        clearTimeout(timer);
        if (data.success) {
          resolve(data.data);
        } else {
          reject(new Error(data.error || `RPC failed: ${command.type}`));
        }
      });

      active.process.stdin?.write(JSON.stringify(command) + "\n");
    });
  }

  // ─── Event Translation ───

  /**
   * Translate pi RPC events to our simplified WebSocket format.
   *
   * Tool events plumb the stable toolCallId from pi RPC so the client can
   * correlate tool_start/tool_output/tool_end without synthesizing IDs.
   *
   * partialResult handling: pi RPC tool_execution_update sends partialResult
   * with replace semantics (accumulated output so far). We compute deltas
   * here so the client can use simple append semantics.
   *
   * Image handling: pi's Read tool returns image files as content blocks with
   * type "image" (base64 + mimeType). We encode these as data URIs in the
   * tool_output text so the iOS ImageExtractor can detect and render them.
   */
  private translateEvent(event: any, active: ActiveSession): ServerMessage[] {
    const session = active.session;

    switch (event.type) {
      case "agent_start":
        return [{ type: "agent_start" }];

      case "agent_end":
        return [{ type: "agent_end" }];

      case "message_update": {
        const evt = event.assistantMessageEvent;
        if (evt?.type === "text_delta") {
          return [{ type: "text_delta", delta: evt.delta }];
        }
        if (evt?.type === "thinking_delta") {
          return [{ type: "thinking_delta", delta: evt.delta }];
        }
        return [];
      }

      case "tool_execution_start":
        return [{
          type: "tool_start",
          tool: event.toolName,
          args: event.args || {},
          toolCallId: event.toolCallId,
        }];

      case "tool_execution_update": {
        const contents = event.partialResult?.content;
        if (!Array.isArray(contents) || contents.length === 0) return [];

        const toolCallId: string | undefined = event.toolCallId;
        const messages: ServerMessage[] = [];

        for (const block of contents) {
          if (block.type === "text") {
            const fullText: string = block.text;

            // Compute delta from last partialResult to avoid duplication.
            // partialResult is accumulated (replace semantics) — we convert
            // to delta so the client can append without duplicating output.
            const key = toolCallId ?? "";
            const lastText = active.partialResults.get(key) ?? "";
            active.partialResults.set(key, fullText);
            const delta = fullText.slice(lastText.length);

            if (delta) {
              messages.push({ type: "tool_output", output: delta, toolCallId });
            }
          } else if (block.type === "image" && block.data) {
            // Encode image as data URI so iOS ImageExtractor can detect it.
            // Pi sends: { type: "image", data: "base64...", mimeType: "image/png" }
            const mime = block.mimeType || "image/png";
            const dataUri = `data:${mime};base64,${block.data}`;
            messages.push({ type: "tool_output", output: dataUri, toolCallId });
          }
        }

        return messages;
      }

      case "tool_execution_end": {
        const toolCallId: string | undefined = event.toolCallId;
        active.partialResults.delete(toolCallId ?? "");
        return [{
          type: "tool_end",
          tool: event.toolName,
          toolCallId,
        }];
      }

      case "auto_compaction_start":
        return [{ type: "compaction_start", reason: event.reason ?? "threshold" }];

      case "auto_compaction_end":
        return [{
          type: "compaction_end",
          aborted: event.aborted ?? false,
          willRetry: event.willRetry ?? false,
          summary: event.result?.summary,
          tokensBefore: event.result?.tokensBefore,
        }];

      case "auto_retry_start":
        return [{
          type: "retry_start",
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
        }];

      case "auto_retry_end":
        return [{
          type: "retry_end",
          success: event.success,
          attempt: event.attempt,
          finalError: event.finalError,
        }];

      case "extension_error":
        console.error(`[pi:${session.id}] extension error: ${event.extensionPath}: ${event.error}`);
        return [];

      case "response":
        // Uncorrelated responses (no id) — ignore unless error
        if (!event.success) {
          return [{ type: "error", error: `${event.command}: ${event.error}` }];
        }
        return [];

      default:
        return [];
    }
  }

  /**
   * Update session state from pi events.
   */
  private updateSessionFromEvent(key: string, session: Session, event: any): void {
    let shouldFlushNow = false;

    switch (event.type) {
      case "agent_start":
        session.status = "busy";
        break;

      case "agent_end":
        session.status = "ready";
        this.clearAbortFallback(key);
        shouldFlushNow = true;
        break;

      case "message_end": {
        const message = event.message;
        const role = message?.role;

        // Only persist assistant messages — user messages are already stored on prompt receipt
        if (role === "user") break;

        const usage = this.extractUsage(message);
        const assistantText = this.extractAssistantText(message);

        if (assistantText) {
          const tokens = usage
            ? { input: usage.input, output: usage.output }
            : undefined;

          this.appendMessage(session, {
            role: "assistant",
            content: assistantText,
            timestamp: Date.now(),
            model: session.model,
            tokens,
            cost: usage?.cost,
          });
        } else if (usage) {
          session.tokens.input += usage.input;
          session.tokens.output += usage.output;
          session.cost += usage.cost;
        }

        // Track context usage for status display (matches pi TUI calculation)
        if (usage) {
          session.contextTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
        }
        break;
      }
    }

    session.lastActivity = Date.now();

    if (shouldFlushNow) {
      this.persistSessionNow(key, session);
      return;
    }

    this.markSessionDirty(key);
  }

  private appendMessage(
    session: Session,
    message: Omit<SessionMessage, "id" | "sessionId">,
  ): void {
    this.storage.addSessionMessage(session.userId, session.id, message);

    // Keep the active in-memory session aligned with persisted stats.
    session.messageCount += 1;
    session.lastMessage = message.content.slice(0, 100);
    session.lastActivity = message.timestamp;

    if (message.tokens) {
      session.tokens.input += message.tokens.input;
      session.tokens.output += message.tokens.output;
    }

    if (message.cost) {
      session.cost += message.cost;
    }
  }

  private extractAssistantText(message: any): string {
    const content = message?.content;

    if (typeof content === "string") {
      return content;
    }

    if (!Array.isArray(content)) {
      return "";
    }

    const textParts: string[] = [];
    for (const part of content) {
      const isTextPart = part?.type === "text" || part?.type === "output_text";
      if (isTextPart && typeof part.text === "string") {
        textParts.push(part.text);
      }
    }

    return textParts.join("");
  }

  private extractUsage(message: any): {
    input: number;
    output: number;
    cost: number;
    cacheRead: number;
    cacheWrite: number;
  } | null {
    const usage = message?.usage;
    if (!usage) {
      return null;
    }

    return {
      input: usage.input || 0,
      output: usage.output || 0,
      cost: usage.cost?.total || 0,
      cacheRead: usage.cacheRead || 0,
      cacheWrite: usage.cacheWrite || 0,
    };
  }

  private markSessionDirty(key: string): void {
    this.dirtySessions.add(key);

    if (this.saveTimer) {
      return;
    }

    this.saveTimer = setTimeout(() => {
      this.flushDirtySessions();
    }, this.saveDebounceMs);
  }

  private flushDirtySessions(): void {
    const keys = Array.from(this.dirtySessions);
    this.dirtySessions.clear();
    this.saveTimer = null;

    for (const key of keys) {
      const active = this.active.get(key);
      if (!active) {
        continue;
      }

      this.storage.saveSession(active.session);
    }
  }

  private persistSessionNow(key: string, session: Session): void {
    this.dirtySessions.delete(key);
    this.storage.saveSession(session);
  }

  // ─── Session End ───

  private handleSessionEnd(key: string, reason: string): void {
    const active = this.active.get(key);
    if (!active) return;

    active.session.status = "stopped";
    this.persistSessionNow(key, active.session);

    // Clean up gate socket and auth proxy registration
    this.gate.destroySessionSocket(active.session.id);
    this.authProxy?.removeSession(active.session.id);

    // Reject pending RPC responses
    for (const [id, handler] of active.pendingResponses) {
      handler({ success: false, error: "Session ended" });
    }
    active.pendingResponses.clear();

    // Cancel pending UI requests
    for (const [id] of active.pendingUIRequests) {
      active.process.stdin?.write(JSON.stringify({
        type: "extension_ui_response",
        id,
        cancelled: true,
      }) + "\n");
    }
    active.pendingUIRequests.clear();

    this.broadcast(key, { type: "session_ended", reason });
    this.clearIdleTimer(key);
    this.clearAbortFallback(key);
    this.active.delete(key);
  }

  // ─── Subscribe / Broadcast ───

  subscribe(userId: string, sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (active) {
      active.subscribers.add(callback);
      return () => active.subscribers.delete(callback);
    }
    return () => {};
  }

  private broadcast(key: string, message: ServerMessage): void {
    const active = this.active.get(key);
    if (!active) return;
    for (const cb of active.subscribers) {
      try { cb(message); } catch (err) { console.error("Subscriber error:", err); }
    }
  }

  // ─── Stop ───

  async stopSession(userId: string, sessionId: string): Promise<void> {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    if (!active) return;

    this.clearAbortFallback(key);

    // Graceful: abort current operation
    try {
      active.process.stdin?.write(JSON.stringify({ type: "abort" }) + "\n");
    } catch {}

    // Wait briefly then stop
    await new Promise(r => setTimeout(r, 1000));

    if (active.runtime === "host") {
      // Host mode: kill the process directly
      if (!active.process.killed) {
        active.process.kill("SIGTERM");
      }
    } else {
      // Container mode: stop via sandbox
      await this.sandbox.stopContainer(sessionId);
    }

    this.handleSessionEnd(key, "stopped");
  }

  async stopAll(): Promise<void> {
    const keys = Array.from(this.active.keys());
    await Promise.all(
      keys.map(key => {
        const [userId, sessionId] = key.split("/");
        return this.stopSession(userId, sessionId);
      }),
    );
  }

  // ─── State Queries ───

  isActive(userId: string, sessionId: string): boolean {
    return this.active.has(`${userId}/${sessionId}`);
  }

  getActiveSession(userId: string, sessionId: string): Session | undefined {
    return this.active.get(`${userId}/${sessionId}`)?.session;
  }

  hasPendingUIRequest(userId: string, sessionId: string, requestId: string): boolean {
    const active = this.active.get(`${userId}/${sessionId}`);
    return active?.pendingUIRequests.has(requestId) ?? false;
  }

  // ─── Idle Management ───

  private resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);
    const timer = setTimeout(() => {
      console.log(`[session] idle timeout: ${key}`);
      const [userId, sessionId] = key.split("/");
      this.stopSession(userId, sessionId);
    }, this.config.sessionTimeout);
    this.idleTimers.set(key, timer);
  }

  private clearIdleTimer(key: string): void {
    const timer = this.idleTimers.get(key);
    if (timer) {
      clearTimeout(timer);
      this.idleTimers.delete(key);
    }
  }
}
