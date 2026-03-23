/**
 * E2E test harness — manages Docker server lifecycle and provides
 * API/WebSocket helpers for pairing and session tests.
 *
 * Two modes:
 * - Docker mode (default): spins up oppi-e2e container
 * - Native mode (E2E_NATIVE=1): starts server as child process (faster iteration)
 *
 * Requires LM Studio running on localhost:1234 with a loaded model.
 */

import { execSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, readFileSync, openSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = join(__dirname, "..");

// ── Configuration ──

export const E2E_PORT = Number(process.env.E2E_PORT || 17760);
export const MLX_PORT = Number(process.env.E2E_MLX_PORT || 9847);
export const MLX_HOST_URL = `http://localhost:${MLX_PORT}`;
export const MLX_DOCKER_URL = `http://host.docker.internal:${MLX_PORT}`;
export const ADMIN_TOKEN = "e2e-admin-token";

// Resolved after MLX server probe
export let E2E_MODEL = "";

const BOOT_TIMEOUT_MS = 120_000;
const HEALTH_POLL_MS = 500;

export const BASE_URL = `http://127.0.0.1:${E2E_PORT}`;
export const STREAM_WS_URL = `ws://127.0.0.1:${E2E_PORT}/stream`;

// ── MLX server check ──

export async function ensureMLXServerReady(): Promise<boolean> {
  try {
    const res = await fetch(`${MLX_HOST_URL}/v1/models`);
    if (!res.ok) return false;
    const data = (await res.json()) as { data?: { id: string }[] };
    const models = data.data || [];
    if (models.length === 0) {
      console.warn("[e2e] MLX server is running but no models loaded");
      return false;
    }

    // Use the first loaded model
    const modelId = models[0].id;
    E2E_MODEL = `mlx-server/${modelId}`;
    console.log(`[e2e] MLX server ready on :${MLX_PORT}, model: ${modelId}`);
    return true;
  } catch {
    console.warn("[e2e] MLX server not reachable at", MLX_HOST_URL);
    return false;
  }
}

// ── Server lifecycle ──

let serverProcess: ChildProcess | null = null;
let nativeDataDir: string | null = null;

export async function startServer(): Promise<void> {
  if (process.env.E2E_NATIVE === "1") {
    await startNativeServer();
  } else {
    await startDockerServer();
  }
}

export async function stopServer(): Promise<void> {
  if (process.env.E2E_NATIVE === "1") {
    await stopNativeServer();
  } else {
    await stopDockerServer();
  }
}

let dockerModelsJson: string | null = null;

async function startDockerServer(): Promise<void> {
  console.log("[e2e] Building and starting Docker server...");

  const composeFile = join(__dirname, "docker-compose.e2e.yml");

  // Probe the MLX server for its loaded model and generate a container-compatible
  // models.json that routes mlx-server/* to host.docker.internal:<port>.
  const res = await fetch(`${MLX_HOST_URL}/v1/models`);
  const data = (await res.json()) as { data?: { id: string }[] };
  const modelId = data.data?.[0]?.id;
  if (!modelId) throw new Error("[e2e] MLX server has no models loaded");

  const modelsConfig = {
    providers: {
      "mlx-server": {
        baseUrl: `${MLX_DOCKER_URL}/v1`,
        apiKey: "DUMMY",
        api: "openai-completions",
        models: [
          {
            id: modelId,
            name: "E2E MLX Model",
            contextWindow: 32768,
            maxTokens: 8192,
            input: ["text"],
            reasoning: true,
            compat: { thinkingFormat: "qwen" },
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          },
        ],
      },
    },
  };

  const tmpModels = join(tmpdir(), `oppi-e2e-models-${Date.now()}.json`);
  writeFileSync(tmpModels, JSON.stringify(modelsConfig, null, 2));
  dockerModelsJson = tmpModels;

  execSync(
    `docker compose -f ${composeFile} up -d --build --wait --wait-timeout 120`,
    {
      cwd: SERVER_DIR,
      stdio: "inherit",
      env: {
        ...process.env,
        E2E_PORT: String(E2E_PORT),
        E2E_MODELS_JSON: tmpModels,
      },
    },
  );

  await waitForHealth();

  // Set the server's defaultModel to the MLX model (replaces the Dockerfile default)
  execSync(
    `docker exec oppi-e2e node dist/cli.js config set defaultModel "${E2E_MODEL}"`,
    { stdio: "pipe" },
  );
  console.log(`[e2e] Docker server healthy, defaultModel=${E2E_MODEL}`);
}

async function stopDockerServer(): Promise<void> {
  const composeFile = join(__dirname, "docker-compose.e2e.yml");
  try {
    execSync(`docker compose -f ${composeFile} down -v --timeout 10`, {
      cwd: SERVER_DIR,
      stdio: "inherit",
      env: { ...process.env, E2E_PORT: String(E2E_PORT) },
    });
  } catch {
    console.warn("[e2e] Docker compose down failed (may already be stopped)");
  }

  if (dockerModelsJson) {
    rmSync(dockerModelsJson, { force: true });
    dockerModelsJson = null;
  }
}

async function startNativeServer(): Promise<void> {
  console.log("[e2e] Starting native server...");

  // Build first
  execSync("npm run build", { cwd: SERVER_DIR, stdio: "inherit" });

  nativeDataDir = mkdtempSync(join(tmpdir(), "oppi-e2e-native-"));

  // Pre-configure
  const { Storage } = await import(join(SERVER_DIR, "dist/storage.js"));
  const storage = new Storage(nativeDataDir);
  storage.updateConfig({
    host: "127.0.0.1",
    port: E2E_PORT,
    token: ADMIN_TOKEN,
    defaultModel: E2E_MODEL,
  });

  // Copy host models.json so pi can resolve the mlx-server provider
  const hostModels = join(process.env.HOME || "", ".pi/agent/models.json");
  const piDir = join(nativeDataDir, "pi-agent");
  const { existsSync: exists, mkdirSync: mkdir, copyFileSync: cpFile } = await import("node:fs");
  if (exists(hostModels)) {
    mkdir(piDir, { recursive: true });
    cpFile(hostModels, join(piDir, "models.json"));
  }

  const logPath = join(nativeDataDir, "server.log");
  const logFd = openSync(logPath, "w");

  serverProcess = spawn("node", ["dist/cli.js", "serve"], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      OPPI_DATA_DIR: nativeDataDir,
    },
    stdio: ["ignore", logFd, logFd],
  });

  closeSync(logFd);

  await waitForHealth();
  console.log("[e2e] Native server healthy");
}

