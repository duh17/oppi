/**
 * Persistent storage for oppi-server
 *
 * Data directory structure:
 * ~/.config/oppi/
 * ├── config.json        # Server config + auth state
 * ├── session-state.db   # Runtime session state
 * └── workspaces/
 *     └── <workspaceId>.json    # Flat owner layout (single-user mode)
 */

import { closeSync, existsSync, openSync, readSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createLogger } from "./logger.js";
import { AgentDefinitionStore } from "./agent-definitions.js";
import { iconAssetId } from "./icon-choice.js";
import { AgentScheduleStore } from "./agent-schedules.js";
import { openDatabase } from "./sqlite-compat.js";
import { AuthStore } from "./storage/auth-store.js";
import {
  DeviceAuthStore,
  type AccessTokenValidation,
  type Challenge,
  type EnrollResult,
  type RefreshResult,
} from "./storage/device-auth.js";
import {
  ConfigStore,
  DEFAULT_DATA_DIR,
  type ConfigValidationResult,
} from "./storage/config-store.js";
import type {
  WorkspaceSessionSummarySnapshot,
  WorkspaceStoppedTimeBucketSnapshot,
} from "./storage/session-dao.js";
import {
  ICON_ASSET_ORPHAN_GRACE_MS,
  IconAssetStore,
  type IconAssetRecord,
} from "./storage/icon-asset-store.js";
import { OppiExtensionSettingsStore } from "./storage/oppi-extension-settings-store.js";
import { SessionSqliteStore } from "./storage/session-sqlite-store.js";
import { WorkspaceStore } from "./storage/workspace-store.js";
import type { OppiExtensionSettingsSnapshot } from "./oppi-extension-settings.js";
import type {
  CreateWorkspaceRequest,
  ServerConfig,
  Session,
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
  private readonly deviceAuthStore: DeviceAuthStore;
  private readonly sessionStore: SessionSqliteStore;
  private readonly iconAssetStore: IconAssetStore;
  private readonly oppiExtensionSettingsStore: OppiExtensionSettingsStore;
  private readonly agentDefinitionStore: AgentDefinitionStore;
  private readonly scheduleStore: AgentScheduleStore;
  private readonly workspaceStore: WorkspaceStore;

  constructor(dataDir?: string) {
    this.configStore = new ConfigStore(dataDir ?? DEFAULT_DATA_DIR);
    this.authStore = new AuthStore(this.configStore);
    this.deviceAuthStore = new DeviceAuthStore(this.configStore);
    this.sessionStore = new SessionSqliteStore(this.configStore.getDataDir());
    this.iconAssetStore = new IconAssetStore(this.configStore.getDataDir());
    this.oppiExtensionSettingsStore = new OppiExtensionSettingsStore(this.configStore.getDataDir());
    this.agentDefinitionStore = new AgentDefinitionStore(
      this.configStore.getDataDir(),
      undefined,
      (assetId) => this.iconAssetStore.has(assetId),
    );
    this.scheduleStore = new AgentScheduleStore(this.configStore.getDataDir());
    this.cleanupServerReviewCommentState();
    this.workspaceStore = new WorkspaceStore(this.configStore, (assetId) =>
      this.iconAssetStore.has(assetId),
    );
    this.migrateLegacyWorkspaceSessions();
    this.deviceAuthStore.migrateLegacyRecords();
    // Reconcile only after Agent current/version history, workspaces, and
    // immutable session launch snapshots are all available.
    this.cleanupUnreferencedIconAssets(undefined, {
      now: Date.now(),
      graceMs: ICON_ASSET_ORPHAN_GRACE_MS,
    });
  }

  /**
   * Review comment drafts are client-local state. Remove server-owned storage
   * created by older builds so the daemon does not retain unused draft data.
   */
  private cleanupServerReviewCommentState(): void {
    const dataDir = this.configStore.getDataDir();
    const db = openDatabase(join(dataDir, "session-state.db"));
    try {
      const rows = db
        .prepare("SELECT name FROM sqlite_master WHERE name IN (?, ?)")
        .all("review_comments", "review_comments_next") as Array<{ name?: string }>;
      const hadTables = rows.length > 0;

      db.exec(`
        DROP INDEX IF EXISTS review_comments_workspace_created_idx;
        DROP INDEX IF EXISTS review_comments_workspace_session_idx;
        DROP INDEX IF EXISTS review_comments_workspace_status_idx;
        DROP INDEX IF EXISTS review_comments_workspace_path_idx;
        DROP TABLE IF EXISTS review_comments;
        DROP TABLE IF EXISTS review_comments_next;
        DELETE FROM app_state_migrations WHERE key LIKE 'review_comments_json_import_sqlite_backend_v2:%';
      `);

      const legacyDir = join(dataDir, "review-comments");
      const hadLegacyDir = existsSync(legacyDir);
      if (hadLegacyDir) {
        rmSync(legacyDir, { recursive: true, force: true });
      }

      if (hadTables || hadLegacyDir) {
        log.info("storage_migration.review_comments.cleanup", {
          removedSqliteTables: hadTables,
          removedLegacyJsonDir: hadLegacyDir,
        });
      }
    } finally {
      db.close();
    }
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

  // ─── Built-in Oppi extension settings ───

  getOppiExtensionSettings(): OppiExtensionSettingsSnapshot {
    return this.oppiExtensionSettingsStore.get();
  }

  getOppiExtensionSettingsLoadError(): string | undefined {
    return this.oppiExtensionSettingsStore.getLoadError();
  }

  replaceOppiExtensionSettings(
    baseRevision: unknown,
    desired: unknown,
  ): ReturnType<OppiExtensionSettingsStore["replace"]> {
    return this.oppiExtensionSettingsStore.replace(baseRevision, desired);
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

  consumePairingToken(candidate: string): ReturnType<AuthStore["consumePairingToken"]> {
    return this.authStore.consumePairingToken(candidate);
  }

  // ─── Device-key auth ───

  enrollViaPairing(
    candidate: string,
    deviceInput: { publicKey: unknown; name?: unknown },
  ): EnrollResult | null {
    return this.deviceAuthStore.enrollViaPairing(candidate, deviceInput);
  }

  migrateLegacyDevice(
    candidate: string,
    deviceInput: { publicKey: unknown; name?: unknown },
  ): EnrollResult | null {
    return this.deviceAuthStore.migrateLegacyDevice(candidate, deviceInput);
  }

  issueChallenge(deviceId: string): Challenge | null {
    return this.deviceAuthStore.issueChallenge(deviceId);
  }

  refresh(input: { deviceId: string; nonce: string; signature: unknown }): RefreshResult {
    return this.deviceAuthStore.refresh(input);
  }

  validateAccessToken(candidate: string): AccessTokenValidation {
    return this.deviceAuthStore.validateAccessToken(candidate);
  }

  commitLegacyRevocation(deviceId: string): boolean {
    return this.deviceAuthStore.commitLegacyRevocation(deviceId);
  }

  revokeDevice(deviceId: string): boolean {
    return this.deviceAuthStore.revokeDevice(deviceId);
  }

  listDevices(): ReturnType<DeviceAuthStore["listDevices"]> {
    return this.deviceAuthStore.listDevices();
  }

  deviceIdForLegacyToken(candidate: string): string | undefined {
    return this.deviceAuthStore.deviceIdForLegacyToken(candidate);
  }

  isMigrationFinalized(): boolean {
    return this.deviceAuthStore.isMigrationFinalized();
  }

  setMigrationFinalized(finalized: boolean): void {
    this.deviceAuthStore.setMigrationFinalized(finalized);
  }

  hasAuthToken(candidate: string): boolean {
    return this.authStore.hasAuthToken(candidate);
  }

  getOwnerName(): string {
    return this.authStore.getOwnerName();
  }

  getAuthDeviceTokens(): string[] {
    return this.authStore.getAuthDeviceTokens();
  }

  getPushDeviceTokens(): string[] {
    return this.authStore.getPushDeviceTokens();
  }

  addPushDeviceToken(token: string): void {
    this.authStore.addPushDeviceToken(token);
  }

  setLiveActivityToken(token: string | null): void {
    this.authStore.setLiveActivityToken(token);
  }

  getLiveActivityToken(): string | undefined {
    return this.authStore.getLiveActivityToken();
  }

  // ─── Sessions ───

  createSession(name?: string, model?: string, options?: { id?: string }): Session {
    return this.sessionStore.createSession(name, model, options);
  }

  saveSession(session: Session): void {
    this.sessionStore.saveSession(session);
  }

  getSession(sessionId: string): Session | undefined {
    return this.sessionStore.getSession(sessionId);
  }

  findSessionByLaunchIdempotencyKey(idempotencyKey: string): Session | undefined {
    return this.sessionStore.findSessionByLaunchIdempotencyKey(idempotencyKey);
  }

  claimSessionLaunchRecovery(
    session: Session,
    leaseOwner: string,
    nowMs: number,
    leaseTtlMs: number,
  ): Session | undefined {
    return this.sessionStore.claimSessionLaunchRecovery(session, leaseOwner, nowMs, leaseTtlMs);
  }

  listSessions(): Session[] {
    return this.sessionStore.listSessions();
  }

  listAllWorkspaceSessionSnapshots(workspaceId: string, worktreeId?: string): Session[] {
    return this.sessionStore.listAllWorkspaceSessionSnapshots(workspaceId, worktreeId);
  }

  listRecentWorkspaceSessionSnapshots(
    workspaceId: string,
    recentDays: number,
    nowMs?: number,
    worktreeId?: string,
  ): Session[] {
    return this.sessionStore.listRecentWorkspaceSessionSnapshots(
      workspaceId,
      recentDays,
      nowMs,
      worktreeId,
    );
  }

  listWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
    worktreeId?: string,
  ): Session[] {
    return this.sessionStore.listWorkspaceTimeRangeSessionSnapshots(
      workspaceId,
      sinceMs,
      untilMs,
      worktreeId,
    );
  }

  listStoppedWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
    worktreeId?: string,
  ): Session[] {
    return this.sessionStore.listStoppedWorkspaceTimeRangeSessionSnapshots(
      workspaceId,
      sinceMs,
      untilMs,
      worktreeId,
    );
  }

  listWorkspaceSessionSummarySnapshots(): WorkspaceSessionSummarySnapshot[] {
    return this.sessionStore.listWorkspaceSessionSummarySnapshots();
  }

  listWorkspaceStoppedTimeBuckets(
    workspaceId: string,
    beforeMs: number,
    nowMs?: number,
    worktreeId?: string,
  ): WorkspaceStoppedTimeBucketSnapshot[] {
    return this.sessionStore.listWorkspaceStoppedTimeBuckets(
      workspaceId,
      beforeMs,
      nowMs,
      worktreeId,
    );
  }

  deleteSession(sessionId: string): boolean {
    const previousAssetId = iconAssetId(this.sessionStore.getSession(sessionId)?.launch?.agentIcon);
    const deleted = this.sessionStore.deleteSession(sessionId);
    if (deleted && previousAssetId) this.cleanupUnreferencedIconAssets(new Set([previousAssetId]));
    return deleted;
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
    const previousAssetId = iconAssetId(this.workspaceStore.getWorkspace(workspaceId)?.icon);
    const workspace = this.workspaceStore.updateWorkspace(workspaceId, updates);
    if (workspace && previousAssetId) {
      this.cleanupUnreferencedIconAssets(new Set([previousAssetId]));
    }
    return workspace;
  }

  deleteWorkspace(workspaceId: string): boolean {
    const previousAssetId = iconAssetId(this.workspaceStore.getWorkspace(workspaceId)?.icon);
    const deleted = this.workspaceStore.deleteWorkspace(workspaceId);
    if (deleted && previousAssetId) this.cleanupUnreferencedIconAssets(new Set([previousAssetId]));
    return deleted;
  }

  // ─── Agent definitions ───

  getAgentDefinitionStore(): AgentDefinitionStore {
    return this.agentDefinitionStore;
  }

  // ─── Icon assets ───

  getIconAssetStore(): IconAssetStore {
    return this.iconAssetStore;
  }

  putIconAsset(bytes: Buffer, declaredContentType: string | undefined): IconAssetRecord {
    // Reclaim only grace-expired abandoned uploads before enforcing the hard
    // quota. Fresh picker drafts retain their full save window.
    this.cleanupUnreferencedIconAssets(undefined, {
      now: Date.now(),
      graceMs: ICON_ASSET_ORPHAN_GRACE_MS,
    });
    return this.iconAssetStore.put(bytes, declaredContentType);
  }

  cleanupUnreferencedIconAssets(
    candidateAssetIds?: ReadonlySet<string>,
    options: { now?: number; graceMs?: number } = {},
  ): string[] {
    const referenced = new Set<string>();
    const add = (assetId: string | undefined): void => {
      if (assetId) referenced.add(assetId);
    };
    for (const agent of this.agentDefinitionStore.listAgents({ includeArchived: true })) {
      add(iconAssetId(agent.definition.icon));
    }
    for (const version of this.agentDefinitionStore.listAgentVersions()) {
      add(iconAssetId(version.definition.icon));
    }
    for (const workspace of this.workspaceStore.listWorkspaces()) add(iconAssetId(workspace.icon));
    for (const assetId of this.sessionStore.listReferencedIconAssetIds()) add(assetId);

    return this.iconAssetStore.collectUnreferenced(referenced, candidateAssetIds, options)
      .removedAssetIds;
  }

  // ─── Agent schedules ───

  getAgentScheduleStore(): AgentScheduleStore {
    return this.scheduleStore;
  }

  // ─── Helpers ───

  getDataDir(): string {
    return this.configStore.getDataDir();
  }
}
