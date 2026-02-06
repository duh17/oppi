#!/usr/bin/env npx tsx
/**
 * Full E2E test — real server, real containers, real pi agent.
 *
 * No mocks. Exercises the complete stack:
 *   HTTP API → WebSocket → SessionManager → SandboxManager
 *     → Apple container → pi RPC → LLM → streaming back
 *
 * Prerequisites:
 *   - macOS with `container` CLI (Apple containers)
 *   - ~/.pi/agent/auth.json with valid API credentials
 *   - Network access for LLM API calls
 *
 * The container image (pi-remote:local) is built automatically if missing.
 * First run may take 2–5 min for image build + npm install inside container.
 *
 * Usage:
 *   npx tsx test-e2e.ts
 *
 * Environment:
 *   TEST_MODEL   Override model (default: server config)
 *   TEST_PORT    Override port  (default: 17749)
 */

import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execSync } from "node:child_process";
import WebSocket from "ws";
import { Storage } from "./src/storage.js";
import { Server } from "./src/server.js";
import type { ServerMessage } from "./src/types.js";

// ─── Config ───

const TEST_PORT = parseInt(process.env.TEST_PORT || "17749");
const TEST_MODEL = process.env.TEST_MODEL;
const BASE = `http://127.0.0.1:${TEST_PORT}`;

// Container boot + pi readiness can be slow
const CONTAINER_TIMEOUT = 90_000;
// LLM round-trip
const AGENT_TIMEOUT = 120_000;
// Image build (first run only)
const IMAGE_BUILD_TIMEOUT = 300_000;

// ─── State ───

let tmpDir: string | null = null;
let server: Server | null = null;
let userToken = "";
let passed = 0;
let failed = 0;

// ─── Test Helpers ───

function phase(name: string): void {
  console.log(`\n━━━ ${name} ━━━\n`);
}

function check(name: string, ok: boolean, detail?: string): void {
  if (ok) {
    console.log(`  ✅ ${name}`);
    passed++;
  } else {
    console.log(`  ❌ ${name}${detail ? ` — ${detail}` : ""}`);
    failed++;
  }
}

function log(msg: string): void {
  console.log(`  ${msg}`);
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error(`Timeout: ${label} (${Math.round(ms / 1000)}s)`)), ms),
    ),
  ]);
}

async function cleanup(): Promise<void> {
  if (server) {
    log("Stopping server…");
    await server.stop().catch(() => {});
    server = null;
  }
  if (tmpDir && existsSync(tmpDir)) {
    log(`Removing ${tmpDir}`);
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = null;
  }
}

// ─── HTTP Helpers ───

async function api(
  method: string,
  path: string,
  body?: Record<string, unknown>,
): Promise<{ status: number; data: any }> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (userToken) headers["Authorization"] = `Bearer ${userToken}`;

  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  return { status: res.status, data };
}

// ─── WebSocket Helpers ───

/** Connect WS and wait for the "connected" message (container boot happens here). */
function connectWs(sessionId: string): Promise<{ ws: WebSocket; session: any }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(
      `ws://127.0.0.1:${TEST_PORT}/sessions/${sessionId}/stream`,
      { headers: { Authorization: `Bearer ${userToken}` } },
    );

    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("WS connect timeout — container may have failed to boot"));
    }, CONTAINER_TIMEOUT);

    function onMessage(raw: WebSocket.RawData): void {
      const msg = JSON.parse(raw.toString()) as ServerMessage;
      if (msg.type === "connected") {
        clearTimeout(timer);
        ws.removeListener("message", onMessage);
        resolve({ ws, session: (msg as any).session });
      }
      if (msg.type === "error") {
        clearTimeout(timer);
        ws.removeListener("message", onMessage);
        ws.close();
        reject(new Error(`Server error during connect: ${(msg as any).error}`));
      }
    }

    ws.on("message", onMessage);
    ws.on("error", (err) => { clearTimeout(timer); reject(err); });
  });
}