async function stopNativeServer(): Promise<void> {
  if (serverProcess && !serverProcess.killed) {
    serverProcess.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        serverProcess?.kill("SIGKILL");
        resolve();
      }, 4000);
      serverProcess!.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  if (nativeDataDir) {
    rmSync(nativeDataDir, { recursive: true, force: true });
    nativeDataDir = null;
  }
}

async function waitForHealth(): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < BOOT_TIMEOUT_MS) {
    try {
      const res = await fetch(`${BASE_URL}/health`);
      if (res.ok) return;
    } catch {
      // keep retrying
    }
    await sleep(HEALTH_POLL_MS);
  }
  throw new Error(`[e2e] Server did not become healthy within ${BOOT_TIMEOUT_MS}ms`);
}

// ── API helpers ──

export interface APIResponse {
  status: number;
  json: Record<string, unknown> | null;
  text: string;
}

export async function api(
  method: string,
  path: string,
  token?: string,
  body?: unknown,
): Promise<APIResponse> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  let json: Record<string, unknown> | null = null;
  try {
    json = text.length ? (JSON.parse(text) as Record<string, unknown>) : null;
  } catch {
    json = null;
  }

  return { status: res.status, json, text };
}

// ── Pairing helpers ──

/**
 * Generate a pairing invite directly via Storage (bypasses server CLI).
 * Returns the invite deep-link URL and the raw invite payload.
 */
