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
import { appendFileSync, createReadStream, existsSync, mkdirSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join, resolve, extname } from "node:path";
import { homedir } from "node:os";
import { execFileSync, execSync } from "node:child_process";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager } from "./sessions.js";
import { PolicyEngine } from "./policy.js";
import { GateServer, type PendingDecision } from "./gate.js";
import { RuleStore } from "./rules.js";
import { AuditLog } from "./audit.js";
import { SandboxManager } from "./sandbox.js";
import { WorkspaceRuntimeError } from "./workspace-runtime.js";
import { SkillRegistry, UserSkillStore, SkillValidationError } from "./skills.js";
import {
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  findToolOutput,
} from "./trace.js";
import { createPushClient, type PushClient, type APNsConfig } from "./push.js";
import { AuthProxy } from "./auth-proxy.js";
import { discoverProjects, scanDirectories } from "./host.js";
import type {
  User,
  Session,
  Workspace,
  ClientMessage,
  ServerMessage,
  CreateSessionRequest,
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  RegisterDeviceTokenRequest,
  ClientLogUploadRequest,
  ApiError,
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

// ─── Available Models ───

interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  contextWindow: number;
}

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

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;
    this.piExecutable = resolvePiExecutable();

    const dataDir = storage.getDataDir();
    this.policy = new PolicyEngine("host"); // Default: restrictive. Per-session overrides via gate.setSessionPolicy().

    // v2 policy infrastructure
    const ruleStore = new RuleStore(join(dataDir, "rules.json"));
    const auditLog = new AuditLog(join(dataDir, "audit.jsonl"));

    this.gate = new GateServer(this.policy, ruleStore, auditLog);
    this.authProxy = new AuthProxy();
    this.sandbox = new SandboxManager();
    this.skillRegistry = new SkillRegistry();
    this.userSkillStore = new UserSkillStore();
    this.userSkillStore.init();
    this.skillRegistry.scan();
    this.sandbox.setSkillRegistry(this.skillRegistry);
    this.sandbox.setAuthProxy(this.authProxy);
    this.push = createPushClient(apnsConfig);
    this.sessions = new SessionManager(storage, this.gate, this.sandbox, this.authProxy);
    this.sessions.contextWindowResolver = (modelId: string) => this.getContextWindow(modelId);

    this.httpServer = createServer((req, res) => this.handleHttp(req, res));
    this.wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

    this.httpServer.on("upgrade", (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });

    // Wire gate events → phone WebSocket
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
          });
        }
      },
    );
  }

  // ─── Start / Stop ───

  async start(): Promise<void> {
    // Best-effort cleanup from previous crashes before accepting connections.
    await this.sandbox.cleanupOrphanedContainers();

    // Migrate legacy session-scoped sandboxes to workspace layout.
    const migration = this.sandbox.migrateAllLegacySandboxes();
    if (migration.migrated > 0) {
      console.log(
        `[startup] Migrated ${migration.migrated} legacy sandbox(es) to workspace layout`,
      );
    }
    if (migration.errors.length > 0) {
      for (const err of migration.errors) {
        console.warn(`[startup] Migration warning: ${err}`);
      }
    }

    // Ensure container image and internal network exist
    await this.sandbox.ensureImage();
    this.sandbox.ensureNetwork();

    // Start auth proxy (credential-injecting reverse proxy for containers)
    await this.authProxy.start();

    // Prime model catalog in background so first picker open is fast.
    void this.refreshModelCatalog(true);

    const config = this.storage.getConfig();
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
      resolutionOptions: pending.resolutionOptions,
    };

    this.broadcastToUser(pending.userId, msg);
    console.log(
      `${ts()} [gate] Permission request ${pending.id} → ${pending.userId}: ${pending.displaySummary}`,
    );
  }

  // ─── User Connection Tracking ───

  private broadcastToUser(userId: string, msg: ServerMessage): void {
    const conns = this.userConnections.get(userId);
    if (!conns || conns.size === 0) {
      this.pushFallback(userId, msg);
      return;
    }

    const hasOpen = Array.from(conns).some((ws) => ws.readyState === WebSocket.OPEN);
    if (hasOpen) {
      const json = JSON.stringify(msg);
      for (const ws of conns) {
        if (ws.readyState === WebSocket.OPEN) ws.send(json, { compress: false });
      }
    } else {
      // No WebSocket connected — fall back to push notification
      this.pushFallback(userId, msg);
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
    for (const user of this.storage.listUsers()) {
      const sessions = this.storage.listUserSessions(user.id);
      const match = sessions.find((s) => s.id === sessionId);
      if (match) return this.ensureSessionContextWindow(match);
    }
    return undefined;
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
    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return null;
    const user = this.storage.getUserByToken(auth.slice(7));
    if (user) this.storage.updateUserLastSeen(user.id);
    return user || null;
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
      const auth = req.headers.authorization;
      console.log(
        `${ts()} [auth] 401 ${method} ${path} — token: ${auth ? auth.slice(0, 15) + "…" : "(none)"}`,
      );
      this.error(res, 401, "Unauthorized");
      return;
    }

    try {
      // Static routes
      if (path === "/me" && method === "GET") return this.handleGetMe(user, res);
      if (path === "/models" && method === "GET") return this.handleListModels(res);
      if (path === "/skills" && method === "GET") return this.handleListSkills(res);
      if (path === "/skills/rescan" && method === "POST") return this.handleRescanSkills(res);

      // Skill detail + file access
      const skillFileMatch = path.match(/^\/skills\/([^/]+)\/file$/);
      if (skillFileMatch && method === "GET")
        return this.handleGetSkillFile(skillFileMatch[1], url, res);
      const skillDetailMatch = path.match(/^\/skills\/([^/]+)$/);
      if (skillDetailMatch && method === "GET")
        return this.handleGetSkillDetail(skillDetailMatch[1], res);

      // Host discovery
      if (path === "/host/directories" && method === "GET")
        return this.handleListDirectories(url, res);

      // Workspaces
      if (path === "/workspaces" && method === "GET") return this.handleListWorkspaces(user, res);
      if (path === "/workspaces" && method === "POST")
        return await this.handleCreateWorkspace(user, req, res);

      const wsMatch = path.match(/^\/workspaces\/([^/]+)$/);
      if (wsMatch) {
        if (method === "GET") return this.handleGetWorkspace(user, wsMatch[1], res);
        if (method === "PUT") return await this.handleUpdateWorkspace(user, wsMatch[1], req, res);
        if (method === "DELETE") return this.handleDeleteWorkspace(user, wsMatch[1], res);
      }

      // Device tokens
      if (path === "/me/device-token" && method === "POST")
        return await this.handleRegisterDeviceToken(user, req, res);
      if (path === "/me/device-token" && method === "DELETE")
        return await this.handleDeleteDeviceToken(user, req, res);

      // User skills CRUD
      if (path === "/me/skills" && method === "GET") return this.handleListUserSkills(user, res);
      if (path === "/me/skills" && method === "POST")
        return await this.handleSaveUserSkill(user, req, res);

      const userSkillFileMatch = path.match(/^\/me\/skills\/([^/]+)\/files$/);
      if (userSkillFileMatch && method === "GET")
        return this.handleGetUserSkillFile(user, userSkillFileMatch[1], url, res);

      const userSkillMatch = path.match(/^\/me\/skills\/([^/]+)$/);
      if (userSkillMatch) {
        if (method === "GET") return this.handleGetUserSkill(user, userSkillMatch[1], res);
        if (method === "DELETE") return this.handleDeleteUserSkill(user, userSkillMatch[1], res);
      }

      // ── Workspace-scoped session routes (v2 API) ──

      const wsSessionsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions$/);
      if (wsSessionsMatch) {
        if (method === "GET")
          return this.handleListWorkspaceSessions(user, wsSessionsMatch[1], res);
        if (method === "POST")
          return await this.handleCreateWorkspaceSession(user, wsSessionsMatch[1], req, res);
      }

      const wsSessionStopMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/);
      if (wsSessionStopMatch && method === "POST") {
        return await this.handleStopSession(user, wsSessionStopMatch[2], res);
      }

      const wsSessionClientLogsMatch = path.match(
        /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/client-logs$/,
      );
      if (wsSessionClientLogsMatch && method === "POST") {
        return await this.handleUploadClientLogs(user, wsSessionClientLogsMatch[2], req, res);
      }

      const wsSessionResumeMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/);
      if (wsSessionResumeMatch && method === "POST") {
        return await this.handleResumeWorkspaceSession(
          user,
          wsSessionResumeMatch[1],
          wsSessionResumeMatch[2],
          res,
        );
      }

      const wsSessionToolOutputMatch = path.match(
        /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
      );
      if (wsSessionToolOutputMatch && method === "GET") {
        return this.handleGetToolOutput(
          user,
          wsSessionToolOutputMatch[2],
          wsSessionToolOutputMatch[3],
          res,
        );
      }

      const wsSessionFilesMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/files$/);
      if (wsSessionFilesMatch && method === "GET") {
        return this.handleGetSessionFile(user, wsSessionFilesMatch[2], url, res);
      }

      const wsSessionEventsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/);
      if (wsSessionEventsMatch && method === "GET") {
        return this.handleGetSessionEvents(user, wsSessionEventsMatch[2], url, res);
      }

      const wsSessionMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/);
      if (wsSessionMatch) {
        if (method === "GET") return await this.handleGetSession(user, wsSessionMatch[2], res);
        if (method === "DELETE")
          return await this.handleDeleteSession(user, wsSessionMatch[2], res);
      }

      // WebSocket stream via workspace path
      // (handled in handleUpgrade, matched below for 404 clarity)

      // ── Global session routes (permanent — workspace-agnostic) ──
      // These serve cross-workspace views (session list, tool output, file access).
      // No deprecation — they complement the workspace-scoped routes.

      if (path === "/sessions" && method === "GET") return this.handleListSessions(user, res);
      if (path === "/sessions" && method === "POST")
        return await this.handleCreateSession(user, req, res);

      const stopMatch = path.match(/^\/sessions\/([^/]+)\/stop$/);
      if (stopMatch && method === "POST")
        return await this.handleStopSession(user, stopMatch[1], res);

      const toolOutputMatch = path.match(/^\/sessions\/([^/]+)\/tool-output\/([^/]+)$/);
      if (toolOutputMatch && method === "GET") {
        return this.handleGetToolOutput(user, toolOutputMatch[1], toolOutputMatch[2], res);
      }

      const filesMatch = path.match(/^\/sessions\/([^/]+)\/files$/);
      if (filesMatch && method === "GET") {
        return this.handleGetSessionFile(user, filesMatch[1], url, res);
      }

      const eventsMatch = path.match(/^\/sessions\/([^/]+)\/events$/);
      if (eventsMatch && method === "GET") {
        return this.handleGetSessionEvents(user, eventsMatch[1], url, res);
      }

      const clientLogsMatch = path.match(/^\/sessions\/([^/]+)\/client-logs$/);
      if (clientLogsMatch && method === "POST") {
        return await this.handleUploadClientLogs(user, clientLogsMatch[1], req, res);
      }

      const sessionMatch = path.match(/^\/sessions\/([^/]+)$/);
      if (sessionMatch) {
        if (method === "GET") return await this.handleGetSession(user, sessionMatch[1], res);
        if (method === "DELETE") return await this.handleDeleteSession(user, sessionMatch[1], res);
      }

      this.error(res, 404, "Not found");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Internal error";
      console.error("HTTP error:", err);
      this.error(res, 500, message);
    }
  }

  // ─── Route Handlers ───

  private handleGetMe(user: User, res: ServerResponse): void {
    this.json(res, { user: user.id, name: user.name });
  }

  private async handleListModels(res: ServerResponse): Promise<void> {
    await this.refreshModelCatalog();
    this.json(res, { models: this.modelCatalog });
  }

  private handleListSkills(res: ServerResponse): void {
    this.json(res, { skills: this.skillRegistry.list() });
  }

  private handleRescanSkills(res: ServerResponse): void {
    this.skillRegistry.scan();
    this.json(res, { skills: this.skillRegistry.list() });
  }

  private handleGetSkillDetail(name: string, res: ServerResponse): void {
    const detail = this.skillRegistry.getDetail(name);
    if (!detail) {
      this.error(res, 404, "Skill not found");
      return;
    }
    this.json(res, detail as unknown as Record<string, unknown>);
  }

  private handleGetSkillFile(name: string, url: URL, res: ServerResponse): void {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const content = this.skillRegistry.getFileContent(name, filePath);
    if (content === undefined) {
      this.error(res, 404, "File not found");
      return;
    }
    this.json(res, { content });
  }

  // ─── User Skills CRUD ───

  private handleListUserSkills(user: User, res: ServerResponse): void {
    const builtIn = this.skillRegistry.list().map((s) => ({
      ...s,
      builtIn: true as const,
    }));
    const userSkills = this.userSkillStore.listSkills(user.id);
    this.json(res, { skills: [...builtIn, ...userSkills] });
  }

  private handleGetUserSkill(user: User, name: string, res: ServerResponse): void {
    // Check user skills first, then built-in
    const userSkill = this.userSkillStore.getSkill(user.id, name);
    if (userSkill) {
      const files = this.userSkillStore.listFiles(user.id, name);
      this.json(res, { skill: userSkill, files });
      return;
    }

    const builtIn = this.skillRegistry.getDetail(name);
    if (builtIn) {
      this.json(res, {
        skill: { ...builtIn.skill, builtIn: true },
        files: builtIn.files,
        content: builtIn.content,
      });
      return;
    }

    this.error(res, 404, "Skill not found");
  }

  private async handleSaveUserSkill(
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<{ name: string; sessionId: string; path?: string }>(req);

    if (!body.name) {
      this.error(res, 400, "name required");
      return;
    }
    if (!body.sessionId) {
      this.error(res, 400, "sessionId required");
      return;
    }

    // Verify session ownership
    const session = this.storage.getSession(user.id, body.sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    // Resolve source directory in session workspace
    const workRoot = this.resolveWorkRoot(session, user.id);
    if (!workRoot) {
      this.error(res, 404, "No workspace root for session");
      return;
    }

    // Source is either explicit path or /work/<name>/
    const relPath = body.path ?? body.name;
    const sourceDir = resolve(workRoot, relPath);

    // Path safety — must be within workspace
    let resolvedSource: string;
    try {
      resolvedSource = realpathSync(sourceDir);
    } catch {
      this.error(res, 404, "Source directory not found");
      return;
    }

    const realWorkRoot = realpathSync(workRoot);
    if (!resolvedSource.startsWith(realWorkRoot + "/") && resolvedSource !== realWorkRoot) {
      this.error(res, 403, "Path outside workspace");
      return;
    }

    try {
      const skill = this.userSkillStore.saveSkill(user.id, body.name, resolvedSource);

      // Re-register in the skill registry so workspace configs can reference it
      this.skillRegistry.registerUserSkills([skill]);

      this.json(res, { skill }, 201);
    } catch (err) {
      if (err instanceof SkillValidationError) {
        this.error(res, 400, err.message);
        return;
      }
      throw err;
    }
  }

  private handleDeleteUserSkill(user: User, name: string, res: ServerResponse): void {
    // Don't allow deleting built-in skills
    const builtIn = this.skillRegistry.get(name);
    const userSkill = this.userSkillStore.getSkill(user.id, name);

    if (!userSkill) {
      if (builtIn) {
        this.error(res, 403, "Cannot delete built-in skill");
        return;
      }
      this.error(res, 404, "Skill not found");
      return;
    }

    this.userSkillStore.deleteSkill(user.id, name);
    res.writeHead(204).end();
  }

  private handleGetUserSkillFile(user: User, name: string, url: URL, res: ServerResponse): void {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    // Try user skill first, then built-in
    const content =
      this.userSkillStore.readFile(user.id, name, filePath) ??
      this.skillRegistry.getFileContent(name, filePath);

    if (content === undefined) {
      this.error(res, 404, "File not found");
      return;
    }
    this.json(res, { content });
  }

  private handleListDirectories(url: URL, res: ServerResponse): void {
    const root = url.searchParams.get("root");
    const dirs = root ? scanDirectories(root) : discoverProjects();
    this.json(res, { directories: dirs });
  }

  private handleListWorkspaces(user: User, res: ServerResponse): void {
    this.storage.ensureDefaultWorkspaces(user.id);
    const workspaces = this.storage.listWorkspaces(user.id);
    this.json(res, { workspaces });
  }

  private async handleCreateWorkspace(
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<CreateWorkspaceRequest>(req);
    if (!body.name) {
      this.error(res, 400, "name required");
      return;
    }
    if (!body.skills || !Array.isArray(body.skills)) {
      this.error(res, 400, "skills array required");
      return;
    }

    const unknown = body.skills.filter((s) => !this.skillRegistry.get(s));
    if (unknown.length > 0) {
      this.error(res, 400, `Unknown skills: ${unknown.join(", ")}`);
      return;
    }

    if (body.memoryNamespace && !this.isValidMemoryNamespace(body.memoryNamespace)) {
      this.error(res, 400, "memoryNamespace must match [a-zA-Z0-9][a-zA-Z0-9._-]{0,63}");
      return;
    }

    const workspace = this.storage.createWorkspace(user.id, body);
    this.json(res, { workspace }, 201);
  }

  private handleGetWorkspace(user: User, wsId: string, res: ServerResponse): void {
    const workspace = this.storage.getWorkspace(user.id, wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }
    this.json(res, { workspace });
  }

  private async handleUpdateWorkspace(
    user: User,
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.storage.getWorkspace(user.id, wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const body = await this.parseBody<UpdateWorkspaceRequest>(req);

    if (body.skills) {
      const unknown = body.skills.filter((s) => !this.skillRegistry.get(s));
      if (unknown.length > 0) {
        this.error(res, 400, `Unknown skills: ${unknown.join(", ")}`);
        return;
      }
    }

    if (body.memoryNamespace && !this.isValidMemoryNamespace(body.memoryNamespace)) {
      this.error(res, 400, "memoryNamespace must match [a-zA-Z0-9][a-zA-Z0-9._-]{0,63}");
      return;
    }

    const updated = this.storage.updateWorkspace(user.id, wsId, body);
    this.json(res, { workspace: updated });
  }

  private handleDeleteWorkspace(user: User, wsId: string, res: ServerResponse): void {
    this.storage.deleteWorkspace(user.id, wsId);
    this.json(res, { ok: true });
  }

  private async handleRegisterDeviceToken(
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<RegisterDeviceTokenRequest>(req);
    if (!body.deviceToken) {
      this.error(res, 400, "deviceToken required");
      return;
    }

    const tokenType = body.tokenType || "apns";
    if (tokenType === "liveactivity") {
      this.storage.setLiveActivityToken(user.id, body.deviceToken);
      console.log(`[push] Live Activity token registered for ${user.name}`);
    } else {
      this.storage.addDeviceToken(user.id, body.deviceToken);
      console.log(`[push] Device token registered for ${user.name}`);
    }

    this.json(res, { ok: true });
  }

  private async handleDeleteDeviceToken(
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<{ deviceToken: string }>(req);
    if (body.deviceToken) {
      this.storage.removeDeviceToken(user.id, body.deviceToken);
      console.log(`[push] Device token removed for ${user.name}`);
    }
    this.json(res, { ok: true });
  }

  private async handleUploadClientLogs(
    user: User,
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const body = await this.parseBody<ClientLogUploadRequest>(req);
    const rawEntries = Array.isArray(body.entries) ? body.entries : [];
    if (rawEntries.length === 0) {
      this.error(res, 400, "entries array required");
      return;
    }

    const receivedAt = Date.now();
    const maxEntries = 1_000;
    const maxMessageChars = 4_000;
    const maxMetadataValueChars = 512;

    const entries = rawEntries
      .slice(-maxEntries)
      .map((entry) => {
        const metadata: Record<string, string> = {};
        if (entry.metadata) {
          for (const [key, value] of Object.entries(entry.metadata)) {
            if (typeof value !== "string") continue;
            metadata[key.slice(0, 64)] = value.slice(0, maxMetadataValueChars);
          }
        }

        const level =
          entry.level === "debug" ||
          entry.level === "info" ||
          entry.level === "warning" ||
          entry.level === "error"
            ? entry.level
            : "info";

        return {
          timestamp:
            typeof entry.timestamp === "number" && Number.isFinite(entry.timestamp)
              ? Math.trunc(entry.timestamp)
              : receivedAt,
          level,
          category:
            typeof entry.category === "string" && entry.category.trim().length > 0
              ? entry.category.trim().slice(0, 64)
              : "unknown",
          message:
            typeof entry.message === "string"
              ? entry.message.slice(0, maxMessageChars)
              : "",
          metadata,
        };
      })
      .filter((entry) => entry.message.length > 0);

    if (entries.length === 0) {
      this.error(res, 400, "No valid log entries");
      return;
    }

    const logsDir = join(this.storage.getDataDir(), "client-logs", user.id);
    if (!existsSync(logsDir)) {
      mkdirSync(logsDir, { recursive: true, mode: 0o700 });
    }

    const logPath = join(logsDir, `${sessionId}.jsonl`);
    const envelope = {
      receivedAt,
      generatedAt:
        typeof body.generatedAt === "number" && Number.isFinite(body.generatedAt)
          ? Math.trunc(body.generatedAt)
          : receivedAt,
      trigger:
        typeof body.trigger === "string" && body.trigger.trim().length > 0
          ? body.trigger.trim().slice(0, 64)
          : "manual",
      appVersion: typeof body.appVersion === "string" ? body.appVersion.slice(0, 64) : undefined,
      buildNumber:
        typeof body.buildNumber === "string" ? body.buildNumber.slice(0, 64) : undefined,
      osVersion: typeof body.osVersion === "string" ? body.osVersion.slice(0, 128) : undefined,
      deviceModel:
        typeof body.deviceModel === "string" ? body.deviceModel.slice(0, 64) : undefined,
      userId: user.id,
      sessionId,
      workspaceId: session.workspaceId,
      entries,
    };

    appendFileSync(logPath, `${JSON.stringify(envelope)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });

    console.log(
      `${ts()} [diagnostics] client logs uploaded: user=${user.name} session=${sessionId} entries=${entries.length}`,
    );
    this.json(res, { ok: true, accepted: entries.length });
  }

  private handleListSessions(user: User, res: ServerResponse): void {
    const sessions = this.storage
      .listUserSessions(user.id)
      .map((session) => this.ensureSessionContextWindow(session));
    this.json(res, { sessions });
  }

  private async handleCreateSession(
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<CreateSessionRequest>(req);

    this.storage.ensureDefaultWorkspaces(user.id);
    let workspace: Workspace | undefined;

    if (body.workspaceId) {
      workspace = this.storage.getWorkspace(user.id, body.workspaceId);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    } else {
      workspace = this.storage.listWorkspaces(user.id)[0];
    }

    const model = body.model || workspace?.defaultModel;
    const session = this.storage.createSession(user.id, body.name, model);

    if (workspace) {
      session.workspaceId = workspace.id;
      session.workspaceName = workspace.name;
      session.runtime = workspace.runtime;
      this.storage.saveSession(session);
    }

    const hydrated = this.ensureSessionContextWindow(session);
    this.json(res, { session: hydrated }, 201);
  }

  // ─── Workspace-scoped session handlers (v2 API) ───

  private handleListWorkspaceSessions(user: User, workspaceId: string, res: ServerResponse): void {
    const workspace = this.storage.getWorkspace(user.id, workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const sessions = this.storage
      .listUserSessions(user.id)
      .filter((s) => s.workspaceId === workspaceId)
      .map((s) => this.ensureSessionContextWindow(s));

    this.json(res, { sessions, workspace });
  }

  private async handleCreateWorkspaceSession(
    user: User,
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.storage.getWorkspace(user.id, workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const body = await this.parseBody<{ name?: string; model?: string }>(req);
    const model = body.model || workspace.defaultModel;
    const session = this.storage.createSession(user.id, body.name, model);

    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.runtime = workspace.runtime;
    this.storage.saveSession(session);

    const hydrated = this.ensureSessionContextWindow(session);
    this.json(res, { session: hydrated }, 201);
  }

  private async handleResumeWorkspaceSession(
    user: User,
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.storage.getWorkspace(user.id, workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    if (session.workspaceId !== workspaceId) {
      this.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    if (this.sessions.isActive(user.id, sessionId)) {
      const active = this.sessions.getActiveSession(user.id, sessionId);
      const hydrated = active ? this.ensureSessionContextWindow(active) : session;
      this.json(res, { session: hydrated });
      return;
    }

    try {
      const started = await this.sessions.startSession(user.id, sessionId, user.name, workspace);
      const hydrated = this.ensureSessionContextWindow(started);
      this.json(res, { session: hydrated });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Resume failed";
      this.error(res, 500, message);
    }
  }

  private async handleStopSession(
    user: User,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const hydratedSession = this.ensureSessionContextWindow(session);

    if (this.sessions.isActive(user.id, sessionId)) {
      await this.sessions.stopSession(user.id, sessionId);
    } else {
      hydratedSession.status = "stopped";
      hydratedSession.lastActivity = Date.now();
      this.storage.saveSession(hydratedSession);
    }

    const updatedSession = this.storage.getSession(user.id, sessionId);
    const hydratedUpdated = updatedSession
      ? this.ensureSessionContextWindow(updatedSession)
      : updatedSession;
    this.json(res, { ok: true, session: hydratedUpdated });
  }

  // ─── Tool Output by ID ───

  /**
   * Return the full tool result for a specific toolCallId.
   *
   * Searches the session's JSONL trace for the matching tool result entry.
   * Used by the iOS client to lazy-load evicted tool output when the user
   * expands an old tool call row.
   */
  private handleGetToolOutput(
    user: User,
    sessionId: string,
    toolCallId: string,
    res: ServerResponse,
  ): void {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    // Gather all candidate JSONL paths (same logic as trace endpoint)
    const jsonlPaths: string[] = [];
    const sandboxBaseDir = this.sandbox.getBaseDir();

    // Container layout (workspace-scoped + legacy fallback)
    const containerDirs: string[] = [];
    if (session.workspaceId) {
      containerDirs.push(
        join(
          sandboxBaseDir,
          user.id,
          session.workspaceId,
          "sessions",
          sessionId,
          "agent",
          "sessions",
          "--work--",
        ),
      );
    }
    containerDirs.push(join(sandboxBaseDir, user.id, sessionId, "agent", "sessions", "--work--"));

    for (const containerDir of containerDirs) {
      if (!existsSync(containerDir)) continue;
      for (const f of readdirSync(containerDir)
        .filter((f) => f.endsWith(".jsonl"))
        .sort()) {
        const p = join(containerDir, f);
        if (!jsonlPaths.includes(p)) {
          jsonlPaths.push(p);
        }
      }
    }

    // Host layout — persisted session file paths
    if (session.piSessionFiles?.length) {
      for (const p of session.piSessionFiles) {
        if (existsSync(p) && !jsonlPaths.includes(p)) jsonlPaths.push(p);
      }
    }
    if (
      session.piSessionFile &&
      existsSync(session.piSessionFile) &&
      !jsonlPaths.includes(session.piSessionFile)
    ) {
      jsonlPaths.push(session.piSessionFile);
    }

    // Search for the tool output
    for (const jsonlPath of jsonlPaths) {
      const output = findToolOutput(jsonlPath, toolCallId);
      if (output !== null) {
        this.json(res, { toolCallId, output: output.text, isError: output.isError });
        return;
      }
    }

    this.error(res, 404, "Tool output not found");
  }

  // ─── Session File Access ───

  /**
   * Serve a single file from the session's working directory.
   *
   * Resolves the work root from the session/workspace config and streams
   * the requested file. No directory listing — just single file access
   * triggered by tapping a file path in the chat view.
   *
   * Security: path traversal guard via realpath + startsWith check.
   */
  private handleGetSessionFile(user: User, sessionId: string, url: URL, res: ServerResponse): void {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const reqPath = url.searchParams.get("path");
    if (!reqPath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const workRoot = this.resolveWorkRoot(session, user.id);
    if (!workRoot) {
      this.error(res, 404, "No workspace root for session");
      return;
    }

    // Resolve path — handles both absolute paths (from host-mode reads)
    // and relative paths (workspace-relative). resolve() returns reqPath
    // as-is when absolute, or joins with workRoot when relative.
    const target = resolve(workRoot, reqPath);
    let resolved: string;
    try {
      resolved = realpathSync(target);
    } catch {
      this.error(res, 404, "File not found");
      return;
    }

    const realWorkRoot = realpathSync(workRoot);
    if (!resolved.startsWith(realWorkRoot + "/") && resolved !== realWorkRoot) {
      this.error(res, 403, "Path outside workspace");
      return;
    }

    let stat: ReturnType<typeof statSync>;
    try {
      stat = statSync(resolved);
    } catch {
      this.error(res, 404, "File not found");
      return;
    }

    if (!stat.isFile()) {
      this.error(res, 400, "Not a file");
      return;
    }

    // Size guard — refuse files > 10MB
    if (stat.size > 10 * 1024 * 1024) {
      this.error(res, 413, "File too large (max 10MB)");
      return;
    }

    const mime = guessMime(resolved);
    res.writeHead(200, {
      "Content-Type": mime,
      "Content-Length": stat.size,
      "Cache-Control": "no-cache",
    });
    createReadStream(resolved).pipe(res);
  }

  /**
   * Resolve the filesystem root for a session's working directory.
   *
   * Works for both active and stopped sessions, both runtimes:
   * - Container: sandbox workspace dir (or workspace hostMount)
   * - Host: workspace hostMount or $HOME
   */
  private resolveWorkRoot(session: Session, userId: string): string | null {
    const workspace = session.workspaceId
      ? this.storage.getWorkspace(userId, session.workspaceId)
      : undefined;

    if (session.runtime === "container") {
      if (workspace?.hostMount) {
        const resolved = workspace.hostMount.replace(/^~/, homedir());
        return existsSync(resolved) ? resolved : null;
      }
      if (session.workspaceId) {
        const workspaceSandbox = join(
          this.sandbox.getBaseDir(),
          userId,
          session.workspaceId,
          "workspace",
        );
        if (existsSync(workspaceSandbox)) {
          return workspaceSandbox;
        }
      }

      // Legacy session-scoped fallback
      const sandboxWork = join(this.sandbox.getBaseDir(), userId, session.id, "workspace");
      return existsSync(sandboxWork) ? sandboxWork : null;
    }

    // Host mode
    if (workspace?.hostMount) {
      const resolved = workspace.hostMount.replace(/^~/, homedir());
      return existsSync(resolved) ? resolved : null;
    }
    return homedir();
  }

  private handleGetSessionEvents(
    user: User,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      this.error(res, 400, "since must be a non-negative integer");
      return;
    }

    const catchUp = this.sessions.getCatchUp(user.id, sessionId, sinceSeq);
    if (!catchUp) {
      this.error(res, 404, "Session not active");
      return;
    }

    this.json(res, {
      events: catchUp.events,
      currentSeq: catchUp.currentSeq,
      session: this.ensureSessionContextWindow(catchUp.session),
      catchUpComplete: catchUp.catchUpComplete,
    });
  }

  private async handleGetSession(
    user: User,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const hydratedSession = this.ensureSessionContextWindow(session);
    const sandboxBaseDir = this.sandbox.getBaseDir();

    // Resolve trace from all available sources (container layout, host JSONL paths, live query)
    let trace = readSessionTrace(sandboxBaseDir, user.id, sessionId, hydratedSession.workspaceId);

    if ((!trace || trace.length === 0) && hydratedSession.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(hydratedSession.piSessionFiles);
    }
    if ((!trace || trace.length === 0) && hydratedSession.piSessionFile) {
      trace = readSessionTraceFromFile(hydratedSession.piSessionFile);
    }
    if ((!trace || trace.length === 0) && hydratedSession.piSessionId) {
      trace = readSessionTraceByUuid(
        sandboxBaseDir,
        user.id,
        hydratedSession.piSessionId,
        hydratedSession.workspaceId,
      );
    }

    // Active session fallback: query live pi process to discover session file
    if (!trace || trace.length === 0) {
      const live = await this.sessions.refreshSessionState(user.id, sessionId);
      if (live?.sessionFile) {
        trace = readSessionTraceFromFile(live.sessionFile);
      }
      if ((!trace || trace.length === 0) && live?.sessionId) {
        trace = readSessionTraceByUuid(
          sandboxBaseDir,
          user.id,
          live.sessionId,
          hydratedSession.workspaceId,
        );
      }

      const refreshed = this.storage.getSession(user.id, sessionId);
      if (refreshed) {
        this.ensureSessionContextWindow(refreshed);
        if ((!trace || trace.length === 0) && refreshed.piSessionFiles?.length) {
          trace = readSessionTraceFromFiles(refreshed.piSessionFiles);
        }
        if ((!trace || trace.length === 0) && refreshed.piSessionFile) {
          trace = readSessionTraceFromFile(refreshed.piSessionFile);
        }
        if ((!trace || trace.length === 0) && refreshed.piSessionId) {
          trace = readSessionTraceByUuid(
            sandboxBaseDir,
            user.id,
            refreshed.piSessionId,
            refreshed.workspaceId,
          );
        }
      }
    }

    const latestSession = this.storage.getSession(user.id, sessionId) || hydratedSession;
    const hydratedLatest = this.ensureSessionContextWindow(latestSession);
    this.json(res, { session: hydratedLatest, trace: trace || [] });
  }

  private async handleDeleteSession(
    user: User,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    await this.sessions.stopSession(user.id, sessionId);
    this.storage.deleteSession(user.id, sessionId);
    this.json(res, { ok: true });
  }

  private async parseBody<T>(req: IncomingMessage): Promise<T> {
    return new Promise((resolve, reject) => {
      let body = "";
      req.on("data", (chunk: Buffer) => (body += chunk));
      req.on("end", () => {
        try {
          resolve(body ? JSON.parse(body) : {});
        } catch {
          reject(new Error("Invalid JSON"));
        }
      });
      req.on("error", reject);
    });
  }

  private json(res: ServerResponse, data: Record<string, unknown>, status = 200): void {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data));
  }

  private error(res: ServerResponse, status: number, message: string): void {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: message } as ApiError));
  }

  private deprecationHeader(res: ServerResponse, legacy: string, replacement: string): void {
    res.setHeader("Deprecation", "true");
    res.setHeader("Sunset", "2026-06-01");
    res.setHeader("Link", `<${replacement}>; rel="successor-version"`);
    console.log(`${ts()} [deprecation] ${legacy} → use ${replacement}`);
  }

  // ─── WebSocket ───

  private handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    (socket as Socket).setNoDelay?.(true);

    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const user = this.authenticate(req);
    if (!user) {
      const auth = req.headers.authorization;
      console.log(
        `${ts()} [auth] 401 WS upgrade ${url.pathname} — token: ${auth ? auth.slice(0, 15) + "…" : "(none)"}`,
      );
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }

    // Match workspace-scoped WS path first, then legacy path.
    const wsMatch = url.pathname.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stream$/);
    const legacyMatch = url.pathname.match(/^\/sessions\/([^/]+)\/stream$/);

    const sessionId = wsMatch ? wsMatch[2] : legacyMatch?.[1];
    if (!sessionId) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    // Both WS paths are supported — workspace-scoped is preferred for
    // new clients, but the global path remains valid permanently.

    const session = this.storage.getSession(user.id, sessionId);
    if (!session) {
      console.log(`${ts()} [ws] 404 session not found: ${sessionId} (user=${user.name})`);
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
      const workspace = session.workspaceId
        ? this.storage.getWorkspace(user.id, session.workspaceId)
        : undefined;

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
      case "prompt": {
        const timestamp = Date.now();
        const requestId = msg.requestId;
        const preview = msg.message.slice(0, 80);
        const imageCount = msg.images?.length ?? 0;
        console.log(
          `${ts()} [ws] PROMPT ${session.id}: "${preview}"${imageCount > 0 ? ` (${imageCount} images)` : ""}`,
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
        console.log(`${ts()} [ws] STEER ${session.id}: "${msg.message.slice(0, 80)}"`);
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
        console.log(`${ts()} [ws] FOLLOW_UP ${session.id}: "${msg.message.slice(0, 80)}"`);
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
        const resolved = this.gate.resolveDecision(msg.id, msg.action, scope);
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

// ─── Helpers ───

/** Minimal MIME type guesser for file serving. */
function guessMime(filePath: string): string {
  const ext = extname(filePath).toLowerCase();
  const mimeMap: Record<string, string> = {
    ".html": "text/html",
    ".htm": "text/html",
    ".css": "text/css",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".ts": "text/typescript",
    ".json": "application/json",
    ".md": "text/markdown",
    ".txt": "text/plain",
    ".csv": "text/csv",
    ".xml": "application/xml",
    ".yaml": "text/yaml",
    ".yml": "text/yaml",
    ".toml": "text/plain",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".pdf": "application/pdf",
    ".zip": "application/zip",
    ".gz": "application/gzip",
    ".tar": "application/x-tar",
    ".wasm": "application/wasm",
    ".py": "text/x-python",
    ".rs": "text/x-rust",
    ".go": "text/x-go",
    ".swift": "text/x-swift",
    ".sh": "text/x-shellscript",
    ".log": "text/plain",
  };
  return mimeMap[ext] || "application/octet-stream";
}
