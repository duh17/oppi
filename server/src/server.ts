/**
 * HTTP + WebSocket server.
 *
 * Bridges phone clients to locally running pi sessions.
 * Handles: auth, session CRUD, WebSocket streaming, permission gate
 * forwarding, and extension UI request relay.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { type Socket } from "node:net";
import { type Duplex } from "node:stream";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { networkInterfaces, type NetworkInterfaceInfo } from "node:os";
import { fileURLToPath } from "node:url";

import { execFileSync } from "node:child_process";
import { timingSafeEqual } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager } from "./sessions.js";
import type { SessionBroadcastEvent } from "./session-broadcast.js";
import { UserStreamMux } from "./stream.js";
import { RouteHandler } from "./routes/index.js";
import { ModelCatalog } from "./model-catalog.js";
import { LiveActivityBridge } from "./live-activity.js";
import { ServerMetricsCollector } from "./server-metrics.js";
import { ServerMetricCollector } from "./server-metric-collector.js";
import { JsonlMetricWriter } from "./server-metric-writer.js";
import { WsMessageHandler } from "./ws-message-handler.js";
import { ModelRegistry, AuthStorage, getAgentDir } from "@mariozechner/pi-coding-agent";
import {
  PolicyEngine,
  defaultPolicy,
  policyRulesFromDeclarativeConfig,
  policyRuntimeConfig,
} from "./policy.js";
import { GateServer, buildPermissionMessage, type PendingDecision } from "./gate.js";
import { RuleStore } from "./rules.js";
import { AuditLog } from "./audit.js";

import { SkillRegistry, UserSkillStore } from "./skills.js";

import { createPushClient, type PushClient, type APNsConfig } from "./push.js";

import type { Session, Workspace, ServerMessage, ApiError, ServerConfig } from "./types.js";
import { ts } from "./log-utils.js";
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
import { SessionTitleGenerator } from "./session-title-generator.js";

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

export function formatPermissionRequestLog(opts: {
  requestId: string;
  sessionId: string;
  tool: string;
  displaySummary: string;
}): string {
  return `${ts()} [gate] Permission request ${opts.requestId} (session=${opts.sessionId}, tool=${opts.tool}, summaryChars=${opts.displaySummary.length})`;
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
 * These warnings are intentionally advisory (non-blocking) so operators can
 * run permissive local/dev setups while still seeing risk posture at boot.
 */
