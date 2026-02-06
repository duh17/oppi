#!/usr/bin/env npx tsx
/**
 * Test client for the permission gate.
 *
 * Connects to pi-remote via WebSocket and handles permission requests
 * from the keyboard: y=allow, n=deny.
 *
 * Usage:
 *   npx tsx test-gate-client.ts <host:port> <token> [sessionId]
 *
 * Example:
 *   npx tsx test-gate-client.ts localhost:7749 sk_abc123 sess_xyz
 */

import WebSocket from "ws";
import { createInterface } from "node:readline";

const [host, token, sessionId] = process.argv.slice(2);

if (!host || !token) {
  console.error("Usage: test-gate-client.ts <host:port> <token> [sessionId]");
  console.error("  If no sessionId, lists sessions then exits.");
  process.exit(1);
}

const baseUrl = `http://${host}`;
const wsUrl = `ws://${host}`;

async function listSessions(): Promise<void> {
  const res = await fetch(`${baseUrl}/sessions`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const data = await res.json() as any;
  console.log("\nSessions:");
  for (const s of data.sessions || []) {
    console.log(`  ${s.id}  ${s.status}  ${s.name || "(unnamed)"}  ${s.model || ""}`);
  }
}

async function main(): Promise<void> {
  if (!sessionId) {
    await listSessions();
    console.log("\nRe-run with a sessionId to connect.");
    process.exit(0);
  }

  console.log(`Connecting to ${wsUrl}/sessions/${sessionId}/stream ...`);

  const ws = new WebSocket(`${wsUrl}/sessions/${sessionId}/stream`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  const pendingRequests: Map<string, { displaySummary: string; risk: string; tool: string }> = new Map();

  ws.on("open", () => {
    console.log("✅ Connected\n");
  });

  ws.on("message", (data) => {
    const msg = JSON.parse(data.toString());

    switch (msg.type) {
      case "connected":
        console.log(`Session: ${msg.session.id} (${msg.session.status})`);
        break;

      case "permission_request":
        pendingRequests.set(msg.id, {
          displaySummary: msg.displaySummary,
          risk: msg.risk,
          tool: msg.tool,
        });

        const riskColor = msg.risk === "critical" ? "\x1b[31m" :
                          msg.risk === "high" ? "\x1b[33m" :
                          msg.risk === "medium" ? "\x1b[36m" : "\x1b[32m";
        const reset = "\x1b[0m";

        console.log(`\n🔒 PERMISSION REQUEST [${msg.id}]`);
        console.log(`   ${riskColor}${msg.risk.toUpperCase()}${reset} — ${msg.displaySummary}`);
        console.log(`   Reason: ${msg.reason}`);
        console.log(`   Tool: ${msg.tool}`);
        const timeLeft = Math.round((msg.timeoutAt - Date.now()) / 1000);
        console.log(`   Timeout: ${timeLeft}s`);
        console.log(`   → y=allow  n=deny`);
        break;

      case "permission_expired":
        console.log(`⏰ Permission expired: ${msg.id} — ${msg.reason}`);
        pendingRequests.delete(msg.id);
        break;

      case "text_delta":
        process.stdout.write(msg.delta);
        break;

      case "thinking_delta":
        process.stdout.write(`\x1b[2m${msg.delta}\x1b[0m`);
        break;

      case "tool_start":
        console.log(`\n🔧 ${msg.tool}(${JSON.stringify(msg.args).slice(0, 100)})`);
        break;

      case "tool_output":
        process.stdout.write(msg.output);
        break;

      case "tool_end":
        console.log(`\n✅ ${msg.tool} done`);
        break;

      case "agent_start":
        console.log("\n--- Agent thinking ---");
        break;

      case "agent_end":
        console.log("\n--- Agent done ---");
        break;

      case "session_ended":
        console.log(`\nSession ended: ${msg.reason}`);
        break;

      case "error":
        console.error(`\n❌ Error: ${msg.error}`);
        break;
    }
  });

  ws.on("close", () => {
    console.log("\nDisconnected");
    process.exit(0);
  });

  ws.on("error", (err) => {
    console.error("WebSocket error:", err.message);
    process.exit(1);
  });

  // Keyboard input for permission responses and prompts
  const rl = createInterface({ input: process.stdin, output: process.stdout });

  rl.on("line", (line) => {
    const trimmed = line.trim();

    // Check for permission response
    if (trimmed === "y" || trimmed === "n") {
      // Find the oldest pending request
      const [id, req] = pendingRequests.entries().next().value || [];
      if (!id) {
        console.log("No pending permission requests.");
        return;
      }

      const action = trimmed === "y" ? "allow" : "deny";
      ws.send(JSON.stringify({ type: "permission_response", id, action }));
      console.log(`→ ${action === "allow" ? "✅ Allowed" : "❌ Denied"}: ${req.displaySummary}`);
      pendingRequests.delete(id);
      return;
    }

    // Otherwise treat as a prompt
    if (trimmed) {
      ws.send(JSON.stringify({ type: "prompt", message: trimmed }));
      console.log(`→ Sent prompt: ${trimmed}`);
    }
  });

  console.log("Type a prompt to send to pi, or y/n to respond to permission requests.\n");
}

main().catch(console.error);
