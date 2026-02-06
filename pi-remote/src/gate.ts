/**
 * Permission gate — Unix socket server for pi extension communication.
 *
 * Each pi session gets its own Unix domain socket at:
 *   /tmp/pi-remote-gate/<sessionId>.sock
 *
 * Protocol: newline-delimited JSON over the socket.
 *
 * Extension → Server:
 *   { type: "guard_ready", sessionId, extensionVersion }
 *   { type: "gate_check", tool, input, toolCallId }
 *   { type: "heartbeat" }
 *
 * Server → Extension:
 *   { type: "guard_ack", status: "ok" }
 *   { type: "gate_result", action: "allow" | "deny", reason?, risk? }
 *   { type: "heartbeat_ack" }
 */

import { createServer, type Server as NetServer, type Socket } from "node:net";
import { createInterface } from "node:readline";
import { mkdirSync, existsSync, unlinkSync, rmSync } from "node:fs";
import { join } from "node:path";
import { EventEmitter } from "node:events";
import { nanoid } from "nanoid";
import { PolicyEngine, type GateRequest, type PolicyDecision } from "./policy.js";

// ─── Types ───

export type GuardState = "unguarded" | "guarded" | "fail_safe";

export interface SessionGuard {
  sessionId: string;
  userId: string;
  state: GuardState;
  socketPath: string;
  server: NetServer;
  client: Socket | null;
  lastHeartbeat: number;
  heartbeatTimer: NodeJS.Timeout | null;
}

export interface PendingDecision {
  id: string;
  sessionId: string;
  userId: string;
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
  displaySummary: string;
  risk: string;
  reason: string;
  createdAt: number;
  timeoutAt: number;
  resolve: (response: GateResponse) => void;
}

interface GateResponse {
  action: "allow" | "deny";
  reason?: string;
}

// Messages from extension
interface GuardReadyMsg {
  type: "guard_ready";
  sessionId: string;
  extensionVersion: string;
}

interface GateCheckMsg {
  type: "gate_check";
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
}

interface HeartbeatMsg {
  type: "heartbeat";
}

type ExtensionMessage = GuardReadyMsg | GateCheckMsg | HeartbeatMsg;

// ─── Constants ───

const GATE_SOCKET_DIR = "/tmp/pi-remote-gate";
const HEARTBEAT_TIMEOUT_MS = 45_000; // Extension sends every 15s, we expect within 45s
const DEFAULT_APPROVAL_TIMEOUT_MS = 120_000; // 2 minutes

// ─── Gate Server ───

export class GateServer extends EventEmitter {
  private policy: PolicyEngine;
  private guards: Map<string, SessionGuard> = new Map();
  private pending: Map<string, PendingDecision> = new Map();
  private pendingTimeouts: Map<string, NodeJS.Timeout> = new Map();

  constructor(policy: PolicyEngine) {
    super();
    this.policy = policy;

    // Ensure socket directory exists
    if (!existsSync(GATE_SOCKET_DIR)) {
      mkdirSync(GATE_SOCKET_DIR, { recursive: true, mode: 0o700 });
    }
  }

  /**
   * Create a Unix socket for a session. Returns the socket path.
   */
  createSessionSocket(sessionId: string, userId: string): string {
    const socketPath = join(GATE_SOCKET_DIR, `${sessionId}.sock`);

    // Clean up stale socket file
    if (existsSync(socketPath)) {
      unlinkSync(socketPath);
    }

    const server = createServer((client) => {
      this.handleConnection(sessionId, client);
    });

    server.listen(socketPath, () => {
      console.log(`[gate] Socket ready: ${socketPath}`);
    });

    server.on("error", (err) => {
      console.error(`[gate] Socket error for ${sessionId}:`, err);
    });

    const guard: SessionGuard = {
      sessionId,
      userId,
      state: "unguarded",
      socketPath,
      server,
      client: null,
      lastHeartbeat: Date.now(),
      heartbeatTimer: null,
    };

    this.guards.set(sessionId, guard);
    return socketPath;
  }

