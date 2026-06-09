/**
 * HTTP + WebSocket server.
 *
 * Bridges phone clients to locally running pi sessions.
 * Handles: auth, session CRUD, WebSocket streaming, and extension UI request relay.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { type Socket } from "node:net";
import { type Duplex } from "node:stream";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";
import { fileURLToPath } from "node:url";

import { spawnSync } from "node:child_process";
import { timingSafeEqual } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager } from "./sessions.js";
import type { SessionBroadcastEvent } from "./session-broadcast.js";
import { BoundSessionStreamMux, DictationStreamMux } from "./stream.js";
import { RouteHandler } from "./routes/index.js";
import { normalizeRegisteredPathPattern } from "./routes/registry.js";
import { ModelCatalog } from "./model-catalog.js";
import { LiveActivityBridge } from "./live-activity.js";
import { ServerResourceSampler } from "./server-resource-sampler.js";
import { ServerMetricCollector } from "./server-metric-collector.js";
import { SearchIndex } from "./search-index.js";
import { JsonlMetricWriter } from "./server-metric-writer.js";
import { WsMessageHandler } from "./ws-message-handler.js";
import { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import { SessionRuntimes } from "./runtime-router.js";
import {
  ModelRegistry,
  AuthStorage,
  getAgentDir,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { SkillRegistry } from "./skills.js";

import { createPushClient, type PushClient, type APNsConfig } from "./push.js";

import type {
  Session,
  Workspace,
  ServerMessage,
  ClientMessage,
  ApiError,
  ServerConfig,
} from "./types.js";
import { ts, safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import {
  BonjourAdvertiser,
  buildBonjourServiceName,
  buildBonjourTxtRecord,
  isBonjourEnabled,
  OPPI_BONJOUR_SERVICE_TYPE,
} from "./bonjour-advertiser.js";
import { DnsSdBonjourPublisher, isDnsSdAvailable } from "./bonjour-dns-sd.js";
import { prepareTlsForServer, readCertificateFingerprint, tlsSchemeForConfig } from "./tls.js";
import { RuntimeUpdateManager } from "./runtime-update.js";
import { getPackageInfo } from "./version.js";
import { SessionTitleGenerator } from "./session-title-generator.js";
import { DictationManager } from "./dictation-manager.js";
import { DEFAULT_DICTATION_CONFIG, type DictationConfig } from "./dictation-types.js";
import { StreamingSttProvider } from "./stt-provider.js";
import { ProviderAuthManager } from "./provider-auth/provider-auth-manager.js";
import { fetchCodexUsageStatus } from "./codex-usage.js";
import {
  garbageCollectUploadStore,
  resolveUploadStoreConfig,
  type UploadStoreConfigResolved,
} from "./uploads/local-upload-store.js";

function hasAuthHeader(header: string | string[] | undefined): boolean {
  if (typeof header === "string") {
    return header.trim().length > 0;
  }
  if (Array.isArray(header)) {
    return header.some((value) => value.trim().length > 0);
  }
  return false;
}

function secureTokenEquals(expected: string, actual: string): boolean {
  const expectedBytes = Buffer.from(expected, "utf-8");
  const actualBytes = Buffer.from(actual, "utf-8");
  if (expectedBytes.length !== actualBytes.length) {
    return false;
  }
  return timingSafeEqual(expectedBytes, actualBytes);
}

const WS_MAX_PAYLOAD_BYTES = 16 * 1024 * 1024;
const WS_CLOSE_GOING_AWAY = 1001;
const MIN_UPLOAD_GC_INTERVAL_MS = 5 * 60 * 1000;
const MAX_UPLOAD_GC_INTERVAL_MS = 60 * 60 * 1000;

const log = createLogger({ base: { component: "server" } });

function writeUpgradeErrorResponse(
  socket: Duplex,
  statusLine: string,
  headers: Record<string, string> = {},
): void {
  const lines = [statusLine, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`), "", ""];
  socket.write(lines.join("\r\n"));
  socket.destroy();
}

function isAllowedWebSocketOrigin(
  req: IncomingMessage,
  transportScheme: "http" | "https",
): boolean {
  const originHeader = Array.isArray(req.headers.origin)
    ? req.headers.origin[0]
    : req.headers.origin;
  if (!originHeader) {
    return true;
  }

  const hostHeader = Array.isArray(req.headers.host) ? req.headers.host[0] : req.headers.host;
  if (!hostHeader) {
    return false;
  }

  try {
    const origin = new URL(originHeader);
    return origin.protocol === `${transportScheme}:` && origin.host === hostHeader;
  } catch {
    return false;
  }
}

export function formatUnauthorizedAuthLog(opts: {
  transport: "http" | "ws";
  path: string;
  method?: string;
  authorization: string | string[] | undefined;
}): string {
  const authPresent = hasAuthHeader(opts.authorization);

  if (opts.transport === "ws") {
    return `${ts()} [auth] 401 WS upgrade ${opts.path} — auth: ${authPresent ? "present" : "missing"}`;
  }

  const method = opts.method || "GET";
  return `${ts()} [auth] 401 ${method} ${opts.path} — auth: ${authPresent ? "present" : "missing"}`;
}

/**
 * Collapse dynamic path segments (UUIDs, hex IDs) into `:id` placeholders
 * so HTTP request metrics aggregate by route pattern, not by resource.
 */
