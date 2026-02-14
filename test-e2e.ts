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
 * The container image (oppi-server:local) is built automatically if missing.
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
import { performance } from "node:perf_hooks";
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
// Cap console streaming to keep test logs bounded if model gets verbose/stuck.
const MAX_PRINTED_STREAM_CHARS = 2000;
// Image build (first run only)
const IMAGE_BUILD_TIMEOUT = 300_000;

// ─── State ───

let tmpDir: string | null = null;
let server: Server | null = null;
let userToken = "";
let workspaceId = "";
let passed = 0;
let failed = 0;

interface IntervalSummary {
  count: number;
  minMs: number;
  maxMs: number;
  avgMs: number;
  p50Ms: number;
  p95Ms: number;
}

interface StreamMetrics {
  promptToFirstEventMs?: number;
  promptToAgentStartMs?: number;
  promptToFirstTextMs?: number;
  promptToFirstToolStartMs?: number;
  promptToFirstPermissionMs?: number;
  promptToAgentEndMs?: number;

  eventCount: number;
  textDeltaCount: number;
  thinkingDeltaCount: number;
  toolStartCount: number;
  toolOutputCount: number;
  permissionRequestCount: number;
  errorCount: number;

  eventInterval?: IntervalSummary;
  textDeltaInterval?: IntervalSummary;
}

interface StopRunMetrics {
  promptToAgentStartMs?: number;
  promptToStopMs?: number;
  stopToTerminalMs?: number;
  promptToTerminalMs?: number;
  stopTrigger?: string;
  terminationType: "agent_end" | "session_ended";
  eventCount: number;
  permissionRequestCount: number;
  errorCount: number;
}

interface StopRunResult {
  events: ServerMessage[];
  errors: string[];
  permissionsApproved: number;
  stopSent: boolean;
  metrics: StopRunMetrics;
}

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

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) {
    return 0;
  }

  const index = (sorted.length - 1) * p;
  const lower = Math.floor(index);
  const upper = Math.ceil(index);

  if (lower === upper) {
    return sorted[lower];
  }

  const weight = index - lower;
  return sorted[lower] + (sorted[upper] - sorted[lower]) * weight;
}

function summarizeIntervals(samples: number[]): IntervalSummary | undefined {
  if (samples.length === 0) {
    return undefined;
  }

  const sorted = [...samples].sort((a, b) => a - b);
  let total = 0;
  for (const sample of sorted) {
    total += sample;
  }

  return {
    count: sorted.length,
    minMs: sorted[0],
    maxMs: sorted[sorted.length - 1],
    avgMs: total / sorted.length,
    p50Ms: percentile(sorted, 0.50),
    p95Ms: percentile(sorted, 0.95),
  };
}

function formatMs(ms: number | undefined): string {
  if (ms === undefined) {
    return "n/a";
  }
  return `${ms.toFixed(1)}ms`;
}

function printIntervalSummary(name: string, summary: IntervalSummary | undefined): void {
  if (!summary) {
    log(`${name}: n/a`);
    return;
  }

  log(
    `${name}: n=${summary.count}, avg=${summary.avgMs.toFixed(1)}ms, `
    + `p50=${summary.p50Ms.toFixed(1)}ms, p95=${summary.p95Ms.toFixed(1)}ms, `
    + `max=${summary.maxMs.toFixed(1)}ms`,
  );
}

function printRunMetrics(label: string, metrics: StreamMetrics): void {
  log(`${label} performance:`);
  log(`  prompt → first event: ${formatMs(metrics.promptToFirstEventMs)}`);
  log(`  prompt → agent_start: ${formatMs(metrics.promptToAgentStartMs)}`);
  log(`  prompt → first text_delta: ${formatMs(metrics.promptToFirstTextMs)}`);
  log(`  prompt → first tool_start: ${formatMs(metrics.promptToFirstToolStartMs)}`);
  log(`  prompt → first permission_request: ${formatMs(metrics.promptToFirstPermissionMs)}`);
  log(`  prompt → agent_end: ${formatMs(metrics.promptToAgentEndMs)}`);

  log(
    "  event counts: "
    + `total=${metrics.eventCount}, text=${metrics.textDeltaCount}, `
    + `thinking=${metrics.thinkingDeltaCount}, tool_start=${metrics.toolStartCount}, `
    + `tool_output=${metrics.toolOutputCount}, permissions=${metrics.permissionRequestCount}, `
    + `errors=${metrics.errorCount}`,
  );

  printIntervalSummary("  all-event spacing", metrics.eventInterval);
  printIntervalSummary("  text-delta spacing", metrics.textDeltaInterval);
}

