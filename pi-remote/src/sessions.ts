/**
 * Session manager - handles pi sandbox processes
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { EventEmitter } from "node:events";
import { cpSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { Session, ServerMessage, ServerConfig } from "./types.js";
import type { Storage } from "./storage.js";
import type { GateServer } from "./gate.js";

interface ActiveSession {
  session: Session;
  process: ChildProcess;
  subscribers: Set<(msg: ServerMessage) => void>;
}

// Path to bundled permission-gate extension
const EXTENSION_SRC_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "extensions", "permission-gate");

export class SessionManager extends EventEmitter {
  private storage: Storage;
  private config: ServerConfig;
  private gate: GateServer;
  private active: Map<string, ActiveSession> = new Map();
  private idleTimers: Map<string, NodeJS.Timeout> = new Map();

  constructor(storage: Storage, gate: GateServer) {
    super();
    this.storage = storage;
    this.config = storage.getConfig();
    this.gate = gate;
  }

  /**
   * Start a new session
   */
  async startSession(userId: string, sessionId: string): Promise<Session> {
    const key = `${userId}/${sessionId}`;
    
    // Check if already running
    if (this.active.has(key)) {
      return this.active.get(key)!.session;
    }

    // Get or create session record
    let session = this.storage.getSession(userId, sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Spawn pi process
    const process = await this.spawnPi(session);
    
    const activeSession: ActiveSession = {
      session,
      process,
      subscribers: new Set(),
    };

    this.active.set(key, activeSession);

    // Update status
    session.status = "ready";
    session.lastActivity = Date.now();
    this.storage.saveSession(session);

    // Set idle timeout
    this.resetIdleTimer(key);

    return session;
  }

  /**
   * Spawn pi in RPC mode (via sandbox)
   * Each user gets their own isolated sandbox environment
   */
  private async spawnPi(session: Session): Promise<ChildProcess> {
    const args = ["--mode", "rpc"];
    
    if (session.model) {
      const [provider, model] = session.model.includes("/") 
        ? session.model.split("/", 2)
        : [undefined, session.model];
      
      if (provider) args.push("--provider", provider);
      args.push("--model", model);
    }

    // Get user-specific sandbox directories
    const userSandboxDir = this.storage.getUserSandboxDir(session.userId);
    const userWorkspaceDir = this.storage.getUserWorkspaceDir(session.userId);

    // Create gate socket for this session
    const socketPath = this.gate.createSessionSocket(session.id, session.userId);

    // Install permission-gate extension into user's sandbox
    const extensionDest = join(userSandboxDir, "agent", "extensions", "permission-gate");
    if (!existsSync(extensionDest) && existsSync(EXTENSION_SRC_DIR)) {
      cpSync(EXTENSION_SRC_DIR, extensionDest, { recursive: true });
      console.log(`[session] Installed permission-gate extension: ${extensionDest}`);
    }

    const proc = spawn(this.config.sandboxScript, args, {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        // User-specific sandbox state (auth, models, sessions)
        PI_SANDBOX_STATE: userSandboxDir,
        // User-specific workspace
        PI_WORK_DIR: userWorkspaceDir,
        // Permission gate socket
        PI_REMOTE_GATE_SOCK: socketPath,
        PI_REMOTE_SESSION: session.id,
        PI_REMOTE_USER: session.userId,
      },
    });

    const key = `${session.userId}/${session.id}`;

    // Single readline consumer for stdout (fixes race condition)
    // waitForReady resolves from this same consumer
    let readyResolve: (() => void) | null = null;
    const rl = createInterface({ input: proc.stdout! });
    rl.on("line", (line) => {
      // If we're still waiting for ready, check this line
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
      // Always pass to normal handler (no messages lost)
      this.handlePiOutput(key, line);
    });

    // Handle stderr
    proc.stderr?.on("data", (data) => {
      console.error(`[pi:${session.id}] ${data.toString().trim()}`);
    });

    // Handle exit
    proc.on("exit", (code) => {
      console.log(`[pi:${session.id}] exited with code ${code}`);
      this.handleSessionEnd(key, code === 0 ? "completed" : "error");
    });

    proc.on("error", (err) => {
      console.error(`[pi:${session.id}] error:`, err);
      this.handleSessionEnd(key, "error");
    });

    // Wait for ready using the single readline consumer above
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        readyResolve = null;
        reject(new Error(`Timeout waiting for pi to start: ${session.id}`));
      }, 30000);

      readyResolve = () => {
        clearTimeout(timer);
        resolve();
      };

      // Probe for readiness
      setTimeout(() => {
        proc.stdin?.write(JSON.stringify({ type: "get_state" }) + "\n");
      }, 500);
    });

    return proc;
  }

  /**
   * Handle output from pi process
   */
  private handlePiOutput(key: string, line: string): void {
    const active = this.active.get(key);
    if (!active) return;

    try {
      const data = JSON.parse(line);
      
      // Transform pi events to our simplified format
      const message = this.transformPiEvent(data, active.session);
      if (message) {
        this.broadcast(key, message);
      }

      // Update session state
      this.updateSessionFromEvent(active.session, data);
      
      // Reset idle timer on activity
      this.resetIdleTimer(key);

    } catch (err) {
      console.warn(`[pi:${active.session.id}] Invalid JSON:`, line);
    }
  }

  /**
   * Transform pi RPC event to our simplified format
   */
  private transformPiEvent(event: any, session: Session): ServerMessage | null {
    switch (event.type) {
      case "agent_start":
        return { type: "agent_start" };

      case "agent_end":
        return { type: "agent_end" };

      case "message_update":
        const msgEvent = event.assistantMessageEvent;
        if (msgEvent?.type === "text_delta") {
          return { type: "text_delta", delta: msgEvent.delta };
        }
        if (msgEvent?.type === "thinking_delta") {
          return { type: "thinking_delta", delta: msgEvent.delta };
        }
        return null;

      case "tool_execution_start":
        return {
          type: "tool_start",
          tool: event.toolName,
          args: event.args || {},
        };

      case "tool_execution_update":
        const content = event.partialResult?.content?.[0];
        if (content?.type === "text") {
          return { type: "tool_output", output: content.text };
        }
        return null;

      case "tool_execution_end":
        return {
          type: "tool_end",
          tool: event.toolName,
        };

      case "response":
        // Command responses - ignore for now
        return null;

      default:
        return null;
    }
  }

  /**
   * Update session from pi event
   */
  private updateSessionFromEvent(session: Session, event: any): void {
    switch (event.type) {
      case "agent_start":
        session.status = "busy";
        break;

      case "agent_end":
        session.status = "ready";
        break;

      case "message_end":
        const msg = event.message;
        if (msg?.usage) {
          session.tokens.input += msg.usage.input || 0;
          session.tokens.output += msg.usage.output || 0;
          session.cost += msg.usage.cost?.total || 0;
        }
        break;
    }

    session.lastActivity = Date.now();
    this.storage.saveSession(session);
  }

  /**
   * Handle session end
   */
  private handleSessionEnd(key: string, reason: string): void {
    const active = this.active.get(key);
    if (!active) return;

    active.session.status = "stopped";
    this.storage.saveSession(active.session);

    // Clean up gate socket
    this.gate.destroySessionSocket(active.session.id);

    this.broadcast(key, { type: "session_ended", reason });
    
    this.clearIdleTimer(key);
    this.active.delete(key);
  }

  /**
   * Send command to pi
   */
  async sendCommand(userId: string, sessionId: string, command: any): Promise<void> {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    
    if (!active) {
      throw new Error(`Session not active: ${sessionId}`);
    }

    // Add command to queue
    const json = JSON.stringify(command);
    active.process.stdin?.write(json + "\n");

    // Reset idle timer
    this.resetIdleTimer(key);
  }

  /**
   * Subscribe to session events
   */
  subscribe(userId: string, sessionId: string, callback: (msg: ServerMessage) => void): () => void {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    
    if (active) {
      active.subscribers.add(callback);
      return () => active.subscribers.delete(callback);
    }

    return () => {};
  }

  /**
   * Broadcast message to subscribers
   */
  private broadcast(key: string, message: ServerMessage): void {
    const active = this.active.get(key);
    if (!active) return;

    for (const callback of active.subscribers) {
      try {
        callback(message);
      } catch (err) {
        console.error("Subscriber error:", err);
      }
    }
  }

  /**
   * Stop a session
   */
  async stopSession(userId: string, sessionId: string): Promise<void> {
    const key = `${userId}/${sessionId}`;
    const active = this.active.get(key);
    
    if (!active) return;

    try {
      // Try graceful abort first
      active.process.stdin?.write(JSON.stringify({ type: "abort" }) + "\n");
      
      // Give it a moment
      await new Promise(r => setTimeout(r, 1000));
      
      // Force kill if still running
      if (!active.process.killed) {
        active.process.kill("SIGTERM");
      }
    } catch {}

    this.handleSessionEnd(key, "stopped");
  }

  /**
   * Check if session is active
   */
  isActive(userId: string, sessionId: string): boolean {
    return this.active.has(`${userId}/${sessionId}`);
  }

  /**
   * Get active session
   */
  getActiveSession(userId: string, sessionId: string): Session | undefined {
    return this.active.get(`${userId}/${sessionId}`)?.session;
  }

  // ─── Idle Management ───

  private resetIdleTimer(key: string): void {
    this.clearIdleTimer(key);
    
    const timer = setTimeout(() => {
      console.log(`[session] Idle timeout: ${key}`);
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

  /**
   * Stop all sessions
   */
  async stopAll(): Promise<void> {
    const keys = Array.from(this.active.keys());
    await Promise.all(
      keys.map(key => {
        const [userId, sessionId] = key.split("/");
        return this.stopSession(userId, sessionId);
      })
    );
  }
}
