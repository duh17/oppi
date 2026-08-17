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
import { AppEventStreamMux } from "./app-event-stream.js";
import { BoundSessionStreamMux, DictationStreamMux } from "./stream.js";
import { RouteHandler } from "./routes/index.js";
import { normalizeRegisteredPathPattern } from "./routes/registry.js";
import { shouldRecordHttpRequestMetric } from "./http-request-metrics.js";
import { ModelCatalog } from "./model-catalog.js";
import { ExtensionProviderCatalog } from "./extension-model-discovery.js";
import { LiveActivityBridge } from "./live-activity.js";
import { SessionPushNotifier } from "./session-push-notifier.js";
import { AgentScheduleRunner } from "./agent-schedule-runner.js";
import { ServerResourceSampler } from "./server-resource-sampler.js";
import { ServerMetricCollector } from "./server-metric-collector.js";
import { SearchIndex } from "./search-index.js";
import { JsonlMetricWriter } from "./server-metric-writer.js";
import { WsMessageHandler } from "./ws-message-handler.js";
import { PiTuiMirrorRuntime } from "./pi-tui-mirror-runtime.js";
import { SessionRuntimes } from "./runtime-router.js";
import {
  ModelRegistry,
  ModelRuntime,
  getAgentDir,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { SkillRegistry } from "./skills.js";
import { isDeclaredControlSession } from "./control-session.js";
import { ServerResourceService } from "./server-resource-service.js";

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
import {
  readCertificateFingerprint,
  TailscaleRemoteUnavailableError,
  tlsSchemeForConfig,
  type ResolvedTlsConfig,
} from "./tls.js";
import { prepareTlsForServerOffMainThread } from "./tls-preparation.js";
import {
  listenOnLocalApiSocket,
  localApiSocketPath,
  type LocalApiSocketBinding,
} from "./local-api-socket.js";
import { isLocalRequest, isSecureNetworkRequest, markLocalRequest } from "./request-trust.js";
import { getPackageInfo } from "./version.js";
import { SessionTitleGenerator } from "./session-title-generator.js";
import { DictationManager } from "./dictation-manager.js";
import { DEFAULT_DICTATION_CONFIG, type DictationConfig } from "./dictation-types.js";
import { StreamingSttProvider } from "./stt-provider.js";
import { ProviderAuthManager } from "./provider-auth/provider-auth-manager.js";
import { fetchProviderQuotas } from "./provider-quota.js";
import {
  garbageCollectUploadStore,
  resolveUploadStoreConfig,
  type UploadStoreConfigResolved,
} from "./uploads/local-upload-store.js";

export type FocusedSessionStreamPath =
  | { scope: "workspace"; workspaceId: string; sessionId: string }
  | { scope: "control"; sessionId: string };

export function matchFocusedSessionStreamPath(path: string): FocusedSessionStreamPath | null {
  const workspaceMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/);
  const controlMatch = path.match(/^\/control-sessions\/([^/]+)\/stream$/);
  try {
    if (workspaceMatch) {
      return {
        scope: "workspace",
        workspaceId: decodeURIComponent(workspaceMatch[1]),
        sessionId: decodeURIComponent(workspaceMatch[2]),
      };
    }
    if (controlMatch) {
      return { scope: "control", sessionId: decodeURIComponent(controlMatch[1]) };
    }
  } catch {
    return null;
  }
  return null;
}

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
const WS_SHUTDOWN_GRACE_MS = 500;
const MIN_UPLOAD_GC_INTERVAL_MS = 5 * 60 * 1000;
const MAX_UPLOAD_GC_INTERVAL_MS = 60 * 60 * 1000;

type SocketPrincipal =
  | { kind: "owner" }
  | { kind: "device"; deviceId: string; tokenClass: "at_" | "dt_" };

const log = createLogger({ base: { component: "server" } });

type TransportServer = ReturnType<typeof createServer> | ReturnType<typeof createHttpsServer>;

