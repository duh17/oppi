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

const SESSION_ID = "test-session-1";
const USER_ID = "test-user";

let gate: GateServer;
let client: Socket;
let testDir = "";

beforeEach(() => {
  testDir = mkdtempSync(join(tmpdir(), "pi-remote-gate-test-"));
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

function createGate(preset: string = "container"): GateServer {
  const policy = new PolicyEngine(preset);
  const ruleStore = new RuleStore(join(testDir, "rules.json"));
  const auditLog = new AuditLog(join(testDir, "audit.jsonl"));
  return new GateServer(policy, ruleStore, auditLog);
}

async function setupGuardedSession(): Promise<void> {
  gate = createGate("container");
  const activeGate = gate;

  // Auto-approve any "ask" decisions after short delay
  activeGate.on("approval_needed", (pending: { id: string }) => {
    setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 200);
  });

  const port = await activeGate.createSessionSocket(SESSION_ID, USER_ID);
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
    const port = await gate.createSessionSocket(SESSION_ID, USER_ID);
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

  it("asks for chained git push in host mode", async () => {
    gate = createGate("host");
    const activeGate = gate;
    let approvalCount = 0;
    let lastReason = "";

    activeGate.on("approval_needed", (pending: { id: string; reason: string }) => {
      approvalCount += 1;
      lastReason = pending.reason;
      setTimeout(() => activeGate.resolveDecision(pending.id, "allow"), 20);
    });

    const port = await activeGate.createSessionSocket(SESSION_ID, USER_ID);
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
      input: { command: "cd /Users/chenda/workspace/pios && git push origin main" },
      toolCallId: "tc_3b",
    });

    expect(result.action).toBe("allow");
    expect(approvalCount).toBe(1);
    expect(lastReason).toBe("Git push");
  });

  it("responds to heartbeat", async () => {
    await setupGuardedSession();

    const result = await sendAndWait(client, { type: "heartbeat" });
    expect(result.type).toBe("heartbeat_ack");
  });
});