  /**
   * Destroy a session's gate socket and clean up pending decisions.
   */
  destroySessionSocket(sessionId: string): void {
    const guard = this.guards.get(sessionId);
    if (!guard) return;

    // Stop heartbeat timer
    if (guard.heartbeatTimer) {
      clearInterval(guard.heartbeatTimer);
    }

    // Close client connection
    if (guard.client) {
      guard.client.destroy();
    }

    // Close server
    guard.server.close();

    // Remove socket file
    if (existsSync(guard.socketPath)) {
      unlinkSync(guard.socketPath);
    }

    // Reject all pending decisions for this session
    for (const [id, decision] of this.pending) {
      if (decision.sessionId === sessionId) {
        decision.resolve({ action: "deny", reason: "Session ended" });
        this.cleanupPending(id);
      }
    }

    this.guards.delete(sessionId);
    console.log(`[gate] Destroyed socket for ${sessionId}`);
  }

  /**
   * Resolve a pending permission decision (called when phone responds).
   */
  resolveDecision(requestId: string, action: "allow" | "deny"): boolean {
    const decision = this.pending.get(requestId);
    if (!decision) return false;

    decision.resolve({ action, reason: action === "deny" ? "Denied by user" : undefined });
    this.cleanupPending(requestId);

    console.log(`[gate] Decision resolved: ${requestId} → ${action}`);
    return true;
  }

  /**
   * Get the guard state for a session.
   */
  getGuardState(sessionId: string): GuardState {
    return this.guards.get(sessionId)?.state || "unguarded";
  }

  /**
   * Get all pending decisions (for reconnecting phone clients).
   */
  getPendingDecisions(): PendingDecision[] {
    return Array.from(this.pending.values());
  }

  /**
   * Get pending decisions for a specific user.
   */
  getPendingForUser(userId: string): PendingDecision[] {
    return Array.from(this.pending.values()).filter(d => d.userId === userId);
  }

  /**
   * Clean up all sockets on shutdown.
   */
  async shutdown(): Promise<void> {
    const sessionIds = Array.from(this.guards.keys());
    for (const id of sessionIds) {
      this.destroySessionSocket(id);
    }

    // Clean up the directory if empty
    try {
      rmSync(GATE_SOCKET_DIR, { recursive: true });
    } catch {}
  }

  // ─── Connection Handling ───

  private handleConnection(sessionId: string, client: Socket): void {
    const guard = this.guards.get(sessionId);
    if (!guard) {
      client.destroy();
      return;
    }

    // Only one client per session
    if (guard.client) {
      guard.client.destroy();
    }

    guard.client = client;
    guard.lastHeartbeat = Date.now();

    console.log(`[gate] Extension connected for ${sessionId}`);

    const rl = createInterface({ input: client });
    rl.on("line", (line) => {
      try {
        const msg = JSON.parse(line) as ExtensionMessage;
        this.handleMessage(sessionId, msg, client);
      } catch (err) {
        console.warn(`[gate] Invalid message from ${sessionId}:`, line);
      }
    });

    client.on("close", () => {
      console.log(`[gate] Extension disconnected for ${sessionId}`);
      if (guard.client === client) {
        guard.client = null;
        this.handleExtensionLost(sessionId);
      }
    });

    client.on("error", (err) => {
      console.error(`[gate] Client error for ${sessionId}:`, err.message);
    });
  }

  private handleMessage(sessionId: string, msg: ExtensionMessage, client: Socket): void {
    const guard = this.guards.get(sessionId);
    if (!guard) return;

    switch (msg.type) {
      case "guard_ready":
        this.handleGuardReady(guard, msg);
        this.send(client, { type: "guard_ack", status: "ok" });
        break;

      case "gate_check":
        this.handleGateCheck(guard, msg, client);
        break;

      case "heartbeat":
        guard.lastHeartbeat = Date.now();
        this.send(client, { type: "heartbeat_ack" });
        break;

      default:
        console.warn(`[gate] Unknown message type from ${sessionId}:`, (msg as any).type);
    }
  }

