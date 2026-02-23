/**
 * HTTP + WebSocket server.
 *
 * Bridges phone clients to locally running pi sessions.
 * Handles: auth, session CRUD, WebSocket streaming, permission gate
 * forwarding, and extension UI request relay.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { BlockList, isIP, type Socket } from "node:net";
import { type Duplex } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";

import { execFileSync } from "node:child_process";
import { timingSafeEqual } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager, type SessionBroadcastEvent } from "./sessions.js";
import { UserStreamMux } from "./stream.js";
import { RouteHandler } from "./routes/index.js";
import { ModelCatalog } from "./model-catalog.js";
import { LiveActivityBridge } from "./live-activity.js";
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

export function normalizeRemoteAddress(
  remoteAddress: string | undefined,
): { ip: string; family: "ipv4" | "ipv6" } | null {
  if (!remoteAddress) return null;

  const trimmed = remoteAddress.trim();
  if (!trimmed) return null;

  // IPv4-mapped IPv6 (::ffff:192.168.1.10)
  if (trimmed.toLowerCase().startsWith("::ffff:")) {
    const mapped = trimmed.slice(7);
    if (isIP(mapped) === 4) {
      return { ip: mapped, family: "ipv4" };
    }
  }

  const family = isIP(trimmed);
  if (family === 4) return { ip: trimmed, family: "ipv4" };
  if (family === 6) return { ip: trimmed, family: "ipv6" };
  return null;
}

export function buildClientAllowlist(cidrs: string[] | undefined): BlockList | null {
  if (!cidrs || cidrs.length === 0) return null;

  const list = new BlockList();
  for (const cidr of cidrs) {
    const [rawBase, rawPrefix] = cidr.split("/");
    const base = rawBase?.trim();
    const prefix = Number(rawPrefix);
    if (!base || !Number.isInteger(prefix)) continue;

    const family = isIP(base);
    if (family === 4) {
      list.addSubnet(base, prefix, "ipv4");
    } else if (family === 6) {
      list.addSubnet(base, prefix, "ipv6");
    }
  }
  return list;
}

export function isClientAllowed(
  remoteAddress: string | undefined,
  allowlist: BlockList | null,
): boolean {
  if (!allowlist) return true;
  const normalized = normalizeRemoteAddress(remoteAddress);
  if (!normalized) return false;
  return allowlist.check(normalized.ip, normalized.family);
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

  if (wildcardBind) {
    warnings.push(
      `host=${config.host} listens on all interfaces; ensure access is constrained by firewall rules.`,
    );
  }

  if (config.allowedCidrs.some((cidr) => cidr === "0.0.0.0/0" || cidr === "::/0")) {
    warnings.push(
      "allowedCidrs contains a global range (0.0.0.0/0 or ::/0); this permits connections from any source network.",
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

  private storage: Storage;
  private sessions: SessionManager;
  private policy: PolicyEngine;
  private gate: GateServer;
  private skillRegistry: SkillRegistry;
  private skillsInitialized = false;
  private userSkillStore: UserSkillStore;
  private push: PushClient;
  private httpServer: ReturnType<typeof createServer>;
  private wss: WebSocketServer;

  private readonly piExecutable: string;
  private modelRegistry: ModelRegistry;
  private models: ModelCatalog;

  // Track WebSocket connections per user for permission/UI forwarding
  private connections: Set<WebSocket> = new Set();

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
    this.models = new ModelCatalog(this.modelRegistry, this.storage);

    const dataDir = storage.getDataDir();
    const config = storage.getConfig();
    const configuredPolicy = config.policy || defaultPolicy();

    // Runtime policy engine only handles fallback + heuristics.
    // Allow/ask/deny rules live in RuleStore (single runtime source of truth).
    this.policy = new PolicyEngine(policyRuntimeConfig(configuredPolicy));

    // v2 policy infrastructure
    const rulesPath = join(dataDir, "rules.json");
    const ruleStore = new RuleStore(rulesPath);
    ruleStore.seedIfEmpty(policyRulesFromDeclarativeConfig(configuredPolicy));

    // Protect the rules file from silent agent modification.
    // This is a hard-coded guard — it can't be overridden by rules in the store.
    this.policy.setProtectedPaths([rulesPath]);
    const auditLog = new AuditLog(join(dataDir, "audit.jsonl"));

    this.gate = new GateServer(this.policy, ruleStore, auditLog, {
      approvalTimeoutMs: config.approvalTimeoutMs,
    });
    this.skillRegistry = new SkillRegistry();
    this.userSkillStore = new UserSkillStore();
    this.userSkillStore.init();

    this.push = createPushClient(apnsConfig);
    this.liveActivity = new LiveActivityBridge(this.push, this.storage, this.gate);
    this.sessions = new SessionManager(storage, this.gate);
    this.sessions.contextWindowResolver = (modelId: string) =>
      this.models.getContextWindow(modelId);
    this.sessions.skillPathResolver = (names: string[]) => this.resolveSkillPaths(names);

    this.wsMessageHandler = new WsMessageHandler({
      sessions: this.sessions,
      gate: this.gate,
      ensureSessionContextWindow: (targetSession) =>
        this.models.ensureSessionContextWindow(targetSession),
    });

    // Create the user stream mux (handles /stream WS, event rings, replay)
    this.streamMux = new UserStreamMux({
      storage: this.storage,
      sessions: this.sessions,
      gate: this.gate,
      ensureSessionContextWindow: (session) => this.models.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (session) => this.resolveWorkspaceForSession(session),
      handleClientMessage: (session, msg, send) =>
        this.wsMessageHandler.handleClientMessage(session, msg, send),
      trackConnection: (ws) => this.trackConnection(ws),
      untrackConnection: (ws) => this.untrackConnection(ws),
    });

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
      isValidMemoryNamespace: (ns) => this.isValidMemoryNamespace(ns),
      refreshModelCatalog: () => {
        this.models.refresh();
        return Promise.resolve();
      },
      getModelCatalog: () => this.models.getAll(),
      serverStartedAt: Date.now(),
      serverVersion: Server.VERSION,
      piVersion: Server.detectPiVersion(this.piExecutable),
    });

    this.httpServer = createServer((req, res) => this.handleHttp(req, res));
    this.wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

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

    const securityWarnings = formatStartupSecurityWarnings(config);
    for (const warning of securityWarnings) {
      console.warn(`[startup][security] ${warning}`);
    }

    return new Promise((resolve, reject) => {
      this.httpServer.once("error", reject);
      this.httpServer.listen(config.port, config.host, () => {
        this.httpServer.removeListener("error", reject);
        console.log(`🚀 oppi listening on ${config.host}:${this.port}`);
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

  async stop(): Promise<void> {
    this.skillRegistry.stopWatching();
    await this.sessions.stopAll();
    await this.gate.shutdown();
    this.liveActivity.shutdown();
    this.push.shutdown();
    this.wss.close();
    this.httpServer.close();
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
        if (ws.readyState === WebSocket.OPEN) ws.send(json, { compress: false });
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

  private ensureSkillsInitialized(): void {
    if (this.skillsInitialized) return;

    this.skillRegistry.scan();
    this.skillRegistry.watch();
    this.skillsInitialized = true;
  }

  /**
   * Resolve workspace skill names to host directory paths.
   * Checks both built-in skills (SkillRegistry) and user skills (UserSkillStore).
   */
  private resolveSkillPaths(skillNames: string[]): string[] {
    this.ensureSkillsInitialized();
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

  private isValidMemoryNamespace(namespace: string): boolean {
    return /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/.test(namespace);
  }

  // ─── Auth ───

  private authenticate(req: IncomingMessage): boolean {
    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return false;

    const token = auth.slice(7);

    // Check main server token
    const configToken = this.storage.getToken();
    if (configToken && secureTokenEquals(configToken, token)) return true;

    // Check auth device tokens (issued during pairing)
    for (const dt of this.storage.getAuthDeviceTokens()) {
      if (secureTokenEquals(dt, token)) return true;
    }

    return false;
  }

  private isSourceAllowed(remoteAddress: string | undefined): boolean {
    const allowedCidrs = this.storage.getConfig().allowedCidrs;
    const allowlist = buildClientAllowlist(allowedCidrs);
    return isClientAllowed(remoteAddress, allowlist);
  }

  // ─── HTTP Router ───

  private async handleHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method || "GET";

    if (!this.isSourceAllowed(req.socket.remoteAddress)) {
      console.log(
        `${ts()} [auth] 403 ${method} ${path} — source ip not in allowedCidrs (${req.socket.remoteAddress ?? "unknown"})`,
      );
      this.error(res, 403, "Forbidden");
      return;
    }

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

    const authenticated = this.authenticate(req);
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

    this.ensureSkillsInitialized();

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

    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    if (!this.isSourceAllowed((socket as Socket).remoteAddress)) {
      console.log(
        `${ts()} [auth] 403 WS upgrade ${url.pathname} — source ip not in allowedCidrs (${(socket as Socket).remoteAddress ?? "unknown"})`,
      );
      socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      socket.destroy();
      return;
    }

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
      this.wss.handleUpgrade(req, socket, head, (ws) => {
        this.streamMux.handleWebSocket(ws);
      });
      return;
    }

    // Per-session WS endpoint removed — use /stream with subscribe instead.
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
  }
}
