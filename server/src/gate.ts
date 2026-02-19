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
import { generateId } from "./id.js";
import type { PolicyEngine, RiskLevel } from "./policy.js";
import {
  addDomainToAllowlist,
  removeDomainFromAllowlist,
  type GateRequest,
  type ResolutionOptions,
} from "./policy.js";
import type { RuleStore } from "./rules.js";
import type { AuditLog } from "./audit.js";

// ─── Types ───

export type GuardState = "unguarded" | "guarded" | "fail_safe";

export interface SessionGuard {
  sessionId: string;
  workspaceId: string;
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
  workspaceId: string;
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
  displaySummary: string;
  risk: RiskLevel;
  reason: string;
  createdAt: number;
  timeoutAt: number;
  expires?: boolean;
  resolutionOptions: ResolutionOptions;
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
const NO_TIMEOUT_PLACEHOLDER_MS = 100 * 365 * 24 * 60 * 60 * 1000; // 100 years
const MAX_RULE_TTL_MS = 365 * 24 * 60 * 60 * 1000; // Cap temporary learned rules at 1 year
const TCP_HOST = "0.0.0.0"; // Listen on all interfaces (containers connect via host-gateway)

// ─── Gate Server ───

export interface GateServerOptions {
  approvalTimeoutMs?: number;
}

export class GateServer extends EventEmitter {
  private defaultPolicy: PolicyEngine;
  private sessionPolicies: Map<string, PolicyEngine> = new Map();
  private guards: Map<string, SessionGuard> = new Map();
  private pending: Map<string, PendingDecision> = new Map();
  private pendingTimeouts: Map<string, NodeJS.Timeout> = new Map();
  readonly ruleStore: RuleStore;
  readonly auditLog: AuditLog;
  private readonly approvalTimeoutMs: number;

  constructor(
    defaultPolicy: PolicyEngine,
    ruleStore: RuleStore,
    auditLog: AuditLog,
    options: GateServerOptions = {},
  ) {
    super();
    this.defaultPolicy = defaultPolicy;
    this.ruleStore = ruleStore;
    this.auditLog = auditLog;

    const configuredTimeout = options.approvalTimeoutMs;
    this.approvalTimeoutMs =
      typeof configuredTimeout === "number" && Number.isFinite(configuredTimeout) && configuredTimeout >= 0
        ? Math.floor(configuredTimeout)
        : DEFAULT_APPROVAL_TIMEOUT_MS;
  }

  /**
   * Set a per-session policy engine. Used by SessionManager to apply
   * workspace/global policy composition and path access rules.
   */
  setSessionPolicy(sessionId: string, policy: PolicyEngine): void {
    this.sessionPolicies.set(sessionId, policy);
  }

  /** Get the policy engine for a session (falls back to default). */
  private getPolicy(sessionId: string): PolicyEngine {
    return this.sessionPolicies.get(sessionId) || this.defaultPolicy;
  }

  /**
   * Create a TCP socket for a session. Returns a promise that resolves to the port number.
   * The extension inside the container connects to host-gateway (192.168.64.1) on this port.
   */
  async createSessionSocket(
    sessionId: string,
    workspaceId: string = "",
  ): Promise<number> {
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
          workspaceId,
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

    // Clean up per-session policy and session rules
    this.sessionPolicies.delete(sessionId);
    this.ruleStore.clearSessionRules(sessionId);

    this.guards.delete(sessionId);
    console.log(`[gate] Destroyed socket for ${sessionId} (port ${guard.port})`);
  }

