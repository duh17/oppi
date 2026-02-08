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
import { createReadStream } from "node:fs";
import { existsSync, readdirSync, realpathSync, statSync } from "node:fs";
import { join, extname } from "node:path";
import { homedir } from "node:os";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager, type ExtensionUIResponse } from "./sessions.js";
import { PolicyEngine } from "./policy.js";
import { GateServer, type PendingDecision } from "./gate.js";
import { SandboxManager } from "./sandbox.js";
import { SkillRegistry } from "./skills.js";
import { readSessionTrace, readSessionTraceByUuid, readSessionTraceFromFile, readSessionTraceFromFiles, findToolOutput } from "./trace.js";
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
  ApiError,
} from "./types.js";

// ─── Available Models ───

interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  contextWindow: number;
}

const AVAILABLE_MODELS: ModelInfo[] = [
  // Anthropic
  { id: "anthropic/claude-opus-4-6", name: "Claude Opus 4.6", provider: "anthropic", contextWindow: 200000 },
  { id: "anthropic/claude-sonnet-4-0", name: "Claude Sonnet 4", provider: "anthropic", contextWindow: 200000 },
  { id: "anthropic/claude-haiku-3-5", name: "Claude Haiku 3.5", provider: "anthropic", contextWindow: 200000 },
  // OpenAI
  { id: "openai/o3", name: "o3", provider: "openai", contextWindow: 200000 },
  { id: "openai/o4-mini", name: "o4-mini", provider: "openai", contextWindow: 200000 },
  { id: "openai/gpt-4.1", name: "GPT-4.1", provider: "openai", contextWindow: 1000000 },
  // Google
  { id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro", provider: "google", contextWindow: 1000000 },
  { id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash", provider: "google", contextWindow: 1000000 },
  // LM Studio (local)
  { id: "lmstudio/qwen3-32b", name: "Qwen3 32B", provider: "lmstudio", contextWindow: 32768 },
  { id: "lmstudio/deepseek-r1-0528-qwen3-8b", name: "DeepSeek R1 8B", provider: "lmstudio", contextWindow: 32768 },
];

function getContextWindow(modelId: string): number {
  const known = AVAILABLE_MODELS.find(m => m.id === modelId)?.contextWindow;
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

export class Server {
  private storage: Storage;
  private sessions: SessionManager;
  private policy: PolicyEngine;
  private gate: GateServer;
  private sandbox: SandboxManager;
  private skillRegistry: SkillRegistry;
  private authProxy: AuthProxy;
  private push: PushClient;
  private httpServer: ReturnType<typeof createServer>;
  private wss: WebSocketServer;

  // Track WebSocket connections per user for permission/UI forwarding
  private userConnections: Map<string, Set<WebSocket>> = new Map();

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;

    this.policy = new PolicyEngine("container"); // Per-workspace in v2
    this.gate = new GateServer(this.policy);
    this.authProxy = new AuthProxy();
    this.sandbox = new SandboxManager();
    this.skillRegistry = new SkillRegistry();
    this.skillRegistry.scan();
    this.sandbox.setSkillRegistry(this.skillRegistry);
    this.sandbox.setAuthProxy(this.authProxy);
    this.push = createPushClient(apnsConfig);
    this.sessions = new SessionManager(storage, this.gate, this.sandbox, this.authProxy);

    this.httpServer = createServer((req, res) => this.handleHttp(req, res));
    this.wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

    this.httpServer.on("upgrade", (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });

    // Wire gate events → phone WebSocket
    this.gate.on("approval_needed", (pending: PendingDecision) => {
      this.forwardPermissionRequest(pending);
    });

    this.gate.on("approval_timeout", ({ requestId, sessionId }: { requestId: string; sessionId: string }) => {
      const session = this.findSessionById(sessionId);
      if (session) {
        this.broadcastToUser(session.userId, {
          type: "permission_expired",
          id: requestId,
          reason: "Approval timeout",
        });
      }
    });
  }

  // ─── Start / Stop ───

  async start(): Promise<void> {
    // Best-effort cleanup from previous crashes before accepting connections.
    await this.sandbox.cleanupOrphanedContainers();

    // Ensure container image and internal network exist
    await this.sandbox.ensureImage();
    this.sandbox.ensureNetwork();

    // Start auth proxy (credential-injecting reverse proxy for containers)
    await this.authProxy.start();

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
    };

    this.broadcastToUser(pending.userId, msg);
    console.log(`[gate] Permission request ${pending.id} → ${pending.userId}: ${pending.displaySummary}`);
  }

  // ─── User Connection Tracking ───

  private broadcastToUser(userId: string, msg: ServerMessage): void {
    const conns = this.userConnections.get(userId);
    const hasWS = conns && conns.size > 0 &&
      Array.from(conns).some(ws => ws.readyState === WebSocket.OPEN);

    if (hasWS) {
      const json = JSON.stringify(msg);
      for (const ws of conns!) {
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
        this.push.sendPermissionPush(token, {
          permissionId: msg.id,
          sessionId: msg.sessionId,
          sessionName: session?.name,
          tool: msg.tool,
          displaySummary: msg.displaySummary,
          risk: msg.risk,
          reason: msg.reason,
          timeoutAt: msg.timeoutAt,
        }).then(ok => {
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
    return sessions.find(s => s.status === "stopped") || sessions[0];
  }

  private trackConnection(userId: string, ws: WebSocket): void {
    let conns = this.userConnections.get(userId);
    if (!conns) { conns = new Set(); this.userConnections.set(userId, conns); }
    conns.add(ws);
  }

  private untrackConnection(userId: string, ws: WebSocket): void {
    const conns = this.userConnections.get(userId);
    if (conns) {
      conns.delete(ws);
      if (conns.size === 0) this.userConnections.delete(userId);
    }
  }

  private findSessionById(sessionId: string): Session | undefined {
    for (const user of this.storage.listUsers()) {
      const sessions = this.storage.listUserSessions(user.id);
      const match = sessions.find(s => s.id === sessionId);
      if (match) return this.ensureSessionContextWindow(match);
    }
    return undefined;
  }

  private ensureSessionContextWindow(session: Session): Session {
    let changed = false;

    if (!session.contextWindow || session.contextWindow <= 0) {
      session.contextWindow = getContextWindow(session.model || "");
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

    if (method === "OPTIONS") { res.writeHead(204); res.end(); return; }
    if (path === "/health") { this.json(res, { ok: true }); return; }

    const user = this.authenticate(req);
    if (!user) {
      const auth = req.headers.authorization;
      console.log(`[auth] 401 ${method} ${path} — token: ${auth ? auth.slice(0, 15) + "…" : "(none)"}`);
      this.error(res, 401, "Unauthorized");
      return;
    }

    try {
      // Static routes
      if (path === "/me" && method === "GET") return this.handleGetMe(user, res);
      if (path === "/models" && method === "GET") return this.handleListModels(res);
      if (path === "/skills" && method === "GET") return this.handleListSkills(res);
      if (path === "/skills/rescan" && method === "POST") return this.handleRescanSkills(res);

      // Host discovery
      if (path === "/host/directories" && method === "GET") return this.handleListDirectories(url, res);

      // Workspaces
      if (path === "/workspaces" && method === "GET") return this.handleListWorkspaces(user, res);
      if (path === "/workspaces" && method === "POST") return await this.handleCreateWorkspace(user, req, res);

      const wsMatch = path.match(/^\/workspaces\/([^/]+)$/);
      if (wsMatch) {
        if (method === "GET") return this.handleGetWorkspace(user, wsMatch[1], res);
        if (method === "PUT") return await this.handleUpdateWorkspace(user, wsMatch[1], req, res);
        if (method === "DELETE") return this.handleDeleteWorkspace(user, wsMatch[1], res);
      }

      // Device tokens
      if (path === "/me/device-token" && method === "POST") return await this.handleRegisterDeviceToken(user, req, res);
      if (path === "/me/device-token" && method === "DELETE") return await this.handleDeleteDeviceToken(user, req, res);

      // Sessions
      if (path === "/sessions" && method === "GET") return this.handleListSessions(user, res);
      if (path === "/sessions" && method === "POST") return await this.handleCreateSession(user, req, res);

      const stopMatch = path.match(/^\/sessions\/([^/]+)\/stop$/);
      if (stopMatch && method === "POST") return await this.handleStopSession(user, stopMatch[1], res);

      const traceMatch = path.match(/^\/sessions\/([^/]+)\/trace$/);
      if (traceMatch && method === "GET") return await this.handleGetSessionTrace(user, traceMatch[1], res);

      const toolOutputMatch = path.match(/^\/sessions\/([^/]+)\/tool-output\/([^/]+)$/);
      if (toolOutputMatch && method === "GET") return this.handleGetToolOutput(user, toolOutputMatch[1], toolOutputMatch[2], res);

      const filesMatch = path.match(/^\/sessions\/([^/]+)\/files$/);
      if (filesMatch && method === "GET") return this.handleGetSessionFile(user, filesMatch[1], url, res);

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

  private handleListModels(res: ServerResponse): void {
    this.json(res, { models: AVAILABLE_MODELS });
  }

  private handleListSkills(res: ServerResponse): void {
    this.json(res, { skills: this.skillRegistry.list() });
  }

  private handleRescanSkills(res: ServerResponse): void {
    this.skillRegistry.scan();
    this.json(res, { skills: this.skillRegistry.list() });
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

  private async handleCreateWorkspace(user: User, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.parseBody<CreateWorkspaceRequest>(req);
    if (!body.name) { this.error(res, 400, "name required"); return; }
    if (!body.skills || !Array.isArray(body.skills)) { this.error(res, 400, "skills array required"); return; }

    const unknown = body.skills.filter(s => !this.skillRegistry.get(s));
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
    if (!workspace) { this.error(res, 404, "Workspace not found"); return; }
    this.json(res, { workspace });
  }

  private async handleUpdateWorkspace(user: User, wsId: string, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const workspace = this.storage.getWorkspace(user.id, wsId);
    if (!workspace) { this.error(res, 404, "Workspace not found"); return; }

    const body = await this.parseBody<UpdateWorkspaceRequest>(req);

    if (body.skills) {
      const unknown = body.skills.filter(s => !this.skillRegistry.get(s));
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

  private async handleRegisterDeviceToken(user: User, req: IncomingMessage, res: ServerResponse): Promise<void> {
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

  private async handleDeleteDeviceToken(user: User, req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await this.parseBody<{ deviceToken: string }>(req);
    if (body.deviceToken) {
      this.storage.removeDeviceToken(user.id, body.deviceToken);
      console.log(`[push] Device token removed for ${user.name}`);
    }
    this.json(res, { ok: true });
  }

  private handleListSessions(user: User, res: ServerResponse): void {
    const sessions = this.storage
      .listUserSessions(user.id)
      .map(session => this.ensureSessionContextWindow(session));
    this.json(res, { sessions });
  }

  private async handleCreateSession(user: User, req: IncomingMessage, res: ServerResponse): Promise<void> {
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

  private async handleStopSession(user: User, sessionId: string, res: ServerResponse): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) { this.error(res, 404, "Session not found"); return; }

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

  private async handleGetSessionTrace(user: User, sessionId: string, res: ServerResponse): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) { this.error(res, 404, "Session not found"); return; }

    const hydratedSession = this.ensureSessionContextWindow(session);
    const sandboxBaseDir = this.sandbox.getBaseDir();

    // 1) Session sandbox trace (container + legacy layouts)
    let trace = readSessionTrace(sandboxBaseDir, user.id, sessionId);

    // 2) Host/runtime traces via persisted pi session file paths
    if ((!trace || trace.length === 0) && hydratedSession.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(hydratedSession.piSessionFiles);
    }
    if ((!trace || trace.length === 0) && hydratedSession.piSessionFile) {
      trace = readSessionTraceFromFile(hydratedSession.piSessionFile);
    }

    // 3) Legacy lookup by pi internal session UUID
    if ((!trace || trace.length === 0) && hydratedSession.piSessionId) {
      trace = readSessionTraceByUuid(sandboxBaseDir, user.id, hydratedSession.piSessionId);
    }

    // 4) Active session fallback: query live get_state to discover session file
    if (!trace || trace.length === 0) {
      const live = await this.sessions.refreshSessionState(user.id, sessionId);
      if (live?.sessionFile) {
        trace = readSessionTraceFromFile(live.sessionFile);
      }
      if ((!trace || trace.length === 0) && live?.sessionId) {
        trace = readSessionTraceByUuid(sandboxBaseDir, user.id, live.sessionId);
      }

      // Session metadata may have been updated by refreshSessionState
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
          trace = readSessionTraceByUuid(sandboxBaseDir, user.id, refreshed.piSessionId);
        }
      }
    }

    const latestSession = this.storage.getSession(user.id, sessionId) || hydratedSession;
    const hydratedLatest = this.ensureSessionContextWindow(latestSession);
    this.json(res, { session: hydratedLatest, trace: trace || [] });
  }

  // ─── Tool Output by ID ───

  /**
   * Return the full tool result for a specific toolCallId.
   *
   * Searches the session's JSONL trace for the matching tool result entry.
   * Used by the iOS client to lazy-load evicted tool output when the user
   * expands an old tool call row.
   */
  private handleGetToolOutput(user: User, sessionId: string, toolCallId: string, res: ServerResponse): void {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) { this.error(res, 404, "Session not found"); return; }

    // Gather all candidate JSONL paths (same logic as trace endpoint)
    const jsonlPaths: string[] = [];
    const sandboxBaseDir = this.sandbox.getBaseDir();

    // Container layout
    const containerDir = join(sandboxBaseDir, user.id, sessionId, "agent", "sessions", "--work--");
    if (existsSync(containerDir)) {
      for (const f of readdirSync(containerDir).filter(f => f.endsWith(".jsonl")).sort()) {
        jsonlPaths.push(join(containerDir, f));
      }
    }

    // Host layout — persisted session file paths
    if (session.piSessionFiles?.length) {
      for (const p of session.piSessionFiles) {
        if (existsSync(p) && !jsonlPaths.includes(p)) jsonlPaths.push(p);
      }
    }
    if (session.piSessionFile && existsSync(session.piSessionFile) && !jsonlPaths.includes(session.piSessionFile)) {
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
    if (!session) { this.error(res, 404, "Session not found"); return; }

    const reqPath = url.searchParams.get("path");
    if (!reqPath) { this.error(res, 400, "path parameter required"); return; }

    const workRoot = this.resolveWorkRoot(session, user.id);
    if (!workRoot) { this.error(res, 404, "No workspace root for session"); return; }

    // Resolve and guard against path traversal
    const target = join(workRoot, reqPath);
    let resolved: string;
    try {
      resolved = realpathSync(target);
    } catch {
      this.error(res, 404, "File not found"); return;
    }

    const realWorkRoot = realpathSync(workRoot);
    if (!resolved.startsWith(realWorkRoot + "/") && resolved !== realWorkRoot) {
      this.error(res, 403, "Path outside workspace"); return;
    }

    let stat: ReturnType<typeof statSync>;
    try {
      stat = statSync(resolved);
    } catch {
      this.error(res, 404, "File not found"); return;
    }

    if (!stat.isFile()) {
      this.error(res, 400, "Not a file"); return;
    }

    // Size guard — refuse files > 10MB
    if (stat.size > 10 * 1024 * 1024) {
      this.error(res, 413, "File too large (max 10MB)"); return;
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

  private async handleGetSession(user: User, sessionId: string, res: ServerResponse): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) { this.error(res, 404, "Session not found"); return; }

    const hydratedSession = this.ensureSessionContextWindow(session);
    const messages = this.storage.getSessionMessages(user.id, sessionId);
    this.json(res, { session: hydratedSession, messages });
  }

  private async handleDeleteSession(user: User, sessionId: string, res: ServerResponse): Promise<void> {
    const session = this.storage.getSession(user.id, sessionId);
    if (!session) { this.error(res, 404, "Session not found"); return; }

    await this.sessions.stopSession(user.id, sessionId);
    this.storage.deleteSession(user.id, sessionId);
    this.json(res, { ok: true });
  }

  private async parseBody<T>(req: IncomingMessage): Promise<T> {
    return new Promise((resolve, reject) => {
      let body = "";
      req.on("data", (chunk: Buffer) => body += chunk);
      req.on("end", () => {
        try { resolve(body ? JSON.parse(body) : {}); }
        catch { reject(new Error("Invalid JSON")); }
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

  // ─── WebSocket ───

  private handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    (socket as Socket).setNoDelay?.(true);

    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const user = this.authenticate(req);
    if (!user) {
      const auth = req.headers.authorization;
      console.log(`[auth] 401 WS upgrade ${url.pathname} — token: ${auth ? auth.slice(0, 15) + "…" : "(none)"}`);
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }

    const match = url.pathname.match(/^\/sessions\/([^/]+)\/stream$/);
    if (!match) { socket.write("HTTP/1.1 404 Not Found\r\n\r\n"); socket.destroy(); return; }

    const session = this.storage.getSession(user.id, match[1]);
    if (!session) { socket.write("HTTP/1.1 404 Not Found\r\n\r\n"); socket.destroy(); return; }

    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.handleWebSocket(ws, user, session);
    });
  }

  private async handleWebSocket(ws: WebSocket, user: User, session: Session): Promise<void> {
    console.log(`[ws] Connected: ${user.name} → ${session.id}`);
    this.trackConnection(user.id, ws);

    const send = (msg: ServerMessage) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg), { compress: false });
      }
    };

    try {
      // Resolve workspace for this session
      const workspace = session.workspaceId
        ? this.storage.getWorkspace(user.id, session.workspaceId)
        : undefined;

      const activeSession = await this.sessions.startSession(user.id, session.id, user.name, workspace);
      const hydratedSession = this.ensureSessionContextWindow(activeSession);
      send({ type: "connected", session: hydratedSession });

      // Send pending permission requests
      for (const pending of this.gate.getPendingForUser(user.id)) {
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
        });
      }

      // Subscribe to session events
      const unsubscribe = this.sessions.subscribe(user.id, session.id, send);

      ws.on("message", async (data) => {
        try {
          const msg = JSON.parse(data.toString()) as ClientMessage;
          await this.handleClientMessage(user, hydratedSession, msg, send);
        } catch (err: unknown) {
          const message = err instanceof Error ? err.message : "Unknown error";
          send({ type: "error", error: message });
        }
      });

      ws.on("close", () => {
        console.log(`[ws] Disconnected: ${user.name} → ${session.id}`);
        unsubscribe();
        this.untrackConnection(user.id, ws);
      });

      ws.on("error", (err) => {
        console.error(`[ws] Error: ${user.name} → ${session.id}`, err);
        unsubscribe();
        this.untrackConnection(user.id, ws);
      });

    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Setup error";
      console.error(`[ws] Setup error:`, err);
      send({ type: "error", error: message });
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
        this.storage.addSessionMessage(user.id, session.id, {
          role: "user",
          content: msg.message,
          timestamp,
        });
        this.sessions.recordUserMessage(user.id, session.id, msg.message, timestamp);

        // RPC image format: { type: "image", data: "base64...", mimeType: "image/png" }
        const images = msg.images?.map(img => ({
          type: "image" as const,
          data: img.data,
          mimeType: img.mimeType,
        }));

        await this.sessions.sendPrompt(user.id, session.id, msg.message, {
          images,
          streamingBehavior: msg.streamingBehavior,
        });
        break;
      }

      case "steer": {
        const steerImages = msg.images?.map(img => ({
          type: "image" as const, data: img.data, mimeType: img.mimeType,
        }));
        await this.sessions.sendSteer(user.id, session.id, msg.message, steerImages);
        break;
      }

      case "follow_up": {
        const fuImages = msg.images?.map(img => ({
          type: "image" as const, data: img.data, mimeType: img.mimeType,
        }));
        await this.sessions.sendFollowUp(user.id, session.id, msg.message, fuImages);
        break;
      }

      case "abort":
      case "stop":
        await this.sessions.sendAbort(user.id, session.id);
        break;

      case "get_state": {
        const active = this.sessions.getActiveSession(user.id, session.id);
        if (active) {
          send({ type: "state", session: this.ensureSessionContextWindow(active) });
        }
        break;
      }

      case "permission_response": {
        const resolved = this.gate.resolveDecision(msg.id, msg.action);
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