export function validateStartupSecurityConfig(config: ServerConfig): string | null {
  const host = normalizeBindHost(config.host);
  const loopbackOnly = isLoopbackBindHost(host);

  if (!loopbackOnly && !config.token) {
    return `Cannot bind to ${config.host} without a token configured. Set token in config or use --host 127.0.0.1`;
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
    warnings.push(`TLS is disabled while binding to ${config.host}; traffic is unencrypted.`);
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
  static readonly VERSION = "0.2.0";

  static detectPiVersion(piExecutable: string): string {
    try {
      const output = execFileSync(piExecutable, ["--version"], {
        encoding: "utf-8",
        timeout: 5000,
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      // Output may be "pi 0.8.0" or just "0.8.0"
      const match = output.match(/(\d+\.\d+\.\d+)/);
      return match ? match[1] : output || "unknown";
    } catch {
      return "unknown";
    }
  }

  /** Read installed @mariozechner/pi-coding-agent version from its package.json. */
  static detectPiAgentVersion(): string {
    try {
      const pkgPath = join(
        dirname(fileURLToPath(import.meta.url)),
        "..",
        "node_modules",
        "@mariozechner",
        "pi-coding-agent",
        "package.json",
      );
      const pkg = JSON.parse(readFileSync(pkgPath, "utf-8")) as { version?: string };
      return pkg.version || "unknown";
    } catch {
      return "unknown";
    }
  }

  private storage: Storage;
  private sessions: SessionManager;
  private policy: PolicyEngine;
  private gate: GateServer;
  private skillRegistry: SkillRegistry;
  private skillsInitialized = false;
  private userSkillStore: UserSkillStore;
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
  private runtimeUpdates: RuntimeUpdateManager;
  private titleGenerator: SessionTitleGenerator;

  // Track WebSocket connections per user for permission/UI forwarding
  private connections: Set<WebSocket> = new Set();

  // Server resource utilization metrics (CPU, memory, sessions)
  private metricsCollector: ServerMetricsCollector;

  // Server operational metrics (latencies, counts, errors)
  private opsMetrics: ServerMetricCollector;

  // Live Activity push bridge (debounced APNs updates)
  private liveActivity: LiveActivityBridge;

  // User-wide stream multiplexer (event ring, subscriptions, /stream WS)
  private streamMux!: UserStreamMux;
  // REST route handler (dispatch + all HTTP handlers)
  private routes!: RouteHandler;
  // WebSocket message command dispatcher (/stream full-session commands)
  private wsMessageHandler!: WsMessageHandler;

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;
    this.piExecutable = resolvePiExecutable();

    // SDK model registry + catalog
    const agentDir = getAgentDir();
    const authStorage = AuthStorage.create(join(agentDir, "auth.json"));
    this.modelRegistry = new ModelRegistry(authStorage, join(agentDir, "models.json"));
    this.models = new ModelCatalog(
      this.modelRegistry,
      this.storage,
      storage.getConfig().modelAllowlist,
    );
    this.runtimeUpdates = new RuntimeUpdateManager({
      packageName: process.env.OPPI_RUNTIME_PACKAGE || "@mariozechner/pi-coding-agent",
      currentVersion: Server.detectPiAgentVersion(),
      npmExecutable: process.env.OPPI_RUNTIME_NPM_BIN || "npm",
      cwd: join(dirname(fileURLToPath(import.meta.url)), ".."),
    });

    const dataDir = storage.getDataDir();
    const config = storage.getConfig();
    const identity = ensureIdentityMaterial(identityConfigForDataDir(dataDir));
    this.identityFingerprint = identity.fingerprint;
    const configuredPolicy = config.policy || defaultPolicy();

    // Runtime policy engine only handles fallback + heuristics.
    // Allow/ask/deny rules live in RuleStore (single runtime source of truth).
    this.policy = new PolicyEngine(policyRuntimeConfig(configuredPolicy));

    // v2 policy infrastructure
    const rulesPath = join(dataDir, "rules.json");
    const ruleStore = new RuleStore(rulesPath);
    ruleStore.seedIfEmpty(policyRulesFromDeclarativeConfig(configuredPolicy));

    // Protect config and rules files from silent agent modification.
    // Hard-coded guard — can't be overridden by rules in the store.
    const configPath = storage.getConfigPath();
    this.policy.setProtectedPaths([rulesPath, configPath]);
    const auditLog = new AuditLog(join(dataDir, "audit.jsonl"));

    // Server operational metrics collector (event-driven latencies, counts)
    // Created before GateServer so we can inject it for gate metrics.
    this.opsMetrics = new ServerMetricCollector(
      new JsonlMetricWriter(join(dataDir, "diagnostics", "telemetry")),
    );

    this.gate = new GateServer(this.policy, ruleStore, auditLog, {
      approvalTimeoutMs: config.approvalTimeoutMs,
      metrics: this.opsMetrics,
    });
    // Scan both host skills (~/.pi/agent/skills/) and bundled skills (server/skills/).
    const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
    const bundledSkillsDir = join(serverRoot, "skills");
    this.skillRegistry = new SkillRegistry(existsSync(bundledSkillsDir) ? [bundledSkillsDir] : []);
    this.userSkillStore = new UserSkillStore();
    this.userSkillStore.init();

    this.push = createPushClient(apnsConfig, this.opsMetrics);
    this.liveActivity = new LiveActivityBridge(this.push, this.storage, this.gate);
    this.sessions = new SessionManager(storage, this.gate, this.opsMetrics);
    this.sessions.contextWindowResolver = (modelId: string) =>
      this.models.getContextWindow(modelId);
    this.sessions.skillPathResolver = (names: string[]) => this.resolveSkillPaths(names);
    this.sessions.availableModelIdsResolver = () => this.models.getAll().map((m) => m.id);

    this.wsMessageHandler = new WsMessageHandler({
      sessions: this.sessions,
      gate: this.gate,
      ensureSessionContextWindow: (targetSession) =>
        this.models.ensureSessionContextWindow(targetSession),
      resolveWorkspaceForSession: (session) => this.resolveWorkspaceForSession(session),
    });

    // Create the user stream mux (handles /stream WS, event rings, replay)
    this.streamMux = new UserStreamMux({
      storage: this.storage,
      sessions: this.sessions,
      gate: this.gate,
      metrics: this.opsMetrics,
      ensureSessionContextWindow: (session) => this.models.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (session) => this.resolveWorkspaceForSession(session),
      handleClientMessage: (session, msg, send) =>
        this.wsMessageHandler.handleClientMessage(session, msg, send),
      trackConnection: (ws) => this.trackConnection(ws),
      untrackConnection: (ws) => this.untrackConnection(ws),
    });

    // Server resource utilization metrics collector
    this.metricsCollector = new ServerMetricsCollector({
      telemetryDir: join(dataDir, "diagnostics", "telemetry"),
      getSessionCounts: () => {
        const ids = this.sessions.getActiveSessionIds();
        let busy = 0;
        let ready = 0;
        let starting = 0;
        for (const id of ids) {
          const s = this.sessions.getActiveSession(id);
          if (!s) continue;
          if (s.status === "busy") busy++;
          else if (s.status === "ready") ready++;
          else if (s.status === "starting") starting++;
        }
        return { busy, ready, starting, total: ids.size };
      },
      getWebSocketCount: () => this.connections.size,
      recordOpsMetric: (metric, value) =>
        this.opsMetrics.record(metric as Parameters<typeof this.opsMetrics.record>[0], value),
    });

    // Auto-title generator — generates concise task titles on first user message
    this.titleGenerator = new SessionTitleGenerator({
      getConfig: () => this.storage.getConfig().autoTitle ?? { enabled: false },
      modelRegistry: this.modelRegistry,
      getSession: (sessionId) => this.storage.getSession(sessionId) ?? undefined,
      updateSessionName: (sessionId, name) => {
        const session = this.storage.getSession(sessionId);
        if (session) {
          session.name = name;
          this.storage.saveSession(session);
        }
      },
      broadcastSessionUpdate: (sessionId) => {
        const session = this.storage.getSession(sessionId);
        if (session) {
          this.broadcastToUser({ type: "state", session, sessionId });
        }
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

    this.sessions.on("session_event", (payload: SessionBroadcastEvent) => {
      this.liveActivity.handleSessionEvent(payload);

      if (!this.streamMux.isNotificationLevelMessage(payload.event)) {
        return;
      }

      // Record in user-level stream ring (creates its own copy with streamSeq).
      // Do NOT mutate payload.event — it's the same object reference stored in
      // the per-session EventRing. The streamSeq is only relevant for the
      // user-level stream ring, not per-session catch-up.
      this.streamMux.recordUserStreamEvent(payload.sessionId, payload.event);
    });

    // Create route handler (dispatch + all HTTP business logic)
    this.routes = new RouteHandler({
      storage: this.storage,
      sessions: this.sessions,
      gate: this.gate,
      skillRegistry: this.skillRegistry,
      userSkillStore: this.userSkillStore,
      streamMux: this.streamMux,
      ensureSessionContextWindow: (session) => this.models.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (session) => this.resolveWorkspaceForSession(session),
      refreshModelCatalog: () => {
        this.models.refresh();
        return Promise.resolve();
      },
      getModelCatalog: () => this.models.getAll(),
      getRuntimeUpdateStatus: (options) => this.runtimeUpdates.getStatus(options),
      runRuntimeUpdate: () => this.runtimeUpdates.updateRuntime(),
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
      perMessageDeflate: {
        zlibDeflateOptions: { level: 1 }, // fast compression (speed > ratio)
        threshold: 1024, // only compress messages >= 1KB
      },
    });

    this.httpServer.on("upgrade", (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });

    // Wire gate events → phone WebSocket + Live Activity updates
    this.gate.on("approval_needed", (pending: PendingDecision) => {
      this.forwardPermissionRequest(pending);
    });

    this.gate.on(
      "approval_timeout",
      ({ requestId, sessionId }: { requestId: string; sessionId: string }) => {
        const session = this.findSessionById(sessionId);
        if (session) {
          this.broadcastToUser({
            type: "permission_expired",
            id: requestId,
            reason: "Approval timeout",
            sessionId,
          });
          this.liveActivity.queueUpdate({
            sessionId,
            lastEvent: "Permission expired",
            priority: 5,
          });
        }
      },
    );

    this.gate.on(
      "approval_resolved",
      ({ sessionId, action }: { sessionId: string; action: "allow" | "deny" }) => {
        this.liveActivity.queueUpdate({
          sessionId,
          lastEvent: action === "allow" ? "Permission approved" : "Permission denied",
          priority: action === "deny" ? 10 : 5,
        });
      },
    );

    this.gate.on(
      "approval_cancelled",
      ({
        requestId,
        sessionId,
        reason,
      }: {
        requestId: string;
        sessionId: string;
        reason: string;
      }) => {
        this.broadcastToUser({
          type: "permission_cancelled",
          id: requestId,
          sessionId,
        });
        this.liveActivity.queueUpdate({
          sessionId,
          lastEvent: reason,
          priority: 5,
        });
      },
    );
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
    const ca = tls.caPath && existsSync(tls.caPath) ? readFileSync(tls.caPath, "utf-8") : undefined;

    return {
      server: createHttpsServer({ cert, key, ca }, handler),
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
      console.warn(`[startup][security] ${warning}`);
    }

    return new Promise((resolve, reject) => {
      this.httpServer.once("error", reject);
      this.httpServer.listen(config.port, config.host, () => {
        this.httpServer.removeListener("error", reject);
        console.log("🚀 oppi listening", {
          scheme: this.transportScheme,
          host: config.host,
          port: this.port,
        });

        try {
          this.startBonjourAdvertisement();
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          console.warn(`[bonjour] advertisement disabled: ${message}`);
        }

        this.metricsCollector.start();
        this.opsMetrics.start();

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
    this.opsMetrics.stop();
    this.metricsCollector.stop();
    this.stopBonjourAdvertisement();
    this.skillRegistry.stopWatching();
    await this.sessions.stopAll();
    await this.gate.shutdown();
    this.liveActivity.shutdown();
    this.push.shutdown();
    this.wss.close();
    this.httpServer.close();
  }

  private startBonjourAdvertisement(): void {
    if (!isBonjourEnabled()) {
      return;
    }

    if (!isDnsSdAvailable()) {
      console.warn("[bonjour] dns-sd command not found; skipping LAN advertisement");
      return;
    }

    const config = this.storage.getConfig();
    const normalizedBindHost = normalizeBindHost(config.host);
    if (isLoopbackBindHost(normalizedBindHost)) {
      console.warn(`[bonjour] host=${config.host} is loopback-only; skipping LAN advertisement`);
      return;
    }

    const lanHost = resolveBonjourLanHost(config.host);
    if (!lanHost) {
      console.warn("[bonjour] no LAN IPv4 address detected; skipping LAN advertisement");
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

    console.log("[bonjour] advertising", {
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
      if (s.status !== "stopped" && s.status !== "error") {
        s.status = "stopped";
        this.storage.saveSession(s);
        healed++;
      }
    }
    if (healed > 0) {
      console.log("[startup] healed orphaned sessions", { count: healed });
    }
  }

  // ─── Permission Forwarding ───

  private forwardPermissionRequest(pending: PendingDecision): void {
    this.broadcastToUser(buildPermissionMessage(pending));
    this.liveActivity.queueUpdate({
      sessionId: pending.sessionId,
      lastEvent: "Permission required",
      priority: 10,
    });
    console.log(
      formatPermissionRequestLog({
        requestId: pending.id,
        sessionId: pending.sessionId,
        tool: pending.tool,
        displaySummary: pending.displaySummary,
      }),
    );
  }

  // ─── User Connection Tracking ───

  private broadcastToUser(msg: ServerMessage): void {
    let outbound = msg;
    if (
      msg.sessionId &&
      this.streamMux.isNotificationLevelMessage(msg) &&
      msg.streamSeq === undefined
    ) {
      const streamSeq = this.streamMux.recordUserStreamEvent(msg.sessionId, msg);
      outbound = {
        ...msg,
        streamSeq,
      };
    }

    const conns = this.connections;
    if (!conns || conns.size === 0) {
      this.pushFallback(outbound);
      return;
    }

    const hasOpen = Array.from(conns).some((ws) => ws.readyState === WebSocket.OPEN);
    if (hasOpen) {
      const json = JSON.stringify(outbound);
      for (const ws of conns) {
        if (ws.readyState === WebSocket.OPEN) ws.send(json);
      }
    } else {
      // No WebSocket connected — fall back to push notification
      this.pushFallback(outbound);
    }
  }

  /**
   * Send a push notification when no WebSocket client is connected.
   * Only fires for permission requests and session lifecycle events.
   */
  private pushFallback(msg: ServerMessage): void {
    const tokens = this.storage.getPushDeviceTokens();
    if (tokens.length === 0) return;

    if (msg.type === "permission_request") {
      const session = this.findSessionById(msg.sessionId);
      for (const token of tokens) {
        this.push
          .sendPermissionPush(token, {
            permissionId: msg.id,
            sessionId: msg.sessionId,
            sessionName: session?.name,
            tool: msg.tool,
            displaySummary: msg.displaySummary,
            reason: msg.reason,
            timeoutAt: msg.timeoutAt,
            expires: msg.expires,
          })
          .then((ok) => {
            if (!ok) {
              // Token might be expired — don't remove yet, APNs 410 handler does that
            }
          });
      }
    } else if (msg.type === "session_ended") {
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
    const conns = this.connections;
    conns.add(ws);
  }

  private untrackConnection(ws: WebSocket): void {
    this.connections.delete(ws);
  }

  private async ensureSkillsInitialized(): Promise<void> {
    if (this.skillsInitialized) return;

    await this.skillRegistry.resolvePackageSkills();
    this.skillRegistry.scan();
    this.skillRegistry.watch();
    this.skillsInitialized = true;
  }

  /**
   * Resolve workspace skill names to host directory paths.
   * Checks both built-in skills (SkillRegistry) and user skills (UserSkillStore).
   */
  private async resolveSkillPaths(skillNames: string[]): Promise<string[]> {
    await this.ensureSkillsInitialized();
    const paths: string[] = [];
    for (const name of skillNames) {
      const builtInPath = this.skillRegistry.getPath(name);
      if (builtInPath) {
        paths.push(builtInPath);
        continue;
      }
      const userPath = this.userSkillStore.getPath(name);
      if (userPath) {
        paths.push(userPath);
        continue;
      }
      console.warn(`[skills] Workspace skill not found: "${name}"`);
    }
    return paths;
  }

  private findSessionById(sessionId: string): Session | undefined {
    if (!this.storage.isPaired()) return undefined;

    const sessions = this.storage.listSessions();
    const match = sessions.find((s) => s.id === sessionId);
    return match ? this.models.ensureSessionContextWindow(match) : undefined;
  }

  // ─── Auth ───

  private authenticate(req: IncomingMessage, url?: URL): boolean {
    // Bearer header (primary auth)
    const auth = req.headers.authorization;
    if (auth?.startsWith("Bearer ")) {
      if (this.matchToken(auth.slice(7))) return true;
    }

    // Query-param token — for browser-loadable content
    if (url) {
      const queryToken = url.searchParams.get("token");
      if (queryToken && this.matchToken(queryToken)) return true;
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
    const url = new URL(req.url || "/", `${this.transportScheme}://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method || "GET";

    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.setHeader("X-Oppi-Protocol", "2");

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
        console.error("HTTP error:", err);
        this.error(res, 500, message);
      }
      return;
    }

    const authenticated = this.authenticate(req, url);
    if (!authenticated) {
      console.log(
        formatUnauthorizedAuthLog({
          transport: "http",
          method,
          path,
          authorization: req.headers.authorization,
        }),
      );
      this.error(res, 401, "Unauthorized");
      return;
    }

    await this.ensureSkillsInitialized();

    try {
      await this.routes.dispatch(method, path, url, req, res);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal error";
      console.error("HTTP error:", err);
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
      console.log(
        formatUnauthorizedAuthLog({
          transport: "ws",
          path: url.pathname,
          authorization: req.headers.authorization,
        }),
      );
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }

    if (url.pathname === "/stream") {
      const upgradeReceivedAt = Date.now();
      this.wss.handleUpgrade(req, socket, head, (ws) => {
        this.streamMux.handleWebSocket(ws, upgradeReceivedAt);
      });
      return;
    }

    // Per-session WS endpoint removed — use /stream with subscribe instead.
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
  }
}
