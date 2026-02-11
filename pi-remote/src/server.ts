/**
 * HTTP + WebSocket server.
 *
 * Bridges phone clients to pi sessions running in sandboxed containers.
 * Handles: auth, session CRUD, WebSocket streaming, permission gate
 * forwarding, and extension UI request relay.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { type Socket } from "node:net";
import { type Duplex } from "node:stream";
import { existsSync } from "node:fs";
import { join } from "node:path";

import { execFileSync, execSync } from "node:child_process";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager, type SessionBroadcastEvent } from "./sessions.js";
import { UserStreamMux } from "./stream.js";
import { RouteHandler, type ModelInfo } from "./routes.js";
import { PolicyEngine } from "./policy.js";
import { GateServer, type PendingDecision } from "./gate.js";
import { RuleStore } from "./rules.js";
import { AuditLog } from "./audit.js";
import { SandboxManager } from "./sandbox.js";
import { WorkspaceRuntimeError } from "./workspace-runtime.js";
import { SkillRegistry, UserSkillStore } from "./skills.js";

import { createPushClient, type PushClient, type APNsConfig } from "./push.js";
import { AuthProxy } from "./auth-proxy.js";

import type {
  User,
  Session,
  Workspace,
  ClientMessage,
  ServerMessage,
  ApiError,
  ServerConfig,
} from "./types.js";

// ─── Logging ───

/** Compact HH:MM:SS.mmm timestamp for log lines. */
function ts(): string {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
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
  userId: string;
  sessionId: string;
  tool: string;
  risk: string;
  displaySummary: string;
}): string {
  return `${ts()} [gate] Permission request ${opts.requestId} → ${opts.userId} (session=${opts.sessionId}, tool=${opts.tool}, risk=${opts.risk}, summaryChars=${opts.displaySummary.length})`;
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

/**
 * Startup-only warnings for insecure server bind + transport posture.
 *
 * These warnings are intentionally advisory (non-blocking) so operators can
 * run permissive local/dev setups while still seeing risk posture at boot.
 */
export function formatStartupSecurityWarnings(config: ServerConfig): string[] {
  const warnings: string[] = [];
  const security = config.security;
  const identity = config.identity;
  const invite = config.invite;
  const host = normalizeBindHost(config.host);
  const loopbackOnly = isLoopbackBindHost(host);
  const wildcardBind = isWildcardBindHost(host);

  if (wildcardBind) {
    warnings.push(
      `host=${config.host} listens on all interfaces; ensure access is constrained by tailnet ACLs/firewall rules.`,
    );
  }

  if (!loopbackOnly && security && !security.requireTlsOutsideTailnet) {
    warnings.push(
      "security.requireTlsOutsideTailnet=false while binding beyond loopback; public-network clients can fall back to cleartext HTTP/WS.",
    );
  }

  if (security?.profile === "legacy") {
    warnings.push(
      "security.profile=legacy keeps compatibility transport posture; prefer tailscale-permissive or strict.",
    );
  }

  if (security && !security.requirePinnedServerIdentity) {
    warnings.push(
      "security.requirePinnedServerIdentity=false disables pinned identity mismatch enforcement on clients.",
    );
  }

  if (identity && !identity.enabled) {
    warnings.push(
      "identity.enabled=false disables signed bootstrap trust metadata and weakens fake-server resistance.",
    );
  }

  if (invite && invite.maxAgeSeconds > 3600) {
    warnings.push(
      `invite.maxAgeSeconds=${invite.maxAgeSeconds} increases replay window; prefer short-lived invites (<=600s).`,
    );
  }

  return warnings;
}

type LiveActivityStatus = "busy" | "stopping" | "ready" | "stopped" | "error";

interface LiveActivityContentState {
  status: LiveActivityStatus;
  activeTool: string | null;
  pendingPermissions: number;
  lastEvent: string | null;
  elapsedSeconds: number;
}

interface PendingLiveActivityUpdate {
  sessionId?: string;
  status?: LiveActivityStatus;
  activeTool?: string | null;
  lastEvent?: string | null;
  end?: boolean;
  priority?: 5 | 10;
}

// ─── Available Models ───

const FALLBACK_MODELS: ModelInfo[] = [
  {
    id: "anthropic/claude-opus-4-6",
    name: "claude-opus-4-6",
    provider: "anthropic",
    contextWindow: 200000,
  },
  {
    id: "openai-codex/gpt-5.3-codex",
    name: "gpt-5.3-codex",
    provider: "openai-codex",
    contextWindow: 272000,
  },
  {
    id: "lmstudio/glm-4.7-flash-mlx",
    name: "glm-4.7-flash-mlx",
    provider: "lmstudio",
    contextWindow: 128000,
  },
];

/** Parse compact token counts like 200K, 196.6K, 1M. */
function parseCompactTokenCount(raw: string): number | null {
  const normalized = raw.trim().toLowerCase().replace(/,/g, "");
  const match = normalized.match(/^(\d+(?:\.\d+)?)([km])?$/);
  if (!match) {
    return null;
  }

  const value = Number.parseFloat(match[1]);
  if (!Number.isFinite(value) || value <= 0) {
    return null;
  }

  const suffix = match[2];
  if (suffix === "m") {
    return Math.round(value * 1_000_000);
  }
  if (suffix === "k") {
    return Math.round(value * 1_000);
  }
  return Math.round(value);
}

/** Parse `pi --list-models` table output into model records. */
function parseModelTable(output: string): ModelInfo[] {
  const models: ModelInfo[] = [];
  const seen = new Set<string>();

  for (const line of output.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("provider")) {
      continue;
    }

    const cols = trimmed
      .split(/\s{2,}/)
      .map((v) => v.trim())
      .filter(Boolean);
    if (cols.length < 3) {
      continue;
    }

    const provider = cols[0];
    const modelId = cols[1];
    const contextRaw = cols[2];

    if (!/^[a-z0-9][a-z0-9_-]*$/i.test(provider)) {
      continue;
    }

    const id = `${provider}/${modelId}`;

    if (seen.has(id)) {
      continue;
    }
    seen.add(id);

    models.push({
      id,
      name: modelId,
      provider,
      contextWindow: parseCompactTokenCount(contextRaw) ?? 200000,
    });
  }

  return models;
}

