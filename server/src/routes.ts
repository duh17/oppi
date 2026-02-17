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
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join, resolve, extname, dirname } from "node:path";
import { tmpdir, homedir, hostname } from "node:os";
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
  type TraceViewMode,
} from "./trace.js";
import {
  collectFileMutations,
  reconstructBaselineFromCurrent,
  computeDiffLines,
  computeLineDiffStatsFromLines,
} from "./overall-diff.js";
import { buildWorkspaceGraph } from "./graph.js";
import { ensureIdentityMaterial } from "./security.js";
import { discoverProjects, scanDirectories } from "./host.js";
import { isValidExtensionName, listHostExtensions } from "./extension-loader.js";
import { PRESETS, type RiskLevel } from "./policy.js";
import type { LearnedRule } from "./rules.js";
import type { AuditEntry } from "./audit.js";
import type {
  Session,
  Workspace,
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  RegisterDeviceTokenRequest,
  ClientLogUploadRequest,
  ApiError,
  SecurityProfile,
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
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  isValidMemoryNamespace: (ns: string) => boolean;
  refreshModelCatalog: () => Promise<void>;
  getModelCatalog: () => ModelInfo[];
  serverStartedAt: number;
  serverVersion: string;
  piVersion: string;
}

type PolicyPresetName = keyof typeof PRESETS;

interface PolicyProfileItem {
  id: string;
  title: string;
  description?: string;
  risk: RiskLevel;
  example?: string;
}

interface PolicyProfileResponse {
  workspaceId?: string;
  workspaceName?: string;
  runtime: "host" | "container";
  policyPreset: PolicyPresetName;
  supervisionLevel: "standard" | "high";
  summary: string;
  generatedAt: number;
  alwaysBlocked: PolicyProfileItem[];
  needsApproval: PolicyProfileItem[];
  usuallyAllowed: string[];
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
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    // Static routes
    if (path === "/stream/events" && method === "GET")
      return this.handleGetUserStreamEvents(url, res);
    if (path === "/permissions/pending" && method === "GET")
      return this.handleGetPendingPermissions(url, res);
    if (path === "/security/profile" && method === "GET") return this.handleGetSecurityProfile(res);
    if (path === "/security/profile" && method === "PUT")
      return this.handleUpdateSecurityProfile(req, res);
    if (path === "/policy/profile" && method === "GET")
      return this.handleGetPolicyProfile(url, res);
    if (path === "/policy/rules" && method === "GET")
      return this.handleGetPolicyRules(url, res);
    if (path.startsWith("/policy/rules/") && method === "DELETE")
      return this.handleDeletePolicyRule(path, res);
    if (path === "/policy/audit" && method === "GET")
      return this.handleGetPolicyAudit(url, res);
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

  private handleGetSecurityProfile(res: ServerResponse): void {
    this.json(res, this.buildSecurityProfileResponse());
  }

  private async handleUpdateSecurityProfile(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<{
      profile?: SecurityProfile;
      requireTlsOutsideTailnet?: boolean;
      allowInsecureHttpInTailnet?: boolean;
      requirePinnedServerIdentity?: boolean;
      invite?: { maxAgeSeconds?: number };
    }>(req);

    const allowedProfiles: SecurityProfile[] = ["tailscale-permissive", "strict"];
    if (body.profile !== undefined && !allowedProfiles.includes(body.profile)) {
      this.error(res, 400, `profile must be one of: ${allowedProfiles.join(", ")}`);
      return;
    }

    const boolFields: Array<
      keyof Pick<
        typeof body,
        "requireTlsOutsideTailnet" | "allowInsecureHttpInTailnet" | "requirePinnedServerIdentity"
      >
    > = ["requireTlsOutsideTailnet", "allowInsecureHttpInTailnet", "requirePinnedServerIdentity"];

    for (const key of boolFields) {
      const value = body[key];
      if (value !== undefined && typeof value !== "boolean") {
        this.error(res, 400, `${key} must be boolean`);
        return;
      }
    }

    if (body.invite !== undefined) {
      const invite = body.invite as unknown;
      if (typeof invite !== "object" || invite === null || Array.isArray(invite)) {
        this.error(res, 400, "invite must be an object");
        return;
      }

      const maxAgeSeconds = body.invite.maxAgeSeconds;
      if (maxAgeSeconds !== undefined) {
        if (!Number.isInteger(maxAgeSeconds) || maxAgeSeconds < 1 || maxAgeSeconds > 86_400) {
          this.error(res, 400, "invite.maxAgeSeconds must be an integer between 1 and 86400");
          return;
        }
      }
    }

    const current = this.ctx.storage.getConfig();
    const security = {
      profile: body.profile ?? current.security?.profile ?? "tailscale-permissive",
      requireTlsOutsideTailnet:
        body.requireTlsOutsideTailnet ?? current.security?.requireTlsOutsideTailnet ?? false,
      allowInsecureHttpInTailnet:
        body.allowInsecureHttpInTailnet ?? current.security?.allowInsecureHttpInTailnet ?? true,
      requirePinnedServerIdentity:
        body.requirePinnedServerIdentity ?? current.security?.requirePinnedServerIdentity ?? false,
    };

    this.ctx.storage.updateConfig({
      security,
      ...(body.invite?.maxAgeSeconds !== undefined
        ? {
            invite: {
              format: current.invite?.format ?? "v2-signed",
              singleUse: current.invite?.singleUse ?? false,
              maxAgeSeconds: body.invite.maxAgeSeconds,
            },
          }
        : {}),
    });

    this.json(res, this.buildSecurityProfileResponse());
  }

