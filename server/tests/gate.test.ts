import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { PolicyEngine } from "../src/policy.js";
import { GateServer } from "../src/gate.js";
import { RuleStore } from "../src/rules.js";
import { AuditLog } from "../src/audit.js";
import type { PolicyConfig } from "../src/types.js";

const SESSION_ID = "test-session-1";

let gate: GateServer;
let client: Socket;
let testDir = "";

beforeEach(() => {
  testDir = mkdtempSync(join(tmpdir(), "oppi-server-gate-test-"));
});

afterEach(async () => {
  if (client && !client.destroyed) client.destroy();
  if (gate) await gate.shutdown();
  rmSync(testDir, { recursive: true, force: true });
});

function connect(port: number): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ port, host: "127.0.0.1" }, () => resolve(socket));
    socket.on("error", reject);
  });
}

function sendAndWait(sock: Socket, msg: Record<string, unknown>): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    const rl = createInterface({ input: sock });
    rl.once("line", (line) => {
      rl.close();
      resolve(JSON.parse(line));
    });
    sock.write(JSON.stringify(msg) + "\n");
  });
}

function createGate(
  policyOrMode: string | PolicyConfig = "container",
  approvalTimeoutMs?: number,
): GateServer {
  const policy = new PolicyEngine(policyOrMode);
  const ruleStore = new RuleStore(join(testDir, "rules.json"));
  const auditLog = new AuditLog(join(testDir, "audit.jsonl"));
  return new GateServer(policy, ruleStore, auditLog, { approvalTimeoutMs });
}

async function setupGuardedSession(): Promise<void> {
  gate = createGate("container");
  const activeGate = gate;

  // Auto-approve any "ask" decisions after short delay
  activeGate.on("approval_needed", (pending: { id: string }) => {
    setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 200);
  });

  const port = await activeGate.createSessionSocket(SESSION_ID);
  await new Promise(r => setTimeout(r, 50));
  client = await connect(port);

  const ack = await sendAndWait(client, {
    type: "guard_ready",
    sessionId: SESSION_ID,
    extensionVersion: "1.0.0",
  });
  expect(ack.type).toBe("guard_ack");
  expect(ack.status).toBe("ok");
}