  /**
   * Resolve a pending permission decision (called when phone responds).
   *
   * scope determines rule persistence:
   *   "once"      — no rule created
   *   "session"   — in-memory rule for current session
   *   "workspace" — persisted rule for this workspace
   *   "global"    — persisted rule for all workspaces
   */
  resolveDecision(
    requestId: string,
    action: "allow" | "deny",
    scope: "once" | "session" | "workspace" | "global" = "once",
    expiresInMs?: number,
  ): boolean {
    const pending = this.pending.get(requestId);
    if (!pending) return false;

    const requestedScope = scope;
    const normalizedScope = this.normalizeDecisionScope(action, requestedScope, pending.resolutionOptions);
    if (normalizedScope !== requestedScope) {
      console.warn(
        `[gate] Scope ${requestedScope} is not permitted for ${action}; downgraded to ${normalizedScope} (request=${requestId})`,
      );
    }

    const policy = this.getPolicy(pending.sessionId);
    const req: GateRequest = {
      tool: pending.tool,
      input: pending.input,
      toolCallId: pending.toolCallId,
    };
    let learnedRuleId: string | undefined;

    const normalizedExpiryMs =
      typeof expiresInMs === "number" && Number.isFinite(expiresInMs) && expiresInMs > 0
        ? Math.min(Math.floor(expiresInMs), MAX_RULE_TTL_MS)
        : undefined;
    const expiresAt =
      normalizedScope !== "once" && normalizedExpiryMs !== undefined
        ? Date.now() + normalizedExpiryMs
        : undefined;

    // Create learned rule if scope != "once"
    if (normalizedScope !== "once") {
      const context = {
        sessionId: pending.sessionId,
        workspaceId: pending.workspaceId,
        risk: pending.risk || "medium",
      };

      const suggest =
        action === "allow"
          ? policy.suggestRule(req, normalizedScope, context)
          : policy.suggestDenyRule(req, normalizedScope, context);

      if (suggest) {
        const rule = this.ruleStore.add({
          ...suggest,
          ...(expiresAt !== undefined ? { expiresAt } : {}),
        });
        learnedRuleId = rule.id;
        const expiryLabel = expiresAt ? `, expiresAt=${new Date(expiresAt).toISOString()}` : "";
        console.log(
          `[gate] Learned rule: ${rule.description} (scope=${normalizedScope}, id=${rule.id}${expiryLabel})`,
        );

        // Browser domain + global allow → also add to shared allowlist
        if (action === "allow" && normalizedScope === "global" && rule.match?.domain) {
          addDomainToAllowlist(rule.match.domain);
          console.log(`[gate] Added ${rule.match.domain} to fetch domain allowlist`);
        }

        // Browser domain + global deny → remove from shared allowlist
        if (action === "deny" && normalizedScope === "global" && rule.match?.domain) {
          removeDomainFromAllowlist(rule.match.domain);
          console.log(`[gate] Removed ${rule.match.domain} from fetch domain allowlist`);
        }
      }
    }

    // Record audit entry
    this.auditLog.record({
      sessionId: pending.sessionId,
      workspaceId: pending.workspaceId,
      tool: pending.tool,
      displaySummary: pending.displaySummary,
      risk: pending.risk || "medium",
      decision: action,
      resolvedBy: "user",
      layer: "user_response",
      userChoice: {
        action,
        scope: normalizedScope,
        learnedRuleId,
        ...(expiresAt !== undefined ? { expiresAt } : {}),
      },
    });

    pending.resolve({ action, reason: action === "deny" ? "Denied by user" : undefined });
    this.cleanupPending(requestId);

    this.emit("approval_resolved", {
      requestId,
      sessionId: pending.sessionId,
      action,
      scope: normalizedScope,
      expiresAt,
    });

    console.log(`[gate] Decision resolved: ${requestId} → ${action} (scope=${normalizedScope})`);
    return true;
  }