/** Resolve the pi executable path for host-side model discovery. */
function resolvePiExecutable(): string {
  const envPath = process.env.PI_REMOTE_PI_BIN;
  if (envPath && existsSync(envPath)) {
    return envPath;
  }

  try {
    const discovered = execSync("which pi", {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (discovered.length > 0) {
      return discovered;
    }
  } catch {
    // Fall through to known locations
  }

  for (const candidate of ["/opt/homebrew/bin/pi", "/usr/local/bin/pi"]) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  return "pi";
}

export class Server {
  private storage: Storage;
  private sessions: SessionManager;
  private policy: PolicyEngine;
  private gate: GateServer;
  private sandbox: SandboxManager;
  private skillRegistry: SkillRegistry;
  private userSkillStore: UserSkillStore;
  private authProxy: AuthProxy;
  private push: PushClient;
  private httpServer: ReturnType<typeof createServer>;
  private wss: WebSocketServer;

  private readonly piExecutable: string;
  private modelCatalog: ModelInfo[] = [...FALLBACK_MODELS];
  private modelCatalogUpdatedAt = 0;
  private modelCatalogRefresh: Promise<void> | null = null;
  private readonly modelCatalogTtlMs = 30_000;

  // Track WebSocket connections per user for permission/UI forwarding
  private userConnections: Map<string, Set<WebSocket>> = new Map();

  // Live Activity push coalescing (one pending update per user, flushed with debounce).
  private liveActivityTimers: Map<string, NodeJS.Timeout> = new Map();
  private liveActivityPending: Map<string, PendingLiveActivityUpdate> = new Map();
  private readonly liveActivityDebounceMs = 750;

  // User-wide stream multiplexer (event ring, subscriptions, /stream WS)
  private streamMux!: UserStreamMux;
  // REST route handler (dispatch + all HTTP handlers)
  private routes!: RouteHandler;

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;
    this.piExecutable = resolvePiExecutable();

    const dataDir = storage.getDataDir();
    const config = storage.getConfig();
    this.policy = new PolicyEngine("host"); // Default host policy (developer trust). Per-session overrides via gate.setSessionPolicy().

    // v2 policy infrastructure
    const ruleStore = new RuleStore(join(dataDir, "rules.json"));
    const auditLog = new AuditLog(join(dataDir, "audit.jsonl"));

    this.gate = new GateServer(this.policy, ruleStore, auditLog, {
      approvalTimeoutMs: config.approvalTimeoutMs,
    });
    this.authProxy = new AuthProxy();
    this.sandbox = new SandboxManager({
      legacyExtensionsEnabled: config.legacyExtensionsEnabled !== false,
    });
    this.skillRegistry = new SkillRegistry();
    this.userSkillStore = new UserSkillStore();
    this.userSkillStore.init();
    this.skillRegistry.scan();
    this.sandbox.setSkillRegistry(this.skillRegistry);
    this.sandbox.setAuthProxy(this.authProxy);
    this.push = createPushClient(apnsConfig);
    this.sessions = new SessionManager(storage, this.gate, this.sandbox, this.authProxy);
    this.sessions.contextWindowResolver = (modelId: string) => this.getContextWindow(modelId);

    // Create the user stream mux (handles /stream WS, event rings, replay)
    this.streamMux = new UserStreamMux({
      storage: this.storage,
      sessions: this.sessions,
      gate: this.gate,
      ensureSessionContextWindow: (session) => this.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (userId, session) =>
        this.resolveWorkspaceForSession(userId, session),
      handleClientMessage: (user, session, msg, send) =>
        this.handleClientMessage(user, session, msg, send),
      trackConnection: (userId, ws) => this.trackConnection(userId, ws),
      untrackConnection: (userId, ws) => this.untrackConnection(userId, ws),
    });

    this.sessions.on("session_event", (payload: SessionBroadcastEvent) => {
      this.handleLiveActivitySessionEvent(payload);

      if (!this.streamMux.isNotificationLevelMessage(payload.event)) {
        return;
      }

      const streamSeq = this.streamMux.recordUserStreamEvent(
        payload.userId,
        payload.sessionId,
        payload.event,
      );

      payload.event.streamSeq = streamSeq;
      payload.event.sessionId = payload.event.sessionId ?? payload.sessionId;
    });

    // Create route handler (dispatch + all HTTP business logic)
    this.routes = new RouteHandler({
      storage: this.storage,
      sessions: this.sessions,
      gate: this.gate,
      sandbox: this.sandbox,
      skillRegistry: this.skillRegistry,
      userSkillStore: this.userSkillStore,
      streamMux: this.streamMux,
      ensureSessionContextWindow: (session) => this.ensureSessionContextWindow(session),
      resolveWorkspaceForSession: (userId, session) =>
        this.resolveWorkspaceForSession(userId, session),
      isValidMemoryNamespace: (ns) => this.isValidMemoryNamespace(ns),
      refreshModelCatalog: () => this.refreshModelCatalog(),
      getModelCatalog: () => this.modelCatalog,
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
          this.broadcastToUser(session.userId, {
            type: "permission_expired",
            id: requestId,
            reason: "Approval timeout",
            sessionId,
          });
          this.queueLiveActivityUpdate(session.userId, {
            sessionId,
            lastEvent: "Permission expired",
            priority: 5,
          });
        }
      },
    );

    this.gate.on(
      "approval_resolved",
      ({ sessionId, userId, action }: { sessionId: string; userId: string; action: "allow" | "deny" }) => {
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          lastEvent: action === "allow" ? "Permission approved" : "Permission denied",
          priority: action === "deny" ? 10 : 5,
        });
      },
    );
  }

  // ─── Start / Stop ───

  async start(): Promise<void> {
    if (this.storage.hasInvalidOwnerData()) {
      throw new Error(
        "Single-user mode violation: invalid owner data in users.json. Keep exactly one owner object.",
      );
    }

    // Best-effort cleanup from previous crashes before accepting connections.
    await this.sandbox.cleanupOrphanedContainers();

    // Ensure container image and internal network exist
    await this.sandbox.ensureImage();
    this.sandbox.ensureNetwork();

    // Start auth proxy (credential-injecting reverse proxy for containers)
    await this.authProxy.start();

    // Prime model catalog in background so first picker open is fast.
    void this.refreshModelCatalog(true);

    const config = this.storage.getConfig();
    const securityWarnings = formatStartupSecurityWarnings(config);
    for (const warning of securityWarnings) {
      console.warn(`[startup][security] ${warning}`);
    }

    return new Promise((resolve) => {
      this.httpServer.listen(config.port, config.host, () => {
        console.log(`🚀 pi-remote listening on ${config.host}:${config.port}`);
        resolve();
      });
    });
  }

  async stop(): Promise<void> {
    await this.sessions.stopAll();
    await this.sandbox.cleanupOrphanedContainers();
    await this.gate.shutdown();
    await this.authProxy.stop();
    for (const timer of this.liveActivityTimers.values()) {
      clearTimeout(timer);
    }
    this.liveActivityTimers.clear();
    this.liveActivityPending.clear();
    this.push.shutdown();
    this.wss.close();
    this.httpServer.close();
  }

  // ─── Permission Forwarding ───

  private forwardPermissionRequest(pending: PendingDecision): void {
    const msg: ServerMessage = {
      type: "permission_request",
      id: pending.id,
      sessionId: pending.sessionId,
      tool: pending.tool,
      input: pending.input,
      displaySummary: pending.displaySummary,
      risk: pending.risk,
      reason: pending.reason,
      timeoutAt: pending.timeoutAt,
      expires: pending.expires ?? true,
      resolutionOptions: pending.resolutionOptions,
    };

    this.broadcastToUser(pending.userId, msg);
    this.queueLiveActivityUpdate(pending.userId, {
      sessionId: pending.sessionId,
      lastEvent: "Permission required",
      priority: pending.risk === "low" ? 5 : 10,
    });
    console.log(
      formatPermissionRequestLog({
        requestId: pending.id,
        userId: pending.userId,
        sessionId: pending.sessionId,
        tool: pending.tool,
        risk: pending.risk,
        displaySummary: pending.displaySummary,
      }),
    );
  }

  // ─── User Connection Tracking ───

  private broadcastToUser(userId: string, msg: ServerMessage): void {
    let outbound = msg;
    if (
      msg.sessionId &&
      this.streamMux.isNotificationLevelMessage(msg) &&
      msg.streamSeq === undefined
    ) {
      const streamSeq = this.streamMux.recordUserStreamEvent(userId, msg.sessionId, msg);
      outbound = {
        ...msg,
        streamSeq,
      };
    }

    const conns = this.userConnections.get(userId);
    if (!conns || conns.size === 0) {
      this.pushFallback(userId, outbound);
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
      this.pushFallback(userId, outbound);
    }
  }

  /**
   * Send a push notification when no WebSocket client is connected.
   * Only fires for permission requests and session lifecycle events.
   */
  private pushFallback(userId: string, msg: ServerMessage): void {
    const tokens = this.storage.getDeviceTokens(userId);
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
            risk: msg.risk,
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
      const session = this.findSessionByReason(userId, msg);
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

  private handleLiveActivitySessionEvent(payload: SessionBroadcastEvent): void {
    const { event, userId, sessionId } = payload;

    switch (event.type) {
      case "state":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: this.mapSessionStatusToLiveActivity(event.session.status),
          lastEvent: this.sessionStatusLabel(event.session.status),
          priority: 5,
        });
        return;
      case "agent_start":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "busy",
          lastEvent: "Agent started",
          priority: 5,
        });
        return;
      case "agent_end":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "ready",
          activeTool: null,
          lastEvent: "Agent finished",
          priority: 5,
        });
        return;
      case "tool_start":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "busy",
          activeTool: event.tool,
          lastEvent: event.tool,
          priority: 5,
        });
        return;
      case "tool_end":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          activeTool: null,
          priority: 5,
        });
        return;
      case "stop_requested":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "stopping",
          lastEvent: "Stopping",
          priority: 5,
        });
        return;
      case "stop_confirmed":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "ready",
          activeTool: null,
          lastEvent: "Stop confirmed",
          priority: 5,
        });
        return;
      case "stop_failed":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "error",
          lastEvent: "Stop failed",
          priority: 10,
        });
        return;
      case "permission_request":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          lastEvent: "Permission required",
          priority: 10,
        });
        return;
      case "permission_expired":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          lastEvent: "Permission expired",
          priority: 5,
        });
        return;
      case "permission_cancelled":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          lastEvent: "Permission resolved",
          priority: 5,
        });
        return;
      case "error":
        if (!event.error.startsWith("Retrying (")) {
          this.queueLiveActivityUpdate(userId, {
            sessionId,
            status: "error",
            lastEvent: "Error",
            priority: 10,
          });
        }
        return;
      case "session_ended":
        this.queueLiveActivityUpdate(userId, {
          sessionId,
          status: "stopped",
          activeTool: null,
          lastEvent: event.reason,
          end: true,
          priority: 5,
        });
        return;
      default:
        return;
    }
  }

  private queueLiveActivityUpdate(userId: string, update: PendingLiveActivityUpdate): void {
    const current = this.liveActivityPending.get(userId) ?? {};
    const merged: PendingLiveActivityUpdate = {
      sessionId: update.sessionId ?? current.sessionId,
      status: update.status ?? current.status,
      activeTool: update.activeTool !== undefined ? update.activeTool : current.activeTool,
      lastEvent: update.lastEvent !== undefined ? update.lastEvent : current.lastEvent,
      end: Boolean(current.end || update.end),
      priority: (Math.max(current.priority ?? 5, update.priority ?? 5) as 5 | 10),
    };

    this.liveActivityPending.set(userId, merged);

    if (this.liveActivityTimers.has(userId)) {
      return;
    }

    const timer = setTimeout(() => this.flushLiveActivityUpdate(userId), this.liveActivityDebounceMs);
    this.liveActivityTimers.set(userId, timer);
  }

  private flushLiveActivityUpdate(userId: string): void {
    const timer = this.liveActivityTimers.get(userId);
    if (timer) {
      clearTimeout(timer);
      this.liveActivityTimers.delete(userId);
    }

    const pending = this.liveActivityPending.get(userId);
    if (!pending) {
      return;
    }
    this.liveActivityPending.delete(userId);

    const token = this.storage.getLiveActivityToken(userId);
    if (!token) {
      return;
    }

    const contentState = this.buildLiveActivityContentState(userId, pending);
    const liveActivityPayload: Record<string, unknown> = { ...contentState };

    if (pending.end) {
      void this.push
        .endLiveActivity(token, liveActivityPayload, undefined, pending.priority ?? 10)
        .then((ok) => {
          if (ok) {
            this.storage.setLiveActivityToken(userId, null);
          }
        });
      return;
    }

    const staleDate = Date.now() + 2 * 60 * 1000;
    void this.push.sendLiveActivityUpdate(token, liveActivityPayload, staleDate, pending.priority ?? 5);
  }

  private buildLiveActivityContentState(
    userId: string,
    pending: PendingLiveActivityUpdate,
  ): LiveActivityContentState {
    const session = pending.sessionId
      ? this.findSessionById(pending.sessionId)
      : this.findPrimarySessionForUser(userId);

    const now = Date.now();
    const elapsedSeconds = session ? Math.max(0, Math.floor((now - session.createdAt) / 1000)) : 0;

    return {
      status: pending.status ?? this.mapSessionStatusToLiveActivity(session?.status),
      activeTool: pending.activeTool ?? null,
      pendingPermissions: this.gate.getPendingForUser(userId).length,
      lastEvent: pending.lastEvent ?? null,
      elapsedSeconds,
    };
  }

  private findPrimarySessionForUser(userId: string): Session | undefined {
    const sessions = this.storage.listUserSessions(userId);
    if (sessions.length === 0) {
      return undefined;
    }

    const score = (status: Session["status"]): number => {
      switch (status) {
        case "busy":
          return 5;
        case "stopping":
          return 4;
        case "ready":
          return 3;
        case "starting":
          return 2;
        case "error":
          return 1;
        case "stopped":
          return 0;
      }
    };

    return sessions
      .slice()
      .sort((a, b) => {
        const priority = score(b.status) - score(a.status);
        if (priority !== 0) {
          return priority;
        }
        return b.lastActivity - a.lastActivity;
      })[0];
  }

  private mapSessionStatusToLiveActivity(status: Session["status"] | undefined): LiveActivityStatus {
    switch (status) {
      case "busy":
        return "busy";
      case "stopping":
        return "stopping";
      case "stopped":
        return "stopped";
      case "error":
        return "error";
      case "ready":
      case "starting":
      default:
        return "ready";
    }
  }

  private sessionStatusLabel(status: Session["status"]): string {
    switch (status) {
      case "busy":
        return "Working";
      case "stopping":
        return "Stopping";
      case "ready":
        return "Ready";
      case "starting":
        return "Starting";
      case "stopped":
        return "Session ended";
      case "error":
        return "Error";
    }
  }

  /**
   * Find session from a session_ended message context.
   * We track which user's sessions are active to find the match.
   */
  private findSessionByReason(userId: string, _msg: ServerMessage): Session | undefined {
    const sessions = this.storage.listUserSessions(userId);
    // Return the most recently active session (best effort)
    return sessions.find((s) => s.status === "stopped") || sessions[0];
  }

  private trackConnection(userId: string, ws: WebSocket): void {
    let conns = this.userConnections.get(userId);
    if (!conns) {
      conns = new Set();
      this.userConnections.set(userId, conns);
    }
    conns.add(ws);
  }

  private untrackConnection(userId: string, ws: WebSocket): void {
    const conns = this.userConnections.get(userId);
    if (conns) {
      conns.delete(ws);
      if (conns.size === 0) this.userConnections.delete(userId);
    }
  }

  private async refreshModelCatalog(force = false): Promise<void> {
    const now = Date.now();
    if (
      !force &&
      this.modelCatalog.length > 0 &&
      now - this.modelCatalogUpdatedAt < this.modelCatalogTtlMs
    ) {
      return;
    }

    if (this.modelCatalogRefresh) {
      await this.modelCatalogRefresh;
      return;
    }

    this.modelCatalogRefresh = (async () => {
      try {
        const output = execFileSync(this.piExecutable, ["--list-models"], {
          encoding: "utf-8",
          stdio: ["ignore", "pipe", "pipe"],
          timeout: 15000,
          maxBuffer: 2 * 1024 * 1024,
        });

        const models = parseModelTable(output);
        if (models.length > 0) {
          this.modelCatalog = models;
          this.modelCatalogUpdatedAt = Date.now();
          return;
        }

        console.warn(`${ts()} [models] parsed 0 models from pi --list-models`);
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.warn(`${ts()} [models] failed to refresh model catalog: ${message}`);
      }

      // Prevent hammering refresh when pi list-models is unavailable.
      if (this.modelCatalogUpdatedAt === 0) {
        this.modelCatalogUpdatedAt = Date.now();
      }
    })().finally(() => {
      this.modelCatalogRefresh = null;
    });

    await this.modelCatalogRefresh;
  }

  private getContextWindow(modelId: string): number {
    const known = this.modelCatalog.find(
      (m) => m.id === modelId || m.id.endsWith(`/${modelId}`),
    )?.contextWindow;
    if (known) {
      return known;
    }

    // Generic model-id fallback, e.g. "...-272k" / "..._128k".
    const match = modelId.match(/(\d{2,4})k\b/i);
    if (match) {
      const thousands = Number.parseInt(match[1], 10);
      if (Number.isFinite(thousands) && thousands > 0) {
        return thousands * 1000;
      }
    }

    return 200000;
  }

  private findSessionById(sessionId: string): Session | undefined {
    const owner = this.storage.getOwnerUser();
    if (!owner) return undefined;

    const sessions = this.storage.listUserSessions(owner.id);
    const match = sessions.find((s) => s.id === sessionId);
    return match ? this.ensureSessionContextWindow(match) : undefined;
  }

  private ensureSessionContextWindow(session: Session): Session {
    let changed = false;

    if (!session.contextWindow || session.contextWindow <= 0) {
      session.contextWindow = this.getContextWindow(session.model || "");
      changed = true;
    }

    if (!session.runtime && session.workspaceId) {
      const workspace = this.storage.getWorkspace(session.userId, session.workspaceId);
      if (workspace?.runtime) {
        session.runtime = workspace.runtime;
        changed = true;
      }
    }

    if (changed) {
      this.storage.saveSession(session);
    }

    return session;
  }

  private isValidMemoryNamespace(namespace: string): boolean {
    return /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/.test(namespace);
  }

  // ─── Auth ───

  private authenticate(req: IncomingMessage): User | null {
    // Fail closed on invalid single-user state.
    if (this.storage.hasInvalidOwnerData()) {
      return null;
    }

    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return null;

    const token = auth.slice(7);
    const owner = this.storage.getOwnerUser();
    if (!owner) return null;
    if (owner.token !== token) return null;

    this.storage.updateUserLastSeen(owner.id);
    return owner;
  }

  // ─── HTTP Router ───

  private async handleHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method || "GET";

    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.setHeader("X-PiRemote-Protocol", "2");

    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }
    if (path === "/health") {
      this.json(res, { ok: true, protocol: 2 });
      return;
    }

    const user = this.authenticate(req);
    if (!user) {
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

    try {
      await this.routes.dispatch(method, path, url, user, req, res);
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

  private resolveWorkspaceForSession(userId: string, session: Session): Workspace | undefined {
    return session.workspaceId ? this.storage.getWorkspace(userId, session.workspaceId) : undefined;
  }

  // ─── WebSocket ───

  private handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    (socket as Socket).setNoDelay?.(true);

    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const user = this.authenticate(req);
    if (!user) {
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
        this.streamMux.handleWebSocket(ws, user);
      });
      return;
    }

    const wsMatch = url.pathname.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/);
    if (!wsMatch) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    const workspaceId = wsMatch[1];
    const sessionId = wsMatch[2];
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      console.log(`${ts()} [ws] 404 session not found: ${sessionId} (user=${user.name})`);
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    if (session.workspaceId !== workspaceId) {
      console.log(
        `${ts()} [ws] 404 session/workspace mismatch: session=${sessionId} requested=${workspaceId} actual=${session.workspaceId ?? "none"} (user=${user.name})`,
      );
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.handleWebSocket(ws, user, session);
    });
  }

  private async handleWebSocket(ws: WebSocket, user: User, session: Session): Promise<void> {
    console.log(`${ts()} [ws] Connected: ${user.name} → ${session.id} (status=${session.status})`);
    this.trackConnection(user.id, ws);

    let msgSent = 0;
    let msgRecv = 0;

    const send = (msg: ServerMessage): void => {
      if (ws.readyState === WebSocket.OPEN) {
        msgSent++;
        ws.send(JSON.stringify(msg), { compress: false });
      } else {
        console.warn(`${ts()} [ws] DROP ${msg.type} → ${session.id} (readyState=${ws.readyState})`);
      }
    };

    // Queue messages received before startSession completes.
    // Without this, the iOS client sends a prompt while pi is still
    // loading and the message is silently dropped — causing a hang.
    let ready = false;
    let hydratedSession: Session = session;
    const messageQueue: ClientMessage[] = [];

    ws.on("message", async (data) => {
      try {
        const msg = JSON.parse(data.toString()) as ClientMessage;
        msgRecv++;
        console.log(
          `${ts()} [ws] RECV ${msg.type} from ${user.name} → ${session.id} (ready=${ready}, queued=${messageQueue.length})`,
        );
        if (ready) {
          await this.handleClientMessage(user, hydratedSession, msg, send);
        } else {
          messageQueue.push(msg);
          console.log(
            `${ts()} [ws] QUEUED ${msg.type} (pi not ready, queue=${messageQueue.length})`,
          );
        }
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : "Unknown error";
        console.error(`${ts()} [ws] MSG ERROR ${session.id}: ${message}`);
        send({ type: "error", error: message });
      }
    });

    let unsubscribe: (() => void) | null = null;

    ws.on("close", (code, reason) => {
      const reasonStr = reason?.toString() || "";
      console.log(
        `${ts()} [ws] Disconnected: ${user.name} → ${session.id} (code=${code}${reasonStr ? ` reason=${reasonStr}` : ""}, sent=${msgSent} recv=${msgRecv})`,
      );
      unsubscribe?.();
      this.untrackConnection(user.id, ws);
    });

    ws.on("error", (err) => {
      console.error(`${ts()} [ws] Error: ${user.name} → ${session.id}:`, err);
      unsubscribe?.();
      this.untrackConnection(user.id, ws);
    });

    try {
      // Send session metadata immediately (from disk) so the iOS client
      // can display the chat history while pi is starting.
      console.log(`${ts()} [ws] SEND connected → ${session.id}`);
      send({
        type: "connected",
        session,
        currentSeq: this.sessions.getCurrentSeq(user.id, session.id),
      });

      // Resolve workspace for this session
      const workspace = this.resolveWorkspaceForSession(user.id, session);

      console.log(
        `${ts()} [ws] Starting pi for ${session.id} (workspace=${workspace?.name ?? "none"}, runtime=${workspace?.runtime ?? "host"})...`,
      );
      const startTime = Date.now();
      const activeSession = await this.sessions.startSession(
        user.id,
        session.id,
        user.name,
        workspace,
      );
      const startMs = Date.now() - startTime;
      hydratedSession = this.ensureSessionContextWindow(activeSession);
      console.log(
        `${ts()} [ws] Pi ready for ${session.id} in ${startMs}ms (status=${hydratedSession.status})`,
      );

      // Send updated session with live pi state (context tokens, etc.)
      send({ type: "state", session: hydratedSession });

      // Send pending permission requests
      const pendingPerms = this.gate.getPendingForUser(user.id);
      if (pendingPerms.length > 0) {
        console.log(
          `${ts()} [ws] Sending ${pendingPerms.length} pending permission(s) → ${session.id}`,
        );
      }
      for (const pending of pendingPerms) {
        send({
          type: "permission_request",
          id: pending.id,
          sessionId: pending.sessionId,
          tool: pending.tool,
          input: pending.input,
          displaySummary: pending.displaySummary,
          risk: pending.risk,
          reason: pending.reason,
          timeoutAt: pending.timeoutAt,
          expires: pending.expires ?? true,
          resolutionOptions: pending.resolutionOptions,
        });
      }

      // Subscribe to session events
      unsubscribe = this.sessions.subscribe(user.id, session.id, send);

      // Drain queued messages (sent while pi was starting)
      ready = true;
      if (messageQueue.length > 0) {
        console.log(
          `${ts()} [ws] Draining ${messageQueue.length} queued message(s) for ${session.id}`,
        );
      }
      for (const msg of messageQueue) {
        console.log(`${ts()} [ws] DRAIN ${msg.type} → ${session.id}`);
        await this.handleClientMessage(user, hydratedSession, msg, send);
      }
      messageQueue.length = 0;
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Setup error";
      console.error(`${ts()} [ws] Setup error for ${session.id}:`, err);

      // WorkspaceRuntimeError is fatal — client should NOT auto-reconnect.
      const isRuntimeError = err instanceof WorkspaceRuntimeError;
      send({
        type: "error",
        error: message,
        code: isRuntimeError ? (err as WorkspaceRuntimeError).code : undefined,
        fatal: isRuntimeError ? true : undefined,
      });
      this.untrackConnection(user.id, ws);
      ws.close();
    }
  }

  private async handleClientMessage(
    user: User,
    session: Session,
    msg: ClientMessage,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    switch (msg.type) {
      case "subscribe":
      case "unsubscribe": {
        send({
          type: "error",
          error: `Stream subscriptions are only supported on /stream (received ${msg.type})`,
        });
        break;
      }

      case "prompt": {
        const timestamp = Date.now();
        const requestId = msg.requestId;
        const promptChars = msg.message.length;
        const imageCount = msg.images?.length ?? 0;
        console.log(
          `${ts()} [ws] PROMPT ${session.id} (chars=${promptChars}${imageCount > 0 ? `, images=${imageCount}` : ""})`,
        );

        // RPC image format: { type: "image", data: "base64...", mimeType: "image/png" }
        const images = msg.images?.map((img) => ({
          type: "image" as const,
          data: img.data,
          mimeType: img.mimeType,
        }));

        try {
          await this.sessions.sendPrompt(user.id, session.id, msg.message, {
            images,
            streamingBehavior: msg.streamingBehavior,
            clientTurnId: msg.clientTurnId,
            requestId,
            timestamp,
          });

          if (requestId) {
            send({ type: "rpc_result", command: "prompt", requestId, success: true });
          }

          console.log(`${ts()} [ws] PROMPT sent to pi for ${session.id}`);
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          if (requestId) {
            send({
              type: "rpc_result",
              command: "prompt",
              requestId,
              success: false,
              error: message,
            });
            return;
          }
          throw err;
        }
        break;
      }

      case "steer": {
        const requestId = msg.requestId;
        const steerChars = msg.message.length;
        const steerImageCount = msg.images?.length ?? 0;
        console.log(
          `${ts()} [ws] STEER ${session.id} (chars=${steerChars}${steerImageCount > 0 ? `, images=${steerImageCount}` : ""})`,
        );
        const steerImages = msg.images?.map((img) => ({
          type: "image" as const,
          data: img.data,
          mimeType: img.mimeType,
        }));

        try {
          await this.sessions.sendSteer(user.id, session.id, msg.message, {
            images: steerImages,
            clientTurnId: msg.clientTurnId,
            requestId,
          });
          if (requestId) {
            send({ type: "rpc_result", command: "steer", requestId, success: true });
          }
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          if (requestId) {
            send({
              type: "rpc_result",
              command: "steer",
              requestId,
              success: false,
              error: message,
            });
            return;
          }
          throw err;
        }
        break;
      }

      case "follow_up": {
        const requestId = msg.requestId;
        const followUpChars = msg.message.length;
        const followUpImageCount = msg.images?.length ?? 0;
        console.log(
          `${ts()} [ws] FOLLOW_UP ${session.id} (chars=${followUpChars}${followUpImageCount > 0 ? `, images=${followUpImageCount}` : ""})`,
        );
        const fuImages = msg.images?.map((img) => ({
          type: "image" as const,
          data: img.data,
          mimeType: img.mimeType,
        }));

        try {
          await this.sessions.sendFollowUp(user.id, session.id, msg.message, {
            images: fuImages,
            clientTurnId: msg.clientTurnId,
            requestId,
          });
          if (requestId) {
            send({ type: "rpc_result", command: "follow_up", requestId, success: true });
          }
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          if (requestId) {
            send({
              type: "rpc_result",
              command: "follow_up",
              requestId,
              success: false,
              error: message,
            });
            return;
          }
          throw err;
        }
        break;
      }

      case "abort":
      case "stop": {
        const requestId = msg.requestId;
        const command = msg.type;
        console.log(`${ts()} [ws] STOP ${session.id}`);
        try {
          await this.sessions.sendAbort(user.id, session.id);
          if (requestId) {
            send({ type: "rpc_result", command, requestId, success: true });
          }
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          if (requestId) {
            send({ type: "rpc_result", command, requestId, success: false, error: message });
            break;
          }
          throw err;
        }
        break;
      }

      case "stop_session": {
        const requestId = msg.requestId;
        console.log(`${ts()} [ws] STOP_SESSION ${session.id}`);
        try {
          await this.sessions.stopSession(user.id, session.id);
          if (requestId) {
            send({ type: "rpc_result", command: "stop_session", requestId, success: true });
          }
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : String(err);
          if (requestId) {
            send({
              type: "rpc_result",
              command: "stop_session",
              requestId,
              success: false,
              error: message,
            });
            break;
          }
          throw err;
        }
        break;
      }

      case "get_state": {
        const active = this.sessions.getActiveSession(user.id, session.id);
        if (active) {
          send({ type: "state", session: this.ensureSessionContextWindow(active) });
        }
        break;
      }

      case "permission_response": {
        const scope = msg.scope || "once";
        const resolved = this.gate.resolveDecision(msg.id, msg.action, scope, msg.expiresInMs);
        if (!resolved) {
          send({ type: "error", error: `Permission request not found: ${msg.id}` });
        }
        break;
      }

      case "extension_ui_response": {
        const ok = this.sessions.respondToUIRequest(user.id, session.id, {
          type: "extension_ui_response",
          id: msg.id,
          value: msg.value,
          confirmed: msg.confirmed,
          cancelled: msg.cancelled,
        });
        if (!ok) {
          send({ type: "error", error: `UI request not found: ${msg.id}` });
        }
        break;
      }

      // ── RPC passthrough — forward to pi and return result ──
      case "get_messages":
      case "get_session_stats":
      case "set_model":
      case "cycle_model":
      case "get_available_models":
      case "set_thinking_level":
      case "cycle_thinking_level":
      case "new_session":
      case "set_session_name":
      case "compact":
      case "set_auto_compaction":
      case "fork":
      case "get_fork_messages":
      case "switch_session":
      case "set_steering_mode":
      case "set_follow_up_mode":
      case "set_auto_retry":
      case "abort_retry":
      case "bash":
      case "abort_bash":
      case "get_commands":
        await this.sessions.forwardRpcCommand(
          user.id,
          session.id,
          msg as unknown as Record<string, unknown>,
          (msg as Record<string, unknown>).requestId as string | undefined,
        );
        break;
    }
  }
}
