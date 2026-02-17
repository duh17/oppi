#!/usr/bin/env npx tsx
/**
 * Test client for the permission gate.
 *
 * Connects to oppi-server via WebSocket and handles permission requests
 * from the keyboard: y=allow, n=deny.
 *
 * Usage:
 *   npx tsx test-gate-client.ts <host:port> <token> [workspaceId] [sessionId]
 *
 * Examples:
 *   # List all workspace sessions and exit
 *   npx tsx test-gate-client.ts localhost:7749 sk_abc123
 *
 *   # List sessions in one workspace and exit
 *   npx tsx test-gate-client.ts localhost:7749 sk_abc123 ws_123
 *
 *   # Connect to a specific session
 *   npx tsx test-gate-client.ts localhost:7749 sk_abc123 ws_123 sess_xyz
 */

import WebSocket from "ws";
import { createInterface } from "node:readline";

interface WorkspaceSummary {
  id: string;
  name?: string;
}

interface SessionSummary {
  id: string;
  status?: string;
  name?: string;
  model?: string;
}

const [host, token, argWorkspaceId, argSessionId] = process.argv.slice(2);

if (!host || !token) {
  console.error("Usage: test-gate-client.ts <host:port> <token> [workspaceId] [sessionId]");
  process.exit(1);
}

