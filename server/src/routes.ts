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
  unlinkSync,
} from "node:fs";
import { join, resolve, extname } from "node:path";
import { homedir, hostname } from "node:os";
import type { Storage } from "./storage.js";
import type { SessionManager } from "./sessions.js";
import type { GateServer } from "./gate.js";
import type { SkillRegistry, UserSkillStore } from "./skills.js";
import type { UserStreamMux } from "./stream.js";
import {
  readSessionTrace,
  readSessionTraceByUuid,
  readSessionTraceFromFile,
  readSessionTraceFromFiles,
  findToolOutput,
  type TraceViewMode,
} from "./trace.js";
import { PolicyEngine, defaultPolicy, type PathAccess } from "./policy.js";
import {
  collectFileMutations,
  reconstructBaselineFromCurrent,
  computeDiffLines,
  computeLineDiffStatsFromLines,
} from "./overall-diff.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import { buildWorkspaceGraph } from "./graph.js";
import { discoverProjects, scanDirectories } from "./host.js";
import { isValidExtensionName, listHostExtensions } from "./extension-loader.js";
import {
  discoverLocalSessions,
  invalidateLocalSessionsCache,
  validateLocalSessionPath,
  validateCwdAlignment,
} from "./local-sessions.js";
import { getGitStatus } from "./git-status.js";
import type { Rule } from "./rules.js";
import type { AuditEntry } from "./audit.js";
import type {
  Session,
  Workspace,
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  RegisterDeviceTokenRequest,
  PairDeviceRequest,
  ClientLogUploadRequest,
  ApiError,
  PolicyPermission,
  PolicyDecision,
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
  skillRegistry: SkillRegistry;
  userSkillStore: UserSkillStore;
  streamMux: UserStreamMux;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  isValidMemoryNamespace: (ns: string) => boolean;
  refreshModelCatalog: () => Promise<void>;
  getModelCatalog: () => ModelInfo[];
  serverStartedAt: number;
  serverVersion: string;
  piVersion: string;
}

// ─── Route Handler ───

export class RouteHandler {
  private static readonly PAIRING_MAX_FAILURES = 5;
  private static readonly PAIRING_WINDOW_MS = 60_000;
  private static readonly PAIRING_COOLDOWN_MS = 120_000;

  private pairingFailuresBySource = new Map<string, number[]>();
  private pairingBlockedUntilBySource = new Map<string, number>();

  constructor(private ctx: RouteContext) {}

  /**
   * Dispatch an authenticated HTTP request to the appropriate handler.
   * Called by Server after CORS, OPTIONS, /health, and auth checks.
   */
  async dispatch(
    method: string,
    path: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    // Static routes
    if (path === "/stream/events" && method === "GET")
      return this.handleGetUserStreamEvents(url, res);
    if (path === "/permissions/pending" && method === "GET")
      return this.handleGetPendingPermissions(url, res);
    if (path === "/policy/rules" && method === "GET")
      return this.handleGetPolicyRules(url, res);
    if (path.startsWith("/policy/rules/") && method === "PATCH")
      return this.handlePatchPolicyRule(path, req, res);
    if (path.startsWith("/policy/rules/") && method === "DELETE")
      return this.handleDeletePolicyRule(path, res);
    if (path === "/policy/audit" && method === "GET")
      return this.handleGetPolicyAudit(url, res);
    if (path === "/pair" && method === "POST")
      return this.handlePair(req, res);
    if (path === "/me" && method === "GET") return this.handleGetMe(res);
    if (path === "/server/info" && method === "GET") return this.handleGetServerInfo(res);
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

    // Local pi sessions (TUI-started, not managed by oppi)
    if (path === "/local-sessions" && method === "GET")
      return this.handleListLocalSessions(res);

    // Workspaces
    if (path === "/workspaces" && method === "GET") return this.handleListWorkspaces(res);
    if (path === "/workspaces" && method === "POST")
      return this.handleCreateWorkspace(req, res);

    const wsMatch = path.match(/^\/workspaces\/([^/]+)$/);
    if (wsMatch) {
      if (method === "GET") return this.handleGetWorkspace(wsMatch[1], res);
      if (method === "PUT") return this.handleUpdateWorkspace(wsMatch[1], req, res);
      if (method === "DELETE") return this.handleDeleteWorkspace(wsMatch[1], res);
    }

    const wsPolicyMatch = path.match(/^\/workspaces\/([^/]+)\/policy$/);
    if (wsPolicyMatch) {
      if (method === "GET") return this.handleGetWorkspacePolicy(wsPolicyMatch[1], res);
      if (method === "PATCH") return this.handlePatchWorkspacePolicy(wsPolicyMatch[1], req, res);
    }

    const wsPolicyPermissionDeleteMatch = path.match(
      /^\/workspaces\/([^/]+)\/policy\/permissions\/([^/]+)$/,
    );
    if (wsPolicyPermissionDeleteMatch && method === "DELETE") {
      return this.handleDeleteWorkspacePolicyPermission(
        wsPolicyPermissionDeleteMatch[1],
        decodeURIComponent(wsPolicyPermissionDeleteMatch[2]),
        res,
      );
    }

    const wsGitStatusMatch = path.match(/^\/workspaces\/([^/]+)\/git-status$/);
    if (wsGitStatusMatch && method === "GET") {
      return this.handleGetWorkspaceGitStatus(wsGitStatusMatch[1], res);
    }

    const wsGraphMatch = path.match(/^\/workspaces\/([^/]+)\/graph$/);
    if (wsGraphMatch && method === "GET") {
      return this.handleGetWorkspaceGraph(wsGraphMatch[1], url, res);
    }

    // Device tokens
    if (path === "/me/device-token" && method === "POST")
      return this.handleRegisterDeviceToken(req, res);
    if (path === "/me/device-token" && method === "DELETE")
      return this.handleDeleteDeviceToken(req, res);

    // User skills CRUD
    if (path === "/me/skills" && method === "GET") return this.handleListUserSkills(res);
    if (path === "/me/skills" && method === "POST") return this.handleSaveUserSkill(req, res);

    const userSkillFileMatch = path.match(/^\/me\/skills\/([^/]+)\/files$/);
    if (userSkillFileMatch && method === "GET")
      return this.handleGetUserSkillFile(userSkillFileMatch[1], url, res);

    const userSkillMatch = path.match(/^\/me\/skills\/([^/]+)$/);
    if (userSkillMatch) {
      if (method === "GET") return this.handleGetUserSkill(userSkillMatch[1], res);
      if (method === "PUT")
        return this.handlePutUserSkill(userSkillMatch[1], req, res);
      if (method === "DELETE") return this.handleDeleteUserSkill(userSkillMatch[1], res);
    }

    // ── Workspace-scoped session routes (v2 API) ──

    const wsSessionsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions$/);
    if (wsSessionsMatch) {
      if (method === "GET") return this.handleListWorkspaceSessions(wsSessionsMatch[1], res);
      if (method === "POST")
        return this.handleCreateWorkspaceSession(wsSessionsMatch[1], req, res);
    }

