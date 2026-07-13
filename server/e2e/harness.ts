/**
 * E2E test harness — manages Docker server lifecycle and provides
 * API/WebSocket helpers for pairing and split-stream session tests.
 *
 * Two modes:
 * - Docker mode (default): spins up oppi-e2e container
 * - Native mode (E2E_NATIVE=1): starts server as child process (faster iteration)
 *
 * Requires an OMLX-compatible local model server running on localhost:8400
 * with at least one model loaded.
 */

import { execSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, rmSync, openSync, closeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import WebSocket from "ws";

const __dirname = dirname(fileURLToPath(import.meta.url));
const HARNESS_SERVER_DIR = join(__dirname, "..");
const TARGET_SERVER_DIR = resolve(process.env.E2E_SERVER_DIR || HARNESS_SERVER_DIR);
const TARGET_SERVER_ENTRY = join(TARGET_SERVER_DIR, "dist", "src", "cli.js");

// ── Configuration ──

export const E2E_PORT = Number(process.env.E2E_PORT || 17760);
export const OMLX_PORT = Number(process.env.E2E_OMLX_PORT || process.env.E2E_MLX_PORT || 8400);
export const OMLX_HOST_URL = `http://localhost:${OMLX_PORT}`;
export const OMLX_DOCKER_URL = `http://host.docker.internal:${OMLX_PORT}`;
export const ADMIN_TOKEN = "e2e-admin-token";

// Resolved after local model server probe
export let E2E_MODEL = "";
export let E2E_MODEL_ID = "";

const PREFERRED_MODEL_REGEX = /qwen3\.?6/i;

function chooseModelId(modelIds: string[]): string | null {
  if (modelIds.length === 0) return null;

  const preferred = modelIds.find((id) => PREFERRED_MODEL_REGEX.test(id));
  return preferred ?? modelIds[0] ?? null;
}

async function discoverLocalModelId(): Promise<string | null> {
  const res = await fetch(`${OMLX_HOST_URL}/v1/models`);
  if (!res.ok) return null;
  const data = (await res.json()) as { data?: { id: string }[] };
  return chooseModelId((data.data || []).map((model) => model.id));
}

function makeModelsConfig(baseUrl: string, modelId: string): Record<string, unknown> {
  return {
    providers: {
      omlx: {
        baseUrl: `${baseUrl}/v1`,
        apiKey: "DUMMY",
        api: "openai-completions",
        models: [
          {
            id: modelId,
            name: "E2E OMLX Model",
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
}

const BOOT_TIMEOUT_MS = 300_000;
const HEALTH_POLL_MS = 500;
const WEBSOCKET_TIMEOUT_MS = 120_000;
const STREAM_CLOSE_TIMEOUT_MS = 30_000;
const DEFAULT_APP_INVITE_FILE = "/tmp/oppi-e2e-invite.txt";
const DEFAULT_APP_DEVICE_TOKEN_FILE = "/tmp/oppi-e2e-device-token.txt";

export type E2ETransportScheme = "http" | "https";
export type NativeStartupStep = "build" | "assertEntrypoint";
let transportScheme: E2ETransportScheme =
  process.env.E2E_TRANSPORT_SCHEME === "https" ? "https" : "http";

export function nativeStartupStepsForTarget(
  targetServerDir: string = TARGET_SERVER_DIR,
  harnessServerDir: string = HARNESS_SERVER_DIR,
): NativeStartupStep[] {
  return resolve(targetServerDir) === resolve(harnessServerDir)
    ? ["build", "assertEntrypoint"]
    : ["assertEntrypoint"];
}

function activeTransportScheme(): E2ETransportScheme {
  const envScheme = process.env.E2E_TRANSPORT_SCHEME;
  if (envScheme === "http" || envScheme === "https") {
    transportScheme = envScheme;
  }

  if (transportScheme === "https") {
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  }

  return transportScheme;
}

export function baseURL(): string {
  const scheme = activeTransportScheme();
  return `${scheme}://127.0.0.1:${E2E_PORT}`;
}

function wsBaseURL(): string {
  const scheme = activeTransportScheme();
  const wsScheme = scheme === "https" ? "wss" : "ws";
  return `${wsScheme}://127.0.0.1:${E2E_PORT}`;
}

export function sessionStreamURL(workspaceId: string, sessionId: string): string {
  return `${wsBaseURL()}/workspaces/${encodeURIComponent(workspaceId)}/sessions/${encodeURIComponent(sessionId)}/stream`;
}

export function isSecureTransport(): boolean {
  return activeTransportScheme() === "https";
}

function applySelfSignedTlsBypass(): void {
  if (activeTransportScheme() === "https") {
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  }
}

// ── Local model server check ──

export async function ensureMLXServerReady(): Promise<boolean> {
  try {
    const modelId = await discoverLocalModelId();
    if (!modelId) {
      console.warn("[e2e] OMLX server is running but no models loaded");
      return false;
    }

    E2E_MODEL_ID = modelId;
    E2E_MODEL = `omlx/${modelId}`;

    if (PREFERRED_MODEL_REGEX.test(modelId)) {
      console.log(`[e2e] OMLX server ready on :${OMLX_PORT}, using preferred model: ${modelId}`);
    } else {
      console.warn(`[e2e] Preferred model (Qwen3.6*) not found, falling back to: ${modelId}`);
    }

    return true;
  } catch {
    console.warn("[e2e] OMLX server not reachable at", OMLX_HOST_URL);
    return false;
  }
}

// ── Server lifecycle ──

let serverProcess: ChildProcess | null = null;
let nativeDataDir: string | null = null;

function cleanStaleE2EListeners(): void {
  try {
    execSync("node scripts/e2e-clean.mjs", {
      cwd: HARNESS_SERVER_DIR,
      stdio: "inherit",
      env: { ...process.env, E2E_PORT: String(E2E_PORT) },
    });
  } catch {
    console.warn("[e2e] Stale E2E listener cleanup failed; continuing with normal startup");
  }
}

export async function startServer(): Promise<void> {
  cleanStaleE2EListeners();
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

/** Restart the e2e server without deleting its data directory/volume. */
export async function restartServerPreservingData(): Promise<void> {
  if (process.env.E2E_NATIVE === "1") {
    await restartNativeServerPreservingData();
  } else {
    await restartDockerServerPreservingData();
  }
}

let dockerModelsJson: string | null = null;

async function canReachHealthOver(scheme: E2ETransportScheme): Promise<boolean> {
  if (scheme === "https") {
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  }

  try {
    const res = await fetch(`${scheme}://127.0.0.1:${E2E_PORT}/health`);
    return res.ok;
  } catch {
    return false;
  }
}

async function resolveDockerTransportScheme(): Promise<E2ETransportScheme> {
  const preferredOrder: E2ETransportScheme[] = (() => {
    try {
      const tlsJson = execSync("docker exec oppi-e2e node dist/src/cli.js config get tls", {
        encoding: "utf-8",
        stdio: "pipe",
      }).trim();

      const tls = JSON.parse(tlsJson) as { mode?: string };
      return tls.mode === "disabled" ? ["http", "https"] : ["https", "http"];
    } catch {
      // Fresh `serve` bootstraps self-signed by default.
      return ["https", "http"];
    }
  })();

  const started = Date.now();
  while (Date.now() - started < BOOT_TIMEOUT_MS) {
    for (const scheme of preferredOrder) {
      if (await canReachHealthOver(scheme)) {
        return scheme;
      }
    }
    await sleep(HEALTH_POLL_MS);
  }

  throw new Error("[e2e] Could not detect server transport (health check failed on http+https)");
}

export function dockerStartupCleanupCommand(composeFile: string): string {
  return `docker compose -f ${composeFile} down -v --timeout 60`;
}

async function startDockerServer(): Promise<void> {
  console.log("[e2e] Building and starting Docker server...");

  const composeFile = join(__dirname, "docker-compose.e2e.yml");
  try {
    execSync(dockerStartupCleanupCommand(composeFile), {
      cwd: HARNESS_SERVER_DIR,
      stdio: "inherit",
      env: { ...process.env, E2E_PORT: String(E2E_PORT) },
    });
  } catch {
    console.warn("[e2e] Docker compose cleanup failed before startup; continuing");
  }

  // Generate a container-compatible models.json that routes omlx/* to
  // host.docker.internal:<port>.
  const modelId = E2E_MODEL_ID || (await discoverLocalModelId());
  if (!modelId) throw new Error("[e2e] OMLX server has no models loaded");

  const tmpModels = join(tmpdir(), `oppi-e2e-models-${Date.now()}.json`);
  writeFileSync(tmpModels, JSON.stringify(makeModelsConfig(OMLX_DOCKER_URL, modelId), null, 2));
  dockerModelsJson = tmpModels;

  execSync(`docker compose -f ${composeFile} up -d --build --wait --wait-timeout 300`, {
    cwd: HARNESS_SERVER_DIR,
    stdio: "inherit",
    env: {
      ...process.env,
      E2E_PORT: String(E2E_PORT),
      E2E_MODELS_JSON: tmpModels,
    },
  });

  transportScheme = await resolveDockerTransportScheme();
  process.env.E2E_TRANSPORT_SCHEME = transportScheme;
  applySelfSignedTlsBypass();
  await waitForHealth();

  console.log(`[e2e] Docker server healthy, e2eModel=${E2E_MODEL}`);
}

async function restartDockerServerPreservingData(): Promise<void> {
  execSync("docker restart oppi-e2e", { stdio: "inherit" });
  transportScheme = await resolveDockerTransportScheme();
  process.env.E2E_TRANSPORT_SCHEME = transportScheme;
  applySelfSignedTlsBypass();
  await waitForHealth();
}

async function stopDockerServer(): Promise<void> {
  const composeFile = join(__dirname, "docker-compose.e2e.yml");
  try {
    execSync(dockerStartupCleanupCommand(composeFile), {
      cwd: HARNESS_SERVER_DIR,
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
  console.log(`[e2e] Starting native server from ${TARGET_SERVER_DIR} ...`);

  const startupSteps = nativeStartupStepsForTarget();

  // Build the repo checkout when the harness targets source. Installed package
  // tarballs already contain dist/ and do not ship source/build tooling.
  if (startupSteps.includes("build")) {
    execSync("npm run build", { cwd: HARNESS_SERVER_DIR, stdio: "inherit" });
  }

  if (startupSteps.includes("assertEntrypoint") && !existsSync(TARGET_SERVER_ENTRY)) {
    throw new Error(`[e2e] Missing server entrypoint: ${TARGET_SERVER_ENTRY}`);
  }

  nativeDataDir = mkdtempSync(join(tmpdir(), "oppi-e2e-native-"));
  process.env.E2E_NATIVE_DATA_DIR = nativeDataDir;

  // Pre-configure. ConfigStore merges this minimal file with defaults at startup.
  const nativeTlsMode = process.env.E2E_TLS_MODE === "disabled" ? "disabled" : "self-signed";
  writeFileSync(
    join(nativeDataDir, "config.json"),
    JSON.stringify(
      { host: "127.0.0.1", port: E2E_PORT, token: ADMIN_TOKEN, tls: { mode: nativeTlsMode } },
      null,
      2,
    ),
    { mode: 0o600 },
  );

  transportScheme = nativeTlsMode === "disabled" ? "http" : "https";
  process.env.E2E_TRANSPORT_SCHEME = transportScheme;
  applySelfSignedTlsBypass();

  // Generate a self-contained models.json so the native server always uses
  // the probed local model instead of relying on the developer's global config.
  const modelId = E2E_MODEL_ID || (await discoverLocalModelId());
  if (!modelId) throw new Error("[e2e] OMLX server has no models loaded");
  const piDir = join(nativeDataDir, "pi-agent");
  const { mkdirSync: mkdir } = await import("node:fs");
  mkdir(piDir, { recursive: true });
  writeFileSync(
    join(piDir, "models.json"),
    JSON.stringify(makeModelsConfig(OMLX_HOST_URL, modelId), null, 2),
  );

  await launchNativeServerProcess();
  console.log("[e2e] Native server healthy");
}

async function launchNativeServerProcess(): Promise<void> {
  const dataDir = nativeDataDir ?? process.env.E2E_NATIVE_DATA_DIR;
  if (!dataDir) {
    throw new Error("[e2e] Native data dir not initialized");
  }
  nativeDataDir = dataDir;

  const logPath = join(dataDir, "server.log");
  const logFd = openSync(logPath, "w");

  serverProcess = spawn("node", [TARGET_SERVER_ENTRY, "serve"], {
    cwd: TARGET_SERVER_DIR,
    env: {
      ...process.env,
      OPPI_DATA_DIR: dataDir,
      PI_CODING_AGENT_DIR: join(dataDir, "pi-agent"),
      PI_AGENT_SYNC_MODE: "skip",
      OPPI_E2E_UI_HARNESS: process.env.OPPI_E2E_UI_HARNESS,
    },
    stdio: ["ignore", logFd, logFd],
  });

  closeSync(logFd);
  if (serverProcess.pid) {
    process.env.E2E_NATIVE_SERVER_PID = String(serverProcess.pid);
  }

  await waitForHealth();
}

async function terminateNativeServerProcess(): Promise<void> {
  if (serverProcess && !serverProcess.killed) {
    serverProcess.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        serverProcess?.kill("SIGKILL");
        resolve();
      }, 30_000);
      serverProcess!.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
  } else if (process.env.E2E_NATIVE_SERVER_PID) {
    const pid = Number(process.env.E2E_NATIVE_SERVER_PID);
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // Process may already be gone.
    }
    try {
      await waitForCondition(
        () => !isProcessRunning(pid),
        `native server process ${pid} to exit`,
        30_000,
        100,
      );
    } catch {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        // Process exited between the condition check and escalation.
      }
      await waitForCondition(
        () => !isProcessRunning(pid),
        `native server process ${pid} to exit after SIGKILL`,
        10_000,
        100,
      );
    }
  }
  serverProcess = null;
  delete process.env.E2E_NATIVE_SERVER_PID;
  cleanStaleE2EListeners();
}

async function restartNativeServerPreservingData(): Promise<void> {
  await terminateNativeServerProcess();
  await launchNativeServerProcess();
}

async function stopNativeServer(): Promise<void> {
  await terminateNativeServerProcess();

  if (nativeDataDir) {
    rmSync(nativeDataDir, { recursive: true, force: true });
    nativeDataDir = null;
    delete process.env.E2E_NATIVE_DATA_DIR;
  }
}

async function waitForHealth(): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < BOOT_TIMEOUT_MS) {
    try {
      const res = await fetch(`${baseURL()}/health`);
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

export interface E2ESessionListRow {
  id: string;
  [key: string]: unknown;
}

export interface E2EAppleBootstrapResult {
  deviceToken: string;
  workspaceId: string;
  inviteURL: string;
  baseURL: string;
  transportScheme: E2ETransportScheme;
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

  const res = await fetch(`${baseURL()}${path}`, {
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

export async function createWorkspace(
  token: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const res = await api("POST", "/workspaces", token, body);
  if (res.status !== 201 || !res.json?.workspace) {
    throw new Error(`Workspace create failed (${res.status}): ${res.text}`);
  }
  return res.json.workspace as Record<string, unknown>;
}

export async function createWorkspaceSession(
  token: string,
  workspaceId: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const res = await api(
    "POST",
    `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
    token,
    body,
  );
  if (res.status !== 201 || !res.json?.session) {
    throw new Error(`Session create failed (${res.status}): ${res.text}`);
  }
  return res.json.session as Record<string, unknown>;
}

export async function listWorkspaceSessions(
  token: string,
  workspaceId: string,
  status: "active" | "stopped" = "active",
  timeRange?: { sinceMs: number; untilMs: number },
): Promise<E2ESessionListRow[]> {
  const params = new URLSearchParams({ status });
  if (timeRange) {
    params.set("sinceMs", String(timeRange.sinceMs));
    params.set("untilMs", String(timeRange.untilMs));
  }

  const res = await api(
    "GET",
    `/workspaces/${encodeURIComponent(workspaceId)}/sessions?${params.toString()}`,
    token,
  );
  if (res.status !== 200) {
    throw new Error(`Session list failed (${res.status}): ${res.text}`);
  }

  const rows = res.json?.[status];
  if (!Array.isArray(rows)) {
    throw new Error(`Session list response missing ${status} session list: ${res.text}`);
  }
  return rows as E2ESessionListRow[];
}

// ── Pairing helpers ──

/**
 * Generate a pairing invite directly via Storage (bypasses server CLI).
 * Returns the invite deep-link URL and the raw invite payload.
 */
export async function generateTestInvite(opts?: {
  inviteHost?: string;
  pairingTokenTtlMs?: number;
}): Promise<{
  inviteURL: string;
  invitePayload: Record<string, unknown>;
  pairingToken: string;
  fingerprint: string;
}> {
  const inviteHost = opts?.inviteHost ?? "host.docker.internal";
  const pairingTokenTtlMs = opts?.pairingTokenTtlMs ?? 60_000;
  const storageImport =
    process.env.E2E_NATIVE === "1"
      ? pathToFileURL(join(TARGET_SERVER_DIR, "dist/src/storage.js")).href
      : "./dist/src/storage.js";
  const inviteImport =
    process.env.E2E_NATIVE === "1"
      ? pathToFileURL(join(TARGET_SERVER_DIR, "dist/src/invite.js")).href
      : "./dist/src/invite.js";
  const scriptContent = [
    `import { Storage } from ${JSON.stringify(storageImport)};`,
    `import { generateInvite } from ${JSON.stringify(inviteImport)};`,
    "const storage = new Storage(process.env.OPPI_DATA_DIR);",
    "const invite = generateInvite(",
    `  storage, () => ${JSON.stringify(inviteHost)}, () => "e2e-server",`,
    `  { pairingTokenTtlMs: ${pairingTokenTtlMs} }`,
    ");",
    "const payload = {",
    `  v: 3, host: "127.0.0.1", port: ${E2E_PORT},`,
    "  scheme: invite.scheme, token: '',",
    "  pairingToken: invite.pairingToken,",
    "  name: invite.name,",
    "  fingerprint: invite.fingerprint,",
    "  tlsCertFingerprint: invite.tlsCertFingerprint,",
    "};",
    "console.log(JSON.stringify({",
    "  inviteURL: invite.inviteURL, invitePayload: payload,",
    "  pairingToken: invite.pairingToken, fingerprint: invite.fingerprint,",
    "}));",
  ].join("\n");

  const tmpScript = join(tmpdir(), `oppi-e2e-invite-${Date.now()}.mjs`);
  writeFileSync(tmpScript, scriptContent);

  try {
    if (process.env.E2E_NATIVE === "1") {
      const dataDir = process.env.E2E_NATIVE_DATA_DIR;
      if (!dataDir) throw new Error("[e2e] Native data dir not available for invite generation");
      const raw = execSync(`OPPI_DATA_DIR=${dataDir} node ${tmpScript}`, {
        cwd: TARGET_SERVER_DIR,
        encoding: "utf-8",
      }).trim();
      return JSON.parse(raw);
    }

    execSync(`docker cp ${tmpScript} oppi-e2e:/opt/oppi-server/gen-invite.mjs`, { stdio: "pipe" });
    const raw = execSync("docker exec -w /opt/oppi-server oppi-e2e node gen-invite.mjs", {
      encoding: "utf-8",
    }).trim();
    return JSON.parse(raw);
  } finally {
    rmSync(tmpScript, { force: true });
  }
}

export async function pairDevice(pairingToken: string, deviceName = "e2e-device"): Promise<string> {
  const res = await api("POST", "/pair", undefined, { pairingToken, deviceName });
  const deviceToken = res.json?.deviceToken;
  if (res.status !== 200 || typeof deviceToken !== "string" || deviceToken.length === 0) {
    throw new Error(`Pairing failed (${res.status}): ${res.text}`);
  }
  return deviceToken;
}

export async function bootstrapAppleE2E(opts?: {
  workspaceName?: string;
  model?: string;
  inviteFile?: string;
  deviceTokenFile?: string;
}): Promise<E2EAppleBootstrapResult> {
  const scriptInvite = await generateTestInvite({ pairingTokenTtlMs: 600_000 });
  const deviceToken = await pairDevice(scriptInvite.pairingToken, "e2e-script-bootstrap");
  const workspace = await createWorkspace(deviceToken, {
    name: opts?.workspaceName ?? "e2e-workspace",
    ...(opts?.model ? { defaultModel: opts.model } : {}),
  });
  const workspaceId = String(workspace.id ?? "");
  if (!workspaceId) {
    throw new Error("Workspace create response did not include an id");
  }

  const appInvite = await generateTestInvite({
    inviteHost: "127.0.0.1",
    pairingTokenTtlMs: 600_000,
  });
  writeFileSync(opts?.inviteFile ?? DEFAULT_APP_INVITE_FILE, appInvite.inviteURL);
  writeFileSync(opts?.deviceTokenFile ?? DEFAULT_APP_DEVICE_TOKEN_FILE, deviceToken);

  return {
    deviceToken,
    workspaceId,
    inviteURL: appInvite.inviteURL,
    baseURL: baseURL(),
    transportScheme: activeTransportScheme(),
  };
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
  workspaceId?: string;
  requestId?: string;
  command?: string;
  id?: string;
  method?: string;
  tool?: string;
  clientTurnId?: string;
  stage?: string;
  duplicate?: boolean;
  success?: boolean;
  error?: string;
  data?: unknown;
  summary?: unknown;
  sessionStatus?: string;
  sessionSeq?: number;
  currentSeq?: number;
  content?: string;
  delta?: string;
  seq: number;
}

async function openStreamAt(url: string, deviceToken: string): Promise<StreamConnection> {
  const ws = new WebSocket(url, {
    headers: { Authorization: `Bearer ${deviceToken}` },
    ...(isSecureTransport() ? { rejectUnauthorized: false } : {}),
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

  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.terminate();
      reject(new Error(`WS open timeout (${WEBSOCKET_TIMEOUT_MS}ms)`));
    }, WEBSOCKET_TIMEOUT_MS);
    ws.once("open", () => {
      clearTimeout(timer);
      resolve();
    });
    ws.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });

  await waitForEvent(connection, (e) => e.type === "stream_connected", "stream_connected");

  return connection;
}

export async function openSessionStream(
  deviceToken: string,
  workspaceId: string,
  sessionId: string,
): Promise<StreamConnection> {
  const connection = await openStreamAt(sessionStreamURL(workspaceId, sessionId), deviceToken);
  await waitForEvent(
    connection,
    (e) => e.direction === "in" && e.type === "connected" && e.sessionId === sessionId,
    `session connected (${sessionId})`,
  );
  return connection;
}

export async function closeStream(conn: StreamConnection): Promise<void> {
  if (conn.closed) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      conn.ws.terminate();
      resolve();
    }, STREAM_CLOSE_TIMEOUT_MS);
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
  const timeoutMs = opts?.timeoutMs ?? WEBSOCKET_TIMEOUT_MS;
  let cursor = opts?.startIndex ?? 0;

  return new Promise((resolve, reject) => {
    const cleanup = (): void => {
      clearTimeout(timer);
      conn.ws.off("message", check);
      conn.ws.off("close", onClose);
      conn.ws.off("error", onError);
    };
    const fail = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const check = (): void => {
      while (cursor < conn.events.length) {
        const index = cursor++;
        const event = conn.events[index];
        if (predicate(event)) {
          cleanup();
          resolve({ event, index });
          return;
        }
      }

      if (conn.closed) {
        fail(new Error(`Stream closed while waiting for ${label} (code=${conn.closeCode})`));
      }
    };
    const onClose = (code: number): void => {
      fail(new Error(`Stream closed while waiting for ${label} (code=${code})`));
    };
    const onError = (error: Error): void => {
      fail(new Error(`Stream errored while waiting for ${label}: ${error.message}`));
    };
    const timer = setTimeout(
      () => fail(new Error(`Timeout waiting for ${label} (${timeoutMs}ms)`)),
      timeoutMs,
    );

    conn.ws.on("message", check);
    conn.ws.once("close", onClose);
    conn.ws.once("error", onError);
    check();
  });
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
  const timeoutMs = opts?.timeoutMs ?? 300_000;

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
 * Compatibility no-op. Permission gating now happens inside Pi extensions via
 * generic extension UI messages; there is no custom approval-response path.
 */
export function autoApprovePermissions(
  _conn: StreamConnection,
  _sessionId: string,
): { stop: () => void; count: () => number } {
  return {
    stop() {},
    count: () => 0,
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
  if (msg.workspaceId) event.workspaceId = msg.workspaceId as string;
  if (msg.requestId) event.requestId = msg.requestId as string;
  if (msg.command) event.command = msg.command as string;
  if (msg.id) event.id = msg.id as string;
  if (msg.method) event.method = msg.method as string;
  if (msg.tool) event.tool = msg.tool as string;
  if (msg.clientTurnId) event.clientTurnId = msg.clientTurnId as string;
  if (msg.stage) event.stage = msg.stage as string;
  if (typeof msg.duplicate === "boolean") event.duplicate = msg.duplicate;
  if (typeof msg.success === "boolean") event.success = msg.success;
  if (msg.error) event.error = msg.error as string;
  if ("data" in msg) event.data = msg.data;
  if ("summary" in msg) event.summary = msg.summary;
  if (msg.session && typeof (msg.session as Record<string, unknown>).status === "string") {
    event.sessionStatus = (msg.session as Record<string, unknown>).status as string;
  }
  if (typeof msg.seq === "number") event.sessionSeq = msg.seq;
  if (typeof msg.currentSeq === "number") event.currentSeq = msg.currentSeq;
  if (typeof msg.content === "string") event.content = msg.content;
  if (typeof msg.delta === "string") event.delta = msg.delta;
  return event;
}

function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForCondition(
  predicate: () => boolean | Promise<boolean>,
  label: string,
  timeoutMs: number,
  pollMs: number,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await predicate())) {
    if (Date.now() >= deadline) {
      throw new Error(`Timeout waiting for ${label} (${timeoutMs}ms)`);
    }
    await sleep(pollMs);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