const baseUrl = `http://${host}`;
const wsBaseUrl = `ws://${host}`;

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${baseUrl}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${res.status} ${res.statusText} ${path}${body ? `: ${body}` : ""}`);
  }

  return (await res.json()) as T;
}

async function listWorkspaces(): Promise<WorkspaceSummary[]> {
  const data = await getJson<{ workspaces?: WorkspaceSummary[] }>("/workspaces");
  return data.workspaces ?? [];
}

async function listWorkspaceSessions(workspaceId: string): Promise<SessionSummary[]> {
  const data = await getJson<{ sessions?: SessionSummary[] }>(`/workspaces/${workspaceId}/sessions`);
  return data.sessions ?? [];
}

async function printAllSessions(): Promise<void> {
  const workspaces = await listWorkspaces();

  if (workspaces.length === 0) {
    console.log("\nNo workspaces found.");
    return;
  }

  console.log("\nWorkspaces + sessions:");
  for (const workspace of workspaces) {
    const sessions = await listWorkspaceSessions(workspace.id);
    console.log(`\n  ${workspace.id}  (${workspace.name || "unnamed"})`);

    if (sessions.length === 0) {
      console.log("    (no sessions)");
      continue;
    }

    for (const session of sessions) {
      console.log(
        `    ${session.id}  ${session.status || "?"}  ${session.name || "(unnamed)"}  ${session.model || ""}`,
      );
    }
  }
}

async function resolveWorkspaceForSession(sessionId: string): Promise<string | null> {
  const workspaces = await listWorkspaces();

  for (const workspace of workspaces) {
    const sessions = await listWorkspaceSessions(workspace.id);
    if (sessions.some((session) => session.id === sessionId)) {
      return workspace.id;
    }
  }

  return null;
}

async function main(): Promise<void> {
  let workspaceId = argWorkspaceId;
  const sessionId = argSessionId;

  if (!workspaceId && !sessionId) {
    await printAllSessions();
    console.log("\nRe-run with <workspaceId> <sessionId> to connect.");
    process.exit(0);
  }

  if (workspaceId && !sessionId) {
    const sessions = await listWorkspaceSessions(workspaceId);
    console.log(`\nSessions in workspace ${workspaceId}:`);
    for (const session of sessions) {
      console.log(
        `  ${session.id}  ${session.status || "?"}  ${session.name || "(unnamed)"}  ${session.model || ""}`,
      );
    }
    console.log("\nRe-run with <workspaceId> <sessionId> to connect.");
    process.exit(0);
  }

  if (!sessionId) {
    throw new Error("sessionId is required when connecting");
  }

  if (!workspaceId) {
    workspaceId = await resolveWorkspaceForSession(sessionId);
    if (!workspaceId) {
      throw new Error(`Could not find workspace for session ${sessionId}`);
    }
    console.log(`Resolved workspace ${workspaceId} for session ${sessionId}`);
  }

  const wsUrl = `${wsBaseUrl}/workspaces/${workspaceId}/sessions/${sessionId}/stream`;
  console.log(`Connecting to ${wsUrl} ...`);

  const ws = new WebSocket(wsUrl, {
    headers: { Authorization: `Bearer ${token}` },
  });

  const pendingRequests: Map<string, { displaySummary: string; risk: string; tool: string }> = new Map();

  ws.on("open", () => {
    console.log("✅ Connected\n");
  });

  ws.on("message", (data) => {
    const msg = JSON.parse(data.toString()) as { type: string; [key: string]: unknown };

    switch (msg.type) {
      case "connected":
        console.log(`Session: ${String((msg.session as { id?: string })?.id || "?")} (${String((msg.session as { status?: string })?.status || "?")})`);
        break;

      case "permission_request": {
        pendingRequests.set(String(msg.id), {
          displaySummary: String(msg.displaySummary),
          risk: String(msg.risk),
          tool: String(msg.tool),
        });

        const risk = String(msg.risk);
        const riskColor = risk === "critical" ? "\x1b[31m" :
          risk === "high" ? "\x1b[33m" :
            risk === "medium" ? "\x1b[36m" : "\x1b[32m";
        const reset = "\x1b[0m";

        console.log(`\n🔒 PERMISSION REQUEST [${String(msg.id)}]`);
        console.log(`   ${riskColor}${risk.toUpperCase()}${reset} — ${String(msg.displaySummary)}`);
        console.log(`   Reason: ${String(msg.reason)}`);
        console.log(`   Tool: ${String(msg.tool)}`);
        const timeoutAt = Number(msg.timeoutAt);
        const timeLeft = Number.isFinite(timeoutAt) ? Math.round((timeoutAt - Date.now()) / 1000) : -1;
        console.log(`   Timeout: ${timeLeft}s`);
        console.log("   → y=allow  n=deny");
        break;
      }

      case "permission_expired":
        console.log(`⏰ Permission expired: ${String(msg.id)} — ${String(msg.reason)}`);
        pendingRequests.delete(String(msg.id));
        break;

      case "text_delta":
        process.stdout.write(String(msg.delta || ""));
        break;

      case "thinking_delta":
        process.stdout.write(`\x1b[2m${String(msg.delta || "")}\x1b[0m`);
        break;

      case "tool_start":
        console.log(`\n🔧 ${String(msg.tool)}(${JSON.stringify(msg.args).slice(0, 100)})`);
        break;

      case "tool_output":
        process.stdout.write(String(msg.output || ""));
        break;

      case "tool_end":
        console.log(`\n✅ ${String(msg.tool)} done`);
        break;

      case "agent_start":
        console.log("\n--- Agent thinking ---");
        break;

      case "agent_end":
        console.log("\n--- Agent done ---");
        break;

      case "session_ended":
        console.log(`\nSession ended: ${String(msg.reason || "unknown")}`);
        break;

      case "error":
        console.error(`\n❌ Error: ${String(msg.error || "unknown")}`);
        break;

      default:
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

  // Keyboard input for permission responses and prompts.
  const rl = createInterface({ input: process.stdin, output: process.stdout });

  rl.on("line", (line) => {
    const trimmed = line.trim();

    // Check for permission response.
    if (trimmed === "y" || trimmed === "n") {
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

    // Otherwise treat as a prompt.
    if (trimmed) {
      ws.send(JSON.stringify({ type: "prompt", message: trimmed }));
      console.log(`→ Sent prompt: ${trimmed}`);
    }
  });

  console.log("Type a prompt to send to pi, or y/n to respond to permission requests.\n");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
