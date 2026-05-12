/**
 * Persistent storage for oppi-server
 *
 * Data directory structure:
 * ~/.config/oppi/
 * ├── config.json       # Server config
 * ├── users.json        # Owner identity & token (single-user)
 * ├── session-state.db # Runtime session state
 * ├── sessions/        # Legacy JSON session sidecars imported once on startup
 * └── workspaces/
 *     └── <workspaceId>.json    # Flat owner layout (single-user mode)
 */

import { existsSync, openSync, readSync, closeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createLogger } from "./logger.js";
import { AuthStore } from "./storage/auth-store.js";
import {
  ConfigStore,
  DEFAULT_DATA_DIR,
  type ConfigValidationResult,
} from "./storage/config-store.js";
import type { ReviewCommentListFilters } from "./storage/review-comment-dao.js";
import { ReviewCommentSqliteStore } from "./storage/review-comment-sqlite-store.js";
import type {
  WorkspaceSessionSnapshotListOptions,
  WorkspaceSessionSnapshotListResult,
} from "./storage/session-dao.js";
import { SessionSqliteStore } from "./storage/session-sqlite-store.js";
import { WorkspaceStore } from "./storage/workspace-store.js";
import type {
  AttachReviewCommentsToTurnRequest,
  CreateReviewCommentRequest,
  CreateWorkspaceRequest,
  ReviewComment,
  ServerConfig,
  Session,
  UpdateReviewCommentRequest,
  UpdateWorkspaceRequest,
  Workspace,
} from "./types.js";

export type { ConfigValidationResult };

const log = createLogger({ base: { component: "storage_migration" } });

