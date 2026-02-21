import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PolicyEngine, defaultPresetRules } from "../src/policy.js";
import { GateServer } from "../src/gate.js";
import { RuleStore } from "../src/rules.js";
import { AuditLog } from "../src/audit.js";
import type { PolicyConfig } from "../src/types.js";

const SESSION_ID = "test-session-1";

let gate: GateServer;
let testDir = "";

beforeEach(() => {
  testDir = mkdtempSync(join(tmpdir(), "oppi-server-gate-test-"));
});

afterEach(async () => {
  if (gate) await gate.shutdown();
  rmSync(testDir, { recursive: true, force: true });
});

function createGate(
  policyOrMode: string | PolicyConfig = "container",
  approvalTimeoutMs?: number,
): GateServer {
  const policy = new PolicyEngine(policyOrMode);
  const ruleStore = new RuleStore(join(testDir, "rules.json"));
  ruleStore.seedIfEmpty(defaultPresetRules());
  const auditLog = new AuditLog(join(testDir, "audit.jsonl"));
  return new GateServer(policy, ruleStore, auditLog, { approvalTimeoutMs });
}

function setupGuardedSession(
  policyOrMode: string | PolicyConfig = "container",
  approvalTimeoutMs?: number,
): GateServer {
  gate = createGate(policyOrMode, approvalTimeoutMs);
  gate.createGuard(SESSION_ID, "w1");
  return gate;
}