export async function generateTestInvite(): Promise<{
  inviteURL: string;
  invitePayload: Record<string, unknown>;
  pairingToken: string;
  fingerprint: string;
}> {
  if (process.env.E2E_NATIVE === "1") {
    // Native mode: access storage directly
    const { Storage } = await import(join(SERVER_DIR, "dist/storage.js"));
    const { generateInvite } = await import(join(SERVER_DIR, "dist/invite.js"));

    const storage = new Storage(nativeDataDir!);
    const invite = generateInvite(
      storage,
      () => "127.0.0.1",
      () => "e2e-server",
      { pairingTokenTtlMs: 60_000 },
    );

    const invitePayload = {
      v: 3,
      host: invite.host,
      port: invite.port,
      scheme: invite.scheme,
      token: "",
      pairingToken: invite.pairingToken,
      name: invite.name,
      fingerprint: invite.fingerprint,
      tlsCertFingerprint: invite.tlsCertFingerprint,
    };

    return {
      inviteURL: invite.inviteURL,
      invitePayload,
      pairingToken: invite.pairingToken,
      fingerprint: invite.fingerprint,
    };
  }

  // Docker mode: write script to temp file, copy into container, execute
  const scriptContent = [
    'import { Storage } from "./dist/storage.js";',
    'import { generateInvite } from "./dist/invite.js";',
    "const storage = new Storage(process.env.OPPI_DATA_DIR);",
    "const invite = generateInvite(",
    '  storage, () => "host.docker.internal", () => "e2e-server",',
    "  { pairingTokenTtlMs: 60000 }",
    ");",
    "const payload = {",
    `  v: 3, host: "127.0.0.1", port: ${E2E_PORT},`,
    '  scheme: "http", token: "",',
    "  pairingToken: invite.pairingToken,",
    "  name: invite.name,",
    "  fingerprint: invite.fingerprint,",
    "};",
    "console.log(JSON.stringify({",
    "  inviteURL: invite.inviteURL, invitePayload: payload,",
    "  pairingToken: invite.pairingToken, fingerprint: invite.fingerprint,",
    "}));",
  ].join("\n");

  const tmpScript = join(tmpdir(), `oppi-e2e-invite-${Date.now()}.mjs`);
  writeFileSync(tmpScript, scriptContent);

  try {
    execSync(`docker cp ${tmpScript} oppi-e2e:/opt/oppi-server/gen-invite.mjs`, { stdio: "pipe" });
    const raw = execSync(
      "docker exec -w /opt/oppi-server oppi-e2e node gen-invite.mjs",
      { encoding: "utf-8" },
    ).trim();
    return JSON.parse(raw);
  } finally {
    rmSync(tmpScript, { force: true });
  }
}

// ── WebSocket helpers ──

export interface StreamConnection {
  ws: WebSocket;
  events: StreamEvent[];
  closed: boolean;
  closeCode: number | null;
  send: (payload: Record<string, unknown>) => void;
}

export interface StreamEvent {
  direction: "in" | "out";
  type: string;
  sessionId?: string;
  requestId?: string;
  command?: string;
  id?: string;
  tool?: string;
  clientTurnId?: string;
  stage?: string;
  duplicate?: boolean;
  success?: boolean;
  error?: string;
  data?: unknown;
  sessionStatus?: string;
  sessionSeq?: number;
  content?: string;
  delta?: string;
  seq: number;
}

export async function openStream(deviceToken: string): Promise<StreamConnection> {
  const ws = new WebSocket(STREAM_WS_URL, {
    headers: { Authorization: `Bearer ${deviceToken}` },
  });

  let seq = 0;

  const connection: StreamConnection = {
    ws,
    events: [],
    closed: false,
    closeCode: null,
    send(payload) {
      const event = toEvent("out", payload, ++seq);
      connection.events.push(event);
      ws.send(JSON.stringify(payload));
    },
  };

  ws.on("message", (raw) => {
    const msg = JSON.parse(raw.toString());
    const event = toEvent("in", msg, ++seq);
    connection.events.push(event);
  });

  ws.on("close", (code) => {
    connection.closed = true;
    connection.closeCode = code;
  });

  ws.on("error", (err) => {
    const event = toEvent("in", { type: "ws_error", error: err.message }, ++seq);
    connection.events.push(event);
  });

  // Wait for open
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("WS open timeout")), 15_000);
    ws.once("open", () => {
      clearTimeout(timer);
      resolve();
    });
    ws.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });

  // Wait for stream_connected
  await waitForEvent(connection, (e) => e.type === "stream_connected", "stream_connected");

  return connection;
}

export async function closeStream(conn: StreamConnection): Promise<void> {
  if (conn.closed) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, 2000);
    conn.ws.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
    conn.ws.close();
  });
}

export async function waitForEvent(
  conn: StreamConnection,
  predicate: (e: StreamEvent) => boolean,
  label: string,
  opts?: { timeoutMs?: number; startIndex?: number },
): Promise<{ event: StreamEvent; index: number }> {
  const timeoutMs = opts?.timeoutMs ?? 30_000;
  let cursor = opts?.startIndex ?? 0;
  const started = Date.now();

  while (Date.now() - started < timeoutMs) {
    while (cursor < conn.events.length) {
      const event = conn.events[cursor];
      if (predicate(event)) {
        return { event, index: cursor };
      }
      cursor++;
    }

    if (conn.closed) {
      throw new Error(`Stream closed while waiting for ${label} (code=${conn.closeCode})`);
    }

    await sleep(25);
  }

  throw new Error(`Timeout waiting for ${label} (${timeoutMs}ms)`);
}

