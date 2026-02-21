/**
 * Permission gate — in-process tool call authorization.
 *
 * Each pi session gets a virtual guard via createGuard().
 * Tool calls are evaluated through checkToolCall() which runs the
 * policy engine, checks learned rules, and emits approval_needed
 * events for decisions that require user input.
 */

import { EventEmitter } from "node:events";
import { generateId } from "./id.js";
import type { PolicyEngine } from "./policy.js";
import { parseBashCommand, type GateRequest } from "./policy.js";
import { normalizeApprovalChoice } from "./policy-approval.js";
import type { RuleInput, RuleStore } from "./rules.js";
import type { AuditLog } from "./audit.js";

// ─── Types ───

export type GuardState = "unguarded" | "guarded" | "fail_safe";

export interface SessionGuard {
  sessionId: string;
  workspaceId: string;
  state: GuardState;
}

export interface PendingDecision {
  id: string;
  sessionId: string;
  workspaceId: string;
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
  displaySummary: string;
  reason: string;
  createdAt: number;
  timeoutAt: number;
  expires?: boolean;
  resolve: (response: GateResponse) => void;
}

interface GateResponse {
  action: "allow" | "deny";
  reason?: string;
}

// ─── Constants ───

const DEFAULT_APPROVAL_TIMEOUT_MS = 120_000; // 2 minutes
const NO_TIMEOUT_PLACEHOLDER_MS = 100 * 365 * 24 * 60 * 60 * 1000; // 100 years
const MAX_RULE_TTL_MS = 365 * 24 * 60 * 60 * 1000; // Cap temporary learned rules at 1 year

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
      typeof configuredTimeout === "number" &&
      Number.isFinite(configuredTimeout) &&
      configuredTimeout >= 0
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
   * Destroy a session's guard and clean up pending decisions.
   */
  destroySessionGuard(sessionId: string): void {
    const guard = this.guards.get(sessionId);
    if (!guard) return;

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
    console.log(`[gate] Destroyed guard for ${sessionId}`);
  }

  /**
   * Resolve a pending permission decision (called when phone responds).
   *
   * scope determines rule persistence:
   *   "once"      — no rule created
   *   "session"   — in-memory rule for current session
   *   "global"    — persisted rule for all workspaces
   */
  resolveDecision(
    requestId: string,
    action: "allow" | "deny",
    scope: "once" | "session" | "global" = "once",
    expiresInMs?: number,
  ): boolean {
    const pending = this.pending.get(requestId);
    if (!pending) return false;

    const normalizedChoice = normalizeApprovalChoice(pending.tool, {
      action,
      scope,
    });
    const normalizedScope = normalizedChoice.scope;

    if (normalizedChoice.normalized) {
      console.warn(
        `[gate] Scope ${scope} is not permitted for ${action}; downgraded to ${normalizedScope} (request=${requestId})`,
      );
    }

    let learnedRuleId: string | undefined;

    const normalizedExpiryMs =
      typeof expiresInMs === "number" && Number.isFinite(expiresInMs) && expiresInMs > 0
        ? Math.min(Math.floor(expiresInMs), MAX_RULE_TTL_MS)
        : undefined;
    const expiresAt =
      normalizedScope !== "once" && normalizedExpiryMs !== undefined
        ? Date.now() + normalizedExpiryMs
        : undefined;

    if (normalizedScope !== "once") {
      const ruleInput = this.buildRuleFromDecision(pending, action, normalizedScope, expiresAt);
      if (ruleInput) {
        const rule = this.ruleStore.add(ruleInput);
        learnedRuleId = rule.id;
        const expiryLabel = expiresAt ? `, expiresAt=${new Date(expiresAt).toISOString()}` : "";
        console.log(
          `[gate] Learned rule: ${rule.label || "(no label)"} (scope=${normalizedScope}, id=${rule.id}${expiryLabel})`,
        );
      }
    }

    // Record audit entry
    this.auditLog.record({
      sessionId: pending.sessionId,
      workspaceId: pending.workspaceId,
      tool: pending.tool,
      displaySummary: pending.displaySummary,
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

  private buildRuleFromDecision(
    pending: PendingDecision,
    action: "allow" | "deny",
    scope: "session" | "global",
    expiresAt?: number,
  ): RuleInput | null {
    if (pending.tool.startsWith("policy.")) return null;

    const tool = pending.tool;
    const decision = action === "allow" ? "allow" : "deny";

    const input: RuleInput = {
      tool,
      decision,
      scope,
      source: "learned",
      label: `${action === "allow" ? "Allow" : "Deny"} ${pending.displaySummary}`,
      ...(scope === "session" ? { sessionId: pending.sessionId } : {}),
      ...(expiresAt !== undefined ? { expiresAt } : {}),
    };

    if (tool === "bash") {
      const command = (pending.input as { command?: string }).command?.trim() || "";
      if (command.length > 0) {
        input.pattern = command;
        const parsed = parseBashCommand(command);
        const executable = parsed.executable.includes("/")
          ? parsed.executable.split("/").pop() || parsed.executable
          : parsed.executable;
        if (executable) input.executable = executable;
      }
      return input;
    }

    if (
      tool === "read" ||
      tool === "write" ||
      tool === "edit" ||
      tool === "find" ||
      tool === "ls"
    ) {
      const path = (pending.input as { path?: string }).path;
      if (typeof path === "string" && path.trim().length > 0) {
        input.pattern = path.trim();
      }
      return input;
    }

    return input;
  }

  /**
   * Create a guard for a session. Starts in "guarded" state immediately
   * since the extension factory runs in-process.
   */
  createGuard(sessionId: string, workspaceId: string = ""): void {
    // Clean up any existing guard first
    if (this.guards.has(sessionId)) {
      this.destroySessionGuard(sessionId);
    }

    const guard: SessionGuard = {
      sessionId,
      workspaceId,
      state: "guarded",
    };

    this.guards.set(sessionId, guard);
    console.log(`[gate] Guard created for ${sessionId}`);
    this.emit("guard_ready", { sessionId });
  }

  /**
   * Evaluate a tool call through the gate and return the decision.
   * Used by SDK extension factory (in-process, no TCP).
   *
   * Returns { action: "allow" } or { action: "deny", reason }.
   */
  async checkToolCall(
    sessionId: string,
    req: { tool: string; input: Record<string, unknown>; toolCallId: string },
  ): Promise<{ action: "allow" | "deny"; reason?: string }> {
    const guard = this.guards.get(sessionId);
    if (!guard || guard.state !== "guarded") {
      return {
        action: "deny",
        reason: `Session not guarded (state: ${guard?.state || "unknown"})`,
      };
    }

    return this.evaluateGateCheck(guard, req);
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
   * Clean up all guards on shutdown.
   */
  async shutdown(): Promise<void> {
    const sessionIds = Array.from(this.guards.keys());
    for (const id of sessionIds) {
      this.destroySessionGuard(id);
    }
  }

  /**
   * Core gate check evaluation — runs policy engine, checks rules,
   * and emits approval_needed for decisions requiring user input.
   */
  private async evaluateGateCheck(
    guard: SessionGuard,
    req: GateRequest,
  ): Promise<{ action: "allow" | "deny"; reason?: string }> {
    const policy = this.getPolicy(guard.sessionId);
    const allRules = this.ruleStore.getAll();
    const decision = policy.evaluateWithRules(req, allRules, guard.sessionId, guard.workspaceId);
    const displaySummary = policy.formatDisplaySummary(req);

    if (decision.action === "allow") {
      this.auditLog.record({
        sessionId: guard.sessionId,
        workspaceId: guard.workspaceId,
        tool: req.tool,
        displaySummary,
        decision: "allow",
        resolvedBy: "policy",
        layer: decision.layer,
        ruleId: decision.ruleId,
        ruleSummary: decision.ruleLabel,
      });
      this.emit("tool_allowed", { sessionId: guard.sessionId, ...req, decision });
      return { action: "allow" };
    }

    if (decision.action === "deny") {
      this.auditLog.record({
        sessionId: guard.sessionId,
        workspaceId: guard.workspaceId,
        tool: req.tool,
        displaySummary,
        decision: "deny",
        resolvedBy: "policy",
        layer: decision.layer,
        ruleId: decision.ruleId,
        ruleSummary: decision.ruleLabel,
      });
      this.emit("tool_denied", { sessionId: guard.sessionId, ...req, decision });
      return { action: "deny", reason: decision.reason };
    }

    // action === "ask" — create pending decision, wait for phone
    const requestId = generateId(12);

    const response = await new Promise<GateResponse>((resolve) => {
      const createdAt = Date.now();
      const expires = this.approvalTimeoutMs > 0;
      const timeoutAt = expires
        ? createdAt + this.approvalTimeoutMs
        : createdAt + NO_TIMEOUT_PLACEHOLDER_MS;

      const pending: PendingDecision = {
        id: requestId,
        sessionId: guard.sessionId,
        workspaceId: guard.workspaceId,
        tool: req.tool,
        input: req.input,
        toolCallId: req.toolCallId,
        displaySummary,
        reason: decision.reason,
        createdAt,
        timeoutAt,
        expires,
        resolve,
      };

      this.pending.set(requestId, pending);

      if (this.approvalTimeoutMs > 0) {
        const timeout = setTimeout(() => {
          if (this.pending.has(requestId)) {
            this.auditLog.record({
              sessionId: guard.sessionId,
              workspaceId: guard.workspaceId,
              tool: req.tool,
              displaySummary,
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

    return { action: response.action, reason: response.reason };
  }

  private cleanupPending(requestId: string): void {
    this.pending.delete(requestId);
    const timeout = this.pendingTimeouts.get(requestId);
    if (timeout) {
      clearTimeout(timeout);
      this.pendingTimeouts.delete(requestId);
    }
  }
}