  private handleGuardReady(guard: SessionGuard, msg: GuardReadyMsg): void {
    guard.state = "guarded";
    guard.lastHeartbeat = Date.now();

    // Start heartbeat monitoring
    if (guard.heartbeatTimer) {
      clearInterval(guard.heartbeatTimer);
    }

    guard.heartbeatTimer = setInterval(() => {
      const elapsed = Date.now() - guard.lastHeartbeat;
      if (elapsed > HEARTBEAT_TIMEOUT_MS) {
        console.warn(`[gate] Heartbeat timeout for ${guard.sessionId} (${elapsed}ms)`);
        this.handleExtensionLost(guard.sessionId);
      }
    }, HEARTBEAT_TIMEOUT_MS);

    console.log(`[gate] Session ${guard.sessionId} is now GUARDED (ext v${msg.extensionVersion})`);
    this.emit("guard_ready", { sessionId: guard.sessionId });
  }

  private async handleGateCheck(guard: SessionGuard, msg: GateCheckMsg, client: Socket): Promise<void> {
    // Fail-safe: if not guarded, deny everything
    if (guard.state !== "guarded") {
      this.send(client, {
        type: "gate_result",
        action: "deny",
        reason: `Session not guarded (state: ${guard.state})`,
      });
      return;
    }

    const req: GateRequest = {
      tool: msg.tool,
      input: msg.input,
      toolCallId: msg.toolCallId,
    };

    // Evaluate policy
    const decision = this.policy.evaluate(req);

    if (decision.action === "allow") {
      this.send(client, { type: "gate_result", action: "allow" });
      this.emit("tool_allowed", { sessionId: guard.sessionId, ...req, decision });
      return;
    }

    if (decision.action === "deny") {
      this.send(client, { type: "gate_result", action: "deny", reason: decision.reason });
      this.emit("tool_denied", { sessionId: guard.sessionId, ...req, decision });
      return;
    }

    // action === "ask" → create pending decision, wait for phone
    const requestId = nanoid(12);
    const displaySummary = this.policy.formatDisplaySummary(req);

    const response = await new Promise<GateResponse>((resolve) => {
      const pending: PendingDecision = {
        id: requestId,
        sessionId: guard.sessionId,
        userId: guard.userId,
        tool: msg.tool,
        input: msg.input,
        toolCallId: msg.toolCallId,
        displaySummary,
        risk: decision.risk,
        reason: decision.reason,
        createdAt: Date.now(),
        timeoutAt: Date.now() + DEFAULT_APPROVAL_TIMEOUT_MS,
        resolve,
      };

      this.pending.set(requestId, pending);

      // Set timeout
      const timeout = setTimeout(() => {
        if (this.pending.has(requestId)) {
          resolve({ action: "deny", reason: "Approval timeout (2 min)" });
          this.cleanupPending(requestId);
          this.emit("approval_timeout", { requestId, sessionId: guard.sessionId });
        }
      }, DEFAULT_APPROVAL_TIMEOUT_MS);
      this.pendingTimeouts.set(requestId, timeout);

      // Emit event for server to forward to phone
      this.emit("approval_needed", pending);
    });

    this.send(client, {
      type: "gate_result",
      action: response.action,
      reason: response.reason,
    });
  }

  private handleExtensionLost(sessionId: string): void {
    const guard = this.guards.get(sessionId);
    if (!guard) return;

    if (guard.state === "guarded") {
      guard.state = "fail_safe";
      console.warn(`[gate] Session ${sessionId} entered FAIL_SAFE mode`);
      this.emit("guard_lost", { sessionId });
    }

    // Deny all pending decisions for this session
    for (const [id, decision] of this.pending) {
      if (decision.sessionId === sessionId) {
        decision.resolve({ action: "deny", reason: "Extension connection lost" });
        this.cleanupPending(id);
      }
    }
  }

  private cleanupPending(requestId: string): void {
    this.pending.delete(requestId);
    const timeout = this.pendingTimeouts.get(requestId);
    if (timeout) {
      clearTimeout(timeout);
      this.pendingTimeouts.delete(requestId);
    }
  }

  private send(client: Socket, msg: Record<string, unknown>): void {
    if (!client.destroyed) {
      client.write(JSON.stringify(msg) + "\n");
    }
  }
}
