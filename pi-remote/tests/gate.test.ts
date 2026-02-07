import { describe, it, expect, afterEach } from "vitest";
import { createConnection, type Socket } from "node:net";
import { createInterface } from "node:readline";
import { PolicyEngine } from "../src/policy.js";
import { GateServer } from "../src/gate.js";

const SESSION_ID = "test-session-1";
const USER_ID = "test-user";

let gate: GateServer;
let client: Socket;

afterEach(async () => {
  if (client && !client.destroyed) client.destroy();
  if (gate) await gate.shutdown();
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

async function setupGuardedSession(): Promise<void> {
  const policy = new PolicyEngine("container");
  gate = new GateServer(policy);

  // Auto-approve any "ask" decisions after short delay
  gate.on("approval_needed", (pending: { id: string }) => {
    setTimeout(() => gate.resolveDecision(pending.id, "allow"), 200);
  });

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
}

describe("GateServer", () => {
  it("completes guard handshake", async () => {
    const policy = new PolicyEngine("container");
    gate = new GateServer(policy);
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

  it("responds to heartbeat", async () => {
    await setupGuardedSession();

    const result = await sendAndWait(client, { type: "heartbeat" });
    expect(result.type).toBe("heartbeat_ack");
  });
});