function normalizePathPattern(path: string): string {
  const registered = normalizeRegisteredPathPattern(path);
  if (registered) return registered;

  return path
    .replace(/\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "/:id")
    .replace(/\/[0-9a-f]{16,}/gi, "/:id");
}

const ROUTINE_HTTP_METRIC_PATTERNS = new Set([
  "/health",
  "/server/info",
  "/server/stats",
  "/workspaces",
  "/skills",
  "/sessions/recent",
  "/workspaces/:workspaceId/attention",
  "/workspaces/:workspaceId/paths",
  "/workspaces/:workspaceId/review/comments",
  "/models",
  "/telemetry/chat-metrics",
  "/telemetry/client-logs",
  "/telemetry/metrickit",
]);
const ROUTINE_HTTP_METRIC_SLOW_MS = 50;

function shouldRecordHttpRequestMetric(
  pathPattern: string,
  statusCode: number,
  durationMs: number,
): boolean {
  if (statusCode >= 400) return true;
  if (durationMs >= ROUTINE_HTTP_METRIC_SLOW_MS) return true;
  return !ROUTINE_HTTP_METRIC_PATTERNS.has(pathPattern);
}

function normalizeBindHost(host: string): string {
  const trimmed = host.trim().toLowerCase();
  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function isLoopbackBindHost(host: string): boolean {
  return host === "127.0.0.1" || host === "localhost" || host === "::1";
}

function isWildcardBindHost(host: string): boolean {
  return host === "0.0.0.0" || host === "::";
}

function isIPv4Address(host: string): boolean {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host);
}

function firstLanIPv4Address(
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces(),
): string | null {
  for (const entries of Object.values(interfaces)) {
    if (!entries) continue;
    for (const entry of entries) {
      if (entry.family !== "IPv4") continue;
      if (entry.internal) continue;
      if (entry.address.startsWith("169.254.")) continue;
      return entry.address;
    }
  }
  return null;
}

export function resolveBonjourLanHost(
  bindHost: string,
  interfaces: NodeJS.Dict<NetworkInterfaceInfo[]> = networkInterfaces(),
): string | null {
  const normalizedHost = normalizeBindHost(bindHost);
  if (!normalizedHost || isLoopbackBindHost(normalizedHost)) {
    return null;
  }

  if (!isWildcardBindHost(normalizedHost) && isIPv4Address(normalizedHost)) {
    return normalizedHost;
  }

  return firstLanIPv4Address(interfaces);
}

/**
 * Startup-only warnings for insecure server bind + transport posture.
 *
 * These warnings are advisory. Startup validation separately blocks unsafe
 * non-loopback HTTP unless the operator explicitly opts into that posture.
 */
function allowInsecureNetworkHttp(config: ServerConfig): boolean {
  return config.tls?.mode === "disabled" && config.tls.allowInsecureNetworkHttp === true;
}

export function validateStartupSecurityConfig(config: ServerConfig): string | null {
  const host = normalizeBindHost(config.host);
  const loopbackOnly = isLoopbackBindHost(host);

  if (!loopbackOnly && !config.token) {
    return `Cannot bind to ${config.host} without a token configured. Set token in config or use --host 127.0.0.1`;
  }

  if (!loopbackOnly && tlsSchemeForConfig(config) === "http" && !allowInsecureNetworkHttp(config)) {
    return `Cannot bind to ${config.host} with TLS disabled. Use tls.mode=self-signed|tailscale|manual, bind to 127.0.0.1, or explicitly set tls.allowInsecureNetworkHttp=true.`;
  }

  return null;
}

export function formatStartupSecurityWarnings(config: ServerConfig): string[] {
  const warnings: string[] = [];
  const host = normalizeBindHost(config.host);
  const wildcardBind = isWildcardBindHost(host);
  const loopbackOnly = isLoopbackBindHost(host);

  if (wildcardBind) {
    warnings.push(
      `host=${config.host} listens on all interfaces; ensure access is constrained by firewall rules.`,
    );
  }

  if (!loopbackOnly && tlsSchemeForConfig(config) === "http") {
    const suffix = allowInsecureNetworkHttp(config)
      ? " tls.allowInsecureNetworkHttp=true permits this insecure network bind."
      : " Startup will refuse this unless tls.allowInsecureNetworkHttp=true is set.";
    warnings.push(
      `TLS is disabled while binding to ${config.host}; traffic is unencrypted.${suffix}`,
    );
  }

  return warnings;
}

