/**
 * Session manager — pi agent lifecycle over RPC.
 *
 * Each session spawns pi inside an Apple container via SandboxManager.
 * Communication uses pi's RPC protocol (JSON lines on stdin/stdout).
 *
 * Handles:
 * - Session lifecycle (start, stop, idle timeout)
 * - RPC event → simplified WebSocket message translation
 * - extension_ui_request forwarding (for permission gate and other extensions)
 * - Response correlation for RPC commands
 */

import { type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { EventEmitter } from "node:events";
import type { Session, SessionMessage, ServerMessage, ServerConfig } from "./types.js";
import type { Storage } from "./storage.js";
import type { GateServer } from "./gate.js";
import type { SandboxManager } from "./sandbox.js";

// ─── Types ───

interface ActiveSession {
  session: Session;
  process: ChildProcess;
  subscribers: Set<(msg: ServerMessage) => void>;
  /** Pending RPC response callbacks keyed by request id */
  pendingResponses: Map<string, (data: any) => void>;
  /** Pending extension UI requests keyed by request id */
  pendingUIRequests: Map<string, ExtensionUIRequest>;
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
  private active: Map<string, ActiveSession> = new Map();
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();
  private rpcIdCounter = 0;

  // Persist active session metadata in batches to avoid sync I/O on every event.
  private dirtySessions: Set<string> = new Set();
  private saveTimer: NodeJS.Timeout | null = null;
  private readonly saveDebounceMs = 1000;

  // Stop-loop safety: if abort does not settle, force-stop the session.
  private abortFallbackTimers: Map<string, NodeJS.Timeout> = new Map();
  private readonly abortFallbackMs = 5000;

  constructor(storage: Storage, gate: GateServer, sandbox: SandboxManager) {
    super();
    this.storage = storage;
    this.config = storage.getConfig();
    this.gate = gate;
    this.sandbox = sandbox;
  }

  // ─── Session Lifecycle ───

  /**
   * Start a new session — spawns pi in a container.
   */
  async startSession(userId: string, sessionId: string): Promise<Session> {
    const key = `${userId}/${sessionId}`;

    if (this.active.has(key)) {
      return this.active.get(key)!.session;
    }

    const session = this.storage.getSession(userId, sessionId);
    if (!session) throw new Error(`Session not found: ${sessionId}`);

    const proc = await this.spawnPi(session);

    const activeSession: ActiveSession = {
      session,
      process: proc,
      subscribers: new Set(),
      pendingResponses: new Map(),
      pendingUIRequests: new Map(),
    };

    this.active.set(key, activeSession);

    session.status = "ready";
    session.lastActivity = Date.now();
    this.persistSessionNow(key, session);
    this.resetIdleTimer(key);

    return session;
  }

  /**
   * Spawn pi inside a container via SandboxManager.
   */
  private async spawnPi(session: Session): Promise<ChildProcess> {
    const key = `${session.userId}/${session.id}`;

    // Create gate TCP socket (extension connects from container to host)
    const gatePort = await this.gate.createSessionSocket(session.id, session.userId);

    // Spawn pi in container
    const proc = this.sandbox.spawnPi({
      sessionId: session.id,
      userId: session.userId,
      model: session.model,
      gatePort,
    });

    // Single readline consumer for stdout — handles all RPC events
    const rl = createInterface({ input: proc.stdout! });
    let readyResolve: (() => void) | null = null;

    rl.on("line", (line) => {
      // If waiting for ready, any valid JSON means pi is up
      if (readyResolve) {
        try {
          const data = JSON.parse(line);
          if (data.type) {
            const resolve = readyResolve;
            readyResolve = null;
            resolve();
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
      console.log(`[pi:${session.id}] exited (${code})`);
      this.handleSessionEnd(key, code === 0 ? "completed" : "error");
    });

    proc.on("error", (err) => {
      console.error(`[pi:${session.id}] spawn error:`, err);
      this.handleSessionEnd(key, "error");
    });

    // Wait for pi to be ready (probe with get_state)
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        readyResolve = null;
        reject(new Error(`Timeout waiting for pi: ${session.id}`));
      }, 30_000);

      readyResolve = () => {
        clearTimeout(timer);
        resolve();
      };

      // Probe readiness after container boot
      setTimeout(() => {
        proc.stdin?.write(JSON.stringify({ type: "get_state" }) + "\n");
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
    const message = this.translateEvent(data, active.session);
    if (message) {
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

    this.sendRpcCommand(key, cmd);
  }

  /**
   * Send a steer message (interrupt agent after current tool).
   */
  async sendSteer(userId: string, sessionId: string, message: string): Promise<void> {
    this.sendRpcCommand(`${userId}/${sessionId}`, { type: "steer", message });
  }

  /**
   * Send a follow-up message (delivered after agent finishes).
   */
  async sendFollowUp(userId: string, sessionId: string, message: string): Promise<void> {
    this.sendRpcCommand(`${userId}/${sessionId}`, { type: "follow_up", message });
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
   */
  private translateEvent(event: any, session: Session): ServerMessage | null {
    switch (event.type) {
      case "agent_start":
        return { type: "agent_start" };

      case "agent_end":
        return { type: "agent_end" };

      case "message_update": {
        const evt = event.assistantMessageEvent;
        if (evt?.type === "text_delta") {
          return { type: "text_delta", delta: evt.delta };
        }
        if (evt?.type === "thinking_delta") {
          return { type: "thinking_delta", delta: evt.delta };
        }
        return null;
      }

      case "tool_execution_start":
        return {
          type: "tool_start",
          tool: event.toolName,
          args: event.args || {},
        };

      case "tool_execution_update": {
        const content = event.partialResult?.content?.[0];
        if (content?.type === "text") {
          return { type: "tool_output", output: content.text };
        }
        return null;
      }

      case "tool_execution_end":
        return {
          type: "tool_end",
          tool: event.toolName,
        };

      case "auto_compaction_start":
        return { type: "tool_start", tool: "__compaction", args: { reason: event.reason } };

      case "auto_compaction_end":
        return { type: "tool_end", tool: "__compaction" };

      case "auto_retry_start":
        return {
          type: "error",
          error: `Retrying (${event.attempt}/${event.maxAttempts}): ${event.errorMessage}`,
        };

      case "extension_error":
        console.error(`[pi:${session.id}] extension error: ${event.extensionPath}: ${event.error}`);
        return null;

      case "response":
        // Uncorrelated responses (no id) — ignore unless error
        if (!event.success) {
          return { type: "error", error: `${event.command}: ${event.error}` };
        }
        return null;

      default:
        return null;
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

  private extractUsage(message: any): { input: number; output: number; cost: number } | null {
    const usage = message?.usage;
    if (!usage) {
      return null;
    }

    return {
      input: usage.input || 0,
      output: usage.output || 0,
      cost: usage.cost?.total || 0,
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

    // Clean up gate socket
    this.gate.destroySessionSocket(active.session.id);

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

    // Wait briefly then stop container
    await new Promise(r => setTimeout(r, 1000));
    await this.sandbox.stopContainer(sessionId);

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
