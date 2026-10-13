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

import { closeSync, existsSync, openSync, readSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createLogger } from "./logger.js";
import { AgentDefinitionStore } from "./agent-definitions.js";
import { iconAssetId } from "./icon-choice.js";
import { AgentScheduleStore } from "./agent-schedules.js";
import { syncProgramStatus } from "./program-status.js";
import { AuthStore } from "./storage/auth-store.js";
import {
  DeviceAuthStore,
  type AccessTokenValidation,
  type Challenge,
  type EnrollResult,
  type PairingTokenConsumption,
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
import { MobileOutputGuideSettingsStore } from "./storage/mobile-output-guide-settings-store.js";
import { SessionSqliteStore, type RestartResumeEntry } from "./storage/session-sqlite-store.js";
import { WorkspaceStore } from "./storage/workspace-store.js";
import type { MobileOutputGuideSettingsSnapshot } from "./mobile-output-guide-settings.js";
import type {
  CreateWorkspaceRequest,
  DevicePairingInfo,
  DevicePublicKey,
  PairingTokenOrigin,
  PushRegistration,
  ServerConfig,
  Session,
  SessionInteraction,
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
  private readonly mobileOutputGuideSettingsStore: MobileOutputGuideSettingsStore;
  private readonly agentDefinitionStore: AgentDefinitionStore;
  private readonly scheduleStore: AgentScheduleStore;
  private readonly workspaceStore: WorkspaceStore;
  /** Workspace id → name, built on first use and dropped on every workspace write. */
  private workspaceNames: Map<string, string> | undefined;

  /**
   * `migrateWorkspaceFolders` is for the one process that serves this data directory: it gives
   * older workspace records their folder before anything reads them. Other openers (scripts,
   * tests) never migrate; a record that still lacks a folder makes their reads throw.
   */
  constructor(dataDir?: string, options: { migrateWorkspaceFolders?: boolean } = {}) {
    this.configStore = new ConfigStore(dataDir ?? DEFAULT_DATA_DIR);
    this.authStore = new AuthStore(this.configStore);
    this.deviceAuthStore = new DeviceAuthStore(this.configStore);
    this.sessionStore = new SessionSqliteStore(this.configStore.getDataDir());
    this.iconAssetStore = new IconAssetStore(this.configStore.getDataDir());
    this.mobileOutputGuideSettingsStore = new MobileOutputGuideSettingsStore(
      this.configStore.getDataDir(),
    );
    this.agentDefinitionStore = new AgentDefinitionStore(
      this.configStore.getDataDir(),
      undefined,
      (assetId) => this.iconAssetStore.has(assetId),
    );
    this.scheduleStore = new AgentScheduleStore(this.configStore.getDataDir());
    this.workspaceStore = new WorkspaceStore(this.configStore, (assetId) =>
      this.iconAssetStore.has(assetId),
    );
    if (options.migrateWorkspaceFolders) {
      this.workspaceStore.migrateMissingHostMounts();
    }
    this.migrateLegacyWorkspaceSessions();
    // Reconcile only after Agent current/version history, workspaces, and
    // immutable session launch snapshots are all available.
    this.cleanupUnreferencedIconAssets(undefined, {
      now: Date.now(),
      graceMs: ICON_ASSET_ORPHAN_GRACE_MS,
    });
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
        .filter((candidate) => pathContains(candidate.hostMount, cwd))
        .sort((a, b) => normalizedPath(b.hostMount).length - normalizedPath(a.hostMount).length);
      const workspace = candidates[0];
      const workspaceMountLength = workspace ? normalizedPath(workspace.hostMount).length : 0;
      const hasAmbiguousTie =
        candidates.length > 1 &&
        normalizedPath(candidates[1]?.hostMount ?? "").length === workspaceMountLength;

      if (!workspace || hasAmbiguousTie) {
        skipped += 1;
        continue;
      }

      session.workspaceId = workspace.id;
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

  describeInvalidTlsConfig(): string | null {
    return this.configStore.describeInvalidTlsConfig();
  }

  getConfigPath(): string {
    return this.configStore.getConfigPath();
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    this.configStore.updateConfig(updates);
  }

  mutateConfig(mutator: (latest: ServerConfig) => Partial<ServerConfig>): ServerConfig {
    return this.configStore.mutate(mutator);
  }

  // ─── Mobile Output Guide settings ───

  getMobileOutputGuideSettings(): MobileOutputGuideSettingsSnapshot {
    return this.mobileOutputGuideSettingsStore.get();
  }

  getMobileOutputGuideSettingsLoadError(): string | undefined {
    return this.mobileOutputGuideSettingsStore.getLoadError();
  }

  replaceMobileOutputGuideSettings(
    baseRevision: unknown,
    desired: unknown,
  ): ReturnType<MobileOutputGuideSettingsStore["replace"]> {
    return this.mobileOutputGuideSettingsStore.replace(baseRevision, desired);
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

  issuePairingToken(ttlMs?: number, origin?: Omit<PairingTokenOrigin, "ttlMs">): string {
    return this.authStore.issuePairingToken(ttlMs, origin);
  }

  clearPairingToken(): void {
    this.authStore.clearPairingToken();
  }

  // ─── Device-key auth ───

  enrollViaPairing(
    candidate: string,
    deviceInput: { publicKey: unknown; name?: unknown },
  ): EnrollResult | null {
    return this.deviceAuthStore.enrollViaPairing(candidate, deviceInput);
  }

  consumePairingToken(
    candidate: string,
    admit?: (origin: PairingTokenOrigin, activeDeviceCount: number) => boolean,
  ): PairingTokenConsumption {
    return this.deviceAuthStore.consumePairingToken(candidate, admit);
  }

  enrollDevice(input: {
    publicKey: DevicePublicKey;
    name: string;
    pairing: DevicePairingInfo;
  }): EnrollResult {
    return this.deviceAuthStore.enrollDevice(input);
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

  revokeDevice(deviceId: string): boolean {
    return this.deviceAuthStore.revokeDevice(deviceId);
  }

  listDevices(): ReturnType<DeviceAuthStore["listDevices"]> {
    return this.deviceAuthStore.listDevices();
  }

  getOwnerName(): string {
    return this.authStore.getOwnerName();
  }

  getPushRegistrations(): PushRegistration[] {
    return this.authStore.getPushRegistrations();
  }

  setPushRegistration(
    registration: Omit<PushRegistration, "registeredAt">,
  ): PushRegistration | null | false {
    return this.authStore.setPushRegistration(registration);
  }

  removePushRegistration(deviceId: string, sendToken?: string): PushRegistration | null {
    return this.authStore.removePushRegistration(deviceId, sendToken);
  }

  // ─── Sessions ───

  createSession(name?: string, model?: string, options?: { id?: string }): Session {
    return this.sessionStore.createSession(name, model, options);
  }

  /**
   * `Session.workspaceName` is not stored with the session: every session this class hands out
   * or saves gets the current name of its workspace, and none when the workspace is gone.
   * Set in place, like `programStatus` in `saveSession`, so held objects stay current.
   */
  private withWorkspaceName<T extends Session | undefined>(session: T): T {
    if (!session) return session;
    const name = session.workspaceId ? this.workspaceNameOf(session.workspaceId) : undefined;
    if (name === undefined) delete session.workspaceName;
    else session.workspaceName = name;
    return session;
  }

  private withWorkspaceNames(sessions: Session[]): Session[] {
    for (const session of sessions) this.withWorkspaceName(session);
    return sessions;
  }

  private workspaceNameOf(workspaceId: string): string | undefined {
    this.workspaceNames ??= new Map(
      this.workspaceStore.listWorkspaces().map((workspace) => [workspace.id, workspace.name]),
    );
    return this.workspaceNames.get(workspaceId);
  }

  saveSession(session: Session): void {
    // Normalizes stopped and error rows. These lifecycle states have no live run to ask, so
    // program status follows from lifecycle and the stored outcome alone. Deriving it here
    // covers every writer (stop of a disconnected mirror, launch failures) and keeps
    // `working`/`blocked` from outliving the lifecycle. It writes `programStatus` back onto the
    // caller's object, and callers rely on that (the broadcast after a disconnected-mirror stop
    // sends this very object). Live sessions are synced by their runtime before they reach this
    // point. `starting` is excluded on purpose: its row is written before any runtime exists, and
    // storing `working` there would erase the last outcome if the server stops mid-start.
    // Do not add a tenth sync site elsewhere; extend this one.
    if (session.status === "stopped" || session.status === "error") {
      syncProgramStatus({ session });
    }
    this.sessionStore.saveSession(session);
    this.withWorkspaceName(session);
  }

  getSession(sessionId: string): Session | undefined {
    return this.withWorkspaceName(this.sessionStore.getSession(sessionId));
  }

  findSessionByLaunchIdempotencyKey(idempotencyKey: string): Session | undefined {
    return this.withWorkspaceName(
      this.sessionStore.findSessionByLaunchIdempotencyKey(idempotencyKey),
    );
  }

  /** Session bound to a durable store's conversation; an indexed lookup. */
  findSessionByDurableConversation(storeId: string, conversationId: number): Session | undefined {
    return this.withWorkspaceName(
      this.sessionStore.findSessionByDurableConversation(storeId, conversationId),
    );
  }

  /** Session ids bound to conversations of one durable store; an indexed lookup. */
  listDurableStoreConversations(
    storeId: string,
  ): Array<{ sessionId: string; conversationId: number }> {
    return this.sessionStore.listDurableStoreConversations(storeId);
  }

  claimSessionLaunchRecovery(
    session: Session,
    leaseOwner: string,
    nowMs: number,
    leaseTtlMs: number,
  ): Session | undefined {
    return this.withWorkspaceName(
      this.sessionStore.claimSessionLaunchRecovery(session, leaseOwner, nowMs, leaseTtlMs),
    );
  }

  listSessions(): Session[] {
    return this.withWorkspaceNames(this.sessionStore.listSessions());
  }

  listAllWorkspaceSessionSnapshots(workspaceId: string, worktreeId?: string): Session[] {
    return this.withWorkspaceNames(
      this.sessionStore.listAllWorkspaceSessionSnapshots(workspaceId, worktreeId),
    );
  }

  listRecentWorkspaceSessionSnapshots(
    workspaceId: string,
    recentDays: number,
    nowMs?: number,
    worktreeId?: string,
  ): Session[] {
    return this.withWorkspaceNames(
      this.sessionStore.listRecentWorkspaceSessionSnapshots(
        workspaceId,
        recentDays,
        nowMs,
        worktreeId,
      ),
    );
  }

  listWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
    worktreeId?: string,
  ): Session[] {
    return this.withWorkspaceNames(
      this.sessionStore.listWorkspaceTimeRangeSessionSnapshots(
        workspaceId,
        sinceMs,
        untilMs,
        worktreeId,
      ),
    );
  }

  listStoppedWorkspaceTimeRangeSessionSnapshots(
    workspaceId: string,
    sinceMs: number,
    untilMs: number,
    worktreeId?: string,
  ): Session[] {
    return this.withWorkspaceNames(
      this.sessionStore.listStoppedWorkspaceTimeRangeSessionSnapshots(
        workspaceId,
        sinceMs,
        untilMs,
        worktreeId,
      ),
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

  recordSessionInteraction(
    input: Parameters<SessionSqliteStore["recordSessionInteraction"]>[0],
  ): void {
    this.sessionStore.recordSessionInteraction(input);
  }

  listSessionInteractions(sessionIds: readonly string[]): SessionInteraction[] {
    return this.sessionStore.listSessionInteractions(sessionIds);
  }

  queueRestartResume(entries: readonly RestartResumeEntry[], recordedAt: number): void {
    this.sessionStore.queueRestartResume(entries, recordedAt);
  }

  listRestartResume(): RestartResumeEntry[] {
    return this.sessionStore.listRestartResume();
  }

  clearRestartResume(sessionId: string): void {
    this.sessionStore.clearRestartResume(sessionId);
  }

  deleteSession(sessionId: string): boolean {
    const previousAssetId = iconAssetId(this.sessionStore.getSession(sessionId)?.launch?.agentIcon);
    const deleted = this.sessionStore.deleteSession(sessionId);
    if (deleted && previousAssetId) this.cleanupUnreferencedIconAssets(new Set([previousAssetId]));
    return deleted;
  }

  // ─── Workspaces ───

  createWorkspace(req: CreateWorkspaceRequest): Workspace {
    this.workspaceNames = undefined;
    return this.workspaceStore.createWorkspace(req);
  }

  saveWorkspace(workspace: Workspace): void {
    this.workspaceNames = undefined;
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
    this.workspaceNames = undefined;
    const workspace = this.workspaceStore.updateWorkspace(workspaceId, updates);
    if (workspace && previousAssetId) {
      this.cleanupUnreferencedIconAssets(new Set([previousAssetId]));
    }
    return workspace;
  }

  deleteWorkspace(workspaceId: string): boolean {
    const previousAssetId = iconAssetId(this.workspaceStore.getWorkspace(workspaceId)?.icon);
    this.workspaceNames = undefined;
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