/** Collect events until agent_end, auto-approving any permission requests. */
function runAgent(
  ws: WebSocket,
  prompt: string,
  timeoutMs = AGENT_TIMEOUT,
): Promise<{
  events: ServerMessage[];
  text: string;
  tools: string[];
  permissionsApproved: number;
  errors: string[];
}> {
  return new Promise((resolve, reject) => {
    const events: ServerMessage[] = [];
    const textChunks: string[] = [];
    const tools: string[] = [];
    const errors: string[] = [];
    let permissionsApproved = 0;

    const timer = setTimeout(() => {
      ws.removeListener("message", onMessage);
      reject(new Error(`Agent timeout after ${Math.round(timeoutMs / 1000)}s`));
    }, timeoutMs);

    function onMessage(raw: WebSocket.RawData): void {
      const msg = JSON.parse(raw.toString()) as ServerMessage;
      events.push(msg);

      switch (msg.type) {
        case "text_delta":
          process.stdout.write(msg.delta);
          textChunks.push(msg.delta);
          break;
        case "thinking_delta":
          // Dim output for thinking
          process.stdout.write(`\x1b[2m${msg.delta}\x1b[0m`);
          break;
        case "tool_start":
          log(`\n  🔧 ${msg.tool}(${JSON.stringify(msg.args).slice(0, 80)})`);
          tools.push(msg.tool);
          break;
        case "tool_output":
          // Show truncated tool output
          if (msg.output.length <= 200) process.stdout.write(`  ${msg.output}`);
          break;
        case "permission_request":
          log(`  🔒 Auto-approving: ${(msg as any).displaySummary}`);
          ws.send(JSON.stringify({
            type: "permission_response",
            id: (msg as any).id,
            action: "allow",
          }));
          permissionsApproved++;
          break;
        case "error":
          errors.push((msg as any).error);
          log(`  ⚠️  ${(msg as any).error}`);
          break;
        case "agent_end":
          clearTimeout(timer);
          ws.removeListener("message", onMessage);
          console.log(""); // newline after streaming
          resolve({ events, text: textChunks.join(""), tools, permissionsApproved, errors });
          break;
      }
    }

    ws.on("message", onMessage);

    // Send the prompt
    ws.send(JSON.stringify({ type: "prompt", message: prompt }));
  });
}

// ─── Phases ───

async function checkPrerequisites(): Promise<void> {
  phase("Phase 0 — Prerequisites");

  try {
    execSync("which container", { stdio: "pipe" });
    log("✓ container CLI found");
  } catch {
    throw new Error("`container` CLI not found. Need macOS with Apple container support.");
  }

  const authPath = join(process.env.HOME!, ".pi", "agent", "auth.json");
  if (!existsSync(authPath)) {
    throw new Error(`${authPath} not found. Need API credentials for pi.`);
  }
  log("✓ auth.json found");

  // Check image (informational — server.start() builds if missing)
  try {
    const images = execSync("container image list", { encoding: "utf-8" });
    if (images.includes("pi-remote")) {
      log("✓ pi-remote:local image exists");
    } else {
      log("⚠  pi-remote:local image not found — will build on start (2–5 min)");
    }
  } catch {}
}

async function startServer(): Promise<void> {
  phase("Phase 1 — Server Setup");

  tmpDir = mkdtempSync(join(tmpdir(), "pi-remote-e2e-"));
  log(`Data dir: ${tmpDir}`);

  const storage = new Storage(tmpDir);
  storage.updateConfig({ port: TEST_PORT });

  const user = storage.createUser("e2e-tester");
  userToken = user.token;
  log(`User: ${user.name} (${user.id})`);

  server = new Server(storage);
  log("Starting server…");
  await withTimeout(server.start(), IMAGE_BUILD_TIMEOUT, "server start + image build");
  log(`✓ Listening on :${TEST_PORT}`);
}

async function testHttpApi(): Promise<void> {
  phase("Phase 2 — HTTP API");

  // Health
  const health = await api("GET", "/health");
  check("GET /health → 200", health.status === 200);
  check("/health body ok", health.data.ok === true);

  // Auth
  const saved = userToken;
  userToken = "";
  const noAuth = await fetch(`${BASE}/me`);
  check("GET /me without token → 401", noAuth.status === 401);
  userToken = saved;

  const me = await api("GET", "/me");
  check("GET /me → 200 with name", me.status === 200 && me.data.name === "e2e-tester");

  // Sessions — empty
  const empty = await api("GET", "/sessions");
  check("GET /sessions → empty", empty.data.sessions?.length === 0);

  // Create session
  const model = TEST_MODEL || "anthropic/claude-haiku-4-5";
  const created = await api("POST", "/sessions", { name: "e2e-test", model });
  check("POST /sessions → 201", created.status === 201);
  check("Response includes session id", !!created.data.session?.id);
  log(`Session: ${created.data.session?.id} (${model})`);

  // List
  const list = await api("GET", "/sessions");
  check("GET /sessions → 1 session", list.data.sessions?.length === 1);

  // Detail
  const detail = await api("GET", `/sessions/${created.data.session?.id}`);
  check("GET /sessions/:id → correct session", detail.data.session?.id === created.data.session?.id);
}

