/**
 * Journaled offline executor for the Session.id = Pi UUID cutover.
 *
 * It inventories a sealed source snapshot, classifies every blocking finding,
 * then rewrites a dedicated disposable workspace copy. It never writes the
 * live Oppi data directory and does not delete the public dual-ID surface.
 */

import {
  chmodSync,
  closeSync,
  constants,
  copyFileSync,
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import { openDatabase, openReadOnlyDatabase, type SqliteDatabase } from "../sqlite-compat.js";
import {
  inventorySessionIdMigration,
  type SessionIdMigrationInventoryOptions,
} from "./session-id-migration-inventory.js";
import {
  decideFieldAuthorityDuplicateMerge,
  type SessionIdMigrationMergeMember,
} from "./session-id-migration-merge.js";
import {
  type SessionIdMigrationDuplicateDispositionInput,
  type SessionIdMigrationFinding,
  type SessionIdMigrationManifest,
} from "./session-id-migration-planner.js";
import { assertSealedSqliteSnapshot } from "./session-id-migration-snapshot.js";

export const DISPOSABLE_COPIED_SESSION_ID_EXECUTOR_ACKNOWLEDGEMENT =
  "I_UNDERSTAND_THIS_MUTATES_A_DISPOSABLE_COPIED_PRODUCTION_SNAPSHOT" as const;

export type SessionIdMigrationExecutorPhase =
  | "backup"
  | "rewrite_session_state"
  | "rewrite_search"
  | "move_paths"
  | "rewrite_uploads";

export type SessionIdMigrationAcceptedLossKind =
  | "already_lost_current_trace"
  | "drop_non_uuid_smoke_session"
  | "drop_dangling_search_for_dropped_session"
  | "drop_dangling_upload_for_deleted_session"
  | "observe_only_non_session_workspace_path"
  | "observe_only_listing_path_not_copied"
  | "observe_only_review_comment"
  | "historical_unattributed_trace";

export interface SessionIdMigrationAcceptancePolicy {
  acceptUnavailableCurrentTracesAsAlreadyLost: boolean;
  dropSourceRowIds: readonly string[];
}

export interface SessionIdMigrationAcceptedLoss {
  kind: SessionIdMigrationAcceptedLossKind;
  location: string;
  detail: string;
  sourceRowId?: string;
}

export interface SessionIdMigrationExecutorBlocker {
  kind: string;
  location: string;
  detail: string;
  severity: "blocking";
}

export interface SessionIdMigrationClassification {
  status: "ready" | "blocked";
  acceptedLosses: SessionIdMigrationAcceptedLoss[];
  blockers: SessionIdMigrationExecutorBlocker[];
}

export interface SessionIdMigrationExecutorCounts {
  rekeyedSessionRows: number;
  discardedDuplicateRows: number;
  droppedSmokeSessions: number;
  droppedReviewComments: number;
  rewrittenSearchRows: number;
  movedAttachmentDirs: number;
  rewrittenUploads: number;
  droppedUploads: number;
  movedWorkspaceAttachmentDirs: number;
}

export interface SessionIdMigrationExecutorResult {
  status: "completed" | "blocked" | "rolled_back";
  alreadyCompleted: boolean;
  acceptedLosses: SessionIdMigrationAcceptedLoss[];
  blockers: SessionIdMigrationExecutorBlocker[];
  counts: SessionIdMigrationExecutorCounts;
  historicalIdentityLoss: {
    rows: number;
    discardedIdentities: number;
    availableTraces: number;
    unavailableTraces: number;
    unattributed: number;
  };
  tablesCreated: string[];
}

export interface SessionIdMigrationExecutorOptions
  extends SessionIdMigrationAcceptancePolicy, Partial<SessionIdMigrationInventoryOptions> {
  acknowledgement: typeof DISPOSABLE_COPIED_SESSION_ID_EXECUTOR_ACKNOWLEDGEMENT;
  workspaceDirectory: string;
  sessionState: {
    snapshotDirectory: string;
    databasePath: string;
  };
  /** Disposable copy of workspace .pi/attachments; inventory still uses the sealed listing. */
  workspaceAttachmentRoot?: string;
  crashAfter?: SessionIdMigrationExecutorPhase;
  rollback?: boolean;
}

interface JournalState {
  version: 1;
  status: "in_progress" | "completed" | "rolled_back";
  phase?: SessionIdMigrationExecutorPhase | "complete";
}

const LIVE_OPPI_ROOT = resolve(homedir(), ".config/oppi");
const LIVE_ROOT_ENTRIES = new Set([
  "session-state.db",
  "session-search.db",
  "session-attachments",
  "uploads",
  "sessions",
  "oppi.db",
  "sessions.db",
  "telemetry.db",
]);

const EMPTY_COUNTS: SessionIdMigrationExecutorCounts = {
  rekeyedSessionRows: 0,
  discardedDuplicateRows: 0,
  droppedSmokeSessions: 0,
  droppedReviewComments: 0,
  rewrittenSearchRows: 0,
  movedAttachmentDirs: 0,
  rewrittenUploads: 0,
  droppedUploads: 0,
  movedWorkspaceAttachmentDirs: 0,
};

const EMPTY_HISTORICAL = {
  rows: 0,
  discardedIdentities: 0,
  availableTraces: 0,
  unavailableTraces: 0,
  unattributed: 0,
};

/**
 * Classify every planner finding. Inventory status=blocked is not a free pass;
 * each blocking finding must be an accepted pre-existing loss or a real blocker.
 */
export function classifySessionIdMigrationFindings(
  manifest: SessionIdMigrationManifest,
  policy: SessionIdMigrationAcceptancePolicy,
): SessionIdMigrationClassification {
  const dropIds = new Set(policy.dropSourceRowIds);
  const rowBySource = new Map(manifest.rows.map((row) => [row.sourceRowId, row]));
  const acceptedLosses: SessionIdMigrationAcceptedLoss[] = [];
  const blockers: SessionIdMigrationExecutorBlocker[] = [];

  for (const finding of manifest.findings) {
    const classified = classifyFinding(finding, policy, dropIds, rowBySource);
    if (classified.kind === "accepted") {
      acceptedLosses.push(classified.loss);
      continue;
    }
    if (classified.kind === "ignore") continue;
    blockers.push({
      kind: finding.kind,
      location: finding.location,
      detail: finding.detail,
      severity: "blocking",
    });
  }

  for (const path of manifest.plannedOperations.paths) {
    if (path.outcome !== "rewrite" || !path.sourceSessionId) continue;
    if (dropIds.has(path.sourceSessionId)) continue;
    if (!isAbsolute(path.path)) continue;
    acceptedLosses.push({
      kind: "observe_only_listing_path_not_copied",
      location: path.location,
      detail: "absolute listing path is not a disposable copy target",
      sourceRowId: path.sourceSessionId,
    });
  }

  for (const reference of manifest.plannedOperations.references) {
    if (
      reference.policy === "observe_only" &&
      reference.location.includes("review_state_comments")
    ) {
      acceptedLosses.push({
        kind: "observe_only_review_comment",
        location: reference.location,
        detail: "leftover review_state_comments are dropped",
        ...(reference.sourceSessionId ? { sourceRowId: reference.sourceSessionId } : {}),
      });
    }
  }

  return {
    status: blockers.length > 0 ? "blocked" : "ready",
    acceptedLosses,
    blockers,
  };
}

export function executeSessionIdMigration(
  options: SessionIdMigrationExecutorOptions,
): SessionIdMigrationExecutorResult {
  if (options.acknowledgement !== DISPOSABLE_COPIED_SESSION_ID_EXECUTOR_ACKNOWLEDGEMENT) {
    throw new Error("Disposable copied session-id executor acknowledgement is required");
  }

  const liveBlocker = liveDataBlockers(options);
  if (liveBlocker) return blockedResult([liveBlocker]);

  const workspaceDirectory = resolve(options.workspaceDirectory);
  mkdirSync(workspaceDirectory, { recursive: true, mode: 0o700 });
  const lock = tryAcquireExclusiveLock(join(workspaceDirectory, "executor.lock"));
  if (!lock.ok) {
    return blockedResult([
      {
        kind: "exclusive_lock",
        location: `workspace:${workspaceDirectory}`,
        detail: lock.detail,
        severity: "blocking",
      },
    ]);
  }

  try {
    const journalPath = join(workspaceDirectory, "journal.json");
    const journal = readJournal(journalPath);
    if (options.rollback) {
      restoreBackup(workspaceDirectory);
      writeJournal(journalPath, { version: 1, status: "rolled_back" });
      return {
        status: "rolled_back",
        alreadyCompleted: false,
        acceptedLosses: [],
        blockers: [],
        counts: { ...EMPTY_COUNTS },
        historicalIdentityLoss: { ...EMPTY_HISTORICAL },
        tablesCreated: [],
      };
    }
    if (journal?.status === "completed") {
      return {
        status: "completed",
        alreadyCompleted: true,
        acceptedLosses: [],
        blockers: [],
        counts: { ...EMPTY_COUNTS },
        historicalIdentityLoss: { ...EMPTY_HISTORICAL },
        tablesCreated: [],
      };
    }
    if (journal?.status === "in_progress") {
      return blockedResult([
        {
          kind: "dirty_journal",
          location: journalPath,
          detail: "in-progress journal requires rollback before another apply",
          severity: "blocking",
        },
      ]);
    }

    assertSealedSqliteSnapshot(options.sessionState);
    if (options.searchSnapshot) assertSealedSqliteSnapshot(options.searchSnapshot);

    const escapeBlockers = inspectCopyRootsForEscapes(options);
    const manifest = inventorySessionIdMigration({
      snapshotDirectory: options.sessionState.snapshotDirectory,
      databasePath: options.sessionState.databasePath,
      allowedTraceRoots: options.allowedTraceRoots ?? [workspaceDirectory],
      ...(options.plannedUuidsBySourceRowId
        ? { plannedUuidsBySourceRowId: options.plannedUuidsBySourceRowId }
        : {}),
      ...(options.duplicateDispositions
        ? { duplicateDispositions: options.duplicateDispositions }
        : {}),
      ...(options.searchSnapshot ? { searchSnapshot: options.searchSnapshot } : {}),
      ...(options.attachmentManifestRoot
        ? { attachmentManifestRoot: options.attachmentManifestRoot }
        : {}),
      ...(options.uploadRecordRoot ? { uploadRecordRoot: options.uploadRecordRoot } : {}),
      ...(options.unnamedTraceRoot ? { unnamedTraceRoot: options.unnamedTraceRoot } : {}),
      ...(options.workspaceAttachmentListingPath
        ? { workspaceAttachmentListingPath: options.workspaceAttachmentListingPath }
        : {}),
      ...(options.traceEvidenceListingPath
        ? { traceEvidenceListingPath: options.traceEvidenceListingPath }
        : {}),
    });
    const classification = classifySessionIdMigrationFindings(manifest, {
      acceptUnavailableCurrentTracesAsAlreadyLost:
        options.acceptUnavailableCurrentTracesAsAlreadyLost,
      dropSourceRowIds: options.dropSourceRowIds,
    });
    const blockers = [...escapeBlockers, ...classification.blockers];
    if (blockers.length > 0) {
      return {
        ...blockedResult(blockers),
        acceptedLosses: classification.acceptedLosses,
        historicalIdentityLoss: summarizeHistorical(manifest),
      };
    }

    const mergeBlocker = preflightDuplicateMerges(options.sessionState.databasePath, manifest);
    if (mergeBlocker) return blockedResult([mergeBlocker]);

    const paths = workspacePaths(workspaceDirectory);
    materializeWorkingCopies(options, paths);
    writeJournal(journalPath, { version: 1, status: "in_progress", phase: "backup" });
    createBackup(paths);
    maybeCrash(options, "backup");

    const counts = { ...EMPTY_COUNTS };
    const tablesBefore = listUserTables(paths.sessionStateDb);
    rewriteSessionState(paths.sessionStateDb, manifest, options, counts);
    writeJournal(journalPath, {
      version: 1,
      status: "in_progress",
      phase: "rewrite_session_state",
    });
    maybeCrash(options, "rewrite_session_state");

    if (existsSync(paths.searchDb)) {
      rewriteSearch(paths.searchDb, manifest, options.dropSourceRowIds, counts);
    }
    writeJournal(journalPath, { version: 1, status: "in_progress", phase: "rewrite_search" });
    maybeCrash(options, "rewrite_search");

    moveCopiedPaths(paths, manifest, options.dropSourceRowIds, counts);
    writeJournal(journalPath, { version: 1, status: "in_progress", phase: "move_paths" });
    maybeCrash(options, "move_paths");

    rewriteUploads(paths.uploadRoot, manifest, options.dropSourceRowIds, counts);
    writeJournal(journalPath, { version: 1, status: "in_progress", phase: "rewrite_uploads" });
    maybeCrash(options, "rewrite_uploads");

    const tablesAfter = listUserTables(paths.sessionStateDb);
    writeJournal(journalPath, { version: 1, status: "completed", phase: "complete" });
    return {
      status: "completed",
      alreadyCompleted: false,
      acceptedLosses: classification.acceptedLosses,
      blockers: [],
      counts,
      historicalIdentityLoss: summarizeHistorical(manifest),
      tablesCreated: tablesAfter.filter((table) => !tablesBefore.includes(table)),
    };
  } finally {
    lock.release();
  }
}

function classifyFinding(
  finding: SessionIdMigrationFinding,
  policy: SessionIdMigrationAcceptancePolicy,
  dropIds: ReadonlySet<string>,
  rowBySource: ReadonlyMap<string, SessionIdMigrationManifest["rows"][number]>,
):
  | { kind: "accepted"; loss: SessionIdMigrationAcceptedLoss }
  | { kind: "ignore" }
  | { kind: "blocker" } {
  const sourceRowId = sourceRowIdFromLocation(finding.location);
  if (finding.severity !== "blocking") {
    if (finding.kind === "unclassified_trace" && finding.detail.includes("unattributed")) {
      return {
        kind: "accepted",
        loss: {
          kind: "historical_unattributed_trace",
          location: finding.location,
          detail: finding.detail,
          ...(sourceRowId ? { sourceRowId } : {}),
        },
      };
    }
    return { kind: "ignore" };
  }

  if (finding.kind === "target_collision" || finding.kind === "unresolved_duplicate_disposition") {
    return { kind: "blocker" };
  }
  if (finding.kind.startsWith("invalid_")) return { kind: "blocker" };

  if (
    sourceRowId &&
    dropIds.has(sourceRowId) &&
    (finding.kind === "unclassified_session" ||
      finding.kind === "unclassified_trace" ||
      finding.kind === "dangling_reference")
  ) {
    return {
      kind: "accepted",
      loss: {
        kind:
          finding.kind === "dangling_reference"
            ? "drop_dangling_search_for_dropped_session"
            : "drop_non_uuid_smoke_session",
        location: finding.location,
        detail: finding.detail,
        sourceRowId,
      },
    };
  }

  if (
    finding.kind === "dangling_reference" &&
    dropIds.has(sessionIdFromSearchOrStoreLocation(finding.location) ?? "")
  ) {
    return {
      kind: "accepted",
      loss: {
        kind: "drop_dangling_search_for_dropped_session",
        location: finding.location,
        detail: finding.detail,
        sourceRowId: sessionIdFromSearchOrStoreLocation(finding.location),
      },
    };
  }

  if (
    finding.kind === "unclassified_trace" &&
    finding.detail === "declared current trace is unavailable"
  ) {
    const row = sourceRowId ? rowBySource.get(sourceRowId) : undefined;
    if (policy.acceptUnavailableCurrentTracesAsAlreadyLost && row?.canonicalSessionId) {
      return {
        kind: "accepted",
        loss: {
          kind: "already_lost_current_trace",
          location: finding.location,
          detail: finding.detail,
          sourceRowId,
        },
      };
    }
    return { kind: "blocker" };
  }

  if (finding.kind === "dangling_reference" && finding.location.startsWith("upload-store:")) {
    return {
      kind: "accepted",
      loss: {
        kind: "drop_dangling_upload_for_deleted_session",
        location: finding.location,
        detail: finding.detail,
      },
    };
  }

  if (
    finding.kind === "dangling_reference" &&
    finding.location.startsWith("workspace-attachments:")
  ) {
    return {
      kind: "accepted",
      loss: {
        kind: "observe_only_non_session_workspace_path",
        location: finding.location,
        detail: finding.detail,
      },
    };
  }

  return { kind: "blocker" };
}

function liveDataBlockers(
  options: SessionIdMigrationExecutorOptions,
): SessionIdMigrationExecutorBlocker | undefined {
  const candidates = [
    options.workspaceDirectory,
    options.sessionState.snapshotDirectory,
    options.sessionState.databasePath,
    options.searchSnapshot?.snapshotDirectory,
    options.searchSnapshot?.databasePath,
    options.attachmentManifestRoot,
    options.uploadRecordRoot,
    options.workspaceAttachmentRoot,
  ].filter((value): value is string => typeof value === "string" && value.length > 0);
  for (const candidate of candidates) {
    if (isLiveOppiDataPath(candidate)) {
      return {
        kind: "live_data_path",
        location: candidate,
        detail: "refuses the live Oppi data directory",
        severity: "blocking",
      };
    }
  }
  return undefined;
}

function isLiveOppiDataPath(path: string): boolean {
  const resolved = resolve(path);
  if (resolved === LIVE_OPPI_ROOT) return true;
  if (dirname(resolved) === LIVE_OPPI_ROOT && LIVE_ROOT_ENTRIES.has(basename(resolved))) {
    return true;
  }
  if (!resolved.startsWith(`${LIVE_OPPI_ROOT}${sep}`)) return false;
  const rest = resolved.slice(LIVE_OPPI_ROOT.length + 1);
  return rest !== "worktrees" && !rest.startsWith(`worktrees${sep}`);
}

function inspectCopyRootsForEscapes(
  options: SessionIdMigrationExecutorOptions,
): SessionIdMigrationExecutorBlocker[] {
  const blockers: SessionIdMigrationExecutorBlocker[] = [];
  for (const [label, root] of [
    ["session-attachments", options.attachmentManifestRoot],
    ["workspace-attachments", options.workspaceAttachmentRoot],
    ["upload-records", options.uploadRecordRoot],
  ] as const) {
    if (!root) continue;
    blockers.push(...inspectRootForEscapes(root, label));
  }
  return blockers;
}

function inspectRootForEscapes(root: string, label: string): SessionIdMigrationExecutorBlocker[] {
  const blockers: SessionIdMigrationExecutorBlocker[] = [];
  if (!existsSync(root)) return blockers;
  let realRoot: string;
  try {
    const entry = lstatSync(root);
    if (entry.isSymbolicLink()) {
      return [
        {
          kind: "path_escape",
          location: `${label}:${root}`,
          detail: "copy root must not be a symlink",
          severity: "blocking",
        },
      ];
    }
    realRoot = realpathSync(root);
  } catch {
    return blockers;
  }
  for (const name of readdirSync(root)) {
    const child = join(root, name);
    let entry;
    try {
      entry = lstatSync(child);
    } catch {
      continue;
    }
    if (entry.isSymbolicLink()) {
      blockers.push({
        kind: "path_escape",
        location: `${label}:${name}`,
        detail: "refuses to follow a symlink out of the disposable copy",
        severity: "blocking",
      });
      continue;
    }
    if (!entry.isDirectory() && !entry.isFile()) {
      blockers.push({
        kind: "path_escape",
        location: `${label}:${name}`,
        detail: "copy entry must be a regular file or directory",
        severity: "blocking",
      });
      continue;
    }
    try {
      const real = realpathSync(child);
      if (!isWithinRoot(real, realRoot)) {
        blockers.push({
          kind: "path_escape",
          location: `${label}:${name}`,
          detail: "copy entry resolves outside its disposable root",
          severity: "blocking",
        });
      }
    } catch {
      blockers.push({
        kind: "path_escape",
        location: `${label}:${name}`,
        detail: "copy entry cannot be resolved inside its disposable root",
        severity: "blocking",
      });
    }
  }
  return blockers;
}

function tryAcquireExclusiveLock(
  lockPath: string,
): { ok: true; release: () => void } | { ok: false; detail: string } {
  try {
    const fd = openSync(lockPath, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    writeFileSync(fd, `${process.pid}\n`);
    return {
      ok: true,
      release: () => {
        try {
          closeSync(fd);
        } catch {
          // Lock release still unlinks even if close already happened.
        }
        try {
          unlinkSync(lockPath);
        } catch {
          // Best-effort lock cleanup.
        }
      },
    };
  } catch {
    return { ok: false, detail: "workspace already has an exclusive executor lock" };
  }
}

function workspacePaths(workspaceDirectory: string) {
  return {
    workspaceDirectory,
    sessionStateDb: join(workspaceDirectory, "session-state", "session-state.db"),
    searchDb: join(workspaceDirectory, "session-search", "session-search.db"),
    attachmentRoot: join(workspaceDirectory, "session-attachments"),
    uploadRoot: join(workspaceDirectory, "upload-records"),
    workspaceAttachmentRoot: join(workspaceDirectory, "workspace-attachments"),
    backupDirectory: join(workspaceDirectory, "backup"),
  };
}

type WorkspacePaths = ReturnType<typeof workspacePaths>;

function materializeWorkingCopies(
  options: SessionIdMigrationExecutorOptions,
  paths: WorkspacePaths,
): void {
  mkdirSync(dirname(paths.sessionStateDb), { recursive: true, mode: 0o700 });
  copyFileSync(options.sessionState.databasePath, paths.sessionStateDb);
  chmodSync(paths.sessionStateDb, 0o600);
  if (options.searchSnapshot) {
    mkdirSync(dirname(paths.searchDb), { recursive: true, mode: 0o700 });
    copyFileSync(options.searchSnapshot.databasePath, paths.searchDb);
    chmodSync(paths.searchDb, 0o600);
  }
  if (options.attachmentManifestRoot && existsSync(options.attachmentManifestRoot)) {
    copyTree(options.attachmentManifestRoot, paths.attachmentRoot);
  }
  if (options.uploadRecordRoot && existsSync(options.uploadRecordRoot)) {
    copyTree(options.uploadRecordRoot, paths.uploadRoot);
  }
  if (options.workspaceAttachmentRoot && existsSync(options.workspaceAttachmentRoot)) {
    copyTree(options.workspaceAttachmentRoot, paths.workspaceAttachmentRoot);
  }
}

function copyTree(source: string, destination: string): void {
  mkdirSync(dirname(destination), { recursive: true, mode: 0o700 });
  cpSync(source, destination, {
    recursive: true,
    dereference: false,
    errorOnExist: false,
    force: true,
  });
}

function createBackup(paths: WorkspacePaths): void {
  mkdirSync(paths.backupDirectory, { recursive: true, mode: 0o700 });
  vacuumInto(paths.sessionStateDb, join(paths.backupDirectory, "session-state.db"));
  if (existsSync(paths.searchDb)) {
    vacuumInto(paths.searchDb, join(paths.backupDirectory, "session-search.db"));
  }
  if (existsSync(paths.attachmentRoot)) {
    copyTree(paths.attachmentRoot, join(paths.backupDirectory, "session-attachments"));
  }
  if (existsSync(paths.uploadRoot)) {
    copyTree(paths.uploadRoot, join(paths.backupDirectory, "upload-records"));
  }
  if (existsSync(paths.workspaceAttachmentRoot)) {
    copyTree(paths.workspaceAttachmentRoot, join(paths.backupDirectory, "workspace-attachments"));
  }
}

function restoreBackup(workspaceDirectory: string): void {
  const paths = workspacePaths(workspaceDirectory);
  const backupState = join(paths.backupDirectory, "session-state.db");
  if (!existsSync(backupState)) {
    throw new Error("Executor backup is missing; cannot rollback");
  }
  copyFileSync(backupState, paths.sessionStateDb);
  chmodSync(paths.sessionStateDb, 0o600);
  const backupSearch = join(paths.backupDirectory, "session-search.db");
  if (existsSync(backupSearch)) {
    mkdirSync(dirname(paths.searchDb), { recursive: true, mode: 0o700 });
    copyFileSync(backupSearch, paths.searchDb);
    chmodSync(paths.searchDb, 0o600);
  }
  restoreTree(join(paths.backupDirectory, "session-attachments"), paths.attachmentRoot);
  restoreTree(join(paths.backupDirectory, "upload-records"), paths.uploadRoot);
  restoreTree(join(paths.backupDirectory, "workspace-attachments"), paths.workspaceAttachmentRoot);
}

function restoreTree(backup: string, destination: string): void {
  if (!existsSync(backup)) return;
  rmSync(destination, { recursive: true, force: true });
  copyTree(backup, destination);
}

function vacuumInto(sourcePath: string, destinationPath: string): void {
  if (existsSync(destinationPath)) unlinkSync(destinationPath);
  const db = openDatabase(sourcePath);
  try {
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    db.exec(`VACUUM INTO ${sqlQuote(destinationPath)}`);
  } finally {
    db.close();
  }
}

function rewriteSessionState(
  databasePath: string,
  manifest: SessionIdMigrationManifest,
  options: SessionIdMigrationExecutorOptions,
  counts: SessionIdMigrationExecutorCounts,
): void {
  const dropIds = new Set(options.dropSourceRowIds);
  const db = openDatabase(databasePath);
  try {
    const columns = tableColumns(db, "session_state_sessions");
    const rows = db.prepare(`SELECT * FROM session_state_sessions`).all() as Array<
      Record<string, unknown>
    >;
    const byId = new Map(rows.map((row) => [String(row.id), row]));
    const idMap = new Map<string, string>();
    for (const row of manifest.rows) {
      if (!row.canonicalSessionId || dropIds.has(row.sourceRowId)) continue;
      idMap.set(row.sourceRowId, row.canonicalSessionId);
    }
    const discardBySource = new Map(
      manifest.plannedOperations.sessionRows
        .filter((operation) => operation.kind === "discard_duplicate_row")
        .map((operation) => [operation.sourceRowId, operation]),
    );
    const rewriteLocations = new Set(
      manifest.plannedOperations.references
        .filter((reference) => reference.outcome === "rewrite" && reference.targetSessionId)
        .map((reference) => reference.location),
    );

    for (const sourceRowId of dropIds) {
      if (byId.has(sourceRowId)) {
        counts.droppedSmokeSessions += 1;
        byId.delete(sourceRowId);
      }
    }

    for (const [sourceRowId, operation] of discardBySource) {
      const discarded = byId.get(sourceRowId);
      const survivorId = operation.survivorSourceRowId;
      const survivor = survivorId ? byId.get(survivorId) : undefined;
      if (!discarded || !survivor || !survivorId) continue;
      applyMergedFields(survivor, discarded, operation.targetSessionId ?? "", survivorId);
      byId.delete(sourceRowId);
      counts.discardedDuplicateRows += 1;
    }

    const rewritten: Array<Record<string, unknown>> = [];
    for (const [sourceRowId, row] of byId) {
      const target = idMap.get(sourceRowId) ?? sourceRowId;
      const next: Record<string, unknown> = { ...row, id: target };
      const session = parseRecord(row.session_json);
      if (session) {
        session.id = target;
        if (typeof session.piSessionId === "string" && !normalizeUuid(session.piSessionId)) {
          throw new Error(
            `refuses to keep non-UUID identity as Session.id: ${session.piSessionId}`,
          );
        }
        delete session.piSessionId;
        rewriteLaunchParent(
          session,
          rewriteLocations.has(
            `sqlite:session_state_sessions:${sourceRowId}:session_json.launch.parentSessionId`,
          ),
          idMap,
        );
        next.session_json = JSON.stringify(session);
        copyProjectedFields(next, session, columns);
      }
      if (columns.has("pi_session_id")) {
        next.pi_session_id = null;
      }
      if (
        columns.has("parent_session_id") &&
        rewriteLocations.has(`sqlite:session_state_sessions:${sourceRowId}:parent_session_id`)
      ) {
        const parent =
          typeof row.parent_session_id === "string" ? row.parent_session_id : undefined;
        if (parent && idMap.has(parent)) next.parent_session_id = idMap.get(parent);
      }
      if (columns.has("launch_metadata_json") && typeof row.launch_metadata_json === "string") {
        const launch = parseRecord(row.launch_metadata_json);
        if (
          launch &&
          rewriteLocations.has(
            `sqlite:session_state_sessions:${sourceRowId}:launch_metadata_json.parentSessionId`,
          )
        ) {
          const parent =
            typeof launch.parentSessionId === "string" ? launch.parentSessionId : undefined;
          if (parent && idMap.has(parent)) {
            launch.parentSessionId = idMap.get(parent);
            next.launch_metadata_json = JSON.stringify(launch);
          }
        }
      }
      if (target !== sourceRowId) counts.rekeyedSessionRows += 1;
      rewritten.push(next);
    }

    replaceTable(db, "session_state_sessions", columns, rewritten);
    rewriteSchedules(db, rewriteLocations, idMap, manifest);
    if (tableExists(db, "review_state_comments")) {
      const deleted = db.prepare("SELECT COUNT(*) AS n FROM review_state_comments").get() as {
        n: number;
      };
      db.exec("DELETE FROM review_state_comments");
      counts.droppedReviewComments = deleted.n;
    }
  } finally {
    db.close();
  }
}

function applyMergedFields(
  survivor: Record<string, unknown>,
  discarded: Record<string, unknown>,
  targetSessionId: string,
  survivorSourceRowId: string,
): void {
  const members = [survivor, discarded].map((row) => {
    const session = parseRecord(row.session_json) ?? {};
    return {
      sourceRowId: String(row.id),
      targetSessionId,
      createdAt: numberField(session.createdAt, row.created_at),
      lastActivity: numberField(session.lastActivity, row.last_activity),
      ...(typeof session.lastAgentReplyAt === "number"
        ? { lastAgentReplyAt: session.lastAgentReplyAt }
        : {}),
      ...(typeof session.name === "string"
        ? { name: session.name }
        : typeof row.name === "string"
          ? { name: row.name }
          : {}),
      ...(typeof session.messageCount === "number"
        ? { messageCount: session.messageCount }
        : typeof row.message_count === "number"
          ? { messageCount: row.message_count }
          : {}),
      ...(typeof session.piSessionFile === "string"
        ? { piSessionFile: session.piSessionFile }
        : {}),
      ...(Array.isArray(session.piSessionFiles)
        ? {
            piSessionFiles: session.piSessionFiles.filter(
              (item): item is string => typeof item === "string",
            ),
          }
        : {}),
      ...(Array.isArray(session.warnings)
        ? { warnings: session.warnings.filter((item): item is string => typeof item === "string") }
        : {}),
      ...(typeof session.workspaceId === "string" ? { workspaceId: session.workspaceId } : {}),
      ...(typeof session.worktreeId === "string" ? { worktreeId: session.worktreeId } : {}),
      ...(typeof session.runtime === "string" ? { runtime: session.runtime } : {}),
    } satisfies SessionIdMigrationMergeMember;
  });
  const merged = decideFieldAuthorityDuplicateMerge(members, "executor-apply");
  if (!merged.ok) {
    throw new Error(`duplicate merge failed during apply: ${merged.detail}`);
  }
  if (merged.disposition.survivorSourceRowId !== survivorSourceRowId) {
    throw new Error("duplicate merge survivor disagrees with the approved disposition");
  }
  const session = parseRecord(survivor.session_json) ?? {};
  session.createdAt = merged.merged.createdAt;
  session.lastActivity = merged.merged.lastActivity;
  if (merged.merged.lastAgentReplyAt !== undefined) {
    session.lastAgentReplyAt = merged.merged.lastAgentReplyAt;
  }
  if (merged.merged.name) session.name = merged.merged.name;
  if (merged.merged.messageCount !== undefined) session.messageCount = merged.merged.messageCount;
  if (merged.merged.piSessionFile) session.piSessionFile = merged.merged.piSessionFile;
  session.piSessionFiles = merged.merged.piSessionFiles;
  session.warnings = merged.merged.warnings;
  survivor.session_json = JSON.stringify(session);
  if ("created_at" in survivor) survivor.created_at = merged.merged.createdAt;
  if ("last_activity" in survivor) survivor.last_activity = merged.merged.lastActivity;
  if ("name" in survivor && merged.merged.name) survivor.name = merged.merged.name;
  if ("message_count" in survivor && merged.merged.messageCount !== undefined) {
    survivor.message_count = merged.merged.messageCount;
  }
}

function rewriteLaunchParent(
  session: Record<string, unknown>,
  shouldRewrite: boolean,
  idMap: ReadonlyMap<string, string>,
): void {
  if (!shouldRewrite || !isRecord(session.launch)) return;
  const parent =
    typeof session.launch.parentSessionId === "string" ? session.launch.parentSessionId : undefined;
  if (parent && idMap.has(parent)) {
    session.launch = { ...session.launch, parentSessionId: idMap.get(parent) };
  }
}

function copyProjectedFields(
  row: Record<string, unknown>,
  session: Record<string, unknown>,
  columns: ReadonlySet<string>,
): void {
  if (columns.has("name") && typeof session.name === "string") row.name = session.name;
  if (columns.has("created_at") && typeof session.createdAt === "number") {
    row.created_at = session.createdAt;
  }
  if (columns.has("last_activity") && typeof session.lastActivity === "number") {
    row.last_activity = session.lastActivity;
  }
  if (columns.has("message_count") && typeof session.messageCount === "number") {
    row.message_count = session.messageCount;
  }
}

function rewriteSchedules(
  db: SqliteDatabase,
  rewriteLocations: ReadonlySet<string>,
  idMap: ReadonlyMap<string, string>,
  manifest: SessionIdMigrationManifest,
): void {
  if (!tableExists(db, "agent_schedules")) return;
  const rows = db.prepare("SELECT id, action_json FROM agent_schedules").all() as Array<{
    id: unknown;
    action_json: unknown;
  }>;
  const update = db.prepare("UPDATE agent_schedules SET action_json = ? WHERE id = ?");
  for (const row of rows) {
    const location = `sqlite:agent_schedules:${String(row.id)}:action_json.sessionId`;
    if (!rewriteLocations.has(location) && !manifestHasRewrite(manifest, location)) continue;
    const action = typeof row.action_json === "string" ? parseRecord(row.action_json) : undefined;
    if (!action || typeof action.sessionId !== "string") continue;
    const target = idMap.get(action.sessionId);
    if (!target || target === action.sessionId) continue;
    update.run(JSON.stringify({ ...action, sessionId: target }), row.id);
  }
}

function manifestHasRewrite(manifest: SessionIdMigrationManifest, location: string): boolean {
  return manifest.plannedOperations.references.some(
    (reference) => reference.location === location && reference.outcome === "rewrite",
  );
}

function replaceTable(
  db: SqliteDatabase,
  table: string,
  columns: ReadonlySet<string>,
  rows: Array<Record<string, unknown>>,
): void {
  const columnList = [...columns];
  const quoted = columnList.map((column) => quoteIdent(column)).join(", ");
  const placeholders = columnList.map(() => "?").join(", ");
  db.exec("BEGIN");
  try {
    db.exec(`DELETE FROM ${quoteIdent(table)}`);
    const insert = db.prepare(
      `INSERT INTO ${quoteIdent(table)} (${quoted}) VALUES (${placeholders})`,
    );
    for (const row of rows) {
      insert.run(...columnList.map((column) => row[column] ?? null));
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function rewriteSearch(
  databasePath: string,
  manifest: SessionIdMigrationManifest,
  dropSourceRowIds: readonly string[],
  counts: SessionIdMigrationExecutorCounts,
): void {
  const dropIds = new Set(dropSourceRowIds);
  const idMap = new Map<string, string>();
  const discarded = new Set(
    manifest.plannedOperations.sessionRows
      .filter((operation) => operation.kind === "discard_duplicate_row")
      .map((operation) => operation.sourceRowId),
  );
  for (const row of manifest.rows) {
    if (!row.canonicalSessionId || dropIds.has(row.sourceRowId)) continue;
    idMap.set(row.sourceRowId, row.canonicalSessionId);
  }
  const db = openDatabase(databasePath);
  try {
    remapSearchTable(db, "fts_meta", idMap, dropIds, discarded, counts);
    remapSearchTable(db, "session_fts", idMap, dropIds, discarded, counts);
  } finally {
    db.close();
  }
}

function remapSearchTable(
  db: SqliteDatabase,
  table: "fts_meta" | "session_fts",
  idMap: ReadonlyMap<string, string>,
  dropIds: ReadonlySet<string>,
  discarded: ReadonlySet<string>,
  counts: SessionIdMigrationExecutorCounts,
): void {
  if (!tableExists(db, table)) return;
  const columns = [...tableColumns(db, table)];
  if (!columns.includes("session_id")) return;
  const rows = db.prepare(`SELECT * FROM ${table}`).all() as Array<Record<string, unknown>>;
  const kept: Array<Record<string, unknown>> = [];
  const seenTargets = new Set<string>();
  for (const row of rows) {
    const source = typeof row.session_id === "string" ? row.session_id : "";
    if (dropIds.has(source) || discarded.has(source)) continue;
    const target = idMap.get(source) ?? source;
    if (seenTargets.has(target)) continue;
    seenTargets.add(target);
    if (target !== source) counts.rewrittenSearchRows += 1;
    kept.push({ ...row, session_id: target });
  }
  db.exec(`DELETE FROM ${table}`);
  if (kept.length === 0) return;
  const quoted = columns.map((column) => quoteIdent(column)).join(", ");
  const placeholders = columns.map(() => "?").join(", ");
  const insert = db.prepare(`INSERT INTO ${table} (${quoted}) VALUES (${placeholders})`);
  for (const row of kept) {
    insert.run(...columns.map((column) => row[column] ?? null));
  }
}

function moveCopiedPaths(
  paths: WorkspacePaths,
  manifest: SessionIdMigrationManifest,
  dropSourceRowIds: readonly string[],
  counts: SessionIdMigrationExecutorCounts,
): void {
  const dropIds = new Set(dropSourceRowIds);
  const idMap = new Map(
    manifest.rows.flatMap((row) =>
      row.canonicalSessionId && !dropIds.has(row.sourceRowId)
        ? [[row.sourceRowId, row.canonicalSessionId] as const]
        : [],
    ),
  );
  if (existsSync(paths.attachmentRoot)) {
    counts.movedAttachmentDirs += renameMappedDirectories(
      paths.attachmentRoot,
      idMap,
      rewriteAttachmentManifest,
    );
  }
  if (existsSync(paths.workspaceAttachmentRoot)) {
    counts.movedWorkspaceAttachmentDirs += renameMappedDirectories(
      paths.workspaceAttachmentRoot,
      idMap,
    );
  }
}

function renameMappedDirectories(
  root: string,
  idMap: ReadonlyMap<string, string>,
  afterRename?: (directory: string, sourceId: string, targetId: string) => void,
): number {
  let moved = 0;
  const realRoot = realpathSync(root);
  for (const [sourceId, targetId] of [...idMap.entries()].sort(([left], [right]) =>
    compareDeterministic(left, right),
  )) {
    if (sourceId === targetId) continue;
    const source = join(root, sourceId);
    if (!existsSync(source)) continue;
    const sourceEntry = lstatSync(source);
    if (sourceEntry.isSymbolicLink() || !sourceEntry.isDirectory()) {
      throw new Error(`path escape while renaming ${source}`);
    }
    if (!isWithinRoot(realpathSync(source), realRoot)) {
      throw new Error(`path escape while renaming ${source}`);
    }
    const destination = join(realRoot, targetId);
    if (existsSync(destination)) {
      throw new Error(`target collision while renaming ${sourceId} -> ${targetId}`);
    }
    if (!isWithinRoot(destination, realRoot)) {
      throw new Error(`path escape while renaming ${source} -> ${destination}`);
    }
    renameSync(source, destination);
    afterRename?.(destination, sourceId, targetId);
    moved += 1;
  }
  return moved;
}

function rewriteAttachmentManifest(directory: string, sourceId: string, targetId: string): void {
  const manifestPath = join(directory, "manifest.json");
  if (!existsSync(manifestPath)) return;
  const parsed = parseRecord(readFileSync(manifestPath, "utf8"));
  if (!parsed || !Array.isArray(parsed.attachments)) return;
  parsed.attachments = parsed.attachments.map((attachment) => {
    if (!isRecord(attachment) || typeof attachment.storageKey !== "string") return attachment;
    if (!attachment.storageKey.startsWith(`${sourceId}/`)) return attachment;
    return {
      ...attachment,
      storageKey: `${targetId}/${attachment.storageKey.slice(sourceId.length + 1)}`,
    };
  });
  writeFileSync(manifestPath, JSON.stringify(parsed));
}

function rewriteUploads(
  uploadRoot: string,
  manifest: SessionIdMigrationManifest,
  dropSourceRowIds: readonly string[],
  counts: SessionIdMigrationExecutorCounts,
): void {
  if (!existsSync(uploadRoot)) return;
  const dropIds = new Set(dropSourceRowIds);
  const idMap = new Map(
    manifest.rows.flatMap((row) =>
      row.canonicalSessionId && !dropIds.has(row.sourceRowId)
        ? [[row.sourceRowId, row.canonicalSessionId] as const]
        : [],
    ),
  );
  const danglingSources = new Set(
    manifest.plannedOperations.references
      .filter(
        (reference) =>
          reference.outcome === "dangling" && reference.location.startsWith("upload-store:"),
      )
      .map((reference) => reference.sourceSessionId)
      .filter((value): value is string => typeof value === "string"),
  );
  for (const entry of readdirSync(uploadRoot).sort(compareDeterministic)) {
    if (!entry.endsWith(".json")) continue;
    const filePath = join(uploadRoot, entry);
    const parsed = parseRecord(readFileSync(filePath, "utf8"));
    if (!parsed || parsed.sessionId === undefined || parsed.sessionId === null) continue;
    if (typeof parsed.sessionId !== "string") continue;
    if (danglingSources.has(parsed.sessionId) || dropIds.has(parsed.sessionId)) {
      unlinkSync(filePath);
      counts.droppedUploads += 1;
      continue;
    }
    const target = idMap.get(parsed.sessionId);
    if (!target || target === parsed.sessionId) continue;
    writeFileSync(filePath, JSON.stringify({ ...parsed, sessionId: target }));
    counts.rewrittenUploads += 1;
  }
}

function preflightDuplicateMerges(
  databasePath: string,
  manifest: SessionIdMigrationManifest,
): SessionIdMigrationExecutorBlocker | undefined {
  const approved = manifest.duplicateGroups.filter((group) => group.resolution === "approved");
  if (approved.length === 0) return undefined;
  const db = openReadOnlyDatabase(databasePath);
  try {
    const rows = db.prepare("SELECT id, session_json FROM session_state_sessions").all() as Array<{
      id: string;
      session_json: string;
    }>;
    const byId = new Map(rows.map((row) => [row.id, row]));
    for (const group of approved) {
      const members: SessionIdMigrationMergeMember[] = group.memberSourceRowIds.map(
        (sourceRowId) => {
          const session = parseRecord(byId.get(sourceRowId)?.session_json) ?? {};
          return {
            sourceRowId,
            targetSessionId: group.canonicalSessionId,
            createdAt: typeof session.createdAt === "number" ? session.createdAt : 0,
            lastActivity: typeof session.lastActivity === "number" ? session.lastActivity : 0,
            ...(typeof session.name === "string" ? { name: session.name } : {}),
            ...(typeof session.messageCount === "number"
              ? { messageCount: session.messageCount }
              : {}),
          };
        },
      );
      const merged = decideFieldAuthorityDuplicateMerge(members, group.decisionId ?? "preflight");
      if (!merged.ok) {
        return {
          kind: "invalid_duplicate_disposition",
          location: `target:${group.canonicalSessionId}`,
          detail: merged.detail,
          severity: "blocking",
        };
      }
      if (merged.disposition.survivorSourceRowId !== group.survivorSourceRowId) {
        return {
          kind: "invalid_duplicate_disposition",
          location: `target:${group.canonicalSessionId}`,
          detail: "field-authority survivor disagrees with the approved disposition",
          severity: "blocking",
        };
      }
    }
  } finally {
    db.close();
  }
  return undefined;
}

function maybeCrash(
  options: SessionIdMigrationExecutorOptions,
  phase: SessionIdMigrationExecutorPhase,
): void {
  if (options.crashAfter === phase) {
    throw new Error(`injected crash after ${phase}`);
  }
}

function readJournal(path: string): JournalState | undefined {
  if (!existsSync(path)) return undefined;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as JournalState;
    return parsed.version === 1 ? parsed : undefined;
  } catch {
    return undefined;
  }
}

function writeJournal(path: string, journal: JournalState): void {
  writeFileSync(path, `${JSON.stringify(journal)}\n`);
}

function listUserTables(databasePath: string): string[] {
  if (!existsSync(databasePath)) return [];
  const db = openReadOnlyDatabase(databasePath);
  try {
    const rows = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .all() as Array<{ name?: unknown }>;
    return rows.flatMap((row) => (typeof row.name === "string" ? [row.name] : []));
  } finally {
    db.close();
  }
}

function tableExists(db: SqliteDatabase, table: string): boolean {
  return Boolean(
    db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table),
  );
}

function tableColumns(db: SqliteDatabase, table: string): Set<string> {
  const rows = db.prepare(`PRAGMA table_info(${quoteIdent(table)})`).all() as Array<{
    name?: unknown;
  }>;
  return new Set(rows.flatMap((row) => (typeof row.name === "string" ? [row.name] : [])));
}

function summarizeHistorical(manifest: SessionIdMigrationManifest) {
  return {
    rows: manifest.historicalIdentityLosses.length,
    discardedIdentities: manifest.historicalIdentityLosses.reduce(
      (sum, loss) => sum + loss.discardedIdentityCount,
      0,
    ),
    availableTraces: manifest.historicalIdentityLosses.reduce(
      (sum, loss) => sum + loss.availableTraceCount,
      0,
    ),
    unavailableTraces: manifest.historicalIdentityLosses.reduce(
      (sum, loss) => sum + loss.unavailableTraceCount,
      0,
    ),
    unattributed: manifest.historicalIdentityLosses.reduce(
      (sum, loss) => sum + loss.unattributedHistoricalTraceCount,
      0,
    ),
  };
}

function blockedResult(
  blockers: SessionIdMigrationExecutorBlocker[],
): SessionIdMigrationExecutorResult {
  return {
    status: "blocked",
    alreadyCompleted: false,
    acceptedLosses: [],
    blockers,
    counts: { ...EMPTY_COUNTS },
    historicalIdentityLoss: { ...EMPTY_HISTORICAL },
    tablesCreated: [],
  };
}

function sourceRowIdFromLocation(location: string): string | undefined {
  if (!location.startsWith("session-row:")) return undefined;
  const rest = location.slice("session-row:".length);
  const current = rest.indexOf(":current-file:");
  if (current >= 0) return rest.slice(0, current);
  const historical = rest.indexOf(":historical-file:");
  if (historical >= 0) return rest.slice(0, historical);
  return rest || undefined;
}

function sessionIdFromSearchOrStoreLocation(location: string): string | undefined {
  const search = /^session-search:(?:fts_meta|session_fts):(.+):session_id$/.exec(location);
  if (search?.[1]) return search[1];
  return undefined;
}

function parseRecord(raw: unknown): Record<string, unknown> | undefined {
  if (typeof raw !== "string") return undefined;
  try {
    const parsed = JSON.parse(raw) as unknown;
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function numberField(primary: unknown, fallback: unknown): number {
  if (typeof primary === "number") return primary;
  if (typeof fallback === "number") return fallback;
  return 0;
}

function normalizeUuid(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(trimmed)
    ? trimmed.toLowerCase()
    : undefined;
}

function isWithinRoot(path: string, root: string): boolean {
  const relation = relative(root, path);
  return relation === "" || (!!relation && !relation.startsWith("..") && !isAbsolute(relation));
}

function sqlQuote(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function quoteIdent(value: string): string {
  return `"${value.replaceAll('"', '""')}"`;
}

function compareDeterministic(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

export type { SessionIdMigrationDuplicateDispositionInput };