function closeListeningServer(server: TransportServer | undefined): Promise<void> {
  if (!server?.listening) return Promise.resolve();
  server.closeIdleConnections?.();
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

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

  private storage: Storage;
  private sessions: SessionManager;
  private skillRegistry: SkillRegistry;
  private readonly serverResources: ServerResourceService;
  private skillsInitialized = false;
  private reportedMissingWorkspaceSkills = new Set<string>();
  private push: PushClient;
  private httpServer?: ReturnType<typeof createServer> | ReturnType<typeof createHttpsServer>;
  private readonly localApiServer: ReturnType<typeof createServer>;
  private readonly localApiSocket: string;
  private localApiBinding?: LocalApiSocketBinding;
  private transportScheme: "http" | "https" = "http";
  private transportCertPath?: string;
  private remoteTransportError?: string;
  private wss: WebSocketServer;
  private localWss: WebSocketServer;

  private readonly piExecutable: string;
  private readonly identityFingerprint: string;
  private bonjourAdvertiser: BonjourAdvertiser | null = null;
  private modelRuntime!: ModelRuntime;
  private modelRegistry!: ModelRegistry;
  private models!: ModelCatalog;
  private extensionProviderCatalog!: ExtensionProviderCatalog;
  private providerAuth!: ProviderAuthManager;
  private titleGenerator!: SessionTitleGenerator;

  // Track all WebSocket connections for lifecycle/resource accounting.
  private connections: Set<WebSocket> = new Set();
  private socketPrincipals: Map<WebSocket, SocketPrincipal> = new Map();

  // Server resource utilization sampler (CPU, memory, sessions)
  private resourceSampler: ServerResourceSampler;

  // Server operational metrics (latencies, counts, errors)
  private opsMetrics: ServerMetricCollector;

  // Live Activity push bridge (debounced APNs updates)
  private liveActivity: LiveActivityBridge;
  // Regular APNs alerts for terminal/error session events.
  private sessionPushNotifier: SessionPushNotifier;

  // Full-text search index (SQLite FTS5)
  private searchIndex: SearchIndex | null = null;
  private appEventStreamMux!: AppEventStreamMux;
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
  private scheduleRunner!: AgentScheduleRunner;

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;
    this.piExecutable = resolvePiExecutable();

    const dataDir = storage.getDataDir();
    const config = storage.getConfig();
    const identity = ensureIdentityMaterial(identityConfigForDataDir(dataDir));
    this.identityFingerprint = identity.fingerprint;
    this.serverResources = new ServerResourceService({
      dataDir,
      agentDir: getAgentDir(),
      oppiSettings: {
        get: () => this.storage.getOppiExtensionSettings(),
        getLoadError: () => this.storage.getOppiExtensionSettingsLoadError(),
      },
    });
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
    this.sessionPushNotifier = new SessionPushNotifier(this.push, this.storage);
    this.sessions = new SessionManager(storage, this.opsMetrics);
    this.sessions.contextWindowResolver = (modelId: string) =>
      this.models.getContextWindow(modelId);
    this.sessions.skillPathResolver = (names: string[]) => this.resolveSkillPaths(names);

    this.mirrorRuntime = new PiTuiMirrorRuntime(this.storage, {
      isOppiSessionActive: (sessionId) => this.sessions.getActiveSession(sessionId) !== undefined,
      stopOppiSession: (sessionId) => this.sessions.stopSession(sessionId),
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

    // Create global app, split session, and audio stream muxes.
    this.appEventStreamMux = new AppEventStreamMux({
      storage: this.storage,
      sessionRuntimes: this.sessionRuntimes,
      ensureSessionContextWindow: (session: Session) =>
        this.models.ensureSessionContextWindow(session),
      trackConnection: (ws: WebSocket) => this.trackConnection(ws),
      untrackConnection: (ws: WebSocket) => this.untrackConnection(ws),
      metrics: this.opsMetrics,
    });
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

    const handleSessionEvent = (payload: SessionBroadcastEvent): void => {
      this.liveActivity.handleSessionEvent(payload);
      this.sessionPushNotifier.handleSessionEvent(payload);
      this.appEventStreamMux.handleSessionBroadcastEvent(payload);
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

    this.scheduleRunner = new AgentScheduleRunner({
      storage: this.storage,
      sessions: this.sessions,
      ensureSessionContextWindow: (session) => this.models.ensureSessionContextWindow(session),
      appEvents: this.appEventStreamMux,
    });

    this.localApiSocket = localApiSocketPath(dataDir);
    this.localApiServer = createServer((req, res) => {
      markLocalRequest(req);
      void this.handleHttp(req, res, "http");
    });

    this.wss = new WebSocketServer({
      noServer: true,
      maxPayload: WS_MAX_PAYLOAD_BYTES,
      perMessageDeflate: {
        zlibDeflateOptions: { level: 1 }, // fast compression (speed > ratio)
        threshold: 1024, // only compress messages >= 1KB
      },
    });
    this.localWss = new WebSocketServer({ noServer: true, maxPayload: WS_MAX_PAYLOAD_BYTES });

    this.transportScheme = tlsSchemeForConfig(config);
  }

  private createTransportServer(tls: ResolvedTlsConfig): {
    server: ReturnType<typeof createServer> | ReturnType<typeof createHttpsServer>;
    scheme: "http" | "https";
    certPath?: string;
  } {
    if (!tls.enabled) {
      return {
        server: createServer((req, res) => {
          void this.handleHttp(req, res, "http");
        }),
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
      server: createHttpsServer({ cert, key }, (req, res) => {
        void this.handleHttp(req, res, "https");
      }),
      scheme: "https",
      certPath: tls.certPath,
    };
  }

  // ─── Start / Stop ───

  private async refreshModelCatalog(options?: { force?: boolean }): Promise<void> {
    // The common GET /models path fingerprints and skips. A source change awaits
    // one reload so the picker does not return a stale extension catalog.
    // models.refresh() stays stale-while-revalidate after that.
    await this.extensionProviderCatalog.sync({ force: options?.force === true });
    await this.models.refresh();
  }

  private async initializeModelServices(): Promise<void> {
    const agentDir = getAgentDir();
    this.modelRuntime = await ModelRuntime.create({
      authPath: join(agentDir, "auth.json"),
      modelsPath: join(agentDir, "models.json"),
    });
    this.modelRegistry = new ModelRegistry(this.modelRuntime);
    this.models = new ModelCatalog(this.modelRegistry, this.storage, () =>
      SettingsManager.create(process.cwd(), agentDir).getEnabledModels(),
    );

    // Discover custom provider extensions (e.g. kiro/antigravity) and register
    // their providers on the server-wide model runtime so their models reach the
    // /models picker. Later GET /models calls resync when global sources change;
    // extension enable/disable force-resyncs. Failures are logged, never fatal.
    this.extensionProviderCatalog = new ExtensionProviderCatalog(this.modelRuntime, {
      cwd: process.cwd(),
      agentDir,
    });
    try {
      await this.extensionProviderCatalog.sync();
    } catch (error) {
      log.warn("models.extension_discovery_failed", {
        error: error instanceof Error ? error.message : String(error),
      });
    }
    this.providerAuth = new ProviderAuthManager({
      modelRuntime: this.modelRuntime,
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
      onCredentialsChanged: () => this.models.refresh(),
    });

    // Auto-title generator — generates concise task titles on first user message.
    this.titleGenerator = new SessionTitleGenerator({
      getConfig: () => this.storage.getConfig().autoTitle ?? { enabled: false },
      modelRuntime: this.modelRuntime,
      getSession: (sessionId) => this.storage.getSession(sessionId) ?? undefined,
      setSessionName: async (sessionId, name) => {
        await this.sessions.runCommand(sessionId, { type: "set_session_name", name });

        // Keep Oppi's Session.name as a projection for list/header broadcasts.
        // Pi's session_info entry is the source of truth.
        const active = this.sessions.getActiveSession(sessionId);
        if (active) {
          active.name = name;
          this.storage.saveSession(active);
        }
      },
      broadcastSessionUpdate: (sessionId) => {
        this.appEventStreamMux.emitSessionSummaryById(sessionId);
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

    // Model/auth routes depend on the asynchronous Pi ModelRuntime.
    this.routes = new RouteHandler({
      storage: this.storage,
      sessions: this.sessions,
      sessionRuntimes: this.sessionRuntimes,
      skillRegistry: this.skillRegistry,
      serverResources: this.serverResources,
      providerAuth: this.providerAuth,
      ensureSessionContextWindow: (session) => this.models.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (session) => this.resolveWorkspaceForSession(session),
      refreshModelCatalog: (options) => this.refreshModelCatalog(options),
      getModelCatalog: () => this.models.getAll(),
      getProviderQuotasStatus: () => fetchProviderQuotas({ modelRuntime: this.modelRuntime }),
      searchIndex: this.searchIndex ?? undefined,
      appEvents: this.appEventStreamMux,
      serverStartedAt: Date.now(),
      serverVersion: Server.VERSION,
      piVersion: Server.detectPiVersion(this.piExecutable),
      onDeviceRevoked: (deviceId) => this.closeConnectionsForDevice(deviceId),
      onMigrationFinalized: (finalized) => {
        if (finalized) this.closeLegacyTokenConnections();
      },
      onOwnerTokenRotated: () => this.closeAllDeviceConnections(),
    });
  }

  async start(): Promise<void> {
    const config = this.storage.getConfig();
    const startupSecurityError = validateStartupSecurityConfig(config);
    if (startupSecurityError) {
      throw new Error(startupSecurityError);
    }
    for (const warning of formatStartupSecurityWarnings(config)) {
      log.warn("startup.security.warning", { warning });
    }

    await this.initializeModelServices();

    // Prime model catalog so first picker open is fast.
    await this.models.refresh();

    // Heal stale persisted contextWindow fallbacks before any client connects.
    this.models.healPersistedSessionContextWindows();

    // Mark zombie sessions (non-terminal status on disk but not in memory) as stopped.
    // These are sessions that crashed mid-startup or were orphaned by a server restart.
    this.healOrphanedSessions();

    const finishStartup = async (): Promise<void> => {
      if (this.httpServer?.listening) {
        try {
          this.startBonjourAdvertisement();
        } catch (err: unknown) {
          log.warn("bonjour.advertisement_disabled", { error: safeErrorMessage(err) });
        }
      }

      this.resourceSampler.start();
      this.opsMetrics.start();
      this.startUploadGcLoop();
      this.scheduleRunner.start();

      // Background: warm the search index without monopolizing the event loop.
      if (this.searchIndex) {
        const idx = this.searchIndex;
        setImmediate(() => {
          try {
            const sessions = this.storage.listSessions();
            void idx.startBackgroundSync(sessions).catch((err: unknown) => {
              log.error("server.search_index_sync.failed", {
                error: safeErrorMessage(err),
              });
            });
          } catch (err: unknown) {
            log.error("server.search_index_sync.failed", {
              error: safeErrorMessage(err),
            });
          }
        });
      }
    };

    this.localApiBinding = await listenOnLocalApiSocket(this.localApiServer, this.localApiSocket);
    log.info("server.local_api_listening", { socketPath: this.localApiSocket });
    this.localApiServer.on("upgrade", (req, socket, head) => {
      markLocalRequest(req);
      const url = new URL(req.url || "/", "http://localhost");
      if (url.pathname !== "/mirror/v1/bridge") {
        writeUpgradeErrorResponse(socket, "HTTP/1.1 404 Not Found", {
          Connection: "close",
          "Content-Length": "0",
        });
        return;
      }
      this.localWss.handleUpgrade(req, socket, head, (ws) => {
        this.trackConnection(ws);
        ws.on("close", () => this.untrackConnection(ws));
        this.mirrorRuntime.handleBridgeWebSocket(ws);
      });
    });

    try {
      try {
        const tls = await prepareTlsForServerOffMainThread(
          { tls: config.tls },
          this.storage.getDataDir(),
          { additionalHosts: [config.host] },
        );
        const transport = this.createTransportServer(tls);
        this.httpServer = transport.server;
        this.transportScheme = transport.scheme;
        this.transportCertPath = transport.certPath;
        this.httpServer.on("upgrade", (req, socket, head) => {
          this.handleUpgrade(req, socket, head);
        });
      } catch (error: unknown) {
        if (!(error instanceof TailscaleRemoteUnavailableError)) throw error;
        this.remoteTransportError = safeErrorMessage(error);
      }

      if (this.httpServer) {
        await new Promise<void>((resolve, reject) => {
          const server = this.httpServer;
          if (!server) {
            resolve();
            return;
          }
          const onError = (error: Error): void => reject(error);
          server.once("error", onError);
          server.listen(config.port, config.host, () => {
            server.off("error", onError);
            resolve();
          });
        });
        log.info("server.listening", {
          scheme: this.transportScheme,
          host: config.host,
          port: this.port,
        });
      } else {
        log.warn("server.remote_listener_unavailable", {
          mode: config.tls?.mode ?? "disabled",
          error: this.remoteTransportError ?? "remote transport unavailable",
        });
      }

      await finishStartup();
    } catch (error: unknown) {
      await closeListeningServer(this.httpServer).catch(() => {});
      await closeListeningServer(this.localApiServer).catch(() => {});
      this.releaseLocalApiBinding();
      throw error;
    }
  }

  /** Actual listening port (may differ from config when config.port is 0). */
  get port(): number {
    const addr = this.httpServer?.address();
    if (addr && typeof addr === "object") return addr.port;
    return this.storage.getConfig().port;
  }

  get scheme(): "http" | "https" {
    return this.transportScheme;
  }

  get socketPath(): string {
    return this.localApiSocket;
  }

  get remoteAvailable(): boolean {
    return this.httpServer?.listening === true;
  }

  get hasPublicHttpListener(): boolean {
    return this.httpServer?.listening === true;
  }

  async stop(): Promise<void> {
    this.stopUploadGcLoop();
    this.scheduleRunner.stop();
    this.opsMetrics.stop();
    this.resourceSampler.stop();
    this.stopBonjourAdvertisement();
    this.skillRegistry.stopWatching();

    let shutdownError: unknown;
    try {
      await this.sessions.stopAll();
      this.liveActivity.shutdown();
      this.push.shutdown();
      this.searchIndex?.close();
      await this.closeWebSocketServer();
    } catch (error: unknown) {
      shutdownError = error;
    }

    const closeResults = await Promise.allSettled([
      closeListeningServer(this.httpServer),
      closeListeningServer(this.localApiServer),
    ]);
    this.releaseLocalApiBinding();

    if (shutdownError) throw shutdownError;
    const closeFailure = closeResults.find(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    if (closeFailure) throw closeFailure.reason;
  }

  private releaseLocalApiBinding(): void {
    this.localApiBinding?.release();
    this.localApiBinding = undefined;
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

  // ─── Dictation ───

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

  private closeConnectionsForDevice(deviceId: string): void {
    for (const [ws, principal] of this.socketPrincipals) {
      if (principal.kind === "device" && principal.deviceId === deviceId) {
        ws.close(1008, "Device revoked");
      }
    }
  }

  private closeLegacyTokenConnections(): void {
    for (const [ws, principal] of this.socketPrincipals) {
      if (principal.kind === "device" && principal.tokenClass === "dt_") {
        ws.close(1008, "Device token rejected");
      }
    }
  }

  private closeLegacyTokenConnectionsForDevice(deviceId: string): void {
    for (const [ws, principal] of this.socketPrincipals) {
      if (
        principal.kind === "device" &&
        principal.deviceId === deviceId &&
        principal.tokenClass === "dt_"
      ) {
        ws.close(1008, "Device credential migrated");
      }
    }
  }

  private closeAllDeviceConnections(): void {
    for (const [ws, principal] of this.socketPrincipals) {
      if (principal.kind === "device") ws.close(1008, "Owner credentials rotated");
    }
  }

  private closeWebSocketServer(): Promise<void> {
    this.closeActiveConnections(WS_CLOSE_GOING_AWAY, "Server shutting down");
    const closeLocal = new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        for (const ws of this.localWss.clients) ws.terminate();
      }, WS_SHUTDOWN_GRACE_MS);
      this.localWss.close(() => {
        clearTimeout(timer);
        resolve();
      });
    });
    const closeNetwork = new Promise<void>((resolve, reject) => {
      const forceCloseTimer = setTimeout(() => {
        for (const ws of this.wss.clients) ws.terminate();
      }, WS_SHUTDOWN_GRACE_MS);
      this.wss.close((error) => {
        clearTimeout(forceCloseTimer);
        if (error) reject(error);
        else resolve();
      });
    });
    return Promise.all([closeLocal, closeNetwork]).then(() => undefined);
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

  private authenticate(req: IncomingMessage): SocketPrincipal | null {
    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return null;
    const candidate = auth.slice(7);
    const owner = this.storage.getToken();
    if (owner && secureTokenEquals(owner, candidate)) {
      return isLocalRequest(req) ? { kind: "owner" } : null;
    }

    if (!isSecureNetworkRequest(req)) return null;

    const access = this.storage.validateAccessToken(candidate);
    if (access.ok) {
      if (this.storage.commitLegacyRevocation(access.deviceId)) {
        this.closeLegacyTokenConnectionsForDevice(access.deviceId);
      }
      return { kind: "device", deviceId: access.deviceId, tokenClass: "at_" };
    }
    if (this.storage.isMigrationFinalized()) return null;
    for (const dt of this.storage.getAuthDeviceTokens()) {
      if (secureTokenEquals(dt, candidate) && this.storage.hasAuthToken(dt)) {
        const deviceId = this.storage.deviceIdForLegacyToken(dt);
        return deviceId ? { kind: "device", deviceId, tokenClass: "dt_" } : null;
      }
    }
    return null;
  }

  // ─── HTTP Router ───

  private async handleHttp(
    req: IncomingMessage,
    res: ServerResponse,
    scheme: "http" | "https",
  ): Promise<void> {
    const startTime = Date.now();
    const url = new URL(req.url || "/", `${scheme}://${req.headers.host ?? "localhost"}`);
    const path = url.pathname;
    const method = req.method || "GET";

    res.setHeader("X-Oppi-Protocol", "2");

    // Record HTTP request duration when the response finishes. Routine health,
    // stats, capability, session poll, and telemetry upload routes are
    // threshold-gated so they do not dominate diagnostics volume while still
    // surfacing slow/error cases.
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

    if (path === "/health") {
      this.json(res, { ok: true, protocol: 2 });
      return;
    }

    // Pairing and device-auth bootstrap are supported only on the remote TLS
    // listener. Plain HTTP cannot enroll, migrate, challenge, or refresh
    // HTTPS/WSS device credentials.
    const isDeviceAuthBootstrap =
      (path === "/pair" && method === "POST") ||
      (path === "/auth/migrate" && method === "POST") ||
      (path === "/auth/challenge" && method === "POST") ||
      (path === "/auth/refresh" && method === "POST");
    if (isDeviceAuthBootstrap && !isSecureNetworkRequest(req)) {
      this.error(res, 403, "HTTPS required");
      return;
    }
    if (isDeviceAuthBootstrap) {
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

    const principal = this.authenticate(req);
    if (!principal) {
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

    const principal = this.authenticate(req);
    if (!principal) {
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

    const sessionStreamMatch = matchFocusedSessionStreamPath(url.pathname);
    const appEventStreamMatch = url.pathname === "/app/events/stream";
    const dictationStreamMatch = url.pathname === "/dictation/stream";
    const mirrorBridgeMatch = url.pathname === "/mirror/v1/bridge";
    if (
      !sessionStreamMatch &&
      !appEventStreamMatch &&
      !dictationStreamMatch &&
      !mirrorBridgeMatch
    ) {
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

    if (mirrorBridgeMatch) {
      writeUpgradeErrorResponse(socket, "HTTP/1.1 404 Not Found", {
        Connection: "close",
        "Content-Length": "0",
      });
      return;
    }

    const upgradeReceivedAt = Date.now();
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.socketPrincipals.set(ws, principal);
      ws.on("close", () => this.socketPrincipals.delete(ws));
      if (sessionStreamMatch) {
        const sessionId = sessionStreamMatch.sessionId;
        const session = this.storage.getSession(sessionId);
        const inScope =
          sessionStreamMatch.scope === "workspace"
            ? session?.workspaceId === sessionStreamMatch.workspaceId
            : session !== undefined && isDeclaredControlSession(session);
        if (!session || !inScope) {
          ws.close(1008, "Session not found");
          return;
        }
        if (sessionStreamMatch.scope === "workspace") {
          this.boundSessionStreamMux.handleWebSocket(
            sessionStreamMatch.workspaceId,
            sessionId,
            ws,
            upgradeReceivedAt,
          );
        } else {
          this.boundSessionStreamMux.handleControlWebSocket(sessionId, ws, upgradeReceivedAt);
        }
        return;
      }
      if (appEventStreamMatch) {
        this.appEventStreamMux.handleWebSocket(ws, upgradeReceivedAt);
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