    const wsSessionStopMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/stop$/);
    if (wsSessionStopMatch && method === "POST") {
      return this.handleStopSession(wsSessionStopMatch[2], res);
    }

    const wsSessionClientLogsMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/client-logs$/,
    );
    if (wsSessionClientLogsMatch && method === "POST") {
      return this.handleUploadClientLogs(wsSessionClientLogsMatch[2], req, res);
    }

    const wsSessionResumeMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/resume$/);
    if (wsSessionResumeMatch && method === "POST") {
      return this.handleResumeWorkspaceSession(
        wsSessionResumeMatch[1],
        wsSessionResumeMatch[2],
        res,
      );
    }

    const wsSessionForkMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/fork$/);
    if (wsSessionForkMatch && method === "POST") {
      return this.handleForkWorkspaceSession(
        wsSessionForkMatch[1],
        wsSessionForkMatch[2],
        req,
        res,
      );
    }

    const wsSessionToolOutputMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/tool-output\/([^/]+)$/,
    );
    if (wsSessionToolOutputMatch && method === "GET") {
      return this.handleGetToolOutput(
        wsSessionToolOutputMatch[2],
        wsSessionToolOutputMatch[3],
        res,
      );
    }

    const wsSessionFilesMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/files$/);
    if (wsSessionFilesMatch && method === "GET") {
      return this.handleGetSessionFile(wsSessionFilesMatch[2], url, res);
    }

    const wsSessionOverallDiffMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/overall-diff$/,
    );
    if (wsSessionOverallDiffMatch && method === "GET") {
      return this.handleGetSessionOverallDiff(wsSessionOverallDiffMatch[2], url, res);
    }

    const wsSessionEventsMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/events$/);
    if (wsSessionEventsMatch && method === "GET") {
      return this.handleGetSessionEvents(wsSessionEventsMatch[2], url, res);
    }

    const wsSessionMatch = path.match(/^\/workspaces\/([^/]+)\/sessions\/([^/]+)$/);
    if (wsSessionMatch) {
      if (method === "GET") return this.handleGetSession(wsSessionMatch[2], url, res);
      if (method === "DELETE") return this.handleDeleteSession(wsSessionMatch[2], res);
    }

    // ─── Theme routes ───

    if (path === "/themes" && method === "GET") {
      return this.handleListThemes(res);
    }

    const themeMatch = path.match(/^\/themes\/([^/]+)$/);
    if (themeMatch) {
      const themeName = decodeURIComponent(themeMatch[1]);
      if (method === "GET") return this.handleGetTheme(themeName, res);
      if (method === "PUT") return this.handlePutTheme(themeName, req, res);
      if (method === "DELETE") return this.handleDeleteTheme(themeName, res);
    }

    this.error(res, 404, "Not found");
  }

  // ─── Route Handlers ───

  private pairingSourceKey(req: IncomingMessage): string {
    return req.socket.remoteAddress || "unknown";
  }

  private isPairingRateLimited(source: string, now: number): boolean {
    const blockedUntil = this.pairingBlockedUntilBySource.get(source) || 0;
    if (blockedUntil > now) {
      return true;
    }

    if (blockedUntil > 0 && blockedUntil <= now) {
      this.pairingBlockedUntilBySource.delete(source);
      this.pairingFailuresBySource.delete(source);
    }

    return false;
  }

  private recordPairingFailure(source: string, now: number): void {
    const windowStart = now - RouteHandler.PAIRING_WINDOW_MS;
    const failures = (this.pairingFailuresBySource.get(source) || []).filter((ts) => ts >= windowStart);
    failures.push(now);
    this.pairingFailuresBySource.set(source, failures);

    if (failures.length >= RouteHandler.PAIRING_MAX_FAILURES) {
      this.pairingBlockedUntilBySource.set(source, now + RouteHandler.PAIRING_COOLDOWN_MS);
    }
  }

  private clearPairingFailures(source: string): void {
    this.pairingFailuresBySource.delete(source);
    this.pairingBlockedUntilBySource.delete(source);
  }

  private async handlePair(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const source = this.pairingSourceKey(req);
    const now = Date.now();
    if (this.isPairingRateLimited(source, now)) {
      this.error(res, 429, "Too many invalid pairing attempts. Try again later.");
      return;
    }

    const body = await this.parseBody<PairDeviceRequest>(req);
    const pairingToken = typeof body.pairingToken === "string" ? body.pairingToken.trim() : "";

    if (!pairingToken) {
      this.error(res, 400, "pairingToken required");
      return;
    }

    const deviceToken = this.ctx.storage.consumePairingToken(pairingToken);
    if (!deviceToken) {
      this.recordPairingFailure(source, now);
      this.error(res, 401, "Invalid or expired pairing token");
      return;
    }

    this.clearPairingFailures(source);
    this.json(res, { deviceToken });
  }

  private handleGetMe(res: ServerResponse): void {
    // Keep a stable single-user identifier for iOS decode compatibility.
    this.json(res, {
      user: "owner",
      name: this.ctx.storage.getOwnerName(),
    });
  }

  private handleGetServerInfo(res: ServerResponse): void {
    const config = this.ctx.storage.getConfig();
    const workspaces = this.ctx.storage.listWorkspaces();
    const sessions = this.ctx.storage.listSessions();
    const activeSessions = sessions.filter(
      (s) => s.status !== "stopped" && s.status !== "error",
    );

    const uptimeSeconds = Math.floor((Date.now() - this.ctx.serverStartedAt) / 1000);

    let identity: { fingerprint: string; keyId: string; algorithm: "ed25519" } | null = null;
    try {
      const material = ensureIdentityMaterial(identityConfigForDataDir(this.ctx.storage.getDataDir()));
      identity = {
        fingerprint: material.fingerprint,
        keyId: material.keyId,
        algorithm: material.algorithm,
      };
    } catch {
      identity = null;
    }

    this.json(res, {
      name: hostname(),
      version: this.ctx.serverVersion,
      uptime: uptimeSeconds,
      os: process.platform,
      arch: process.arch,
      hostname: hostname(),
      nodeVersion: process.version,
      piVersion: this.ctx.piVersion,
      configVersion: config.configVersion ?? 1,
      identity,
      stats: {
        workspaceCount: workspaces.length,
        activeSessionCount: activeSessions.length,
        totalSessionCount: sessions.length,
        skillCount: this.ctx.skillRegistry.list().length,
        modelCount: this.ctx.getModelCatalog().length,
      },
    });
  }

  private async handleListModels(res: ServerResponse): Promise<void> {
    await this.ctx.refreshModelCatalog();
    this.json(res, { models: this.ctx.getModelCatalog() });
  }

  private handleListSkills(res: ServerResponse): void {
    this.json(res, { skills: this.ctx.skillRegistry.list() });
  }

  private handleRescanSkills(res: ServerResponse): void {
    const event = this.ctx.skillRegistry.scan();
    this.json(res, { skills: this.ctx.skillRegistry.list(), changed: event });
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

  // ─── User Skills (read-only; mutation disabled) ───

  private handleListUserSkills(res: ServerResponse): void {
    // Build enabledIn map: skill name → workspace IDs
    const workspaces = this.ctx.storage.listWorkspaces();
    const enabledIn = new Map<string, string[]>();
    for (const ws of workspaces) {
      for (const skill of ws.skills) {
        const list = enabledIn.get(skill) || [];
        list.push(ws.id);
        enabledIn.set(skill, list);
      }
    }

    const builtIn = this.ctx.skillRegistry.list().map((s) => ({
      ...s,
      builtIn: true as const,
      enabledIn: enabledIn.get(s.name) || [],
    }));
    const userSkills = this.ctx.userSkillStore.listSkills().map((s) => ({
      ...s,
      enabledIn: enabledIn.get(s.name) || [],
    }));
    this.json(res, { skills: [...builtIn, ...userSkills] });
  }

  private handleGetUserSkill(name: string, res: ServerResponse): void {
    const userSkill = this.ctx.userSkillStore.getSkill(name);
    if (userSkill) {
      const files = this.ctx.userSkillStore.listFiles(name);
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
    _req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    this.error(res, 403, "Skill editing is disabled on remote clients");
  }

  /**
   * PUT /me/skills/:name
   *
   * Skill mutation is intentionally disabled for remote clients.
   */
  private async handlePutUserSkill(
    _name: string,
    _req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    this.error(res, 403, "Skill editing is disabled on remote clients");
  }

  private handleDeleteUserSkill(_name: string, res: ServerResponse): void {
    this.error(res, 403, "Skill editing is disabled on remote clients");
  }

  private handleGetUserSkillFile(name: string, url: URL, res: ServerResponse): void {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const content =
      this.ctx.userSkillStore.readFile(name, filePath) ??
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

  private async handleListLocalSessions(res: ServerResponse): Promise<void> {
    // Collect piSessionFile paths already tracked by oppi to filter them out
    const allSessions = this.ctx.storage.listSessions();
    const knownFiles = new Set<string>();
    for (const session of allSessions) {
      if (session.piSessionFile) knownFiles.add(session.piSessionFile);
      for (const f of session.piSessionFiles ?? []) knownFiles.add(f);
    }

    const localSessions = await discoverLocalSessions(knownFiles);
    this.json(res, { sessions: localSessions });
  }

  private handleListWorkspaces(res: ServerResponse): void {
    this.ctx.storage.ensureDefaultWorkspaces();
    const workspaces = this.ctx.storage.listWorkspaces();
    this.json(res, { workspaces });
  }

  private async handleCreateWorkspace(
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

    if (body.policy?.fallback !== undefined) {
      if (
        body.policy.fallback !== "allow" &&
        body.policy.fallback !== "ask" &&
        body.policy.fallback !== "block"
      ) {
        this.error(res, 400, "policy.fallback must be one of allow|ask|block");
        return;
      }
    }

    if (body.policy?.permissions) {
      for (const permission of body.policy.permissions) {
        const validationError = this.validateWorkspacePolicyPermission(permission);
        if (validationError) {
          this.error(res, 400, validationError);
          return;
        }

        const additiveError = this.validateAdditiveWorkspacePermission(permission);
        if (additiveError) {
          this.error(res, 400, additiveError);
          return;
        }
      }
    }

    const workspace = this.ctx.storage.createWorkspace(body);
    this.json(res, { workspace }, 201);
  }

  private handleGetWorkspace(wsId: string, res: ServerResponse): void {
    const workspace = this.ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }
    this.json(res, { workspace });
  }

  private async handleUpdateWorkspace(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(wsId);
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

    if (body.policy?.fallback !== undefined) {
      if (
        body.policy.fallback !== "allow" &&
        body.policy.fallback !== "ask" &&
        body.policy.fallback !== "block"
      ) {
        this.error(res, 400, "policy.fallback must be one of allow|ask|block");
        return;
      }
    }

    if (body.policy?.permissions) {
      for (const permission of body.policy.permissions) {
        const validationError = this.validateWorkspacePolicyPermission(permission);
        if (validationError) {
          this.error(res, 400, validationError);
          return;
        }

        const additiveError = this.validateAdditiveWorkspacePermission(permission);
        if (additiveError) {
          this.error(res, 400, additiveError);
          return;
        }
      }
    }

    const updated = this.ctx.storage.updateWorkspace(wsId, body);
    if (!updated) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    this.json(res, { workspace: updated });
  }

  private handleDeleteWorkspace(wsId: string, res: ServerResponse): void {
    this.ctx.storage.deleteWorkspace(wsId);
    this.json(res, { ok: true });
  }

  private async handleGetWorkspaceGitStatus(wsId: string, res: ServerResponse): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    if (!workspace.hostMount) {
      this.json(res, {
        isGitRepo: false,
        branch: null,
        headSha: null,
        ahead: null,
        behind: null,
        dirtyCount: 0,
        untrackedCount: 0,
        stagedCount: 0,
        files: [],
        totalFiles: 0,
        stashCount: 0,
        lastCommitMessage: null,
        lastCommitDate: null,
      });
      return;
    }

    const status = await getGitStatus(workspace.hostMount);
    this.json(res, status as unknown as Record<string, unknown>);
  }

  private handleGetWorkspacePolicy(wsId: string, res: ServerResponse): void {
    const workspace = this.ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const globalPolicy = this.ctx.storage.getConfig().policy;
    const workspacePolicy = workspace.policy || { permissions: [] };

    this.json(res, {
      workspaceId: wsId,
      globalPolicy,
      workspacePolicy,
      effectivePolicy: {
        fallback: workspacePolicy.fallback ?? globalPolicy?.fallback ?? "ask",
        guardrails: globalPolicy?.guardrails ?? [],
        permissions: [...(globalPolicy?.permissions ?? []), ...workspacePolicy.permissions],
      },
    });
  }

  private refreshActiveWorkspaceSessionPolicies(workspace: Workspace): void {
    const sessions = this.ctx.storage.listSessions();

    const cwd = workspace.hostMount ? workspace.hostMount.replace(/^~/, homedir()) : homedir();
    const allowedPaths: PathAccess[] = [
      { path: cwd, access: "readwrite" },
      { path: join(homedir(), ".pi"), access: "read" },
    ];

    if (workspace.allowedPaths) {
      for (const entry of workspace.allowedPaths) {
        allowedPaths.push({
          path: entry.path.replace(/^~/, homedir()),
          access: entry.access,
        });
      }
    }

    const globalPolicy = this.ctx.storage.getConfig().policy;
    const mergedGlobalPolicy = globalPolicy
      ? {
          ...globalPolicy,
          fallback: workspace.policy?.fallback ?? globalPolicy.fallback,
          permissions: [...globalPolicy.permissions, ...(workspace.policy?.permissions || [])],
        }
      : undefined;

    const policySource = mergedGlobalPolicy || defaultPolicy();
    const allowedExecutables = workspace.allowedExecutables;

    let refreshed = 0;

    for (const session of sessions) {
      if (session.workspaceId !== workspace.id) continue;
      if (!this.ctx.sessions.isActive(session.id)) continue;

      this.ctx.gate.setSessionPolicy(
        session.id,
        new PolicyEngine(policySource, { allowedPaths, allowedExecutables }),
      );
      refreshed += 1;
    }

    if (refreshed > 0) {
      console.log(
        `${ts()} [policy] refreshed session policy for workspace ${workspace.id} (${refreshed} active session${refreshed === 1 ? "" : "s"})`,
      );
    }
  }

  private async handlePatchWorkspacePolicy(
    wsId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const body = await this.parseBody<{
      permissions?: PolicyPermission[];
      fallback?: PolicyDecision;
    }>(req);

    const hasPermissions = Object.prototype.hasOwnProperty.call(body, "permissions");
    const hasFallback = Object.prototype.hasOwnProperty.call(body, "fallback");

    if (!hasPermissions && !hasFallback) {
      this.error(res, 400, "permissions or fallback must be provided");
      return;
    }

    if (hasPermissions && !Array.isArray(body.permissions)) {
      this.error(res, 400, "permissions must be an array when provided");
      return;
    }

    let fallback = workspace.policy?.fallback;
    if (hasFallback) {
      if (body.fallback !== "allow" && body.fallback !== "ask" && body.fallback !== "block") {
        this.error(res, 400, "fallback must be one of allow|ask|block");
        return;
      }
      fallback = body.fallback;
    }

    const incomingPermissions = body.permissions || [];
    for (const permission of incomingPermissions) {
      const validationError = this.validateWorkspacePolicyPermission(permission);
      if (validationError) {
        this.error(res, 400, validationError);
        return;
      }

      const additiveError = this.validateAdditiveWorkspacePermission(permission);
      if (additiveError) {
        this.error(res, 400, additiveError);
        return;
      }
    }

    const existing = workspace.policy?.permissions || [];
    const mergedById = new Map<string, PolicyPermission>();
    for (const permission of existing) mergedById.set(permission.id, permission);
    for (const permission of incomingPermissions) mergedById.set(permission.id, permission);

    const updated = this.ctx.storage.setWorkspacePolicyPermissions(
      wsId,
      Array.from(mergedById.values()),
      fallback,
    );
    if (!updated) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    this.refreshActiveWorkspaceSessionPolicies(updated);

    this.json(res, { workspace: updated, policy: updated.policy || { permissions: [] } });
  }

  private handleDeleteWorkspacePolicyPermission(
    wsId: string,
    permissionId: string,
    res: ServerResponse,
  ): void {
    const workspace = this.ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const updated = this.ctx.storage.deleteWorkspacePolicyPermission(wsId, permissionId);
    if (!updated) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    this.refreshActiveWorkspaceSessionPolicies(updated);

    this.json(res, { workspace: updated, policy: updated.policy || { permissions: [] } });
  }

  private validateWorkspacePolicyPermission(permission: PolicyPermission): string | null {
    if (!permission || typeof permission !== "object") return "permission entry must be an object";
    if (typeof permission.id !== "string" || !/^[a-z0-9][a-z0-9._-]{2,63}$/.test(permission.id)) {
      return "permission.id must be slug-like (3-64 chars)";
    }

    if (!["allow", "ask", "block"].includes(permission.decision)) {
      return `permission ${permission.id}: decision must be one of allow|ask|block`;
    }

    if (!permission.match || typeof permission.match !== "object") {
      return `permission ${permission.id}: match object required`;
    }

    const hasMatchField = [
      permission.match.tool,
      permission.match.executable,
      permission.match.commandMatches,
      permission.match.pathMatches,
      permission.match.pathWithin,
      permission.match.domain,
    ].some((value) => typeof value === "string" && value.trim().length > 0);

    if (!hasMatchField) {
      return `permission ${permission.id}: at least one match field required`;
    }

    return null;
  }

  private permissionMatchKey(permission: PolicyPermission): string {
    const match = permission.match;
    return [
      match.tool || "",
      match.executable || "",
      match.commandMatches || "",
      match.pathMatches || "",
      match.pathWithin || "",
      match.domain || "",
    ].join("|");
  }

  private decisionRank(decision: "allow" | "ask" | "block"): number {
    // Lower is more permissive. Workspace overrides must not reduce strictness.
    if (decision === "allow") return 0;
    if (decision === "ask") return 1;
    return 2;
  }

  private validateAdditiveWorkspacePermission(permission: PolicyPermission): string | null {
    const globalPolicy = this.ctx.storage.getConfig().policy;
    if (!globalPolicy) return null;

    const key = this.permissionMatchKey(permission);

    const matchingGuardrail = globalPolicy.guardrails.find(
      (rule) => this.permissionMatchKey(rule) === key,
    );
    if (matchingGuardrail?.immutable) {
      return `permission ${permission.id}: cannot override immutable global guardrail ${matchingGuardrail.id}`;
    }

    const matchingGlobalPermission = globalPolicy.permissions.find(
      (rule) => this.permissionMatchKey(rule) === key,
    );
    if (!matchingGlobalPermission) return null;

    const requested = this.decisionRank(permission.decision);
    const baseline = this.decisionRank(matchingGlobalPermission.decision);
    if (requested < baseline) {
      return `permission ${permission.id}: cannot weaken global decision ${matchingGlobalPermission.decision} for matching rule ${matchingGlobalPermission.id}`;
    }

    return null;
  }

  private handleGetWorkspaceGraph(
    workspaceId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const workspace = this.ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const sessions = this.ctx.storage
      .listSessions()
      .filter((session) => session.workspaceId === workspaceId);

    const currentSessionId = url.searchParams.get("sessionId") || undefined;
    if (currentSessionId && !sessions.some((session) => session.id === currentSessionId)) {
      this.error(res, 404, "Session not found");
      return;
    }

    const includeParam = url.searchParams.get("include") || "session";
    const includeParts = includeParam
      .split(",")
      .map((part) => part.trim().toLowerCase())
      .filter((part) => part.length > 0);
    const includeEntryGraph = includeParts.includes("entry");

    const entrySessionId = url.searchParams.get("entrySessionId") || undefined;
    const includePaths = url.searchParams.get("includePaths") === "true";

    const activeSessionIds = new Set<string>();
    for (const session of sessions) {
      if (this.ctx.sessions.isActive(session.id)) {
        activeSessionIds.add(session.id);
      }
    }

    const graph = buildWorkspaceGraph({
      workspaceId,
      sessions,
      activeSessionIds,
      currentSessionId,
      includeEntryGraph,
      entrySessionId,
      includePaths,
    });

    this.json(res, { ...graph });
  }

  private async handleRegisterDeviceToken(
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
      this.ctx.storage.setLiveActivityToken(body.deviceToken);
      console.log(`[push] Live Activity token registered for ${this.ctx.storage.getOwnerName()}`);
    } else {
      this.ctx.storage.addPushDeviceToken(body.deviceToken);
      console.log(`[push] Device token registered for ${this.ctx.storage.getOwnerName()}`);
    }

    this.json(res, { ok: true });
  }

  private async handleDeleteDeviceToken(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<{ deviceToken: string }>(req);
    if (body.deviceToken) {
      this.ctx.storage.removePushDeviceToken(body.deviceToken);
      console.log(`[push] Device token removed for ${this.ctx.storage.getOwnerName()}`);
    }
    this.json(res, { ok: true });
  }

  private async handleUploadClientLogs(
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.ctx.storage.getSession(sessionId);
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

    const logsDir = join(this.ctx.storage.getDataDir(), "client-logs");
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
      sessionId,
      workspaceId: session.workspaceId,
      entries,
    };

    appendFileSync(logPath, `${JSON.stringify(envelope)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });

    console.log(
      `${ts()} [diagnostics] client logs uploaded: user=${this.ctx.storage.getOwnerName()} session=${sessionId} entries=${entries.length}`,
    );
    this.json(res, { ok: true, accepted: entries.length });
  }

  // ─── Workspace-scoped session handlers (v2 API) ───

  private handleListWorkspaceSessions(workspaceId: string, res: ServerResponse): void {
    const workspace = this.ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const sessions = this.ctx.storage
      .listSessions()
      .filter((s) => s.workspaceId === workspaceId)
      .map((s) => this.ctx.ensureSessionContextWindow(s));

    this.json(res, { sessions, workspace });
  }

  private async handleCreateWorkspaceSession(
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const body = await this.parseBody<{ name?: string; model?: string; piSessionFile?: string }>(req);

    // ── Local session import: validate path confinement + CWD alignment ──
    if (body.piSessionFile) {
      const validation = validateLocalSessionPath(body.piSessionFile);
      if ("error" in validation) {
        this.error(res, 400, `Invalid session file: ${validation.error}`);
        return;
      }

      // Read CWD from the JSONL header for alignment check
      const headerCwd = this.readSessionCwd(validation.path);
      if (!headerCwd) {
        this.error(res, 400, "Cannot read session CWD from file");
        return;
      }

      if (!workspace.hostMount) {
        this.error(res, 400, "Workspace has no hostMount configured");
        return;
      }

      if (!validateCwdAlignment(headerCwd, workspace.hostMount)) {
        this.error(
          res,
          400,
          `Session CWD (${headerCwd}) is not within workspace path (${workspace.hostMount})`,
        );
        return;
      }

      // Extract name from the local session JSONL if not explicitly provided
      let sessionName = body.name;
      if (!sessionName) {
        const localMeta = await this.readLocalSessionMeta(validation.path);
        sessionName = localMeta?.name || localMeta?.firstMessage?.slice(0, 80);
      }

      const model = body.model || workspace.lastUsedModel || workspace.defaultModel;
      const session = this.ctx.storage.createSession(sessionName, model);

      session.workspaceId = workspace.id;
      session.workspaceName = workspace.name;
      session.piSessionFile = validation.path;
      session.piSessionFiles = [validation.path];
      this.ctx.storage.saveSession(session);
      invalidateLocalSessionsCache();

      const hydrated = this.ctx.ensureSessionContextWindow(session);
      this.json(res, { session: hydrated }, 201);
      return;
    }

    // ── Standard new session ──
    const model = body.model || workspace.lastUsedModel || workspace.defaultModel;
    const session = this.ctx.storage.createSession(body.name, model);

    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    this.ctx.storage.saveSession(session);

    const hydrated = this.ctx.ensureSessionContextWindow(session);
    this.json(res, { session: hydrated }, 201);
  }

  /** Read the CWD from a pi session JSONL header (first line). */
  private readSessionCwd(filePath: string): string | null {
    try {
      const content = readFileSync(filePath, "utf8");
      const firstLine = content.split("\n")[0];
      if (!firstLine) return null;
      const header = JSON.parse(firstLine);
      return typeof header.cwd === "string" ? header.cwd : null;
    } catch {
      return null;
    }
  }

  /** Read name and first message from a local JSONL session (first 16KB only). */
  private async readLocalSessionMeta(
    filePath: string,
  ): Promise<{ name?: string; firstMessage?: string } | null> {
    try {
      const content = readFileSync(filePath, "utf8").slice(0, 16384);
      const lines = content.split("\n");
      let name: string | undefined;
      let firstMessage: string | undefined;

      for (const line of lines) {
        if (!line.trim()) continue;
        let entry: Record<string, unknown>;
        try {
          entry = JSON.parse(line) as Record<string, unknown>;
        } catch {
          continue;
        }
        if (entry.type === "session_info") {
          const n = entry.name;
          if (typeof n === "string" && n.trim()) name = n.trim();
        }
        if (!firstMessage && entry.type === "message") {
          const msg = entry.message as Record<string, unknown> | undefined;
          if (msg?.role === "user") {
            const c = msg.content;
            if (typeof c === "string") firstMessage = c;
            else if (Array.isArray(c)) {
              const t = c.find(
                (x: unknown) =>
                  typeof x === "object" && x !== null && (x as Record<string, unknown>).type === "text",
              ) as { text?: string } | undefined;
              if (t?.text) firstMessage = t.text;
            }
          }
        }
        if (name && firstMessage) break;
      }
      return { name, firstMessage };
    } catch {
      return null;
    }
  }

  private async handleResumeWorkspaceSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    if (session.workspaceId !== workspaceId) {
      this.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    if (this.ctx.sessions.isActive(sessionId)) {
      const active = this.ctx.sessions.getActiveSession(sessionId);
      const hydrated = active ? this.ctx.ensureSessionContextWindow(active) : session;
      this.json(res, { session: hydrated });
      return;
    }

    try {
      const started = await this.ctx.sessions.startSession(
        sessionId,
        this.ctx.storage.getOwnerName(),
        workspace,
      );
      const hydrated = this.ctx.ensureSessionContextWindow(started);
      this.json(res, { session: hydrated });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Resume failed";
      this.error(res, 500, message);
    }
  }

  private async handleForkWorkspaceSession(
    workspaceId: string,
    sourceSessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = this.ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    const sourceSession = this.ctx.storage.getSession(sourceSessionId);
    if (!sourceSession) {
      this.error(res, 404, "Session not found");
      return;
    }

    if (sourceSession.workspaceId !== workspaceId) {
      this.error(res, 400, "Session does not belong to this workspace");
      return;
    }

    const body = await this.parseBody<{ entryId?: string; name?: string }>(req);
    const entryId = body.entryId?.trim() || "";
    if (!entryId) {
      this.error(res, 400, "entryId required");
      return;
    }

    await this.ctx.sessions.refreshSessionState(sourceSessionId);

    const latestSource = this.ctx.storage.getSession(sourceSessionId) || sourceSession;
    const sourceSessionFile =
      latestSource.piSessionFile ||
      latestSource.piSessionFiles?.[latestSource.piSessionFiles.length - 1];

    if (!sourceSessionFile) {
      this.error(res, 409, "Source session has no trace file to fork from");
      return;
    }

    const sourceName = latestSource.name?.trim() || `Session ${latestSource.id.slice(0, 8)}`;
    const requestedName = body.name?.trim();
    const forkName = (
      requestedName && requestedName.length > 0 ? requestedName : `Fork: ${sourceName}`
    ).slice(0, 160);

    const forkSession = this.ctx.storage.createSession(
      forkName,
      latestSource.model || workspace.defaultModel,
    );

    forkSession.workspaceId = workspace.id;
    forkSession.workspaceName = workspace.name;
    forkSession.piSessionFile = sourceSessionFile;
    forkSession.piSessionFiles = Array.from(
      new Set([...(latestSource.piSessionFiles || []), sourceSessionFile]),
    );

    if (latestSource.thinkingLevel) forkSession.thinkingLevel = latestSource.thinkingLevel;
    if (latestSource.contextWindow) forkSession.contextWindow = latestSource.contextWindow;

    this.ctx.storage.saveSession(forkSession);

    try {
      await this.ctx.sessions.startSession(forkSession.id, this.ctx.storage.getOwnerName(), workspace);
      await this.ctx.sessions.runRpcCommand(
        forkSession.id,
        { type: "fork", entryId },
        30_000,
      );
      await this.ctx.sessions.refreshSessionState(forkSession.id);
    } catch (err: unknown) {
      await this.ctx.sessions.stopSession(forkSession.id).catch(() => {});
      this.ctx.storage.deleteSession(forkSession.id);
      const message = err instanceof Error ? err.message : "Fork failed";
      this.error(res, 500, message);
      return;
    }

    const created = this.ctx.storage.getSession(forkSession.id) || forkSession;
    this.json(res, { session: this.ctx.ensureSessionContextWindow(created) }, 201);
  }

  private async handleStopSession(
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const hydratedSession = this.ctx.ensureSessionContextWindow(session);

    if (this.ctx.sessions.isActive(sessionId)) {
      await this.ctx.sessions.stopSession(sessionId);
    } else {
      hydratedSession.status = "stopped";
      hydratedSession.lastActivity = Date.now();
      this.ctx.storage.saveSession(hydratedSession);
    }

    const updatedSession = this.ctx.storage.getSession(sessionId);
    const hydratedUpdated = updatedSession
      ? this.ctx.ensureSessionContextWindow(updatedSession)
      : updatedSession;
    this.json(res, { ok: true, session: hydratedUpdated });
  }

  // ─── Tool Output by ID ───

  private handleGetToolOutput(
    sessionId: string,
    toolCallId: string,
    res: ServerResponse,
  ): void {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const jsonlPaths: string[] = [];

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

  private handleGetSessionFile(sessionId: string, url: URL, res: ServerResponse): void {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const reqPath = url.searchParams.get("path");
    if (!reqPath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const workRoot = this.resolveWorkRoot(session);
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
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const reqPath = url.searchParams.get("path")?.trim();
    if (!reqPath) {
      this.error(res, 400, "path parameter required");
      return;
    }

    const trace = this.loadSessionTrace(session);
    if (!trace || trace.length === 0) {
      this.error(res, 404, "Session trace not found");
      return;
    }

    const mutations = collectFileMutations(trace, reqPath);

    if (mutations.length === 0) {
      this.error(res, 404, "No file mutations found for path");
      return;
    }

    const currentText = this.readCurrentFileText(session, reqPath);
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

  private readCurrentFileText(session: Session, reqPath: string): string {
    const workRoot = this.resolveWorkRoot(session);
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

  private legacySandboxBaseDir(): string {
    const storageWithDataDir = this.ctx.storage as Storage & {
      getDataDir?: () => string;
    };
    const dataDir = storageWithDataDir.getDataDir?.() ?? process.cwd();
    const sandboxesDir = join(dataDir, "sandboxes");
    return existsSync(sandboxesDir) ? sandboxesDir : dataDir;
  }

  private loadSessionTrace(session: Session, traceView: TraceViewMode = "context") {
    const sandboxBaseDir = this.legacySandboxBaseDir();
    let trace = readSessionTrace(sandboxBaseDir, session.id, session.workspaceId, {
      view: traceView,
    });

    if ((!trace || trace.length === 0) && session.piSessionFiles?.length) {
      trace = readSessionTraceFromFiles(session.piSessionFiles, { view: traceView });
    }
    if ((!trace || trace.length === 0) && session.piSessionFile) {
      trace = readSessionTraceFromFile(session.piSessionFile, { view: traceView });
    }
    if ((!trace || trace.length === 0) && session.piSessionId) {
      trace = readSessionTraceByUuid(
        sandboxBaseDir,
        session.piSessionId,
        session.workspaceId,
        { view: traceView },
      );
    }

    return trace;
  }

  private resolveWorkRoot(session: Session): string | null {
    const workspace = session.workspaceId
      ? this.ctx.storage.getWorkspace(session.workspaceId)
      : undefined;

    if (workspace?.hostMount) {
      const resolved = workspace.hostMount.replace(/^~/, homedir());
      return existsSync(resolved) ? resolved : null;
    }
    return homedir();
  }

  private isRuleVisibleToUser(rule: Rule): boolean {
    switch (rule.scope) {
      case "session":
        return rule.sessionId
          ? Boolean(this.ctx.storage.getSession(rule.sessionId))
          : false;
      case "workspace":
        return rule.workspaceId
          ? Boolean(this.ctx.storage.getWorkspace(rule.workspaceId))
          : false;
      case "global":
        return true; // single-owner: all rules are visible
      default:
        return false;
    }
  }

  private sessionBelongsToWorkspace(
    sessionId: string | undefined,
    workspaceId: string,
  ): boolean {
    if (!sessionId) return false;
    const session = this.ctx.storage.getSession(sessionId);
    return session?.workspaceId === workspaceId;
  }

  private handleGetUserStreamEvents(url: URL, res: ServerResponse): void {
    const sinceParam = url.searchParams.get("since");
    const sinceSeq = sinceParam ? Number.parseInt(sinceParam, 10) : 0;
    if (!Number.isFinite(sinceSeq) || sinceSeq < 0) {
      this.error(res, 400, "since must be a non-negative integer");
      return;
    }

    const catchUp = this.ctx.streamMux.getUserStreamCatchUp(sinceSeq);

    this.json(res, {
      events: catchUp.events,
      currentSeq: catchUp.currentSeq,
      catchUpComplete: catchUp.catchUpComplete,
    });
  }

  private handleGetPendingPermissions(url: URL, res: ServerResponse): void {
    const sessionIdFilter = url.searchParams.get("sessionId") || undefined;
    const workspaceIdFilter = url.searchParams.get("workspaceId") || undefined;

    if (sessionIdFilter) {
      const session = this.ctx.storage.getSession(sessionIdFilter);
      if (!session) {
        this.error(res, 404, "Session not found");
        return;
      }
    }

    if (workspaceIdFilter) {
      const workspace = this.ctx.storage.getWorkspace(workspaceIdFilter);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    }

    const serverTime = Date.now();
    const pending = this.ctx.gate
      .getPendingForUser()
      .filter((decision) => decision.expires === false || decision.timeoutAt > serverTime)
      .filter((decision) => !sessionIdFilter || decision.sessionId === sessionIdFilter)
      .filter((decision) => !workspaceIdFilter || decision.workspaceId === workspaceIdFilter)
      .map((decision) => ({
        id: decision.id,
        sessionId: decision.sessionId,
        workspaceId: decision.workspaceId,
        tool: decision.tool,
        input: decision.input,
        displaySummary: decision.displaySummary,
        reason: decision.reason,
        timeoutAt: decision.timeoutAt,
        expires: decision.expires ?? true,
        resolutionOptions: decision.resolutionOptions,
      }));

    this.json(res, {
      pending,
      serverTime,
    });
  }

  private handleGetPolicyRules(url: URL, res: ServerResponse): void {
    const workspaceId = url.searchParams.get("workspaceId") || undefined;
    if (workspaceId) {
      const workspace = this.ctx.storage.getWorkspace(workspaceId);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    }

    const scope = url.searchParams.get("scope") || undefined;
    if (scope && scope !== "session" && scope !== "workspace" && scope !== "global") {
      this.error(res, 400, 'scope must be one of: "session", "workspace", "global"');
      return;
    }

    let rules = this.ctx.gate.ruleStore
      .getAll()
      .filter((rule) => this.isRuleVisibleToUser(rule));

    if (workspaceId) {
      rules = rules.filter((rule) => {
        if (rule.scope === "global") return true;
        if (rule.scope === "workspace") return rule.workspaceId === workspaceId;
        if (rule.scope === "session") {
          return this.sessionBelongsToWorkspace(rule.sessionId, workspaceId);
        }
        return false;
      });
    }

    if (scope) {
      rules = rules.filter((rule) => rule.scope === scope);
    }

    rules.sort((a, b) => b.createdAt - a.createdAt);

    this.json(res, { rules });
  }

  private async handlePatchPolicyRule(
    path: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const ruleId = decodeURIComponent(path.split("/").pop() || "");
    if (!ruleId) {
      this.error(res, 400, "Missing rule ID");
      return;
    }

    const allRules = this.ctx.gate.ruleStore.getAll();
    const existing = allRules.find((r) => r.id === ruleId);
    if (!existing || !this.isRuleVisibleToUser(existing)) {
      this.error(res, 404, "Rule not found");
      return;
    }

    const body = await this.parseBody<Record<string, unknown>>(req);
    const hasField = (key: string): boolean => Object.prototype.hasOwnProperty.call(body, key);

    const hasPatchField =
      hasField("decision") ||
      hasField("label") ||
      hasField("tool") ||
      hasField("pattern") ||
      hasField("executable") ||
      hasField("expiresAt");

    if (!hasPatchField) {
      this.error(res, 400, "At least one patch field is required");
      return;
    }

    const updates: {
      decision?: "allow" | "ask" | "deny";
      tool?: string | null;
      pattern?: string | null;
      executable?: string | null;
      label?: string | null;
      expiresAt?: number | null;
    } = {};

    if (hasField("decision")) {
      const rawDecision = body.decision;
      const normalized =
        rawDecision === "block"
          ? "deny"
          : rawDecision === "allow" || rawDecision === "ask" || rawDecision === "deny"
            ? rawDecision
            : null;
      if (!normalized) {
        this.error(res, 400, 'decision must be one of "allow", "ask", "deny"');
        return;
      }
      updates.decision = normalized;
    }

    if (hasField("label")) {
      if (body.label === null) {
        updates.label = null;
      } else if (typeof body.label === "string") {
        const trimmed = body.label.trim();
        updates.label = trimmed.length > 0 ? trimmed : null;
      } else {
        this.error(res, 400, "label must be a string or null");
        return;
      }
    }

    if (hasField("tool")) {
      if (body.tool === null) {
        updates.tool = null;
      } else if (typeof body.tool === "string") {
        const trimmed = body.tool.trim();
        if (!trimmed) {
          this.error(res, 400, "tool cannot be empty");
          return;
        }
        updates.tool = trimmed;
      } else {
        this.error(res, 400, "tool must be a string or null");
        return;
      }
    }

    if (hasField("pattern")) {
      if (body.pattern === null) {
        updates.pattern = null;
      } else if (typeof body.pattern === "string") {
        const trimmed = body.pattern.trim();
        updates.pattern = trimmed.length > 0 ? trimmed : null;
      } else {
        this.error(res, 400, "pattern must be a string or null");
        return;
      }
    }

    if (hasField("executable")) {
      if (body.executable === null) {
        updates.executable = null;
      } else if (typeof body.executable === "string") {
        const trimmed = body.executable.trim();
        updates.executable = trimmed.length > 0 ? trimmed : null;
      } else {
        this.error(res, 400, "executable must be a string or null");
        return;
      }
    }

    if (hasField("expiresAt")) {
      if (body.expiresAt === null) {
        updates.expiresAt = null;
      } else if (typeof body.expiresAt === "number" && Number.isFinite(body.expiresAt)) {
        const timestamp = Math.trunc(body.expiresAt);
        if (timestamp <= 0) {
          this.error(res, 400, "expiresAt must be a positive timestamp or null");
          return;
        }
        updates.expiresAt = timestamp;
      } else {
        this.error(res, 400, "expiresAt must be a number or null");
        return;
      }
    }

    const updated = this.ctx.gate.ruleStore.update(ruleId, updates);
    if (!updated) {
      this.error(res, 500, "Failed to update rule");
      return;
    }

    if (!updated.tool || updated.tool.trim().length === 0) {
      this.error(res, 400, "rule.tool cannot be empty");
      return;
    }

    console.log(`[policy] Rule ${ruleId} updated: ${updated.label || "(no label)"}`);
    this.json(res, { rule: updated });
  }

  private handleDeletePolicyRule(path: string, res: ServerResponse): void {
    const ruleId = decodeURIComponent(path.split("/").pop() || "");
    if (!ruleId) {
      this.error(res, 400, "Missing rule ID");
      return;
    }

    // Verify rule exists and belongs to this user
    const allRules = this.ctx.gate.ruleStore.getAll();
    const rule = allRules.find((r) => r.id === ruleId);
    if (!rule) {
      this.error(res, 404, "Rule not found");
      return;
    }

    if (!this.isRuleVisibleToUser(rule)) {
      this.error(res, 404, "Rule not found");
      return;
    }

    const removed = this.ctx.gate.ruleStore.remove(ruleId);
    if (!removed) {
      this.error(res, 500, "Failed to remove rule");
      return;
    }

    console.log(
      `[policy] Rule ${ruleId} deleted: ${rule.label || "(no label)"}`,
    );
    this.json(res, { ok: true, deleted: ruleId });
  }

  private handleGetPolicyAudit(url: URL, res: ServerResponse): void {
    const sessionId = url.searchParams.get("sessionId") || undefined;
    const workspaceId = url.searchParams.get("workspaceId") || undefined;

    if (sessionId) {
      const session = this.ctx.storage.getSession(sessionId);
      if (!session) {
        this.error(res, 404, "Session not found");
        return;
      }
    }

    if (workspaceId) {
      const workspace = this.ctx.storage.getWorkspace(workspaceId);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    }

    const limitParam = url.searchParams.get("limit");
    const beforeParam = url.searchParams.get("before");

    let limit = 50;
    if (limitParam !== null) {
      const parsedLimit = Number.parseInt(limitParam, 10);
      if (!Number.isFinite(parsedLimit) || parsedLimit <= 0 || parsedLimit > 500) {
        this.error(res, 400, "limit must be an integer between 1 and 500");
        return;
      }
      limit = parsedLimit;
    }

    let before: number | undefined;
    if (beforeParam !== null) {
      const parsedBefore = Number.parseInt(beforeParam, 10);
      if (!Number.isFinite(parsedBefore) || parsedBefore <= 0) {
        this.error(res, 400, "before must be a positive integer timestamp");
        return;
      }
      before = parsedBefore;
    }

    const entries: AuditEntry[] = this.ctx.gate.auditLog.query({
      limit,
      before,
      sessionId,
      workspaceId,
    });

    this.json(res, { entries });
  }

  private handleGetSessionEvents(
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): void {
    const session = this.ctx.storage.getSession(sessionId);
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

    const catchUp = this.ctx.sessions.getCatchUp(sessionId, sinceSeq);
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

  private resolveTraceView(url: URL): TraceViewMode {
    const view = url.searchParams.get("view");
    return view === "full" ? "full" : "context";
  }

  private async handleGetSession(
    sessionId: string,
    url: URL,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const traceView = this.resolveTraceView(url);
    const hydratedSession = this.ctx.ensureSessionContextWindow(session);
    const sandboxBaseDir = this.legacySandboxBaseDir();

    let trace = this.loadSessionTrace(hydratedSession, traceView);

    if (!trace || trace.length === 0) {
      const live = await this.ctx.sessions.refreshSessionState(sessionId);
      if (live?.sessionFile) {
        trace = readSessionTraceFromFile(live.sessionFile, { view: traceView });
      }
      if ((!trace || trace.length === 0) && live?.sessionId) {
        trace = readSessionTraceByUuid(
        sandboxBaseDir,
          live.sessionId,
          hydratedSession.workspaceId,
          { view: traceView },
        );
      }

      const refreshed = this.ctx.storage.getSession(sessionId);
      if (refreshed && (!trace || trace.length === 0)) {
        this.ctx.ensureSessionContextWindow(refreshed);
        trace = this.loadSessionTrace(refreshed, traceView);
      }
    }

    const latestSession = this.ctx.storage.getSession(sessionId) || hydratedSession;
    const hydratedLatest = this.ctx.ensureSessionContextWindow(latestSession);
    this.json(res, { session: hydratedLatest, trace: trace || [] });
  }

  private async handleDeleteSession(
    sessionId: string,
    res: ServerResponse,
  ): Promise<void> {
    const session = this.ctx.storage.getSession(sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    await this.ctx.sessions.stopSession(sessionId);
    this.ctx.storage.deleteSession(sessionId);
    this.json(res, { ok: true });
  }

  // ─── Theme CRUD ───

  private themesDir(): string {
    return join(this.ctx.storage.getDataDir(), "themes");
  }

  /** Bundled theme files shipped with the server. */
  private bundledThemesDir(): string {
    return join(import.meta.dirname, "..", "themes");
  }

  /** Scan a directory for theme JSON files. */
  private scanThemeDir(
    dir: string,
  ): Array<{ name: string; filename: string; colorScheme: string }> {
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => {
        try {
          const content = readFileSync(join(dir, f), "utf8");
          const parsed = JSON.parse(content);
          return {
            name: (parsed.name as string) ?? f.replace(/\.json$/, ""),
            filename: f.replace(/\.json$/, ""),
            colorScheme: (parsed.colorScheme as string) ?? "dark",
          };
        } catch {
          return null;
        }
      })
      .filter(
        (t): t is { name: string; filename: string; colorScheme: string } =>
          t !== null,
      );
  }

  private handleListThemes(res: ServerResponse): void {
    // Merge bundled + user themes. User themes override bundled by filename.
    const bundled = this.scanThemeDir(this.bundledThemesDir());
    const user = this.scanThemeDir(this.themesDir());
    const byFilename = new Map<
      string,
      { name: string; filename: string; colorScheme: string }
    >();
    for (const t of bundled) byFilename.set(t.filename, t);
    for (const t of user) byFilename.set(t.filename, t);
    this.json(res, { themes: [...byFilename.values()] });
  }

  private handleGetTheme(name: string, res: ServerResponse): void {
    // User themes override bundled; fall back to bundled dir.
    let filePath = join(this.themesDir(), `${name}.json`);
    if (!existsSync(filePath)) {
      filePath = join(this.bundledThemesDir(), `${name}.json`);
    }
    if (!existsSync(filePath)) {
      this.error(res, 404, `Theme "${name}" not found`);
      return;
    }
    try {
      const content = readFileSync(filePath, "utf8");
      const theme = JSON.parse(content);
      this.json(res, { theme });
    } catch {
      this.error(res, 500, "Failed to read theme");
    }
  }

  private async handlePutTheme(
    name: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<{ theme: Record<string, unknown> }>(req);
    const theme = body.theme;
    if (!theme || typeof theme !== "object") {
      this.error(res, 400, "Missing theme object in body");
      return;
    }
    // Validate required color fields — all 51 pi theme tokens
    const colors = theme.colors as Record<string, string> | undefined;
    // 49 tokens — maps 1:1 with iOS ThemePalette. Stripped from pi's 51-token
    // TUI schema: border/borderAccent/borderMuted (TUI box borders),
    // customMessageBg/customMessageText/customMessageLabel (TUI hook.message,
    // not in RPC events), selectedBg (no view wired), bashMode (TUI editor).
    const requiredKeys = [
      // Base palette (13)
      "bg",
      "bgDark",
      "bgHighlight",
      "fg",
      "fgDim",
      "comment",
      "blue",
      "cyan",
      "green",
      "orange",
      "purple",
      "red",
      "yellow",
      "thinkingText",
      // User message (2)
      "userMessageBg",
      "userMessageText",
      // Tool state (5)
      "toolPendingBg",
      "toolSuccessBg",
      "toolErrorBg",
      "toolTitle",
      "toolOutput",
      // Markdown (10)
      "mdHeading",
      "mdLink",
      "mdLinkUrl",
      "mdCode",
      "mdCodeBlock",
      "mdCodeBlockBorder",
      "mdQuote",
      "mdQuoteBorder",
      "mdHr",
      "mdListBullet",
      // Diffs (3)
      "toolDiffAdded",
      "toolDiffRemoved",
      "toolDiffContext",
      // Syntax (9)
      "syntaxComment",
      "syntaxKeyword",
      "syntaxFunction",
      "syntaxVariable",
      "syntaxString",
      "syntaxNumber",
      "syntaxType",
      "syntaxOperator",
      "syntaxPunctuation",
      // Thinking levels (6)
      "thinkingOff",
      "thinkingMinimal",
      "thinkingLow",
      "thinkingMedium",
      "thinkingHigh",
      "thinkingXhigh",
    ];
    if (!colors || typeof colors !== "object") {
      this.error(res, 400, "Missing colors object");
      return;
    }
    const missing = requiredKeys.filter((k) => !(k in colors));
    if (missing.length > 0) {
      this.error(res, 400, `Missing color keys: ${missing.join(", ")}`);
      return;
    }
    // Validate hex format (empty string "" allowed = "use default")
    for (const [key, value] of Object.entries(colors)) {
      if (typeof value !== "string") {
        this.error(res, 400, `Invalid color value for "${key}": expected string`);
        return;
      }
      if (value !== "" && !/^#[0-9a-fA-F]{6}$/.test(value)) {
        this.error(res, 400, `Invalid hex color for "${key}": ${value}`);
        return;
      }
    }
    const dir = this.themesDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const sanitizedName = name.replace(/[^a-zA-Z0-9_-]/g, "");
    if (!sanitizedName) {
      this.error(res, 400, "Invalid theme name");
      return;
    }
    const themeData = {
      name: (theme.name as string) ?? sanitizedName,
      colorScheme: (theme.colorScheme as string) ?? "dark",
      colors,
    };
    const { writeFileSync } = await import("node:fs");
    writeFileSync(join(dir, `${sanitizedName}.json`), JSON.stringify(themeData, null, 2), "utf8");
    this.json(res, { theme: themeData, saved: true }, 201);
  }

  private handleDeleteTheme(name: string, res: ServerResponse): void {
    const sanitizedName = name.replace(/[^a-zA-Z0-9_-]/g, "");
    const filePath = join(this.themesDir(), `${sanitizedName}.json`);
    if (!existsSync(filePath)) {
      this.error(res, 404, `Theme "${name}" not found`);
      return;
    }
    unlinkSync(filePath);
    this.json(res, { deleted: true });
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