/** Resolve the pi executable path for version detection. */
function resolvePiExecutable(): string {
  const envPath = process.env.OPPI_PI_BIN;
  if (envPath && existsSync(envPath)) {
    return envPath;
  }

  for (const candidate of ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"]) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  return "pi";
}

export class Server {
  static readonly VERSION = getPackageInfo().version;

  static detectPiVersion(piExecutable: string): string {
    try {
      // pi --version writes to stderr (not stdout), so capture both.
      const result = spawnSync(piExecutable, ["--version"], {
        encoding: "utf-8",
        timeout: 5000,
        stdio: ["ignore", "pipe", "pipe"],
      });
      const output = result.stdout?.trim() || result.stderr?.trim() || "";
      // Output may be "pi 0.8.0" or just "0.8.0"
      const match = output.match(/(\d+\.\d+\.\d+)/);
      return match ? match[1] : output || "unknown";
    } catch {
      return "unknown";
    }
  }

  /** Read installed pi-coding-agent version from its package.json. */
  static detectPiAgentVersion(): string {
    // import.meta.url points to dist/src/server.js
    // node_modules is at the project root (two levels up from dist/src/)
    const srcDir = dirname(fileURLToPath(import.meta.url));
    const packageScopes = ["@earendil-works", "@mariozechner"];
    const candidateRoots = [
      join(srcDir, "..", "..", "node_modules"),
      join(srcDir, "..", "node_modules"),
    ];
    const candidates = candidateRoots.flatMap((root) =>
      packageScopes.map((scope) => join(root, scope, "pi-coding-agent", "package.json")),
    );
    for (const pkgPath of candidates) {
      try {
        const pkg = JSON.parse(readFileSync(pkgPath, "utf-8")) as { version?: string };
        if (pkg.version) return pkg.version;
      } catch {
        // Try next candidate
      }
    }
    return "unknown";
  }

  private storage: Storage;
  private sessions: SessionManager;
  private skillRegistry: SkillRegistry;
  private skillsInitialized = false;
  private reportedMissingWorkspaceSkills = new Set<string>();
  private push: PushClient;
  private httpServer: ReturnType<typeof createServer> | ReturnType<typeof createHttpsServer>;
  private transportScheme: "http" | "https" = "http";
  private transportCertPath?: string;
  private wss: WebSocketServer;

  private readonly piExecutable: string;
  private readonly identityFingerprint: string;
  private bonjourAdvertiser: BonjourAdvertiser | null = null;
  private modelRegistry: ModelRegistry;
  private models: ModelCatalog;
  private providerAuth: ProviderAuthManager;
  private runtimeUpdates: RuntimeUpdateManager;
  private titleGenerator: SessionTitleGenerator;

  // Track all WebSocket connections for lifecycle/resource accounting.
  private connections: Set<WebSocket> = new Set();

  // Server resource utilization sampler (CPU, memory, sessions)
  private resourceSampler: ServerResourceSampler;

  // Server operational metrics (latencies, counts, errors)
  private opsMetrics: ServerMetricCollector;

  // Live Activity push bridge (debounced APNs updates)
  private liveActivity: LiveActivityBridge;

  // Full-text search index (SQLite FTS5)
  private searchIndex: SearchIndex | null = null;
  private boundSessionStreamMux!: BoundSessionStreamMux;
  private dictationStreamMux!: DictationStreamMux;
  private mirrorRuntime!: PiTuiMirrorRuntime;
  private sessionRuntimes!: SessionRuntimes;
  // REST route handler (dispatch + all HTTP handlers)
  private routes!: RouteHandler;
  // WebSocket message command dispatcher for full-session commands
  private wsMessageHandler!: WsMessageHandler;
  // Dictation pipeline capability source for ASR streams
  private dictationManager: DictationManager | undefined;
  private dictationConfig: DictationConfig | undefined;
  private uploadGcTimer: ReturnType<typeof setInterval> | null = null;

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;
    this.piExecutable = resolvePiExecutable();

    // SDK model registry + catalog
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
    this.modelRegistry = ModelRegistry.create(authStorage, join(agentDir, "models.json"));
    this.models = new ModelCatalog(this.modelRegistry, this.storage, () =>
      SettingsManager.create(process.cwd(), agentDir).getEnabledModels(),
    );
    this.providerAuth = new ProviderAuthManager({
      authStorage,
      getKnownApiKeyProviderIds: () => {
        const knownApiKeyProviders = new Set<string>([
          "anthropic",
          "openai",
          "google",
          "deepseek",
          "mistral",
          "groq",
          "xai",
          "openrouter",
          "zai",
        ]);
        const oauthOnlyProviders = new Set<string>([
          "openai-codex",
          "github-copilot",
          "google-gemini-cli",
          "google-antigravity",
        ]);

        for (const model of this.modelRegistry.getAll()) {
          if (!oauthOnlyProviders.has(model.provider)) {
            knownApiKeyProviders.add(model.provider);
          }
        }

        return [...knownApiKeyProviders];
      },
      onCredentialsChanged: () => {
        this.models.refresh();
      },
    });
    // Runtime version reporter — updates are managed by the Mac app via Sparkle.
    this.runtimeUpdates = new RuntimeUpdateManager({
      currentVersion: Server.detectPiAgentVersion(),
    });

    const dataDir = storage.getDataDir();
    const config = storage.getConfig();
    const identity = ensureIdentityMaterial(identityConfigForDataDir(dataDir));
    this.identityFingerprint = identity.fingerprint;
    // Server operational metrics collector (event-driven latencies, counts).
    this.opsMetrics = new ServerMetricCollector(
      new JsonlMetricWriter(join(dataDir, "diagnostics", "telemetry")),
    );

    // Scan both host skills (~/.pi/agent/skills/) and bundled skills (server/skills/).
    const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
    const bundledSkillsDir = join(serverRoot, "skills");
    this.skillRegistry = new SkillRegistry(existsSync(bundledSkillsDir) ? [bundledSkillsDir] : []);

    this.push = createPushClient(apnsConfig, this.opsMetrics);
    this.liveActivity = new LiveActivityBridge(this.push, this.storage);
    this.sessions = new SessionManager(storage, this.opsMetrics);
    this.sessions.contextWindowResolver = (modelId: string) =>
      this.models.getContextWindow(modelId);
    this.sessions.skillPathResolver = (names: string[]) => this.resolveSkillPaths(names);

    this.mirrorRuntime = new PiTuiMirrorRuntime(this.storage, {
      isOppiSessionActive: (sessionId) => this.sessions.getActiveSession(sessionId) !== undefined,
    });
    this.sessionRuntimes = new SessionRuntimes(this.storage, this.sessions, this.mirrorRuntime);

    this.wsMessageHandler = new WsMessageHandler({
      sessions: this.sessionRuntimes,
      ensureSessionContextWindow: (targetSession) =>
        this.models.ensureSessionContextWindow(targetSession),
    });

    // Dictation pipeline. Dictation streams create one DictationManager per WebSocket.
    const asrEnabled = !!config.asr?.sttEndpoint;
    if (asrEnabled) {
      this.dictationConfig = { ...DEFAULT_DICTATION_CONFIG, ...config.asr } as DictationConfig;
      this.dictationManager = this.createDictationManager();
    }

    const streamContext = {
      storage: this.storage,
      sessions: this.sessions,
      sessionRuntimes: this.sessionRuntimes,
      metrics: this.opsMetrics,
      ensureSessionContextWindow: (session: Session) =>
        this.models.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (session: Session) => this.resolveWorkspaceForSession(session),
      handleClientMessage: (
        session: Session,
        msg: ClientMessage,
        send: (msg: ServerMessage) => void,
        meta?: { connId?: string },
      ) => this.wsMessageHandler.handleClientMessage(session, msg, send, meta),
      trackConnection: (ws: WebSocket) => this.trackConnection(ws),
      untrackConnection: (ws: WebSocket) => this.untrackConnection(ws),
      dictationManager: this.dictationManager,
      createDictationManager: () => this.createDictationManager(),
    };

    // Create split session/audio stream muxes.
    this.boundSessionStreamMux = new BoundSessionStreamMux(streamContext);
    this.dictationStreamMux = new DictationStreamMux(streamContext);

    // Server resource utilization sampler
    this.resourceSampler = new ServerResourceSampler({
      telemetryDir: join(dataDir, "diagnostics", "telemetry"),
      getSessionCounts: () => {
        const ids = this.sessionRuntimes.getActiveSessionIds();
        let busy = 0;
        let ready = 0;
        let starting = 0;
        for (const id of ids) {
          const s = this.sessionRuntimes.getActiveSession(id);
          if (!s) continue;
          if (s.status === "busy") busy++;
          else if (s.status === "ready") ready++;
          else if (s.status === "starting") starting++;
        }
        return { busy, ready, starting, total: ids.size };
      },
      getWebSocketCount: () => this.connections.size,
      recordOpsMetric: (metric, value, tags) =>
        this.opsMetrics.record(metric as Parameters<typeof this.opsMetrics.record>[0], value, tags),
      getEventRingSnapshots: () => {
        const snapshots: Array<{ ring: string; length: number; capacity: number }> = [];
        // Per-session event rings
        for (const id of this.sessionRuntimes.getActiveSessionIds()) {
          const ring = this.sessionRuntimes.getEventRing(id);
          if (ring) {
            snapshots.push({ ring: "session", length: ring.length, capacity: ring.capacity });
          }
        }
        return snapshots;
      },
    });

    // Auto-title generator — generates concise task titles on first user message
    this.titleGenerator = new SessionTitleGenerator({
      getConfig: () => this.storage.getConfig().autoTitle ?? { enabled: false },
      modelRegistry: this.modelRegistry,
      getSession: (sessionId) => this.storage.getSession(sessionId) ?? undefined,
      updateSessionName: (sessionId, name) => {
        // Update the active session object (authoritative in-memory reference)
        // so subsequent lifecycle persists carry the name. Falling back to the
        // storage copy handles stopped/inactive sessions.
        const active = this.sessionRuntimes.getActiveSession(sessionId);
        if (active) {
          active.name = name;
          this.storage.saveSession(active);
        } else {
          const session = this.storage.getSession(sessionId);
          if (session) {
            session.name = name;
            this.storage.saveSession(session);
          }
        }
      },
      broadcastSessionUpdate: () => {
        // Workspace/session list refreshes pick up title changes.
      },
      onMetrics: (metrics) => {
        this.opsMetrics.record("server.session_title_gen_ms", metrics.durationMs, {
          model: metrics.model,
          status: metrics.status,
          tokens: String(metrics.tokens),
        });
      },
    });
    this.sessions.onFirstMessage = (session) => this.titleGenerator.tryGenerateTitle(session);

    const handleSessionEvent = (payload: SessionBroadcastEvent): void => {
      this.liveActivity.handleSessionEvent(payload);
    };
    this.sessions.on("session_event", handleSessionEvent);
    this.mirrorRuntime.on("session_event", handleSessionEvent);

    // Initialize search index (SQLite FTS5)
    try {
      this.searchIndex = new SearchIndex(config.dataDir, (id) => this.storage.getSession(id));
      this.sessions.searchIndex = this.searchIndex;
      this.mirrorRuntime.searchIndex = this.searchIndex;
    } catch (err) {
      log.error("server.search_index_init.failed", {
        error: safeErrorMessage(err),
      });
    }

    // Create route handler (dispatch + all HTTP business logic)
    this.routes = new RouteHandler({
      storage: this.storage,
      sessions: this.sessions,
      sessionRuntimes: this.sessionRuntimes,
      skillRegistry: this.skillRegistry,
      providerAuth: this.providerAuth,
      ensureSessionContextWindow: (session) => this.models.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (session) => this.resolveWorkspaceForSession(session),
      refreshModelCatalog: () => {
        this.models.refresh();
        return Promise.resolve();
      },
      getModelCatalog: () => this.models.getAll(),
      getRuntimeUpdateStatus: (options) => this.runtimeUpdates.getStatus(options),
      runRuntimeUpdate: () => this.runtimeUpdates.updateRuntime(),
      getCodexUsageStatus: () => fetchCodexUsageStatus(),
      searchIndex: this.searchIndex ?? undefined,
      serverStartedAt: Date.now(),
      serverVersion: Server.VERSION,
      piVersion: Server.detectPiVersion(this.piExecutable),
    });

    const transport = this.createTransportServer(config);
    this.httpServer = transport.server;
    this.transportScheme = transport.scheme;
    this.transportCertPath = transport.certPath;

    this.wss = new WebSocketServer({
      noServer: true,
      maxPayload: WS_MAX_PAYLOAD_BYTES,
      perMessageDeflate: {
        zlibDeflateOptions: { level: 1 }, // fast compression (speed > ratio)
        threshold: 1024, // only compress messages >= 1KB
      },
    });

    this.httpServer.on("upgrade", (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });
  }

  private createTransportServer(config: ServerConfig): {
    server: ReturnType<typeof createServer> | ReturnType<typeof createHttpsServer>;
    scheme: "http" | "https";
    certPath?: string;
  } {
    const handler = (req: IncomingMessage, res: ServerResponse): void => {
      void this.handleHttp(req, res);
    };

    const tls = prepareTlsForServer(config, this.storage.getDataDir(), {
      additionalHosts: [config.host],
    });

    if (!tls.enabled) {
      return {
        server: createServer(handler),
        scheme: "http",
      };
    }

    if (!tls.certPath || !tls.keyPath) {
      throw new Error(`TLS mode "${tls.mode}" requires certPath and keyPath`);
    }

    const cert = readFileSync(tls.certPath, "utf-8");
    const key = readFileSync(tls.keyPath, "utf-8");

    // Note: `ca` is intentionally NOT passed to createHttpsServer.
    // We don't use mutual TLS (client certificates) — auth is bearer tokens.
    // Passing `ca` here causes Bun's node:https compat layer to demand client
    // certs (oven-sh/bun#16254), breaking HTTPS for all clients.
    return {
      server: createHttpsServer({ cert, key }, handler),
      scheme: "https",
      certPath: tls.certPath,
    };
  }

  // ─── Start / Stop ───

  async start(): Promise<void> {
    const config = this.storage.getConfig();
    const startupSecurityError = validateStartupSecurityConfig(config);
    if (startupSecurityError) {
      throw new Error(startupSecurityError);
    }

    // Prime model catalog so first picker open is fast.
    this.models.refresh();

    // Heal stale persisted contextWindow fallbacks before any client connects.
    this.models.healPersistedSessionContextWindows();

    // Mark zombie sessions (non-terminal status on disk but not in memory) as stopped.
    // These are sessions that crashed mid-startup or were orphaned by a server restart.
    this.healOrphanedSessions();

    const securityWarnings = formatStartupSecurityWarnings(config);
    for (const warning of securityWarnings) {
      log.warn("startup.security.warning", { warning });
    }

    return new Promise((resolve, reject) => {
      this.httpServer.once("error", reject);
      this.httpServer.listen(config.port, config.host, () => {
        this.httpServer.removeListener("error", reject);
        log.info("server.listening", {
          scheme: this.transportScheme,
          host: config.host,
          port: this.port,
        });

        try {
          this.startBonjourAdvertisement();
        } catch (err: unknown) {
          const message = safeErrorMessage(err);
          log.warn("bonjour.advertisement_disabled", { error: message });
        }

        this.resourceSampler.start();
        this.opsMetrics.start();
        this.startUploadGcLoop();

        // Background: sync search index (non-blocking, fires after listen)
        if (this.searchIndex) {
          const idx = this.searchIndex;
          const sessions = this.storage.listSessions();
          setTimeout(() => {
            try {
              idx.sync(sessions);
            } catch (err) {
              log.error("server.search_index_sync.failed", {
                error: safeErrorMessage(err),
              });
            }
          }, 0);
        }

        resolve();
      });
    });
  }

  /** Actual listening port (may differ from config when config.port is 0). */
  get port(): number {
    const addr = this.httpServer.address();
    if (addr && typeof addr === "object") return addr.port;
    return this.storage.getConfig().port;
  }

  get scheme(): "http" | "https" {
    return this.transportScheme;
  }

  async stop(): Promise<void> {
    this.stopUploadGcLoop();
    this.opsMetrics.stop();
    this.resourceSampler.stop();
    this.stopBonjourAdvertisement();
    this.skillRegistry.stopWatching();
    await this.sessions.stopAll();
    this.liveActivity.shutdown();
    this.push.shutdown();
    this.searchIndex?.close();
    this.closeActiveConnections(WS_CLOSE_GOING_AWAY, "Server shutting down");
    this.wss.close();
    this.httpServer.close();
  }

  private uploadGcIntervalMs(config: UploadStoreConfigResolved): number {
    const ttlFloor = Math.min(config.unusedTtlMs, config.retainedTtlMs);
    return Math.max(
      MIN_UPLOAD_GC_INTERVAL_MS,
      Math.min(MAX_UPLOAD_GC_INTERVAL_MS, Math.max(1, Math.floor(ttlFloor / 2))),
    );
  }

  private startUploadGcLoop(): void {
    const config = resolveUploadStoreConfig(this.storage.getConfig());
    const run = async (): Promise<void> => {
      try {
        const result = await garbageCollectUploadStore(
          resolveUploadStoreConfig(this.storage.getConfig()),
        );
        if (result.removedRecords || result.removedTmpFiles || result.removedBlobs) {
          log.info("upload_store.gc.completed", {
            removedRecords: result.removedRecords,
            removedTmpFiles: result.removedTmpFiles,
            removedBlobs: result.removedBlobs,
          });
        }
      } catch (err: unknown) {
        log.warn("upload_store.gc.failed", {
          error: safeErrorMessage(err),
        });
      }
    };

    void run();
    this.uploadGcTimer = setInterval(() => {
      void run();
    }, this.uploadGcIntervalMs(config));
    this.uploadGcTimer.unref?.();
  }

  private stopUploadGcLoop(): void {
    if (!this.uploadGcTimer) {
      return;
    }
    clearInterval(this.uploadGcTimer);
    this.uploadGcTimer = null;
  }

  private startBonjourAdvertisement(): void {
    if (!isBonjourEnabled()) {
      return;
    }

    if (!isDnsSdAvailable()) {
      log.warn("bonjour.skipped", {
        reason: "dns_sd_unavailable",
      });
      return;
    }

    const config = this.storage.getConfig();
    const normalizedBindHost = normalizeBindHost(config.host);
    if (isLoopbackBindHost(normalizedBindHost)) {
      log.warn("bonjour.skipped", {
        reason: "loopback_bind_host",
        host: config.host,
      });
      return;
    }

    const lanHost = resolveBonjourLanHost(config.host);
    if (!lanHost) {
      log.warn("bonjour.skipped", {
        reason: "no_lan_ipv4",
      });
      return;
    }

    const serviceName = buildBonjourServiceName(this.identityFingerprint);

    const tlsCertFingerprint = this.transportCertPath
      ? readCertificateFingerprint(this.transportCertPath)
      : undefined;

    const txt = buildBonjourTxtRecord({
      serverFingerprint: this.identityFingerprint,
      tlsCertFingerprint,
      lanHost,
      port: this.port,
    });

    if (!this.bonjourAdvertiser) {
      this.bonjourAdvertiser = new BonjourAdvertiser(new DnsSdBonjourPublisher());
    }

    this.bonjourAdvertiser.start({
      serviceType: OPPI_BONJOUR_SERVICE_TYPE,
      serviceName,
      port: this.port,
      txt,
    });

    log.info("bonjour.advertising", {
      serviceName,
      host: lanHost,
      port: this.port,
    });
  }

  private stopBonjourAdvertisement(): void {
    this.bonjourAdvertiser?.stop();
    this.bonjourAdvertiser = null;
  }

  // ─── Startup Healing ───

  private healOrphanedSessions(): void {
    const sessions = this.storage.listSessions();
    let healed = 0;

    for (const s of sessions) {
      // Non-active sessions stuck in running states
      if (s.status !== "stopped" && s.status !== "error") {
        s.status = "stopped";
        s.currentTurnStartedAt = undefined;
        this.storage.saveSession(s);
        healed++;
        continue;
      }
    }

    if (healed > 0) {
      log.info("startup.healed_orphaned_sessions", { count: healed });
    }
  }

  // ─── Push Fallback ───

  /**
   * Send a push notification for attention-worthy events not delivered by a
   * bound session stream. Only fires for selected session lifecycle events.
   */
  private createDictationManager(): DictationManager | undefined {
    if (!this.dictationConfig?.sttEndpoint) return undefined;
    const sttProvider = new StreamingSttProvider(
      {
        endpoint: this.dictationConfig.sttEndpoint,
        model: this.dictationConfig.sttModel,
      },
      globalThis.fetch,
    );
    return new DictationManager(sttProvider, this.opsMetrics);
  }

  private pushFallback(msg: ServerMessage): void {
    const tokens = this.storage.getPushDeviceTokens();
    if (tokens.length === 0) return;

    if (msg.type === "session_ended") {
      const session = this.findSessionByReason(msg);
      for (const token of tokens) {
        this.push.sendSessionEventPush(token, {
          sessionId: session?.id || "unknown",
          sessionName: session?.name,
          event: "ended",
          reason: msg.reason,
        });
      }
    } else if (msg.type === "error") {
      // Only push errors that aren't retries
      if (!msg.error.startsWith("Retrying (")) {
        for (const token of tokens) {
          this.push.sendSessionEventPush(token, {
            sessionId: "unknown",
            event: "error",
            reason: msg.error,
          });
        }
      }
    }
  }

  /**
   * Find session from a session_ended message context.
   * We track which user's sessions are active to find the match.
   */
  private findSessionByReason(_msg: ServerMessage): Session | undefined {
    const sessions = this.storage.listSessions();
    // Return the most recently active session (best effort)
    return sessions.find((s) => s.status === "stopped") || sessions[0];
  }

  private trackConnection(ws: WebSocket): void {
    this.connections.add(ws);
  }

  private untrackConnection(ws: WebSocket): void {
    this.connections.delete(ws);
  }

  private closeActiveConnections(code: number, reason: string): void {
    for (const ws of this.connections) {
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CLOSING) {
        ws.close(code, reason);
      }
    }
  }

  private async ensureSkillsInitialized(): Promise<void> {
    if (this.skillsInitialized) return;

    await this.skillRegistry.resolvePackageSkills();
    this.skillRegistry.scan();
    this.skillRegistry.watch();
    this.skillsInitialized = true;
  }

  /** Resolve workspace skill names to Pi-discovered host directory paths. */
  private async resolveSkillPaths(skillNames: string[]): Promise<string[]> {
    await this.ensureSkillsInitialized();
    const paths: string[] = [];
    const newlyMissingSkills: string[] = [];
    for (const name of skillNames) {
      const skillPath = this.skillRegistry.getPath(name);
      if (skillPath) {
        paths.push(skillPath);
        continue;
      }
      if (!this.reportedMissingWorkspaceSkills.has(name)) {
        this.reportedMissingWorkspaceSkills.add(name);
        newlyMissingSkills.push(name);
      }
    }
    if (newlyMissingSkills.length > 0) {
      log.warn("skills.workspace_skills_not_found", {
        count: newlyMissingSkills.length,
        skills: newlyMissingSkills,
      });
    }
    return paths;
  }

  // ─── Auth ───

  private authenticate(req: IncomingMessage): boolean {
    // Bearer header (primary auth)
    const auth = req.headers.authorization;
    if (auth?.startsWith("Bearer ")) {
      if (this.matchToken(auth.slice(7))) return true;
    }

    return false;
  }

  private matchToken(candidate: string): boolean {
    const configToken = this.storage.getToken();
    if (configToken && secureTokenEquals(configToken, candidate)) return true;

    for (const dt of this.storage.getAuthDeviceTokens()) {
      if (secureTokenEquals(dt, candidate)) return true;
    }

    return false;
  }

  // ─── HTTP Router ───

  private async handleHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const startTime = Date.now();
    const url = new URL(req.url || "/", `${this.transportScheme}://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method || "GET";

    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, DELETE, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.setHeader("X-Oppi-Protocol", "2");

    // Record HTTP request duration when the response finishes. Routine health,
    // stats, capability, and telemetry upload routes are threshold-gated so
    // they do not dominate diagnostics volume while still surfacing slow/error cases.
    res.on("finish", () => {
      const durationMs = Date.now() - startTime;
      const pathPattern = normalizePathPattern(path);
      if (!shouldRecordHttpRequestMetric(pathPattern, res.statusCode, durationMs)) {
        return;
      }
      this.opsMetrics.record("server.http_request_ms", durationMs, {
        method,
        path_pattern: pathPattern,
        status_code: String(res.statusCode),
      });
    });

    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }
    if (path === "/health") {
      this.json(res, { ok: true, protocol: 2 });
      return;
    }

    // Pairing bootstrap endpoint is intentionally unauthenticated.
    if (path === "/pair" && method === "POST") {
      try {
        await this.routes.dispatch(method, path, url, req, res);
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : "Internal error";
        log.error("http.request.failed", {
          method,
          path,
          error: safeErrorMessage(err),
        });
        this.error(res, 500, message);
      }
      return;
    }

    const authenticated = this.authenticate(req);
    if (!authenticated) {
      log.warn("auth.unauthorized", {
        transport: "http",
        method,
        path,
        authPresent: hasAuthHeader(req.headers.authorization),
      });
      this.error(res, 401, "Unauthorized");
      return;
    }

    await this.ensureSkillsInitialized();

    try {
      await this.routes.dispatch(method, path, url, req, res);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal error";
      log.error("http.request.failed", {
        method,
        path,
        error: safeErrorMessage(err),
      });
      this.error(res, 500, message);
    }
  }

  // ─── HTTP Utilities (kept for handleHttp shell) ───

  private json(res: ServerResponse, data: Record<string, unknown>, status = 200): void {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data));
  }

  private error(res: ServerResponse, status: number, message: string): void {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: message } as ApiError));
  }

  private resolveWorkspaceForSession(session: Session): Workspace | undefined {
    return session.workspaceId ? this.storage.getWorkspace(session.workspaceId) : undefined;
  }

  // ─── WebSocket ───

  private handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    (socket as Socket).setNoDelay?.(true);

    const url = new URL(req.url || "/", `${this.transportScheme}://${req.headers.host}`);

    const authenticated = this.authenticate(req);
    if (!authenticated) {
      log.warn("auth.unauthorized", {
        transport: "ws",
        path: url.pathname,
        authPresent: hasAuthHeader(req.headers.authorization),
      });
      writeUpgradeErrorResponse(socket, "HTTP/1.1 401 Unauthorized", {
        "WWW-Authenticate": 'Bearer realm="oppi"',
        Connection: "close",
        "Content-Length": "0",
      });
      return;
    }

    const sessionStreamMatch = url.pathname.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/,
    );
    const dictationStreamMatch = url.pathname === "/dictation/stream";
    const mirrorBridgeMatch = url.pathname === "/mirror/v1/bridge";
    if (!sessionStreamMatch && !dictationStreamMatch && !mirrorBridgeMatch) {
      // Unknown WebSocket endpoint.
      writeUpgradeErrorResponse(socket, "HTTP/1.1 404 Not Found", {
        Connection: "close",
        "Content-Length": "0",
      });
      return;
    }

    if (!isAllowedWebSocketOrigin(req, this.transportScheme)) {
      log.warn("ws.upgrade_rejected_origin_mismatch", {
        origin: req.headers.origin,
        host: req.headers.host,
      });
      writeUpgradeErrorResponse(socket, "HTTP/1.1 403 Forbidden", {
        Connection: "close",
        "Content-Length": "0",
      });
      return;
    }

    const upgradeReceivedAt = Date.now();
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      if (sessionStreamMatch) {
        const workspaceId = decodeURIComponent(sessionStreamMatch[1]);
        const sessionId = decodeURIComponent(sessionStreamMatch[2]);
        const session = this.storage.getSession(sessionId);
        if (!session || session.workspaceId !== workspaceId) {
          ws.close(1008, "Session not found");
          return;
        }
        this.boundSessionStreamMux.handleWebSocket(workspaceId, sessionId, ws, upgradeReceivedAt);
        return;
      }
      if (dictationStreamMatch) {
        this.dictationStreamMux.handleServerWebSocket(ws, upgradeReceivedAt);
        return;
      }
      if (mirrorBridgeMatch) {
        this.trackConnection(ws);
        ws.on("close", () => this.untrackConnection(ws));
        this.mirrorRuntime.handleBridgeWebSocket(ws);
        return;
      }
      ws.close(1008, "Unsupported WebSocket endpoint");
    });
  }
}
