#!/usr/bin/env npx tsx
/**
 * Integration test for the gate socket server.
 *
 * Simulates what the pi extension does:
 * 1. Connect to session socket
 * 2. Send guard_ready
 * 3. Send gate_check for various commands
 * 4. Verify allow/deny/ask responses
 */

import { createConnection, type Socket } from "node:net";
import { createInterface } from "node:readline";
import { PolicyEngine } from "./src/policy.js";
import { GateServer } from "./src/gate.js";

const SESSION_ID = "test-session-1";
const USER_ID = "test-user";

async function main() {
  const policy = new PolicyEngine("admin");
  const gate = new GateServer(policy);

  // Listen for events
  gate.on("guard_ready", ({ sessionId }: any) => {
    console.log(`[event] guard_ready: ${sessionId}`);
  });

  gate.on("approval_needed", (pending: any) => {
    console.log(`[event] approval_needed: ${pending.id} — ${pending.displaySummary}`);
    // Auto-approve after 1 second (simulating phone)
    setTimeout(() => {
      console.log(`[auto-approve] Resolving ${pending.id}`);
      gate.resolveDecision(pending.id, "allow");
    }, 1000);
  });

  // Create session socket
  const socketPath = gate.createSessionSocket(SESSION_ID, USER_ID);
  console.log(`Socket: ${socketPath}`);

  // Wait a tick for socket to be ready
  await new Promise(r => setTimeout(r, 100));

  // Connect as extension
  const client = await connect(socketPath);
  console.log("Connected to gate socket\n");

  // 1. Send guard_ready
  console.log("--- Handshake ---");
  const ack = await sendAndWait(client, {
    type: "guard_ready",
    sessionId: SESSION_ID,
    extensionVersion: "1.0.0",
  });
  console.log(`guard_ack: ${JSON.stringify(ack)}`);
  assert(ack.type === "guard_ack" && ack.status === "ok", "guard_ack should be ok");
  console.log(`Guard state: ${gate.getGuardState(SESSION_ID)}`);
  assert(gate.getGuardState(SESSION_ID) === "guarded", "should be guarded");

  // 2. Test auto-allowed command (ls)
  console.log("\n--- Auto-allow: ls ---");
  const lsResult = await sendAndWait(client, {
    type: "gate_check",
    tool: "bash",
    input: { command: "ls -la" },
    toolCallId: "tc_1",
  });
  console.log(`Result: ${JSON.stringify(lsResult)}`);
  assert(lsResult.action === "allow", "ls should be allowed");

  // 3. Test hard-deny (sudo)
  console.log("\n--- Hard deny: sudo ---");
  const sudoResult = await sendAndWait(client, {
    type: "gate_check",
    tool: "bash",
    input: { command: "sudo rm -rf /" },
    toolCallId: "tc_2",
  });
  console.log(`Result: ${JSON.stringify(sudoResult)}`);
  assert(sudoResult.action === "deny", "sudo should be denied");

  // 4. Test ask (git push) — auto-approved by event handler above
  console.log("\n--- Ask → auto-approve: git push ---");
  const pushResult = await sendAndWait(client, {
    type: "gate_check",
    tool: "bash",
    input: { command: "git push origin main" },
    toolCallId: "tc_3",
  });
  console.log(`Result: ${JSON.stringify(pushResult)}`);
  assert(pushResult.action === "allow", "git push should be allowed after auto-approve");

  // 5. Test heartbeat
  console.log("\n--- Heartbeat ---");
  const hbResult = await sendAndWait(client, { type: "heartbeat" });
  console.log(`Result: ${JSON.stringify(hbResult)}`);
  assert(hbResult.type === "heartbeat_ack", "should get heartbeat_ack");

  // Cleanup
  client.destroy();
  await gate.shutdown();

  console.log("\n✅ All gate tests passed!\n");
}

// ─── Helpers ───

function connect(socketPath: string): Promise<Socket> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath, () => resolve(socket));
    socket.on("error", reject);
  });
}

function sendAndWait(client: Socket, msg: Record<string, unknown>): Promise<any> {
  return new Promise((resolve) => {
    const rl = createInterface({ input: client });
    rl.once("line", (line) => {
      rl.close();
      resolve(JSON.parse(line));
    });
    client.write(JSON.stringify(msg) + "\n");
  });
}

function assert(condition: boolean, msg: string): void {
  if (!condition) {
    console.error(`❌ ASSERTION FAILED: ${msg}`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("Test failed:", err);
  process.exit(1);
});