async function testAgentSession(): Promise<string> {
  phase("Phase 3 — Agent Session (real container + LLM)");

  // Get the session we created in Phase 2
  const sessions = await api("GET", "/sessions");
  const sessionId = sessions.data.sessions?.[0]?.id;
  if (!sessionId) throw new Error("No session found — Phase 2 may have failed");

  // Connect WebSocket (this boots the container)
  log("Connecting WebSocket — booting container…");
  const { ws, session } = await withTimeout(
    connectWs(sessionId),
    CONTAINER_TIMEOUT,
    "container boot",
  );
  check("Container booted, session ready", session.status === "ready");

  // ── Run 1: Simple tool use (auto-allowed by policy) ──
  log("\n── Run 1: Tool use (ls — auto-allowed) ──\n");
  const run1 = await withTimeout(
    runAgent(ws, "List files in /work with ls -la. Keep your response to one sentence."),
    AGENT_TIMEOUT,
    "agent run 1",
  );

  check("agent_start received", run1.events.some(e => e.type === "agent_start"));
  check("agent_end received", run1.events.some(e => e.type === "agent_end"));
  check("Got text output", run1.text.length > 0, `${run1.text.length} chars`);
  check("No errors", run1.errors.length === 0, run1.errors.join("; "));

  log(`  Tools used: ${run1.tools.length > 0 ? run1.tools.join(", ") : "(none — text only)"}`);
  log(`  Permissions auto-approved: ${run1.permissionsApproved}`);

  // ── Run 2: Permission-gated command ──
  log("\n── Run 2: Permission gate (npm — requires approval) ──\n");
  const run2 = await withTimeout(
    runAgent(ws, "Run `npm --version` and tell me the version number. Nothing else."),
    AGENT_TIMEOUT,
    "agent run 2",
  );

  check("Run 2 completed", run2.events.some(e => e.type === "agent_end"));
  check("Got text output", run2.text.length > 0);

  // Permission gate is informational — extension may or may not be connected
  if (run2.permissionsApproved > 0) {
    log(`  ✓ Permission gate verified — ${run2.permissionsApproved} request(s) auto-approved`);
  } else {
    log("  ⚠  No permission requests seen (extension may not have connected to gate)");
  }

  ws.close();
  return sessionId;
}

async function testCleanup(sessionId: string): Promise<void> {
  phase("Phase 4 — Session Cleanup");

  const del = await api("DELETE", `/sessions/${sessionId}`);
  check("DELETE /sessions/:id → 200", del.status === 200);

  const list = await api("GET", "/sessions");
  check("Sessions empty after delete", list.data.sessions?.length === 0);
}

// ─── Main ───

async function main(): Promise<void> {
  console.log("\n╭───────────────────────────────────────────╮");
  console.log("│      pi-remote E2E test (no mocks)        │");
  console.log("╰───────────────────────────────────────────╯");

  await checkPrerequisites();
  await startServer();
  await testHttpApi();
  const sessionId = await testAgentSession();
  await testCleanup(sessionId);

  // ── Results ──
  phase("Results");
  console.log(`  Passed: ${passed}`);
  console.log(`  Failed: ${failed}`);
  console.log(`  Total:  ${passed + failed}\n`);

  await cleanup();
  process.exit(failed > 0 ? 1 : 0);
}

process.on("SIGINT", async () => {
  console.log("\n\nInterrupted — cleaning up…");
  await cleanup();
  process.exit(130);
});

main().catch(async (err) => {
  console.error(`\n❌ Fatal: ${err.message}\n`);
  if (err.stack) console.error(err.stack);
  await cleanup();
  process.exit(1);
});
