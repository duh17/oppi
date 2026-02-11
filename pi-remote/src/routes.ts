/**
 * REST route handlers.
 *
 * All HTTP route logic extracted from server.ts for independent testability.
 * Routes receive a RouteContext with the services they need — no direct
 * coupling to the Server class.
 */

import type { IncomingMessage, ServerResponse } from "node:http";
import {
  appendFileSync,
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { join, resolve, extname } from "node:path";
import { homedir } from "node:os";
import type { Storage } from "./storage.js";
import type { SessionManager } from "./sessions.js";
import type { GateServer } from "./gate.js";
import type { SandboxManager } from "./sandbox.js";
import type { SkillRegistry, UserSkillStore } from "./skills.js";
import { SkillValidationError } from "./skills.js";
import type { UserStreamMux } from "./stream.js";
import {
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  findToolOutput,
} from "./trace.js";
import {
  collectFileMutations,
  reconstructBaselineFromCurrent,
  computeDiffLines,
  computeLineDiffStatsFromLines,
} from "./overall-diff.js";
import { discoverProjects, scanDirectories } from "./host.js";
import { isValidExtensionName, listHostExtensions } from "./extension-loader.js";
import type {
  User,
  Session,
  Workspace,
  CreateSessionRequest,
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  RegisterDeviceTokenRequest,
  ClientLogUploadRequest,
  ApiError,
} from "./types.js";

function ts(): string {
  return new Date().toISOString().replace("T", " ").slice(0, 23);
}

// ─── Types ───

export interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  contextWindow?: number;
}

/** Services needed by route handlers — injected by Server. */
export interface RouteContext {
  storage: Storage;
  sessions: SessionManager;
  gate: GateServer;
  sandbox: SandboxManager;
  skillRegistry: SkillRegistry;
  userSkillStore: UserSkillStore;
  streamMux: UserStreamMux;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (userId: string, session: Session) => Workspace | undefined;
  isValidMemoryNamespace: (ns: string) => boolean;
  refreshModelCatalog: () => Promise<void>;
  getModelCatalog: () => ModelInfo[];
}

// ─── Route Handler ───

export class RouteHandler {
  constructor(private ctx: RouteContext) {}

  /**
   * Dispatch an authenticated HTTP request to the appropriate handler.
   * Called by Server after CORS, OPTIONS, /health, and auth checks.
   */
  async dispatch(
    method: string,
    path: string,
    url: URL,
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    // Static routes
    if (path === "/stream/events" && method === "GET")
      return this.handleGetUserStreamEvents(user, url, res);
    if (path === "/permissions/pending" && method === "GET")
      return this.handleGetPendingPermissions(user, url, res);
    if (path === "/me" && method === "GET") return this.handleGetMe(user, res);
    if (path === "/models" && method === "GET") return this.handleListModels(res);
    if (path === "/skills" && method === "GET") return this.handleListSkills(res);
    if (path === "/skills/rescan" && method === "POST") return this.handleRescanSkills(res);
    if (path === "/extensions" && method === "GET") return this.handleListExtensions(res);

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
      return this.handleCreateWorkspace(user, req, res);

    const wsMatch = path.match(/^\/workspaces\/([^/]+)$/);
    if (wsMatch) {
      if (method === "GET") return this.handleGetWorkspace(user, wsMatch[1], res);
      if (method === "PUT") return this.handleUpdateWorkspace(user, wsMatch[1], req, res);
      if (method === "DELETE") return this.handleDeleteWorkspace(user, wsMatch[1], res);
    }

    // Device tokens
    if (path === "/me/device-token" && method === "POST")
      return this.handleRegisterDeviceToken(user, req, res);
    if (path === "/me/device-token" && method === "DELETE")
      return this.handleDeleteDeviceToken(user, req, res);

    // User skills CRUD
    if (path === "/me/skills" && method === "GET") return this.handleListUserSkills(user, res);
    if (path === "/me/skills" && method === "POST") return this.handleSaveUserSkill(user, req, res);

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
      if (method === "GET") return this.handleListWorkspaceSessions(user, wsSessionsMatch[1], res);
      if (method === "POST")
        return this.handleCreateWorkspaceSession(user, wsSessionsMatch[1], req, res);
    }