  private buildSecurityProfileResponse(): Record<string, unknown> {
    const config = this.ctx.storage.getConfig();

    const security = config.security;
    const identityConfig = config.identity;
    const invite = config.invite;

    let keyId = identityConfig?.keyId ?? "";
    let algorithm = identityConfig?.algorithm ?? "ed25519";
    let fingerprint = identityConfig?.fingerprint ?? "";

    if (identityConfig?.enabled) {
      try {
        const identity = ensureIdentityMaterial(identityConfig);
        keyId = identity.keyId;
        algorithm = "ed25519";
        fingerprint = identity.fingerprint;

        if (identityConfig.fingerprint !== identity.fingerprint) {
          this.ctx.storage.updateConfig({
            identity: {
              ...identityConfig,
              fingerprint: identity.fingerprint,
            },
          });
        }
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.warn(`[security] failed to load identity material: ${message}`);
      }
    }

    return {
      configVersion: config.configVersion ?? 1,
      profile: security?.profile ?? "tailscale-permissive",
      requireTlsOutsideTailnet: security?.requireTlsOutsideTailnet ?? false,
      allowInsecureHttpInTailnet: security?.allowInsecureHttpInTailnet ?? true,
      requirePinnedServerIdentity: security?.requirePinnedServerIdentity ?? false,
      identity: {
        enabled: identityConfig?.enabled ?? false,
        algorithm,
        keyId,
        fingerprint,
      },
      invite: {
        format: invite?.format ?? "v2-signed",
        maxAgeSeconds: invite?.maxAgeSeconds ?? 600,
      },
    };
  }

  private handleGetMe(res: ServerResponse): void {
    this.json(res, { name: this.ctx.storage.getOwnerName() });
  }