describe("GateServer", () => {
  it("creates guard in guarded state", () => {
    setupGuardedSession();
    expect(gate.getGuardState(SESSION_ID)).toBe("guarded");
  });

  it("auto-allows safe commands (ls)", async () => {
    setupGuardedSession();

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "ls -la" },
      toolCallId: "tc_1",
    });

    expect(result.action).toBe("allow");
  });

  it("hard-denies dangerous commands (sudo)", async () => {
    setupGuardedSession();

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "sudo rm -rf /" },
      toolCallId: "tc_2",
    });

    expect(result.action).toBe("deny");
  });

  it("asks then allows after approval (git push --force)", async () => {
    setupGuardedSession();

    gate.on("approval_needed", (pending: { id: string }) => {
      setTimeout(() => gate.resolveDecision(pending.id, "allow"), 20);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "git push --force origin main" },
      toolCallId: "tc_3",
    });

    expect(result.action).toBe("allow");
  });

  it("uses configurable approval timeout when set", async () => {
    setupGuardedSession("host", 25);

    gate.on("approval_needed", (pending: { id: string }) => {
      // Intentionally slower than timeout.
      setTimeout(() => gate.resolveDecision(pending.id, "allow"), 80);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_timeout",
    });

    expect(result.action).toBe("deny");
    expect(result.reason).toBe("Approval timeout");
  });

  it("disables approval expiry when approvalTimeoutMs=0", async () => {
    setupGuardedSession("host", 0);

    gate.on("approval_needed", (pending: { id: string }) => {
      setTimeout(() => gate.resolveDecision(pending.id, "allow"), 80);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_no_timeout",
    });

    expect(result.action).toBe("allow");
  });

  it("asks for chained git push in local execution", async () => {
    setupGuardedSession("host");
    let approvalCount = 0;
    let lastReason = "";

    gate.on("approval_needed", (pending: { id: string; reason: string }) => {
      approvalCount += 1;
      lastReason = pending.reason;
      setTimeout(() => gate.resolveDecision(pending.id, "allow"), 20);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "cd /Users/dev/workspace/myproject && git push origin main" },
      toolCallId: "tc_3b",
    });

    expect(result.action).toBe("allow");
    expect(approvalCount).toBe(1);
    expect(lastReason).toContain("Git push");
  });

  it("applies fallback policy changes to live gate checks", async () => {
    const askFallbackPolicy: PolicyConfig = {
      schemaVersion: 1,
      fallback: "ask",
      guardrails: [],
      permissions: [],
    };
    const allowFallbackPolicy: PolicyConfig = {
      ...askFallbackPolicy,
      fallback: "allow",
    };

    setupGuardedSession(askFallbackPolicy);
    let approvalCount = 0;
    const approvalReasons: string[] = [];

    gate.on("approval_needed", (pending: { id: string; reason: string }) => {
      approvalCount += 1;
      approvalReasons.push(pending.reason);
      setTimeout(() => gate.resolveDecision(pending.id, "allow"), 10);
    });

    const runFallbackCheck = (toolCallId: string) =>
      gate.checkToolCall(SESSION_ID, {
        tool: "bash",
        input: { command: "echo fallback-toggle-check" },
        toolCallId,
      });

    const askResult1 = await runFallbackCheck("tc_fallback_1");
    expect(askResult1.action).toBe("allow");
    expect(approvalCount).toBe(1);
    expect(approvalReasons[0]).toContain("No matching rule");

    gate.setSessionPolicy(SESSION_ID, new PolicyEngine(allowFallbackPolicy));

    const allowResult = await runFallbackCheck("tc_fallback_2");
    expect(allowResult.action).toBe("allow");
    expect(approvalCount).toBe(1);

    gate.setSessionPolicy(SESSION_ID, new PolicyEngine(askFallbackPolicy));

    const askResult2 = await runFallbackCheck("tc_fallback_3");
    expect(askResult2.action).toBe("allow");
    expect(approvalCount).toBe(2);
    expect(approvalReasons[1]).toContain("No matching rule");
  });

  it("stores session rules with TTL from permission responses", async () => {
    setupGuardedSession("host");
    let approvalAt = 0;

    gate.on("approval_needed", (pending: { id: string }) => {
      approvalAt = Date.now();
      gate.resolveDecision(pending.id, "allow", "session", 60_000);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_ttl_workspace",
    });

    expect(result.action).toBe("allow");

    const learned = gate.ruleStore
      .getAll()
      .find(
        (rule) =>
          rule.scope === "session" &&
          rule.sessionId === SESSION_ID &&
          rule.decision === "allow" &&
          rule.tool === "bash" &&
          rule.pattern === "git push origin main",
      );

    expect(learned).toBeTruthy();
    expect(typeof learned?.expiresAt).toBe("number");

    const ttlMs = (learned?.expiresAt ?? 0) - approvalAt;
    expect(ttlMs).toBeGreaterThanOrEqual(55_000);
    expect(ttlMs).toBeLessThanOrEqual(65_000);
  });

  it("caps learned session-rule TTL at one year", async () => {
    setupGuardedSession("host");
    let approvalAt = 0;

    gate.on("approval_needed", (pending: { id: string }) => {
      approvalAt = Date.now();
      gate.resolveDecision(pending.id, "allow", "session", 10 * 365 * 24 * 60 * 60 * 1000);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_ttl_cap",
    });

    expect(result.action).toBe("allow");

    const learned = gate.ruleStore
      .getAll()
      .find(
        (rule) =>
          rule.scope === "session" &&
          rule.sessionId === SESSION_ID &&
          rule.decision === "allow" &&
          rule.tool === "bash" &&
          rule.pattern === "git push origin main",
      );

    expect(learned).toBeTruthy();
    expect(typeof learned?.expiresAt).toBe("number");

    const ttlMs = (learned?.expiresAt ?? 0) - approvalAt;
    const oneYearMs = 365 * 24 * 60 * 60 * 1000;
    expect(ttlMs).toBeGreaterThanOrEqual(oneYearMs - 5_000);
    expect(ttlMs).toBeLessThanOrEqual(oneYearMs + 5_000);
  });

  it("normalizes deny session scope responses to one-shot", async () => {
    setupGuardedSession("host");

    gate.on("approval_needed", (pending: { id: string }) => {
      gate.resolveDecision(pending.id, "deny", "session", 60_000);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_scope_downgrade",
    });

    expect(result.action).toBe("deny");

    const learned = gate.ruleStore
      .getAll()
      .find(
        (rule) =>
          rule.scope === "session" &&
          rule.decision === "deny" &&
          rule.pattern === "git push origin main",
      );
    expect(learned).toBeUndefined();
  });

  it("forces policy approvals to one-shot even when global scope is requested", async () => {
    setupGuardedSession("host");

    gate.on("approval_needed", (pending: { id: string }) => {
      gate.resolveDecision(pending.id, "allow", "global", 60_000);
    });

    const result = await gate.checkToolCall(SESSION_ID, {
      tool: "policy.update",
      input: { diff: "-allow\n+ask" },
      toolCallId: "tc_policy_scope",
    });

    expect(result.action).toBe("allow");

    const learned = gate.ruleStore
      .getAll()
      .find((rule) => rule.scope === "global" && rule.tool.startsWith("policy."));
    expect(learned).toBeUndefined();

    const latestAudit = gate.auditLog.query({ limit: 1 })[0];
    expect(latestAudit?.userChoice?.scope).toBe("once");
  });
});