/**
 * Subscribe to a session on a /stream connection.
 */
export async function subscribeSession(
  conn: StreamConnection,
  sessionId: string,
  requestId: string,
): Promise<{ rpcData: Record<string, unknown> }> {
  const startIndex = conn.events.length;

  conn.send({
    type: "subscribe",
    sessionId,
    level: "full",
    sinceSeq: 0,
    requestId,
  });

  const { event } = await waitForEvent(
    conn,
    (e) =>
      e.direction === "in" &&
      (e.type === "command_result" || e.type === "rpc_result") &&
      e.requestId === requestId,
    `subscribe rpc_result (${requestId})`,
    { startIndex },
  );

  if (event.success !== true) {
    throw new Error(`Subscribe failed: ${event.error || "unknown"}`);
  }

  return { rpcData: (event.data as Record<string, unknown>) || {} };
}

/**
 * Send a prompt and wait for agent_end.
 */
export async function sendPromptAndWait(
  conn: StreamConnection,
  sessionId: string,
  message: string,
  requestId: string,
  opts?: { timeoutMs?: number },
): Promise<void> {
  const startIndex = conn.events.length;
  const timeoutMs = opts?.timeoutMs ?? 90_000;

  conn.send({
    type: "prompt",
    sessionId,
    message,
    requestId,
  });

  // Wait for prompt ack
  const { event: rpc } = await waitForEvent(
    conn,
    (e) =>
      e.direction === "in" &&
      (e.type === "command_result" || e.type === "rpc_result") &&
      e.requestId === requestId,
    `prompt rpc_result (${requestId})`,
    { startIndex, timeoutMs },
  );

  if (rpc.success !== true) {
    throw new Error(`Prompt failed: ${rpc.error || "unknown"}`);
  }

  // Wait for agent_end
  await waitForEvent(
    conn,
    (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === sessionId,
    `agent_end (${requestId})`,
    { startIndex, timeoutMs },
  );
}

/**
 * Auto-approve permissions as they arrive.
 */
export function autoApprovePermissions(
  conn: StreamConnection,
  sessionId: string,
): { stop: () => void; count: () => number } {
  let cursor = 0;
  const approved = new Set<string>();

  const tick = () => {
    while (cursor < conn.events.length) {
      const e = conn.events[cursor++];
      if (
        e.direction === "in" &&
        e.type === "permission_request" &&
        e.sessionId === sessionId &&
        e.id &&
        !approved.has(e.id)
      ) {
        approved.add(e.id);
        conn.send({
          type: "permission_response",
          sessionId,
          id: e.id,
          action: "allow",
          scope: "once",
          requestId: `auto-perm-${e.id}`,
        });
      }
    }
  };

  const timer = setInterval(tick, 25);
  return {
    stop() {
      clearInterval(timer);
      tick();
    },
    count: () => approved.size,
  };
}

// ── Helpers ──

function toEvent(direction: "in" | "out", msg: Record<string, unknown>, seq: number): StreamEvent {
  const event: StreamEvent = {
    seq,
    direction,
    type: (msg.type as string) || "unknown",
  };
  if (msg.sessionId) event.sessionId = msg.sessionId as string;
  if (msg.requestId) event.requestId = msg.requestId as string;
  if (msg.command) event.command = msg.command as string;
  if (msg.id) event.id = msg.id as string;
  if (msg.tool) event.tool = msg.tool as string;
  if (msg.clientTurnId) event.clientTurnId = msg.clientTurnId as string;
  if (msg.stage) event.stage = msg.stage as string;
  if (typeof msg.duplicate === "boolean") event.duplicate = msg.duplicate;
  if (typeof msg.success === "boolean") event.success = msg.success;
  if (msg.error) event.error = msg.error as string;
  if ("data" in msg) event.data = msg.data;
  if (msg.session && typeof (msg.session as Record<string, unknown>).status === "string") {
    event.sessionStatus = (msg.session as Record<string, unknown>).status as string;
  }
  if (typeof msg.seq === "number") event.sessionSeq = msg.seq;
  if (typeof msg.content === "string") event.content = msg.content;
  if (typeof msg.delta === "string") event.delta = msg.delta;
  return event;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