function printStopRunMetrics(label: string, metrics: StopRunMetrics): void {
  log(`${label} stop behavior:`);
  log(`  termination: ${metrics.terminationType}`);
  log(`  stop trigger: ${metrics.stopTrigger || "n/a"}`);
  log(`  prompt → agent_start: ${formatMs(metrics.promptToAgentStartMs)}`);
  log(`  prompt → stop sent: ${formatMs(metrics.promptToStopMs)}`);
  log(`  stop sent → terminal: ${formatMs(metrics.stopToTerminalMs)}`);
  log(`  prompt → terminal: ${formatMs(metrics.promptToTerminalMs)}`);
  log(
    "  event counts: "
    + `total=${metrics.eventCount}, permissions=${metrics.permissionRequestCount}, `
    + `errors=${metrics.errorCount}`,
  );
}

function definedNumbers(values: Array<number | undefined>): number[] {
  const nums: number[] = [];
  for (const value of values) {
    if (value !== undefined) {
      nums.push(value);
    }
  }
  return nums;
}

function average(values: number[]): number | undefined {
  if (values.length === 0) {
    return undefined;
  }

  let total = 0;
  for (const value of values) {
    total += value;
  }
  return total / values.length;
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

function wsSessionPath(workspace: string, session: string): string {
  return `/workspaces/${workspace}/sessions/${session}`;
}

async function waitForSessionReady(workspaceId: string, sessionId: string): Promise<void> {
  const deadline = Date.now() + CONTAINER_TIMEOUT;

  while (Date.now() < deadline) {
    const detail = await api("GET", wsSessionPath(workspaceId, sessionId));
    const status = detail.data?.session?.status;

    if (status === "ready") {
      return;
    }

    if (status === "error") {
      throw new Error("Session entered error state while waiting for ready");
    }

    await new Promise((resolve) => setTimeout(resolve, 200));
  }

  throw new Error("Timed out waiting for session to become ready");
}

// ─── WebSocket Helpers ───

/** Connect WS and wait for the "connected" message (container boot happens here). */
function connectWs(workspace: string, sessionId: string): Promise<{ ws: WebSocket; session: any }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(
      `ws://127.0.0.1:${TEST_PORT}/workspaces/${workspace}/sessions/${sessionId}/stream`,
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
  metrics: StreamMetrics;
}> {
  return new Promise((resolve, reject) => {
    const events: ServerMessage[] = [];
    const textChunks: string[] = [];
    const tools: string[] = [];
    const errors: string[] = [];
    let permissionsApproved = 0;

    let promptSentAt = 0;
    let firstEventAt: number | undefined;
    let agentStartAt: number | undefined;
    let firstTextAt: number | undefined;
    let firstToolStartAt: number | undefined;
    let firstPermissionAt: number | undefined;
    let agentEndAt: number | undefined;

    let lastEventAt: number | undefined;
    let lastTextDeltaAt: number | undefined;

    const eventIntervals: number[] = [];
    const textDeltaIntervals: number[] = [];

    let textDeltaCount = 0;
    let thinkingDeltaCount = 0;
    let toolStartCount = 0;
    let toolOutputCount = 0;
    let permissionRequestCount = 0;
    let errorCount = 0;

    let printedChars = 0;
    let streamOutputTruncated = false;

    const timer = setTimeout(() => {
      ws.removeListener("message", onMessage);
      reject(new Error(`Agent timeout after ${Math.round(timeoutMs / 1000)}s`));
    }, timeoutMs);

    function elapsed(timestamp: number | undefined): number | undefined {
      if (timestamp === undefined || promptSentAt === 0) {
        return undefined;
      }
      return timestamp - promptSentAt;
    }

    function writeBounded(text: string): void {
      if (streamOutputTruncated) {
        return;
      }

      const remaining = MAX_PRINTED_STREAM_CHARS - printedChars;
      if (remaining <= 0) {
        streamOutputTruncated = true;
        log("  …stream output truncated…");
        return;
      }

      const chunk = text.slice(0, remaining);
      process.stdout.write(chunk);
      printedChars += chunk.length;

      if (chunk.length < text.length || printedChars >= MAX_PRINTED_STREAM_CHARS) {
        streamOutputTruncated = true;
        log("  …stream output truncated…");
      }
    }

    function onMessage(raw: WebSocket.RawData): void {
      const receivedAt = performance.now();
      const msg = JSON.parse(raw.toString()) as ServerMessage;
      events.push(msg);

      if (firstEventAt === undefined) {
        firstEventAt = receivedAt;
      }
      if (lastEventAt !== undefined) {
        eventIntervals.push(receivedAt - lastEventAt);
      }
      lastEventAt = receivedAt;

      switch (msg.type) {
        case "agent_start":
          if (agentStartAt === undefined) {
            agentStartAt = receivedAt;
          }
          break;
        case "text_delta":
          textDeltaCount += 1;
          if (firstTextAt === undefined) {
            firstTextAt = receivedAt;
          }
          if (lastTextDeltaAt !== undefined) {
            textDeltaIntervals.push(receivedAt - lastTextDeltaAt);
          }
          lastTextDeltaAt = receivedAt;

          writeBounded(msg.delta);
          textChunks.push(msg.delta);
          break;
        case "thinking_delta":
          thinkingDeltaCount += 1;
          // Dim output for thinking
          writeBounded(`\x1b[2m${msg.delta}\x1b[0m`);
          break;
        case "tool_start":
          toolStartCount += 1;
          if (firstToolStartAt === undefined) {
            firstToolStartAt = receivedAt;
          }

          log(`\n  🔧 ${msg.tool}(${JSON.stringify(msg.args).slice(0, 80)})`);
          tools.push(msg.tool);
          break;
        case "tool_output":
          toolOutputCount += 1;
          // Show truncated tool output
          if (msg.output.length <= 200) writeBounded(`  ${msg.output}`);
          break;
        case "permission_request":
          permissionRequestCount += 1;
          if (firstPermissionAt === undefined) {
            firstPermissionAt = receivedAt;
          }

          log(`  🔒 Auto-approving: ${(msg as any).displaySummary}`);
          ws.send(JSON.stringify({
            type: "permission_response",
            id: (msg as any).id,
            action: "allow",
          }));
          permissionsApproved += 1;
          break;
        case "error":
          errorCount += 1;
          errors.push((msg as any).error);
          log(`  ⚠️  ${(msg as any).error}`);
          break;
        case "agent_end": {
          agentEndAt = receivedAt;

          const metrics: StreamMetrics = {
            promptToFirstEventMs: elapsed(firstEventAt),
            promptToAgentStartMs: elapsed(agentStartAt),
            promptToFirstTextMs: elapsed(firstTextAt),
            promptToFirstToolStartMs: elapsed(firstToolStartAt),
            promptToFirstPermissionMs: elapsed(firstPermissionAt),
            promptToAgentEndMs: elapsed(agentEndAt),

            eventCount: events.length,
            textDeltaCount,
            thinkingDeltaCount,
            toolStartCount,
            toolOutputCount,
            permissionRequestCount,
            errorCount,

            eventInterval: summarizeIntervals(eventIntervals),
            textDeltaInterval: summarizeIntervals(textDeltaIntervals),
          };

          clearTimeout(timer);
          ws.removeListener("message", onMessage);
          console.log(""); // newline after streaming
          resolve({
            events,
            text: textChunks.join(""),
            tools,
            permissionsApproved,
            errors,
            metrics,
          });
          break;
        }
      }
    }

    ws.on("message", onMessage);

    // Send the prompt
    promptSentAt = performance.now();
    ws.send(JSON.stringify({ type: "prompt", message: prompt }));
  });
}

/**
 * Start a long-running turn, then send `stop` while the agent is still active.
 * Resolves when the turn ends (`agent_end`) or session is force-stopped (`session_ended`).
 */
function runAgentWithMidStreamStop(
  ws: WebSocket,
  prompt: string,
  timeoutMs = AGENT_TIMEOUT,
): Promise<StopRunResult> {
  return new Promise((resolve, reject) => {
    const events: ServerMessage[] = [];
    const errors: string[] = [];
    let permissionsApproved = 0;

    let promptSentAt = 0;
    let agentStartAt: number | undefined;
    let stopSentAt: number | undefined;
    let terminalAt: number | undefined;
    let stopTrigger: string | undefined;
    let terminationType: "agent_end" | "session_ended" | undefined;

    let permissionRequestCount = 0;
    let errorCount = 0;

    let fallbackStopTimer: NodeJS.Timeout | null = null;

    const timer = setTimeout(() => {
      ws.removeListener("message", onMessage);
      clearFallbackTimer();
      reject(new Error(`Mid-stream stop timeout after ${Math.round(timeoutMs / 1000)}s`));
    }, timeoutMs);

    function clearFallbackTimer(): void {
      if (!fallbackStopTimer) {
        return;
      }

      clearTimeout(fallbackStopTimer);
      fallbackStopTimer = null;
    }

    function elapsed(timestamp: number | undefined): number | undefined {
      if (timestamp === undefined || promptSentAt === 0) {
        return undefined;
      }
      return timestamp - promptSentAt;
    }

    function sendStop(trigger: string): void {
      if (stopSentAt !== undefined) {
        return;
      }

      stopTrigger = trigger;
      stopSentAt = performance.now();
      log(`  ⏹️  sending stop (${trigger})`);
      ws.send(JSON.stringify({ type: "stop" }));
    }

    function maybeStopOnStreamEvent(trigger: string): void {
      if (agentStartAt === undefined) {
        return;
      }

      sendStop(trigger);
    }

    function finish(): void {
      clearTimeout(timer);
      clearFallbackTimer();
      ws.removeListener("message", onMessage);

      const metrics: StopRunMetrics = {
        promptToAgentStartMs: elapsed(agentStartAt),
        promptToStopMs: elapsed(stopSentAt),
        stopToTerminalMs:
          stopSentAt !== undefined && terminalAt !== undefined
            ? terminalAt - stopSentAt
            : undefined,
        promptToTerminalMs: elapsed(terminalAt),
        stopTrigger,
        terminationType: terminationType || "agent_end",
        eventCount: events.length,
        permissionRequestCount,
        errorCount,
      };

      resolve({
        events,
        errors,
        permissionsApproved,
        stopSent: stopSentAt !== undefined,
        metrics,
      });
    }

    function onMessage(raw: WebSocket.RawData): void {
      const now = performance.now();
      const msg = JSON.parse(raw.toString()) as ServerMessage;
      events.push(msg);

      switch (msg.type) {
        case "agent_start":
          if (agentStartAt === undefined) {
            agentStartAt = now;
            fallbackStopTimer = setTimeout(() => {
              sendStop("agent_start + 1200ms fallback");
            }, 1200);
          }
          break;

        case "text_delta":
          maybeStopOnStreamEvent("first text_delta");
          break;

        case "thinking_delta":
          maybeStopOnStreamEvent("first thinking_delta");
          break;

        case "tool_start":
          maybeStopOnStreamEvent("first tool_start");
          break;

        case "tool_output":
          maybeStopOnStreamEvent("first tool_output");
          break;

        case "permission_request":
          permissionRequestCount += 1;
          ws.send(JSON.stringify({
            type: "permission_response",
            id: (msg as any).id,
            action: "allow",
          }));
          permissionsApproved += 1;
          break;

        case "error":
          errorCount += 1;
          errors.push((msg as any).error);
          log(`  ⚠️  ${(msg as any).error}`);
          break;

        case "agent_end":
          terminalAt = now;
          terminationType = "agent_end";
          finish();
          break;

        case "session_ended":
          terminalAt = now;
          terminationType = "session_ended";
          finish();
          break;
      }
    }

    ws.on("message", onMessage);

    promptSentAt = performance.now();
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
    if (images.includes("oppi-server")) {
      log("✓ oppi-server:local image exists");
    } else {
      log("⚠  oppi-server:local image not found — will build on start (2–5 min)");
    }
  } catch {}
}

async function startServer(): Promise<void> {
  phase("Phase 1 — Server Setup");

  tmpDir = mkdtempSync(join(tmpdir(), "oppi-server-e2e-"));
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

  // Workspaces
  const workspaces = await api("GET", "/workspaces");
  check("GET /workspaces → 200", workspaces.status === 200);
  check("GET /workspaces seeds defaults", (workspaces.data.workspaces?.length ?? 0) > 0);

  workspaceId = workspaces.data.workspaces?.[0]?.id || "";
  check("Resolved workspace id", workspaceId.length > 0);
  log(`Workspace: ${workspaceId}`);

  // Sessions in workspace — empty
  const empty = await api("GET", `/workspaces/${workspaceId}/sessions`);
  check("GET /workspaces/:wid/sessions → empty", empty.data.sessions?.length === 0);

  // Create session
  const model = TEST_MODEL || "lmstudio/glm-4.7-flash-mlx";
  const created = await api("POST", `/workspaces/${workspaceId}/sessions`, { name: "e2e-test", model });
  check("POST /workspaces/:wid/sessions → 201", created.status === 201);
  check("Response includes session id", !!created.data.session?.id);
  log(`Session: ${created.data.session?.id} (${model})`);

  const sessionId = String(created.data.session?.id || "");

  // List
  const list = await api("GET", `/workspaces/${workspaceId}/sessions`);
  check("GET /workspaces/:wid/sessions → 1 session", list.data.sessions?.length === 1);

  // Detail
  const detail = await api("GET", wsSessionPath(workspaceId, sessionId));
  check(
    "GET /workspaces/:wid/sessions/:id → correct session",
    detail.data.session?.id === created.data.session?.id,
  );

  // Stop (works even if session is not active yet)
  const stopped = await api("POST", `${wsSessionPath(workspaceId, sessionId)}/stop`);
  check("POST /workspaces/:wid/sessions/:id/stop → 200", stopped.status === 200);
  check(
    "POST /workspaces/:wid/sessions/:id/stop marks stopped",
    stopped.data.session?.status === "stopped",
  );
}

async function testAgentSession(): Promise<string> {
  phase("Phase 3 — Agent Session (real container + LLM)");

  // Get the session we created in Phase 2
  const sessions = await api("GET", `/workspaces/${workspaceId}/sessions`);
  const sessionId = sessions.data.sessions?.[0]?.id;
  if (!sessionId) throw new Error("No session found — Phase 2 may have failed");

  // Connect WebSocket (this boots the container)
  log("Connecting WebSocket — booting container…");
  const { ws, session } = await withTimeout(
    connectWs(workspaceId, sessionId),
    CONTAINER_TIMEOUT,
    "container boot",
  );
  check("Connected to session stream", typeof session?.id === "string" && session.id === sessionId);

  await withTimeout(
    waitForSessionReady(workspaceId, sessionId),
    CONTAINER_TIMEOUT,
    "session ready",
  );
  check("Container booted, session ready", true);

  // ── Run 1: Simple tool use (auto-allowed by policy) ──
  log("\n── Run 1: Tool use (ls — auto-allowed) ──\n");
  let run1 = await withTimeout(
    runAgent(ws, "Use the bash tool to run: ls -la /work\nRespond with one sentence about the output."),
    AGENT_TIMEOUT,
    "agent run 1",
  );

  // Retry once if LLM didn't call tools (local model flakiness)
  if (run1.tools.length === 0) {
    log("  ⟳ LLM didn't use tools — retrying with explicit prompt…");
    run1 = await withTimeout(
      runAgent(ws, "You MUST call the bash tool with command 'ls -la /work'. Do it now."),
      AGENT_TIMEOUT,
      "agent run 1 retry",
    );
  }

  check("Run 1: agent_start received", run1.events.some(e => e.type === "agent_start"));
  check("Run 1: agent_end received", run1.events.some(e => e.type === "agent_end"));
  check("Run 1: bash tool called", run1.tools.includes("bash"), `tools: [${run1.tools}]`);
  check("Run 1: no errors", run1.errors.length === 0, run1.errors.join("; "));
  check("Run 1: no gate-blocked output",
    !run1.text.includes("Permission gate not connected"),
    "extension should be connected before first tool call",
  );

  log(`  Tools used: ${run1.tools.join(", ")}`);
  log(`  Permissions auto-approved: ${run1.permissionsApproved} (expected: 0 for ls)`);
  printRunMetrics("Run 1", run1.metrics);

  // ── Run 2: Permission-gated command (rm -rf triggers "ask") ──
  //
  // The container policy auto-allows most commands but flags destructive
  // ones (rm -rf, git push --force, etc.) as "ask", which routes through
  // the permission gate to the phone. Here we use rm -rf on a temp dir
  // to deterministically trigger the gate and verify auto-approval works.
  log("\n── Run 2: Permission gate (rm -rf — requires approval) ──\n");

  // First, create a target dir so the rm has something to remove.
  // This is a setup step — we don't assert on it.
  await withTimeout(
    runAgent(ws, "Call bash with exactly: mkdir -p /tmp/e2e-gate-test\nReply: OK"),
    AGENT_TIMEOUT,
    "agent run 2 setup",
  );

  let run2 = await withTimeout(
    runAgent(ws, "Call bash with exactly: rm -rf /tmp/e2e-gate-test\nReply: DONE"),
    AGENT_TIMEOUT,
    "agent run 2",
  );

  // Retry once if LLM didn't call tools (local model flakiness)
  if (run2.tools.length === 0) {
    log("  ⟳ LLM didn't use tools — retrying with explicit prompt…");
    run2 = await withTimeout(
      runAgent(ws, "Call bash with 'rm -rf /tmp/e2e-gate-test' now. Reply: DONE"),
      AGENT_TIMEOUT,
      "agent run 2 retry",
    );
  }

  check("Run 2: completed", run2.events.some(e => e.type === "agent_end"));
  check("Run 2: bash tool called", run2.tools.includes("bash"), `tools: [${run2.tools}]`);
  check("Run 2: permission gate triggered (rm -rf → ask)",
    run2.permissionsApproved > 0,
    `expected ≥1 permission request for rm -rf, got ${run2.permissionsApproved}`,
  );
  check("Run 2: no gate-blocked output",
    !run2.text.includes("Permission gate not connected"),
    "extension must stay connected across prompts",
  );

  log(`  Tools used: ${run2.tools.join(", ")}`);
  log(`  Permissions auto-approved: ${run2.permissionsApproved}`);
  printRunMetrics("Run 2", run2.metrics);

  // ── Run 3: Mid-stream stop behavior ──
  log("\n── Run 3: Mid-stream stop (loop prevention) ──\n");
  const run3 = await withTimeout(
    runAgentWithMidStreamStop(
      ws,
      "You MUST call bash with: for i in $(seq 1 300); do echo tick:$i; sleep 0.2; done\n"
      + "Do not summarize until the command finishes.",
      AGENT_TIMEOUT,
    ),
    AGENT_TIMEOUT,
    "agent run 3 stop",
  );

  const run3Ended = run3.events.some((event) => event.type === "agent_end" || event.type === "session_ended");
  check("Run 3: stop signal sent mid-turn", run3.stopSent === true);
  check("Run 3: stop leads to terminal event", run3Ended);
  check(
    "Run 3: stop-to-terminal under 8s",
    (run3.metrics.stopToTerminalMs || Number.POSITIVE_INFINITY) < 8000,
    `stop-to-terminal=${formatMs(run3.metrics.stopToTerminalMs)}`,
  );
  check("Run 3: no errors", run3.errors.length === 0, run3.errors.join("; "));
  printStopRunMetrics("Run 3", run3.metrics);

  const runMetrics = [run1.metrics, run2.metrics];
  const avgStart = average(definedNumbers(runMetrics.map((m) => m.promptToAgentStartMs)));
  const avgFirstText = average(definedNumbers(runMetrics.map((m) => m.promptToFirstTextMs)));
  const avgEnd = average(definedNumbers(runMetrics.map((m) => m.promptToAgentEndMs)));

  log("Aggregate performance across runs:");
  log(`  avg prompt → agent_start: ${formatMs(avgStart)}`);
  log(`  avg prompt → first text_delta: ${formatMs(avgFirstText)}`);
  log(`  avg prompt → agent_end: ${formatMs(avgEnd)}`);

  // ── Trace endpoint — verify JSONL was captured ──
  log("\n── Trace endpoint ──\n");
  const trace = await api("GET", `${wsSessionPath(workspaceId, sessionId)}?view=full`);
  check("GET /workspaces/:wid/sessions/:id?view=full → 200", trace.status === 200);
  check("Trace has events", Array.isArray(trace.data.trace) && trace.data.trace.length > 0,
    `got ${trace.data.trace?.length ?? 0} events`,
  );
  if (trace.data.trace?.length > 0) {
    const types = [...new Set(trace.data.trace.map((e: { type: string }) => e.type))];
    log(`  Trace event types: ${types.join(", ")}`);
    log(`  Total trace events: ${trace.data.trace.length}`);
  }

  ws.close();
  return sessionId;
}

async function testCleanup(sessionId: string): Promise<void> {
  phase("Phase 4 — Session Cleanup");

  const del = await api("DELETE", wsSessionPath(workspaceId, sessionId));
  check("DELETE /workspaces/:wid/sessions/:id → 200", del.status === 200);

  // Wait for async cleanup (pi process exit, gate teardown) to settle
  // before making the next request. DELETE returns 200 immediately but
  // the container teardown continues asynchronously.
  await new Promise(r => setTimeout(r, 1000));

  const list = await api("GET", `/workspaces/${workspaceId}/sessions`);
  check("Workspace sessions empty after delete", list.data.sessions?.length === 0);
}

// ─── Main ───

async function main(): Promise<void> {
  console.log("\n╭───────────────────────────────────────────╮");
  console.log("│      oppi-server E2E test (no mocks)        │");
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