  private handleGetServerInfo(res: ServerResponse): void {
    const config = this.ctx.storage.getConfig();
    const identity = config.identity;
    const workspaces = this.ctx.storage.listWorkspaces();
    const sessions = this.ctx.storage.listSessions();
    const activeSessions = sessions.filter(
      (s) => s.status !== "stopped" && s.status !== "error",
    );

    const uptimeSeconds = Math.floor((Date.now() - this.ctx.serverStartedAt) / 1000);

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
      identity: identity
        ? {
            fingerprint: identity.fingerprint,
            keyId: identity.keyId,
            algorithm: identity.algorithm,
          }
        : null,
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

  // ─── User Skills CRUD ───

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

    const session = this.ctx.storage.getSession(body.sessionId);
    if (!session) {
      this.error(res, 404, "Session not found");
      return;
    }

    const workRoot = this.resolveWorkRoot(session);
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
      const skill = this.ctx.userSkillStore.saveSkill(body.name, resolvedSource);
      // scan() first (re-reads disk), then register user skill on top
      this.ctx.skillRegistry.scan();
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

  /**
   * PUT /me/skills/:name — create or update a user skill with inline content.
   *
   * Body: { content: string, files?: Record<string, string> }
   *   content: SKILL.md content (required)
   *   files: optional extra files as { "scripts/run.sh": "#!/bin/bash\n..." }
   */
  private async handlePutUserSkill(
    name: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await this.parseBody<{
      content: string;
      files?: Record<string, string>;
    }>(req);

    if (!body.content) {
      this.error(res, 400, "content (SKILL.md) required");
      return;
    }

    // Check if this is an existing skill (built-in or user) — write in-place.
    const existing = this.ctx.skillRegistry.get(name);
    if (existing) {
      // Write directly to the skill's on-disk location
      try {
        writeFileSync(join(existing.path, "SKILL.md"), body.content);
        if (body.files) {
          for (const [relPath, fileContent] of Object.entries(body.files)) {
            if (relPath.includes("..") || relPath.startsWith("/")) {
              this.error(res, 400, `Invalid file path: ${relPath}`);
              return;
            }
            const dir = dirname(join(existing.path, relPath));
            mkdirSync(dir, { recursive: true });
            writeFileSync(join(existing.path, relPath), fileContent);
          }
        }
        // Re-scan picks up changes; re-register user skills after (scan clears map)
        this.ctx.skillRegistry.scan();
        const userSkills = this.ctx.userSkillStore.listSkills();
        this.ctx.skillRegistry.registerUserSkills(userSkills);
        const updated = this.ctx.skillRegistry.get(name);
        this.json(res, { skill: updated ?? existing });
        return;
      } catch (err) {
        this.error(res, 500, `Failed to write skill: ${err instanceof Error ? err.message : String(err)}`);
        return;
      }
    }

    // New user skill — write via UserSkillStore
    const tmpDir = join(tmpdir(), `oppi-skill-${name}-${Date.now()}`);
    try {
      mkdirSync(tmpDir, { recursive: true });
      writeFileSync(join(tmpDir, "SKILL.md"), body.content);

      if (body.files) {
        for (const [relPath, fileContent] of Object.entries(body.files)) {
          if (relPath.includes("..") || relPath.startsWith("/")) {
            this.error(res, 400, `Invalid file path: ${relPath}`);
            return;
          }
          const dir = dirname(join(tmpDir, relPath));
          mkdirSync(dir, { recursive: true });
          writeFileSync(join(tmpDir, relPath), fileContent);
        }
      }

      const skill = this.ctx.userSkillStore.saveSkill(name, tmpDir);
      this.ctx.skillRegistry.scan();
      this.ctx.skillRegistry.registerUserSkills([skill]);
      this.json(res, { skill });
    } catch (err) {
      if (err instanceof SkillValidationError) {
        this.error(res, 400, err.message);
        return;
      }
      throw err;
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  private handleDeleteUserSkill(name: string, res: ServerResponse): void {
    const builtIn = this.ctx.skillRegistry.get(name);
    const userSkill = this.ctx.userSkillStore.getSkill(name);

    if (!userSkill) {
      if (builtIn) {
        this.error(res, 403, "Cannot delete built-in skill");
        return;
      }
      this.error(res, 404, "Skill not found");
      return;
    }

    this.ctx.userSkillStore.deleteSkill(name);
    this.ctx.skillRegistry.scan(); // refresh catalog
    res.writeHead(204).end();
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

    if (body.runtime && body.runtime !== "host" && body.runtime !== "container") {
      this.error(res, 400, 'runtime must be "host" or "container"');
      return;
    }

    if (body.policyPreset && !this.isValidPolicyPreset(body.policyPreset)) {
      this.error(res, 400, `policyPreset must be one of: ${Object.keys(PRESETS).join(", ")}`);
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

    if (body.runtime && body.runtime !== "host" && body.runtime !== "container") {
      this.error(res, 400, 'runtime must be "host" or "container"');
      return;
    }

    if (body.policyPreset && !this.isValidPolicyPreset(body.policyPreset)) {
      this.error(res, 400, `policyPreset must be one of: ${Object.keys(PRESETS).join(", ")}`);
      return;
    }

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

    const updated = this.ctx.storage.updateWorkspace(wsId, body);
    if (!updated) {
      this.error(res, 404, "Workspace not found");
      return;
    }

    // If skills changed on a container workspace, re-sync the sandbox
    if (body.skills && updated.runtime === "container") {
      this.ctx.sandbox.resyncWorkspaceSkills(wsId, updated.skills);
    }

    this.json(res, { workspace: updated });
  }

  private handleDeleteWorkspace(wsId: string, res: ServerResponse): void {
    this.ctx.storage.deleteWorkspace(wsId);
    this.json(res, { ok: true });
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
      this.ctx.storage.addDeviceToken(body.deviceToken);
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
      this.ctx.storage.removeDeviceToken(body.deviceToken);
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

    const body = await this.parseBody<{ name?: string; model?: string }>(req);
    const model = body.model || workspace.lastUsedModel || workspace.defaultModel;
    const session = this.ctx.storage.createSession(body.name, model);

    session.workspaceId = workspace.id;
    session.workspaceName = workspace.name;
    session.runtime = workspace.runtime;
    this.ctx.storage.saveSession(session);

    const hydrated = this.ctx.ensureSessionContextWindow(session);
    this.json(res, { session: hydrated }, 201);
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
    forkSession.runtime = workspace.runtime;
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
    const sandboxBaseDir = this.ctx.sandbox.getBaseDir();

    const containerDirs: string[] = [];
    if (session.workspaceId) {
      containerDirs.push(
        join(
          sandboxBaseDir,
          session.workspaceId,
          "sessions",
          sessionId,
          "agent",
          "sessions",
          "--work--",
        ),
      );
    }

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

  private loadSessionTrace(session: Session, traceView: TraceViewMode = "context") {
    const sandboxBaseDir = this.ctx.sandbox.getBaseDir();
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

    if (session.runtime === "container") {
      if (workspace?.hostMount) {
        const resolved = workspace.hostMount.replace(/^~/, homedir());
        return existsSync(resolved) ? resolved : null;
      }
      if (!session.workspaceId) {
        return null;
      }

      const workspaceSandbox = join(
        this.ctx.sandbox.getBaseDir(),
        session.workspaceId,
        "workspace",
      );
      return existsSync(workspaceSandbox) ? workspaceSandbox : null;
    }

    if (workspace?.hostMount) {
      const resolved = workspace.hostMount.replace(/^~/, homedir());
      return existsSync(resolved) ? resolved : null;
    }
    return homedir();
  }

  private isValidPolicyPreset(value: string): value is PolicyPresetName {
    return Object.prototype.hasOwnProperty.call(PRESETS, value);
  }

  private resolvePolicyPresetName(
    raw: string | undefined,
    runtime: "host" | "container",
  ): PolicyPresetName {
    if (raw && this.isValidPolicyPreset(raw)) {
      return raw;
    }

    return runtime === "container" ? "container" : "host";
  }

  private isRuleVisibleToUser(rule: LearnedRule): boolean {
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

  private buildPolicyProfile(
    presetName: PolicyPresetName,
    runtime: "host" | "container",
    workspace?: Workspace,
  ): PolicyProfileResponse {
    const preset = PRESETS[presetName];

    const alwaysBlocked: PolicyProfileItem[] = preset.hardDeny.map((rule, index) => ({
      id: `hard-${index}`,
      title: rule.label || `${rule.tool || "tool"} blocked`,
      description:
        rule.tool === "bash"
          ? "Blocked by an immutable security rule."
          : "Blocked by credential/safety protection.",
      risk: rule.risk || "critical",
      example: rule.pattern,
    }));

    const needsApproval: PolicyProfileItem[] = preset.rules
      .filter((rule) => rule.action === "ask")
      .map((rule, index) => ({
        id: `ask-${index}`,
        title: rule.label || `${rule.tool || "tool"} requires approval`,
        description: "Requires phone approval before execution.",
        risk: rule.risk || "medium",
        example: rule.pattern,
      }));

    // Structural heuristics applied by policy engine (not represented as preset rules).
    needsApproval.push(
      {
        id: "heuristic-data-egress",
        title: "Outbound data transfer",
        description: "Posting/uploading data with curl/wget requires approval.",
        risk: "medium",
        example: "curl -d 'payload' https://api.example.com",
      },
      {
        id: "heuristic-pipe-shell",
        title: "Pipe to shell",
        description: "Piping remote scripts into sh/bash requires approval.",
        risk: "high",
        example: "curl https://example.com/install.sh | bash",
      },
      {
        id: "heuristic-secret-env-url",
        title: "Secret env expansion in URL",
        description: "Expanding credential-like env vars into external URLs requires approval.",
        risk: "high",
        example: 'curl "https://example.com/?token=$OPENAI_API_KEY"',
      },
    );

    if (preset.defaultAction === "ask") {
      needsApproval.push({
        id: "default-ask",
        title: "Other actions",
        description: "Unmatched actions require phone approval.",
        risk: "medium",
      });
    } else if (preset.defaultAction === "deny") {
      alwaysBlocked.push({
        id: "default-deny",
        title: "Unknown tools/actions",
        description: "Unmatched actions are blocked by default.",
        risk: "high",
      });
    }

    let usuallyAllowed: string[];
    let supervisionLevel: "standard" | "high";
    let summary: string;

    if (presetName === "host") {
      supervisionLevel = "standard";
      summary =
        "Host Developer Trust mode: runs directly on your Mac with low friction. External and high-impact actions still require approval.";
      usuallyAllowed = [
        "Most local development commands",
        "Local read/edit/write operations",
        "Build, test, lint, and search commands",
        "Local git operations that do not push to remotes",
      ];
    } else if (presetName === "host_standard") {
      supervisionLevel = "high";
      summary =
        "Host Standard mode: approval-first on your Mac. Safe read-only actions in workspace bounds run automatically; other actions ask.";
      usuallyAllowed = [
        "Read-only commands in workspace-bound paths",
        "Safe read/list/find operations in allowed directories",
        "Browser navigation to allowlisted domains",
      ];
    } else if (presetName === "host_locked") {
      supervisionLevel = "high";
      summary =
        "Host Locked mode: strict supervision on your Mac. Read-only bounded actions run automatically; known tools ask; unknown actions are blocked.";
      usuallyAllowed = [
        "Read-only commands in workspace-bound paths",
        "Safe list/find/read operations in allowed directories",
      ];
    } else {
      supervisionLevel = "standard";
      summary =
        "Container mode: runs in an isolated environment. Most local container actions run automatically; external/destructive actions may require approval.";
      usuallyAllowed = [
        "Most filesystem/tool operations inside the container",
        "Build, test, lint, and search commands in workspace",
        "Local git operations in container (push still needs approval)",
      ];
    }

    return {
      workspaceId: workspace?.id,
      workspaceName: workspace?.name,
      runtime,
      policyPreset: presetName,
      supervisionLevel,
      summary,
      generatedAt: Date.now(),
      alwaysBlocked,
      needsApproval,
      usuallyAllowed,
    };
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
        risk: decision.risk,
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

  private handleGetPolicyProfile(url: URL, res: ServerResponse): void {
    const workspaceId = url.searchParams.get("workspaceId") || undefined;

    let workspace: Workspace | undefined;
    if (workspaceId) {
      workspace = this.ctx.storage.getWorkspace(workspaceId);
      if (!workspace) {
        this.error(res, 404, "Workspace not found");
        return;
      }
    }

    const runtime: "host" | "container" = workspace?.runtime ?? "host";
    const policyPreset = this.resolvePolicyPresetName(workspace?.policyPreset, runtime);
    const profile = this.buildPolicyProfile(policyPreset, runtime, workspace);

    this.json(res, { profile });
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

  private handleDeletePolicyRule(path: string, res: ServerResponse): void {
    const ruleId = path.split("/").pop();
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
      `[policy] Rule ${ruleId} deleted: ${rule.description}`,
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
    const sandboxBaseDir = this.ctx.sandbox.getBaseDir();

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

  private handleListThemes(res: ServerResponse): void {
    const dir = this.themesDir();
    if (!existsSync(dir)) {
      this.json(res, { themes: [] });
      return;
    }
    const themes = readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => {
        try {
          const content = readFileSync(join(dir, f), "utf8");
          const parsed = JSON.parse(content);
          return {
            name: parsed.name ?? f.replace(/\.json$/, ""),
            filename: f.replace(/\.json$/, ""),
            colorScheme: parsed.colorScheme ?? "dark",
          };
        } catch {
          return null;
        }
      })
      .filter(Boolean);
    this.json(res, { themes });
  }

  private handleGetTheme(name: string, res: ServerResponse): void {
    const filePath = join(this.themesDir(), `${name}.json`);
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
    // Validate required color fields
    const colors = theme.colors as Record<string, string> | undefined;
    const requiredKeys = [
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
    ];
    if (!colors || typeof colors !== "object") {
      this.error(res, 400, "Missing colors object");
      return;
    }
    const missing = requiredKeys.filter((k) => !colors[k]);
    if (missing.length > 0) {
      this.error(res, 400, `Missing color keys: ${missing.join(", ")}`);
      return;
    }
    // Validate hex format
    for (const [key, value] of Object.entries(colors)) {
      if (typeof value !== "string" || !/^#[0-9a-fA-F]{6}$/.test(value)) {
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