    const wsSessionStopMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/);
    if (wsSessionStopMatch && method === "POST") {
      return this.handleStopSession(user, wsSessionStopMatch[2], res);
    }

    const wsSessionClientLogsMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/client-logs$/,
    );
    if (wsSessionClientLogsMatch && method === "POST") {
      return this.handleUploadClientLogs(user, wsSessionClientLogsMatch[2], req, res);
    }

    const wsSessionResumeMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/);
    if (wsSessionResumeMatch && method === "POST") {
      return this.handleResumeWorkspaceSession(
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

    const wsSessionOverallDiffMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/overall-diff$/);
    if (wsSessionOverallDiffMatch && method === "GET") {
      return this.handleGetSessionOverallDiff(user, wsSessionOverallDiffMatch[2], url, res);
    }

    const wsSessionEventsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/);
    if (wsSessionEventsMatch && method === "GET") {
      return this.handleGetSessionEvents(user, wsSessionEventsMatch[2], url, res);
    }

    const wsSessionMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/);
    if (wsSessionMatch) {
      if (method === "GET") return this.handleGetSession(user, wsSessionMatch[2], res);
      if (method === "DELETE") return this.handleDeleteSession(user, wsSessionMatch[2], res);
    }

    // ── Global session routes (permanent — workspace-agnostic) ──

    if (path === "/sessions" && method === "GET") return this.handleListSessions(user, res);
    if (path === "/sessions" && method === "POST") return this.handleCreateSession(user, req, res);

    const stopMatch = path.match(/^\/sessions\/([^/]+)\/stop$/);
    if (stopMatch && method === "POST") return this.handleStopSession(user, stopMatch[1], res);

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
      return this.handleUploadClientLogs(user, clientLogsMatch[1], req, res);
    }

    const sessionMatch = path.match(/^\/sessions\/([^/]+)$/);
    if (sessionMatch) {
      if (method === "GET") return this.handleGetSession(user, sessionMatch[1], res);
      if (method === "DELETE") return this.handleDeleteSession(user, sessionMatch[1], res);
    }

    this.error(res, 404, "Not found");
  }

  // ─── Route Handlers ───

  private handleGetMe(user: User, res: ServerResponse): void {
    this.json(res, { user: user.id, name: user.name });
  }

  private async handleListModels(res: ServerResponse): Promise<void> {
    await this.ctx.refreshModelCatalog();
    this.json(res, { models: this.ctx.getModelCatalog() });
  }

  private handleListSkills(res: ServerResponse): void {
    this.json(res, { skills: this.ctx.skillRegistry.list() });
  }

  private handleRescanSkills(res: ServerResponse): void {
    this.ctx.skillRegistry.scan();
    this.json(res, { skills: this.ctx.skillRegistry.list() });
  }

  private handleListExtensions(res: ServerResponse): void {
    this.json(res, { extensions: listHostExtensions() });
  }

  private handleGetSkillDetail(name: string, res: ServerResponse): void {
    const detail = this.ctx.skillRegistry.getDetail(name);
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

    const content = this.ctx.skillRegistry.getFileContent(name, filePath);
    if (content === undefined) {
      this.error(res, 404, "File not found");
      return;
    }
    this.json(res, { content });
  }

  // ─── User Skills CRUD ───

  private handleListUserSkills(user: User, res: ServerResponse): void {
    const builtIn = this.ctx.skillRegistry.list().map((s) => ({
      ...s,
      builtIn: true as const,
    }));
    const userSkills = this.ctx.userSkillStore.listSkills(user.id);
    this.json(res, { skills: [...builtIn, ...userSkills] });
  }

  private handleGetUserSkill(user: User, name: string, res: ServerResponse): void {
    const userSkill = this.ctx.userSkillStore.getSkill(user.id, name);
    if (userSkill) {
      const files = this.ctx.userSkillStore.listFiles(user.id, name);
      this.json(res, { skill: userSkill, files });
      return;
    }

    const builtIn = this.ctx.skillRegistry.getDetail(name);
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

    const session = this.ctx.storage.getSession(user.id, body.sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const workRoot = this.resolveWorkRoot(session, user.id);
    if (!workRoot) {
      this.error(res, 404, "No workspace root for session");
      return;
    }

    const relPath = body.path ?? body.name;
    const sourceDir = resolve(workRoot, relPath);

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
      const skill = this.ctx.userSkillStore.saveSkill(user.id, body.name, resolvedSource);
      this.ctx.skillRegistry.registerUserSkills([skill]);
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
    const builtIn = this.ctx.skillRegistry.get(name);
    const userSkill = this.ctx.userSkillStore.getSkill(user.id, name);

    if (!userSkill) {
      if (builtIn) {
        this.error(res, 403, "Cannot delete built-in skill");
        return;
      }
      this.error(res, 404, "Skill not found");
      return;
    }

    this.ctx.userSkillStore.deleteSkill(user.id, name);
    res.writeHead(204).end();
  }

  private handleGetUserSkillFile(user: User, name: string, url: URL, res: ServerResponse): void {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const content =
      this.ctx.userSkillStore.readFile(user.id, name, filePath) ??
      this.ctx.skillRegistry.getFileContent(name, filePath);

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
    this.ctx.storage.ensureDefaultWorkspaces(user.id);
    const workspaces = this.ctx.storage.listWorkspaces(user.id);
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

    const unknown = body.skills.filter((s) => !this.ctx.skillRegistry.get(s));
    if (unknown.length > 0) {
      this.error(res, 400, `Unknown skills: ${unknown.join(", ")}`);
      return;
    }

    if (body.memoryNamespace && !this.ctx.isValidMemoryNamespace(body.memoryNamespace)) {
      this.error(res, 400, "memoryNamespace must match [a-zA-Z0-9][a-zA-Z0-9._-]{0,63}");
      return;
    }

    if (body.extensionMode && body.extensionMode !== "legacy" && body.extensionMode !== "explicit") {
      this.error(res, 400, 'extensionMode must be "legacy" or "explicit"');
      return;
    }

    if (body.extensions !== undefined) {
      if (!Array.isArray(body.extensions)) {
        this.error(res, 400, "extensions must be an array");
        return;
      }

      const invalid = body.extensions.filter(
        (name) => typeof name !== "string" || !isValidExtensionName(name),
      );
      if (invalid.length > 0) {
        this.error(res, 400, `Invalid extension names: ${invalid.join(", ")}`);
        return;
      }
    }

    const workspace = this.ctx.storage.createWorkspace(user.id, body);
    this.json(res, { workspace }, 201);
  }

  private handleGetWorkspace(user: User, wsId: string, res: ServerResponse): void {
    const workspace = this.ctx.storage.getWorkspace(user.id, wsId);
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
    const workspace = this.ctx.storage.getWorkspace(user.id, wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const body = await this.parseBody<UpdateWorkspaceRequest>(req);

    if (body.skills) {
      const unknown = body.skills.filter((s) => !this.ctx.skillRegistry.get(s));
      if (unknown.length > 0) {
        this.error(res, 400, `Unknown skills: ${unknown.join(", ")}`);
        return;
      }
    }

    if (body.memoryNamespace && !this.ctx.isValidMemoryNamespace(body.memoryNamespace)) {
      this.error(res, 400, "memoryNamespace must match [a-zA-Z0-9][a-zA-Z0-9._-]{0,63}");
      return;
    }

    if (body.extensionMode && body.extensionMode !== "legacy" && body.extensionMode !== "explicit") {
      this.error(res, 400, 'extensionMode must be "legacy" or "explicit"');
      return;
    }

    if (body.extensions !== undefined) {
      if (!Array.isArray(body.extensions)) {
        this.error(res, 400, "extensions must be an array");
        return;
      }

      const invalid = body.extensions.filter(
        (name) => typeof name !== "string" || !isValidExtensionName(name),
      );
      if (invalid.length > 0) {
        this.error(res, 400, `Invalid extension names: ${invalid.join(", ")}`);
        return;
      }
    }

    const updated = this.ctx.storage.updateWorkspace(user.id, wsId, body);
    this.json(res, { workspace: updated });
  }

  private handleDeleteWorkspace(user: User, wsId: string, res: ServerResponse): void {
    this.ctx.storage.deleteWorkspace(user.id, wsId);
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
      this.ctx.storage.setLiveActivityToken(user.id, body.deviceToken);
      console.log(`[push] Live Activity token registered for ${user.name}`);
    } else {
      this.ctx.storage.addDeviceToken(user.id, body.deviceToken);
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
      this.ctx.storage.removeDeviceToken(user.id, body.deviceToken);
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
    const session = this.ctx.storage.getSession(user.id, sessionId);
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
          message: typeof entry.message === "string" ? entry.message.slice(0, maxMessageChars) : "",
          metadata,
        };
      })
      .filter((entry) => entry.message.length > 0);

    if (entries.length === 0) {
      this.error(res, 400, "No valid log entries");
      return;
    }

    const logsDir = join(this.ctx.storage.getDataDir(), "client-logs", user.id);
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
      buildNumber: typeof body.buildNumber === "string" ? body.buildNumber.slice(0, 64) : undefined,
      osVersion: typeof body.osVersion === "string" ? body.osVersion.slice(0, 128) : undefined,
      deviceModel: typeof body.deviceModel === "string" ? body.deviceModel.slice(0, 64) : undefined,
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
    const sessions = this.ctx.storage
      .listUserSessions(user.id)
      .map((session) => this.ctx.ensureSessionContextWindow(session));
    this.json(res, { sessions });
  }

  private async handleCreateSession(
    user: User,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<CreateSessionRequest>(req);

    this.ctx.storage.ensureDefaultWorkspaces(user.id);
    let workspace: Workspace | undefined;

    if (body.workspaceId) {
      workspace = this.ctx.storage.getWorkspace(user.id, body.workspaceId);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    } else {
      workspace = this.ctx.storage.listWorkspaces(user.id)[0];
    }

    const model = body.model || workspace?.defaultModel;
    const session = this.ctx.storage.createSession(user.id, body.name, model);

    if (workspace) {
      session.workspaceId = workspace.id;
      session.workspaceName = workspace.name;
      session.runtime = workspace.runtime;
      this.ctx.storage.saveSession(session);
    }

    const hydrated = this.ctx.ensureSessionContextWindow(session);
    this.json(res, { session: hydrated }, 201);
  }

  // ─── Workspace-scoped session handlers (v2 API) ───

  private handleListWorkspaceSessions(user: User, workspaceId: string, res: ServerResponse): void {
    const workspace = this.ctx.storage.getWorkspace(user.id, workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const sessions = this.ctx.storage
      .listUserSessions(user.id)
      .filter((s) => s.workspaceId === workspaceId)
      .map((s) => this.ctx.ensureSessionContextWindow(s));

    this.json(res, { sessions, workspace });
  }

  private async handleCreateWorkspaceSession(
    user: User,
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(user.id, workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const body = await this.parseBody<{ name?: string; model?: string }>(req);
    const model = body.model || workspace.defaultModel;
    const session = this.ctx.storage.createSession(user.id, body.name, model);

    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.runtime = workspace.runtime;
    this.ctx.storage.saveSession(session);

    const hydrated = this.ctx.ensureSessionContextWindow(session);
    this.json(res, { session: hydrated }, 201);
  }

  private async handleResumeWorkspaceSession(
    user: User,
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(user.id, workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const session = this.ctx.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    if (session.workspaceId !== workspaceId) {
      this.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    if (this.ctx.sessions.isActive(user.id, sessionId)) {
      const active = this.ctx.sessions.getActiveSession(user.id, sessionId);
      const hydrated = active ? this.ctx.ensureSessionContextWindow(active) : session;
      this.json(res, { session: hydrated });
      return;
    }

    try {
      const started = await this.ctx.sessions.startSession(
        user.id,
        sessionId,
        user.name,
        workspace,
      );
      const hydrated = this.ctx.ensureSessionContextWindow(started);
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
    const session = this.ctx.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const hydratedSession = this.ctx.ensureSessionContextWindow(session);

    if (this.ctx.sessions.isActive(user.id, sessionId)) {
      await this.ctx.sessions.stopSession(user.id, sessionId);
    } else {
      hydratedSession.status = "stopped";
      hydratedSession.lastActivity = Date.now();
      this.ctx.storage.saveSession(hydratedSession);
    }

    const updatedSession = this.ctx.storage.getSession(user.id, sessionId);
    const hydratedUpdated = updatedSession
      ? this.ctx.ensureSessionContextWindow(updatedSession)
      : updatedSession;
    this.json(res, { ok: true, session: hydratedUpdated });
  }

  // ─── Tool Output by ID ───

  private handleGetToolOutput(
    user: User,
    sessionId: string,
    toolCallId: string,
    res: ServerResponse,
  ): void {
    const session = this.ctx.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const jsonlPaths: string[] = [];
    const sandboxBaseDir = this.ctx.sandbox.getBaseDir();

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

  private handleGetSessionFile(user: User, sessionId: string, url: URL, res: ServerResponse): void {
    const session = this.ctx.storage.getSession(user.id, sessionId);
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

  private handleGetSessionOverallDiff(
    user: User,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const session = this.ctx.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const reqPath = url.searchParams.get("path")?.trim();
    if (!reqPath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const trace = this.loadSessionTrace(user.id, session);
    if (!trace || trace.length === 0) {
      this.error(res, 404, "Session trace not found");
      return;
    }

    const mutations = collectFileMutations(trace, reqPath);

    if (mutations.length === 0) {
      this.error(res, 404, "No file mutations found for path");
      return;
    }

    const currentText = this.readCurrentFileText(session, user.id, reqPath);
    const baselineText = reconstructBaselineFromCurrent(currentText, mutations);
    const diffLines = computeDiffLines(baselineText, currentText);
    const stats = computeLineDiffStatsFromLines(diffLines);

    this.json(res, {
      path: reqPath,
      revisionCount: mutations.length,
      baselineText,
      currentText,
      diffLines,
      addedLines: stats.added,
      removedLines: stats.removed,
      cacheKey: `${sessionId}:${reqPath}:${mutations[mutations.length - 1]?.id ?? "none"}`,
    });
  }

  private readCurrentFileText(session: Session, userId: string, reqPath: string): string {
    const workRoot = this.resolveWorkRoot(session, userId);
    if (!workRoot) return "";

    const target = resolve(workRoot, reqPath);
    try {
      const resolved = realpathSync(target);
      const realWorkRoot = realpathSync(workRoot);
      if (!resolved.startsWith(realWorkRoot + "/") && resolved !== realWorkRoot) {
        return "";
      }
      const stat = statSync(resolved);
      if (!stat.isFile() || stat.size > 10 * 1024 * 1024) return "";
      return readFileSync(resolved, "utf8");
    } catch {
      return "";
    }
  }

  private loadSessionTrace(userId: string, session: Session) {
    const sandboxBaseDir = this.ctx.sandbox.getBaseDir();
    let trace = readSessionTrace(sandboxBaseDir, userId, session.id, session.workspaceId);

    if ((!trace || trace.length === 0) && session.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(session.piSessionFiles);
    }
    if ((!trace || trace.length === 0) && session.piSessionFile) {
      trace = readSessionTraceFromFile(session.piSessionFile);
    }
    if ((!trace || trace.length === 0) && session.piSessionId) {
      trace = readSessionTraceByUuid(sandboxBaseDir, userId, session.piSessionId, session.workspaceId);
    }

    return trace;
  }

  private resolveWorkRoot(session: Session, userId: string): string | null {
    const workspace = session.workspaceId
      ? this.ctx.storage.getWorkspace(userId, session.workspaceId)
      : undefined;

    if (session.runtime === "container") {
      if (workspace?.hostMount) {
        const resolved = workspace.hostMount.replace(/^~/, homedir());
        return existsSync(resolved) ? resolved : null;
      }
      if (session.workspaceId) {
        const workspaceSandbox = join(
          this.ctx.sandbox.getBaseDir(),
          userId,
          session.workspaceId,
          "workspace",
        );
        if (existsSync(workspaceSandbox)) {
          return workspaceSandbox;
        }
      }

      const sandboxWork = join(this.ctx.sandbox.getBaseDir(), userId, session.id, "workspace");
      return existsSync(sandboxWork) ? sandboxWork : null;
    }

    if (workspace?.hostMount) {
      const resolved = workspace.hostMount.replace(/^~/, homedir());
      return existsSync(resolved) ? resolved : null;
    }
    return homedir();
  }

  private handleGetUserStreamEvents(user: User, url: URL, res: ServerResponse): void {
    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      this.error(res, 400, "since must be a non-negative integer");
      return;
    }

    const catchUp = this.ctx.streamMux.getUserStreamCatchUp(user.id, sinceSeq);

    this.json(res, {
      events: catchUp.events,
      currentSeq: catchUp.currentSeq,
      catchUpComplete: catchUp.catchUpComplete,
    });
  }

  private handleGetPendingPermissions(user: User, url: URL, res: ServerResponse): void {
    const sessionIdFilter = url.searchParams.get("sessionId") || undefined;
    const workspaceIdFilter = url.searchParams.get("workspaceId") || undefined;

    if (sessionIdFilter) {
      const session = this.ctx.storage.getSession(user.id, sessionIdFilter);
      if (!session) {
        this.error(res, 404, "Session not found");
        return;
      }
    }

    if (workspaceIdFilter) {
      const workspace = this.ctx.storage.getWorkspace(user.id, workspaceIdFilter);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    }

    const serverTime = Date.now();
    const pending = this.ctx.gate
      .getPendingForUser(user.id)
      .filter((decision) => decision.timeoutAt > serverTime)
      .filter((decision) => !sessionIdFilter || decision.sessionId === sessionIdFilter)
      .filter((decision) => !workspaceIdFilter || decision.workspaceId === workspaceIdFilter)
      .map((decision) => ({
        id: decision.id,
        sessionId: decision.sessionId,
        workspaceId: decision.workspaceId,
        tool: decision.tool,
        input: decision.input,
        displaySummary: decision.displaySummary,
        risk: decision.risk,
        reason: decision.reason,
        timeoutAt: decision.timeoutAt,
        resolutionOptions: decision.resolutionOptions,
      }));

    this.json(res, {
      pending,
      serverTime,
    });
  }

  private handleGetSessionEvents(
    user: User,
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const session = this.ctx.storage.getSession(user.id, sessionId);
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

    const catchUp = this.ctx.sessions.getCatchUp(user.id, sessionId, sinceSeq);
    if (!catchUp) {
      this.error(res, 404, "Session not active");
      return;
    }

    this.json(res, {
      events: catchUp.events,
      currentSeq: catchUp.currentSeq,
      session: this.ctx.ensureSessionContextWindow(catchUp.session),
      catchUpComplete: catchUp.catchUpComplete,
    });
  }

  private async handleGetSession(
    user: User,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.ctx.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const hydratedSession = this.ctx.ensureSessionContextWindow(session);
    const sandboxBaseDir = this.ctx.sandbox.getBaseDir();

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

    if (!trace || trace.length === 0) {
      const live = await this.ctx.sessions.refreshSessionState(user.id, sessionId);
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

      const refreshed = this.ctx.storage.getSession(user.id, sessionId);
      if (refreshed) {
        this.ctx.ensureSessionContextWindow(refreshed);
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

    const latestSession = this.ctx.storage.getSession(user.id, sessionId) || hydratedSession;
    const hydratedLatest = this.ctx.ensureSessionContextWindow(latestSession);
    this.json(res, { session: hydratedLatest, trace: trace || [] });
  }

  private async handleDeleteSession(
    user: User,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.ctx.storage.getSession(user.id, sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    await this.ctx.sessions.stopSession(user.id, sessionId);
    this.ctx.storage.deleteSession(user.id, sessionId);
    this.json(res, { ok: true });
  }

  // ─── HTTP Utilities ───

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