describe("GateServer", () => {
  it("completes guard handshake", async () => {
    gate = createGate("container");
    const port = await gate.createSessionSocket(SESSION_ID);
    await new Promise(r => setTimeout(r, 50));

    client = await connect(port);
    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });

    expect(ack.type).toBe("guard_ack");
    expect(ack.status).toBe("ok");
    expect(gate.getGuardState(SESSION_ID)).toBe("guarded");
  });

  it("auto-allows safe commands (ls)", async () => {
    await setupGuardedSession();

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "ls -la" },
      toolCallId: "tc_1",
    });

    expect(result.action).toBe("allow");
  });

  it("hard-denies dangerous commands (sudo)", async () => {
    await setupGuardedSession();

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "sudo rm -rf /" },
      toolCallId: "tc_2",
    });

    expect(result.action).toBe("deny");
  });

  it("asks then allows after approval (git push --force)", async () => {
    await setupGuardedSession();

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "git push --force origin main" },
      toolCallId: "tc_3",
    });

    // Auto-approved by the approval_needed handler after 200ms
    expect(result.action).toBe("allow");
  });

  it("uses configurable approval timeout when set", async () => {
    gate = createGate("host", 25);
    const activeGate = gate;

    activeGate.on("approval_needed", (pending: { id: string }) => {
      // Intentionally slower than timeout.
      setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 80);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID);
    await new Promise(r => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_timeout",
    });

    expect(result.action).toBe("deny");
    expect(result.reason).toBe("Approval timeout");
  });

  it("disables approval expiry when approvalTimeoutMs=0", async () => {
    gate = createGate("host", 0);
    const activeGate = gate;

    activeGate.on("approval_needed", (pending: { id: string }) => {
      setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 80);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID);
    await new Promise(r => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_no_timeout",
    });

    expect(result.action).toBe("allow");
  });

  it("asks for chained git push in local execution", async () => {
    gate = createGate("host");
    const activeGate = gate;
    let approvalCount = 0;
    let lastReason = "";

    activeGate.on("approval_needed", (pending: { id: string; reason: string }) => {
      approvalCount += 1;
      lastReason = pending.reason;
      setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 20);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID);
    await new Promise(r => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");
    expect(ack.status).toBe("ok");

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "cd /Users/dev/workspace/myproject && git push origin main" },
      toolCallId: "tc_3b",
    });

    expect(result.action).toBe("allow");
    expect(approvalCount).toBe(1);
    expect(lastReason).toBe("Git push");
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

    gate = createGate(askFallbackPolicy);
    const activeGate = gate;

    let approvalCount = 0;
    const approvalReasons: string[] = [];

    activeGate.on("approval_needed", (pending: { id: string; reason: string }) => {
      approvalCount += 1;
      approvalReasons.push(pending.reason);
      setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 10);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID, "w1");
    await new Promise((r) => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");

    const runFallbackCheck = (toolCallId: string) =>
      sendAndWait(client, {
        type: "gate_check",
        tool: "bash",
        input: { command: "echo fallback-toggle-check" },
        toolCallId,
      });

    const askResult1 = await runFallbackCheck("tc_fallback_1");
    expect(askResult1.action).toBe("allow");
    expect(approvalCount).toBe(1);
    expect(approvalReasons[0]).toContain("No matching rule");

    activeGate.setSessionPolicy(SESSION_ID, new PolicyEngine(allowFallbackPolicy));

    const allowResult = await runFallbackCheck("tc_fallback_2");
    expect(allowResult.action).toBe("allow");
    expect(approvalCount).toBe(1);

    activeGate.setSessionPolicy(SESSION_ID, new PolicyEngine(askFallbackPolicy));

    const askResult2 = await runFallbackCheck("tc_fallback_3");
    expect(askResult2.action).toBe("allow");
    expect(approvalCount).toBe(2);
    expect(approvalReasons[1]).toContain("No matching rule");
  });

  it("stores session rules with TTL from permission responses", async () => {
    gate = createGate("host");
    const activeGate = gate;
    let approvalAt = 0;

    activeGate.on("approval_needed", (pending: { id: string }) => {
      approvalAt = Date.now();
      activeGate.resolveDecision(pending.id, "allow", "session", 60_000);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID, "w1");
    await new Promise((r) => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_ttl_workspace",
    });

    expect(result.action).toBe("allow");

    const learned = activeGate
      .ruleStore
      .getAll()
      .find(
        (rule) =>
          rule.scope === "session" &&
          rule.sessionId === SESSION_ID &&
          rule.effect === "allow" &&
          rule.tool === "bash" &&
          rule.match?.commandPattern === "git push*",
      );

    expect(learned).toBeTruthy();
    expect(typeof learned?.expiresAt).toBe("number");

    const ttlMs = (learned?.expiresAt ?? 0) - approvalAt;
    expect(ttlMs).toBeGreaterThanOrEqual(55_000);
    expect(ttlMs).toBeLessThanOrEqual(65_000);
  });

  it("caps learned session-rule TTL at one year", async () => {
    gate = createGate("host");
    const activeGate = gate;
    let approvalAt = 0;

    activeGate.on("approval_needed", (pending: { id: string }) => {
      approvalAt = Date.now();
      activeGate.resolveDecision(pending.id, "allow", "session", 10 * 365 * 24 * 60 * 60 * 1000);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID, "w1");
    await new Promise((r) => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_ttl_cap",
    });

    expect(result.action).toBe("allow");

    const learned = activeGate
      .ruleStore
      .getAll()
      .find(
        (rule) =>
          rule.scope === "session" &&
          rule.sessionId === SESSION_ID &&
          rule.effect === "allow" &&
          rule.tool === "bash" &&
          rule.match?.commandPattern === "git push*",
      );

    expect(learned).toBeTruthy();
    expect(typeof learned?.expiresAt).toBe("number");

    const ttlMs = (learned?.expiresAt ?? 0) - approvalAt;
    const oneYearMs = 365 * 24 * 60 * 60 * 1000;
    expect(ttlMs).toBeGreaterThanOrEqual(oneYearMs - 5_000);
    expect(ttlMs).toBeLessThanOrEqual(oneYearMs + 5_000);
  });

  it("downgrades unsupported allow scope to once", async () => {
    gate = createGate("host");
    const activeGate = gate;

    activeGate.on("approval_needed", (pending: { id: string }) => {
      // git push only permits allowSession in resolution options.
      activeGate.resolveDecision(pending.id, "allow", "workspace", 60_000);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID, "w1");
    await new Promise((r) => setTimeout(r, 50));
    client = await connect(port);

    const ack = await sendAndWait(client, {
      type: "guard_ready",
      sessionId: SESSION_ID,
      extensionVersion: "1.0.0",
    });
    expect(ack.type).toBe("guard_ack");

    const result = await sendAndWait(client, {
      type: "gate_check",
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc_scope_downgrade",
    });

    expect(result.action).toBe("allow");

    const learned = activeGate
      .ruleStore
      .getAll()
      .find((rule) => rule.scope === "workspace" && rule.workspaceId === "w1" && rule.effect === "allow");
    expect(learned).toBeUndefined();
  });

  it("responds to heartbeat", async () => {
    await setupGuardedSession();

    const result = await sendAndWait(client, { type: "heartbeat" });
    expect(result.type).toBe("heartbeat_ack");
  });
});
