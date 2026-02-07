/**
 * Permission gate — TCP server for pi extension communication.
 *
 * Each pi session gets its own TCP port on localhost. The extension
 * inside the container connects to host-gateway (192.168.64.1) on that port.
 *
 * Protocol: newline-delimited JSON over TCP.
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
import { EventEmitter } from "node:events";
import { nanoid } from "nanoid";
import { PolicyEngine, type GateRequest, type PolicyDecision } from "./policy.js";

// ─── Types ───

export type GuardState = "unguarded" | "guarded" | "fail_safe";

export interface SessionGuard {
  sessionId: string;
  userId: string;
  state: GuardState;
  port: number;
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

const HEARTBEAT_TIMEOUT_MS = 45_000; // Extension sends every 15s, we expect within 45s
const DEFAULT_APPROVAL_TIMEOUT_MS = 120_000; // 2 minutes
const TCP_HOST = "0.0.0.0"; // Listen on all interfaces (containers connect via host-gateway)

// ─── Gate Server ───

export class GateServer extends EventEmitter {
  private policy: PolicyEngine;
  private guards: Map<string, SessionGuard> = new Map();
  private pending: Map<string, PendingDecision> = new Map();
  private pendingTimeouts: Map<string, NodeJS.Timeout> = new Map();

  constructor(policy: PolicyEngine) {
    super();
    this.policy = policy;
  }

  /**
   * Create a TCP socket for a session. Returns a promise that resolves to the port number.
   * The extension inside the container connects to host-gateway (192.168.64.1) on this port.
   */
  async createSessionSocket(sessionId: string, userId: string): Promise<number> {
    return new Promise((resolve, reject) => {
      const server = createServer((client) => {
        this.handleConnection(sessionId, client);
      });

      // Listen on localhost with a dynamic port (0 = OS assigns)
      server.listen(0, TCP_HOST, () => {
        const addr = server.address();
        const port = typeof addr === "object" && addr ? addr.port : 0;
        console.log(`[gate] TCP socket ready for ${sessionId}: ${TCP_HOST}:${port}`);

        const guard: SessionGuard = {
          sessionId,
          userId,
          state: "unguarded",
          port,
          server,
          client: null,
          lastHeartbeat: Date.now(),
          heartbeatTimer: null,
        };

        this.guards.set(sessionId, guard);
        resolve(port);
      });

      server.on("error", (err) => {
        console.error(`[gate] TCP socket error for ${sessionId}:`, err);
        reject(err);
      });
    });
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

    // Reject all pending decisions for this session
    for (const [id, decision] of this.pending) {
      if (decision.sessionId === sessionId) {
        decision.resolve({ action: "deny", reason: "Session ended" });
        this.cleanupPending(id);
      }
    }

    this.guards.delete(sessionId);
    console.log(`[gate] Destroyed socket for ${sessionId} (port ${guard.port})`);
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