  private normalizeDecisionScope(
    action: "allow" | "deny",
    requested: "once" | "session" | "workspace" | "global",
    options: ResolutionOptions,
  ): "once" | "session" | "workspace" | "global" {
    if (requested === "once") return "once";

    if (action === "allow") {
      if (requested === "session") {
        return options.allowSession ? "session" : "once";
      }
      // workspace/global share the same UI capability today.
      return options.allowAlways ? requested : "once";
    }

    // action === "deny"
    if (requested === "session") return "once";
    return options.denyAlways ? requested : "once";
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
  getPendingForUser(): PendingDecision[] {
    return Array.from(this.pending.values());
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
      } catch (_err) {
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
        console.warn(
          `[gate] Unknown message type from ${sessionId}:`,
          (msg as unknown as Record<string, unknown>).type,
        );
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

  private async handleGateCheck(
    guard: SessionGuard,
    msg: GateCheckMsg,
    client: Socket,
  ): Promise<void> {
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

    // Evaluate policy with learned rules
    const policy = this.getPolicy(guard.sessionId);
    const allRules = this.ruleStore.getAll();
    const decision = policy.evaluateWithRules(req, allRules, guard.sessionId, guard.workspaceId);
    const displaySummary = policy.formatDisplaySummary(req);

    if (decision.action === "allow") {
      this.send(client, { type: "gate_result", action: "allow" });
      this.auditLog.record({
        sessionId: guard.sessionId,
        workspaceId: guard.workspaceId,
        tool: msg.tool,
        displaySummary,
        risk: decision.risk,
        decision: "allow",
        resolvedBy: "policy",
        layer: decision.layer,
        ruleId: decision.ruleId,
        ruleSummary: decision.ruleLabel,
      });
      this.emit("tool_allowed", { sessionId: guard.sessionId, ...req, decision });
      return;
    }

    if (decision.action === "deny") {
      this.send(client, { type: "gate_result", action: "deny", reason: decision.reason });
      this.auditLog.record({
        sessionId: guard.sessionId,
        workspaceId: guard.workspaceId,
        tool: msg.tool,
        displaySummary,
        risk: decision.risk,
        decision: "deny",
        resolvedBy: "policy",
        layer: decision.layer,
        ruleId: decision.ruleId,
        ruleSummary: decision.ruleLabel,
      });
      this.emit("tool_denied", { sessionId: guard.sessionId, ...req, decision });
      return;
    }

    // action === "ask" → create pending decision, wait for phone
    const requestId = generateId(12);
    const resolutionOptions = policy.getResolutionOptions(req, decision);

    const response = await new Promise<GateResponse>((resolve) => {
      const createdAt = Date.now();
      const expires = this.approvalTimeoutMs > 0;
      const timeoutAt =
        expires
          ? createdAt + this.approvalTimeoutMs
          : createdAt + NO_TIMEOUT_PLACEHOLDER_MS;

      const pending: PendingDecision = {
        id: requestId,
        sessionId: guard.sessionId,
        workspaceId: guard.workspaceId,
        tool: msg.tool,
        input: msg.input,
        toolCallId: msg.toolCallId,
        displaySummary,
        risk: decision.risk,
        reason: decision.reason,
        createdAt,
        timeoutAt,
        expires,
        resolutionOptions,
        resolve,
      };

      this.pending.set(requestId, pending);

      if (this.approvalTimeoutMs > 0) {
        const timeout = setTimeout(() => {
          if (this.pending.has(requestId)) {
            this.auditLog.record({
              sessionId: guard.sessionId,
              workspaceId: guard.workspaceId,
              tool: msg.tool,
              displaySummary,
              risk: decision.risk,
              decision: "deny",
              resolvedBy: "timeout",
              layer: "timeout",
            });
            resolve({ action: "deny", reason: "Approval timeout" });
            this.cleanupPending(requestId);
            this.emit("approval_timeout", { requestId, sessionId: guard.sessionId });
          }
        }, this.approvalTimeoutMs);
        this.pendingTimeouts.set(requestId, timeout);
      }

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
    for (const [id, pd] of this.pending) {
      if (pd.sessionId === sessionId) {
        this.auditLog.record({
          sessionId: pd.sessionId,
          workspaceId: pd.workspaceId,
          tool: pd.tool,
          displaySummary: pd.displaySummary,
          risk: pd.risk || "medium",
          decision: "deny",
          resolvedBy: "extension_lost",
          layer: "extension_lost",
        });
        pd.resolve({ action: "deny", reason: "Extension connection lost" });
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