function expandHome(path: string): string {
  return path === "~" || path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

function normalizedPath(path: string): string {
  return resolve(expandHome(path));
}

function pathContains(parent: string, child: string): boolean {
  const resolvedParent = normalizedPath(parent);
  const resolvedChild = normalizedPath(child);
  return resolvedChild === resolvedParent || resolvedChild.startsWith(resolvedParent + "/");
}

function readJsonlSessionCwd(filePath: string | undefined): string | null {
  if (!filePath || !existsSync(filePath)) return null;

  let fd: number | undefined;
  try {
    fd = openSync(filePath, "r");
    const buffer = Buffer.alloc(8192);
    const bytesRead = readSync(fd, buffer, 0, buffer.length, 0);
    const firstLine = buffer.toString("utf8", 0, bytesRead).split("\n")[0];
    if (!firstLine) return null;

    const parsed = JSON.parse(firstLine) as unknown;
    if (!parsed || typeof parsed !== "object") return null;
    const cwd = (parsed as { cwd?: unknown }).cwd;
    return typeof cwd === "string" && cwd.trim().length > 0 ? cwd : null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

export class Storage {
  private readonly configStore: ConfigStore;
  private readonly authStore: AuthStore;
  private readonly sessionStore: SessionSqliteStore;
  private readonly reviewCommentStore: ReviewCommentSqliteStore;
  private readonly workspaceStore: WorkspaceStore;

  constructor(dataDir?: string) {
    this.configStore = new ConfigStore(dataDir ?? DEFAULT_DATA_DIR);
    this.authStore = new AuthStore(this.configStore);
    this.sessionStore = new SessionSqliteStore(this.configStore.getDataDir());
    this.reviewCommentStore = new ReviewCommentSqliteStore(this.configStore.getDataDir());
    this.workspaceStore = new WorkspaceStore(this.configStore);
    this.migrateLegacyWorkspaceSessions();
  }

  /**
   * Legacy workspace migration: older sessions could exist without workspaceId.
   * Workspace-scoped iOS/server flows require workspace-backed sessions for
   * attachments, file browsing, review comments, and routing. Recover the
   * workspace from the pi JSONL header CWD only when it unambiguously fits an
   * existing hostMount. This avoids inventing workspaces or guessing wrong.
   */
  private migrateLegacyWorkspaceSessions(): void {
    const sessions = this.sessionStore.listSessionsWithoutWorkspace();
    if (sessions.length === 0) return;

    const workspaces = this.workspaceStore.listWorkspaces();
    let migrated = 0;
    let skipped = 0;

    for (const session of sessions) {
      const cwd =
        readJsonlSessionCwd(session.piSessionFile) ??
        session.piSessionFiles?.map(readJsonlSessionCwd).find((value): value is string => !!value);
      if (!cwd) continue;

      const candidates = workspaces
        .filter((candidate) => candidate.hostMount && pathContains(candidate.hostMount, cwd))
        .sort(
          (a, b) =>
            normalizedPath(b.hostMount ?? "").length - normalizedPath(a.hostMount ?? "").length,
        );
      const workspace = candidates[0];
      const workspaceMountLength = workspace ? normalizedPath(workspace.hostMount ?? "").length : 0;
      const hasAmbiguousTie =
        candidates.length > 1 &&
        normalizedPath(candidates[1]?.hostMount ?? "").length === workspaceMountLength;

      if (!workspace || hasAmbiguousTie) {
        skipped += 1;
        continue;
      }

      session.workspaceId = workspace.id;
      session.workspaceName = workspace.name;
      this.sessionStore.saveSession(session);
      migrated += 1;
    }

    if (migrated > 0) {
      log.info("legacy_workspace_sessions.migrated", {
        migratedSessions: migrated,
        skippedSessions: skipped,
      });
    } else if (skipped > 0) {
      log.info("legacy_workspace_sessions.skipped", { skippedSessions: skipped });
    }
  }

  // ─── Config ───

  static getDefaultConfig(dataDir: string = DEFAULT_DATA_DIR): ServerConfig {
    return ConfigStore.getDefaultConfig(dataDir);
  }

  static validateConfig(
    raw: unknown,
    dataDir: string = DEFAULT_DATA_DIR,
    strictUnknown: boolean = true,
  ): ConfigValidationResult {
    return ConfigStore.validateConfig(raw, dataDir, strictUnknown);
  }

  static validateConfigFile(
    configPath: string,
    dataDir: string = dirname(configPath),
    strictUnknown: boolean = true,
  ): ConfigValidationResult {
    return ConfigStore.validateConfigFile(configPath, dataDir, strictUnknown);
  }

  getConfig(): ServerConfig {
    return this.configStore.getConfig();
  }

  getConfigPath(): string {
    return this.configStore.getConfigPath();
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    this.configStore.updateConfig(updates);
  }

  // ─── Pairing / auth / push tokens ───

  isPaired(): boolean {
    return this.authStore.isPaired();
  }

  getToken(): string | undefined {
    return this.authStore.getToken();
  }

  ensurePaired(): string {
    return this.authStore.ensurePaired();
  }

  rotateToken(): string {
    return this.authStore.rotateToken();
  }

  issuePairingToken(ttlMs?: number): string {
    return this.authStore.issuePairingToken(ttlMs);
  }

  consumePairingToken(candidate: string): string | null {
    return this.authStore.consumePairingToken(candidate);
  }

  getOwnerName(): string {
    return this.authStore.getOwnerName();
  }

  addAuthDeviceToken(token: string): void {
    this.authStore.addAuthDeviceToken(token);
  }

  removeAuthDeviceToken(token: string): void {
    this.authStore.removeAuthDeviceToken(token);
  }

  getAuthDeviceTokens(): string[] {
    return this.authStore.getAuthDeviceTokens();
  }

  addPushDeviceToken(token: string): void {
    this.authStore.addPushDeviceToken(token);
  }

  removePushDeviceToken(token: string): void {
    this.authStore.removePushDeviceToken(token);
  }

  getPushDeviceTokens(): string[] {
    return this.authStore.getPushDeviceTokens();
  }

  setLiveActivityToken(token: string | null): void {
    this.authStore.setLiveActivityToken(token);
  }

  getLiveActivityToken(): string | undefined {
    return this.authStore.getLiveActivityToken();
  }

  // ─── Sessions ───

  createSession(name?: string, model?: string): Session {
    return this.sessionStore.createSession(name, model);
  }

  saveSession(session: Session): void {
    this.sessionStore.saveSession(session);
  }

  getSession(sessionId: string): Session | undefined {
    return this.sessionStore.getSession(sessionId);
  }

  listSessions(): Session[] {
    return this.sessionStore.listSessions();
  }

  listSessionsByWorkspace(workspaceId: string): Session[] {
    return this.sessionStore.listSessionsByWorkspace(workspaceId);
  }

  listWorkspaceSessionSnapshots(
    workspaceId: string,
    options?: WorkspaceSessionSnapshotListOptions,
  ): WorkspaceSessionSnapshotListResult {
    return this.sessionStore.listWorkspaceSessionSnapshots(workspaceId, options);
  }

  deleteSession(sessionId: string): boolean {
    return this.sessionStore.deleteSession(sessionId);
  }

  // ─── Review comments ───

  listReviewComments(workspaceId: string, filters?: ReviewCommentListFilters): ReviewComment[] {
    return this.reviewCommentStore.list(workspaceId, filters);
  }

  createReviewComment(workspaceId: string, input: CreateReviewCommentRequest): ReviewComment {
    return this.reviewCommentStore.create(workspaceId, input);
  }

  updateReviewComment(
    workspaceId: string,
    commentId: string,
    patch: UpdateReviewCommentRequest,
  ): ReviewComment {
    return this.reviewCommentStore.update(workspaceId, commentId, patch);
  }

  deleteReviewComment(workspaceId: string, commentId: string): void {
    this.reviewCommentStore.delete(workspaceId, commentId);
  }

  attachReviewCommentsToTurn(
    workspaceId: string,
    input: AttachReviewCommentsToTurnRequest,
  ): ReviewComment[] {
    return this.reviewCommentStore.attachToTurn(workspaceId, input);
  }

  // ─── Workspaces ───

  createWorkspace(req: CreateWorkspaceRequest): Workspace {
    return this.workspaceStore.createWorkspace(req);
  }

  saveWorkspace(workspace: Workspace): void {
    this.workspaceStore.saveWorkspace(workspace);
  }

  getWorkspace(workspaceId: string): Workspace | undefined {
    return this.workspaceStore.getWorkspace(workspaceId);
  }

  listWorkspaces(): Workspace[] {
    return this.workspaceStore.listWorkspaces();
  }

  updateWorkspace(workspaceId: string, updates: UpdateWorkspaceRequest): Workspace | undefined {
    return this.workspaceStore.updateWorkspace(workspaceId, updates);
  }

  deleteWorkspace(workspaceId: string): boolean {
    return this.workspaceStore.deleteWorkspace(workspaceId);
  }

  // ─── Helpers ───

  getDataDir(): string {
    return this.configStore.getDataDir();
  }
}
