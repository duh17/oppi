/**
 * Read-only evidence adapter for the Session.id = Pi UUID cutover.
 *
 * It accepts only a caller-supplied SQLite copy and explicit trace roots. It
 * never opens the configured Oppi data directory, walks a root, or writes.
 */

import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  realpathSync,
} from "node:fs";
import { basename, extname, isAbsolute, join, relative, resolve } from "node:path";

import { openReadOnlyDatabase, type SqliteDatabase } from "../sqlite-compat.js";
import {
  assertNormalizedSqliteSnapshotDatabase,
  assertSealedSqliteSnapshot,
} from "./session-id-migration-snapshot.js";
import {
  planSessionIdMigration,
  type SessionIdMigrationDuplicateDispositionInput,
  type SessionIdMigrationFileEvidence,
  type SessionIdMigrationManifest,
  type SessionIdMigrationPathInput,
  type SessionIdMigrationPlannerInput,
  type SessionIdMigrationReferenceInput,
  type SessionIdMigrationReferencePolicy,
  type SessionIdMigrationSessionRowInput,
} from "./session-id-migration-planner.js";

const SESSION_TABLE = "session_state_sessions";
const SCHEDULE_TABLE = "agent_schedules";
const SCHEDULE_RUN_TABLE = "agent_schedule_runs";
const SESSION_COLUMNS = [
  "id",
  "session_json",
  "pi_session_id",
  "pi_session_file",
  "pi_session_files_json",
  "parent_session_id",
  "launch_metadata_json",
] as const;

interface SessionInventoryRow {
  id: unknown;
  session_json: unknown;
  pi_session_id: unknown;
  pi_session_file: unknown;
  pi_session_files_json: unknown;
  parent_session_id: unknown;
  launch_metadata_json: unknown;
}

interface ScheduleInventoryRow {
  id: unknown;
  action_json: unknown;
}

interface ScheduleRunInventoryRow {
  id: unknown;
  action_snapshot_json: unknown;
  result_json: unknown;
}

interface AllowedTraceRoot {
  lexical: string;
  real: string;
}

interface InventoryCoverage {
  acceptedInputs: string[];
  notInventoried: string[];
  inspectedButAbsent: string[];
  unavailable: string[];
}

export interface SessionIdMigrationInventoryOptions {
  /** Explicit dedicated directory holding only the normalized, sealed database copy. */
  snapshotDirectory: string;
  /** Explicit path to that normalized, sealed copied SQLite database. */
  databasePath: string;
  /** Explicit roots that may contain trace files named by session rows. */
  allowedTraceRoots: readonly string[];
  /** Caller-approved UUIDs for rows without a current Pi identity. */
  plannedUuidsBySourceRowId?: Readonly<Record<string, string | undefined>>;
  /** Caller-approved duplicate survivors; inventory never selects one. */
  duplicateDispositions?: readonly SessionIdMigrationDuplicateDispositionInput[];
  /** Optional sealed session-search.db copy. */
  searchSnapshot?: {
    snapshotDirectory: string;
    databasePath: string;
  };
  /** Dedicated copy of session-attachments/<sessionId>/manifest.json files. */
  attachmentManifestRoot?: string;
  /** Dedicated copy of upload-store records, not live blobs. */
  uploadRecordRoot?: string;
  /** Dedicated copy of server-owned traces not necessarily named by a Session row. */
  unnamedTraceRoot?: string;
  /** Sealed JSON listing of workspace .pi/attachments/<sessionId> directories. */
  workspaceAttachmentListingPath?: string;
  /** Sealed JSON array of named-trace file evidence; used instead of opening live paths. */
  traceEvidenceListingPath?: string;
}

/**
 * Inventory the current SQLite session rows and schema-backed session
 * references, then pass all evidence into the pure migration planner.
 */
export function inventorySessionIdMigration(
  options: SessionIdMigrationInventoryOptions,
): SessionIdMigrationManifest {
  const snapshot = assertSealedSqliteSnapshot(options);
  const roots = normalizeAllowedTraceRoots(options.allowedTraceRoots);
  const db = openReadOnlyDatabase(snapshot.databasePath);
  try {
    assertNormalizedSqliteSnapshotDatabase(db);
    const input = collectPlannerInput(db, roots, options);
    return planSessionIdMigration({
      ...input,
      ...(options.plannedUuidsBySourceRowId
        ? { plannedUuidsBySourceRowId: options.plannedUuidsBySourceRowId }
        : {}),
      ...(options.duplicateDispositions
        ? { duplicateDispositions: options.duplicateDispositions }
        : {}),
    });
  } finally {
    db.close();
  }
}

function collectPlannerInput(
  db: SqliteDatabase,
  roots: readonly AllowedTraceRoot[],
  options: SessionIdMigrationInventoryOptions,
): SessionIdMigrationPlannerInput {
  const sessionRows: SessionIdMigrationSessionRowInput[] = [];
  const references: SessionIdMigrationReferenceInput[] = [];
  const paths: SessionIdMigrationPathInput[] = [];
  const coverage: InventoryCoverage = {
    acceptedInputs: ["explicitly named Pi JSONL traces under caller-approved roots"],
    notInventoried: [
      "runtime memory, event rings, push/live-activity state, and Apple-only state",
    ],
    inspectedButAbsent: [],
    unavailable: [],
  };
  const traceListing = loadTraceEvidenceListing(options.traceEvidenceListingPath, references);

  const sessionTable = tableAvailability(db, SESSION_TABLE, SESSION_COLUMNS);
  if (sessionTable !== "present") {
    coverage.unavailable.push(`sqlite:${SESSION_TABLE} (${sessionTable})`);
    references.push(
      unclassifiedReference(
        `sqlite:${SESSION_TABLE}`,
        "required Session table/columns unavailable",
        "rewrite",
      ),
    );
  } else {
    coverage.acceptedInputs.push(
      "copied SQLite session_state_sessions rows and JSON projections",
      "copied SQLite session parent_session_id stale evidence and launch parent references",
    );
    const rows = db
      .prepare(
        `SELECT id, session_json, pi_session_id, pi_session_file, pi_session_files_json,
                parent_session_id, launch_metadata_json
         FROM ${SESSION_TABLE}
         ORDER BY id ASC`,
      )
      .all() as SessionInventoryRow[];
    for (const row of rows) {
      collectSessionRow(row, roots, sessionRows, references, traceListing);
    }
  }

  collectScheduleReferences(db, references, coverage);
  collectSqliteSchemaStores(db, references, coverage);
  collectSearchReferences(options, references, coverage);
  collectAttachmentManifests(options.attachmentManifestRoot, references, paths, coverage);
  collectUploadRecords(options.uploadRecordRoot, references, coverage);
  collectUnnamedTraces(options.unnamedTraceRoot, sessionRows, references, coverage);
  collectWorkspaceAttachmentListing(
    options.workspaceAttachmentListingPath,
    references,
    paths,
    coverage,
  );
  return { sessionRows, references, paths, inventoryCoverage: coverage };
}

function collectSessionRow(
  row: SessionInventoryRow,
  roots: readonly AllowedTraceRoot[],
  sessionRows: SessionIdMigrationSessionRowInput[],
  references: SessionIdMigrationReferenceInput[],
  traceListing: ReadonlyMap<string, SessionIdMigrationFileEvidence> | undefined,
): void {
  const sourceRowId = typeof row.id === "string" ? row.id : "";
  const location = `sqlite:${SESSION_TABLE}:${sourceRowId || "<invalid-id>"}`;
  const parsedSession = parseRecord(row.session_json, `${location}:session_json`, references);
  if (!parsedSession) {
    sessionRows.push({ sourceRowId });
    return;
  }

  if (typeof parsedSession.id !== "string" || parsedSession.id !== sourceRowId) {
    references.push(
      unclassifiedReference(`${location}:session_json.id`, "session JSON id does not match row id"),
    );
  }

  const piSessionId = stringField(parsedSession, "piSessionId", location, references);
  const currentPath = stringField(parsedSession, "piSessionFile", location, references);
  const historicalPaths = stringArrayField(parsedSession, "piSessionFiles", location, references);
  const piSessionFile = currentPath ? inspectTrace(currentPath, roots, traceListing) : undefined;
  const piSessionFiles = historicalPaths?.map((path) => inspectTrace(path, roots, traceListing));
  sessionRows.push({
    sourceRowId,
    ...(piSessionId ? { piSessionId } : {}),
    ...(piSessionFile ? { piSessionFile } : {}),
    ...(piSessionFiles ? { piSessionFiles } : {}),
  });

  reconcileProjectedString(row.pi_session_id, piSessionId, `${location}:pi_session_id`, references);
  reconcileProjectedString(
    row.pi_session_file,
    currentPath,
    `${location}:pi_session_file`,
    references,
  );
  reconcileProjectedStringArray(
    row.pi_session_files_json,
    historicalPaths,
    `${location}:pi_session_files_json`,
    references,
  );

  const sessionLaunchValue = parsedSession.launch;
  const sessionLaunchParent = launchParentReference(
    sessionLaunchValue,
    `${location}:session_json.launch`,
    references,
  );
  const launchMetadata = parseOptionalRecord(
    row.launch_metadata_json,
    `${location}:launch_metadata_json`,
    references,
  );
  const metadataLaunchParent = launchMetadata
    ? launchParentReference(launchMetadata, `${location}:launch_metadata_json`, references)
    : undefined;
  const bothLaunchObjects = isRecord(sessionLaunchValue) && launchMetadata !== undefined;
  let authoritativeLaunchParent: string | undefined;
  if (bothLaunchObjects && sessionLaunchParent !== metadataLaunchParent) {
    references.push(
      unclassifiedReference(
        `${location}:launch-parent-reconciliation`,
        "session JSON and launch metadata parentSessionId disagree, including presence/absence",
      ),
    );
  } else if (bothLaunchObjects && sessionLaunchParent !== undefined) {
    authoritativeLaunchParent = sessionLaunchParent;
    addSessionReference(
      sessionLaunchParent,
      `${location}:session_json.launch.parentSessionId`,
      references,
    );
    addSessionReference(
      metadataLaunchParent,
      `${location}:launch_metadata_json.parentSessionId`,
      references,
    );
  } else if (sessionLaunchParent !== undefined) {
    authoritativeLaunchParent = sessionLaunchParent;
    addSessionReference(
      sessionLaunchParent,
      `${location}:session_json.launch.parentSessionId`,
      references,
    );
  } else if (metadataLaunchParent !== undefined) {
    authoritativeLaunchParent = metadataLaunchParent;
    addSessionReference(
      metadataLaunchParent,
      `${location}:launch_metadata_json.parentSessionId`,
      references,
    );
  }

  if (row.parent_session_id !== null && row.parent_session_id !== undefined) {
    const parentLocation = `${location}:parent_session_id`;
    if (row.parent_session_id === authoritativeLaunchParent) {
      addSessionReference(row.parent_session_id, parentLocation, references);
    } else if (authoritativeLaunchParent !== undefined) {
      addStaleSessionReference(
        row.parent_session_id,
        parentLocation,
        references,
        "physical parent_session_id disagrees with reconciled launch parent evidence",
      );
    } else {
      addStaleSessionReference(
        row.parent_session_id,
        parentLocation,
        references,
        "physical parent_session_id has no reconciled current launch parent evidence",
      );
    }
  }
}

function collectScheduleReferences(
  db: SqliteDatabase,
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  const scheduleTable = tableAvailability(db, SCHEDULE_TABLE, ["id", "action_json"]);
  if (scheduleTable === "present") {
    coverage.acceptedInputs.push("copied SQLite agent_schedules existing-session actions");
    const rows = db
      .prepare(`SELECT id, action_json FROM ${SCHEDULE_TABLE} ORDER BY id ASC`)
      .all() as ScheduleInventoryRow[];
    for (const row of rows) {
      const location = `sqlite:${SCHEDULE_TABLE}:${stringLocation(row.id)}`;
      addScheduleActionReference(row.action_json, `${location}:action_json`, references, "rewrite");
    }
  } else {
    recordOptionalTableCoverage(SCHEDULE_TABLE, scheduleTable, coverage, references);
  }

  const scheduleRunTable = tableAvailability(db, SCHEDULE_RUN_TABLE, [
    "id",
    "action_snapshot_json",
    "result_json",
  ]);
  if (scheduleRunTable === "present") {
    coverage.acceptedInputs.push(
      "copied SQLite agent_schedule_runs historical action snapshots and result session IDs",
    );
    const rows = db
      .prepare(
        `SELECT id, action_snapshot_json, result_json FROM ${SCHEDULE_RUN_TABLE} ORDER BY id ASC`,
      )
      .all() as ScheduleRunInventoryRow[];
    for (const row of rows) {
      const location = `sqlite:${SCHEDULE_RUN_TABLE}:${stringLocation(row.id)}`;
      addScheduleActionReference(
        row.action_snapshot_json,
        `${location}:action_snapshot_json`,
        references,
        "observe_only",
      );
      addResultReference(row.result_json, `${location}:result_json`, references, "observe_only");
    }
  } else {
    recordOptionalTableCoverage(SCHEDULE_RUN_TABLE, scheduleRunTable, coverage, references);
  }
}

function addScheduleActionReference(
  rawJson: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
  policy: SessionIdMigrationReferencePolicy,
): void {
  const action = parseRecord(rawJson, location, references, policy);
  if (!action) return;
  if (action.type === "new_session") {
    if (action.sessionId !== undefined) {
      references.push(
        unclassifiedReference(
          `${location}.sessionId`,
          "new_session action must not carry sessionId",
          policy,
        ),
      );
    }
    return;
  }
  if (action.type !== "existing_session") {
    references.push(
      unclassifiedReference(location, "schedule action type is not recognized", policy),
    );
    return;
  }
  addSessionReference(action.sessionId, `${location}.sessionId`, references, policy);
}

function addResultReference(
  rawJson: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
  policy: SessionIdMigrationReferencePolicy,
): void {
  if (rawJson === null || rawJson === undefined) return;
  const result = parseRecord(rawJson, location, references, policy);
  if (!result || result.sessionId === undefined) return;
  addSessionReference(result.sessionId, `${location}.sessionId`, references, policy);
}

function launchParentReference(
  value: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
): string | undefined {
  if (value === null || value === undefined) return undefined;
  if (!isRecord(value)) {
    references.push(unclassifiedReference(location, "launch metadata is not an object"));
    return undefined;
  }
  if (value.parentSessionId === undefined) return undefined;
  if (typeof value.parentSessionId !== "string" || !value.parentSessionId.trim()) {
    references.push(
      unclassifiedReference(
        `${location}.parentSessionId`,
        "parentSessionId is not a nonempty string",
      ),
    );
    return undefined;
  }
  return value.parentSessionId;
}

function addSessionReference(
  value: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
  policy: SessionIdMigrationReferencePolicy = "rewrite",
): void {
  if (typeof value !== "string" || !value.trim()) {
    references.push(
      unclassifiedReference(
        location,
        "session reference is missing or not a nonempty string",
        policy,
      ),
    );
    return;
  }
  references.push({
    location,
    sourceSessionId: value,
    classification: "classified",
    policy,
  });
}

function addStaleSessionReference(
  value: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
  detail: string,
): void {
  if (typeof value !== "string" || !value.trim()) {
    addSessionReference(value, location, references, "observe_only");
    return;
  }
  references.push({
    location,
    sourceSessionId: value,
    classification: "classified",
    policy: "observe_only",
    observation: "stale",
    detail,
  });
}

function reconcileProjectedString(
  projected: unknown,
  sessionJsonValue: string | undefined,
  location: string,
  references: SessionIdMigrationReferenceInput[],
): void {
  if (projected === null || projected === undefined) {
    if (sessionJsonValue !== undefined) {
      references.push(
        unclassifiedReference(
          location,
          "projected value is absent while session JSON has evidence",
        ),
      );
    }
    return;
  }
  if (typeof projected !== "string" || projected !== sessionJsonValue) {
    references.push(
      unclassifiedReference(location, "projected value disagrees with session JSON evidence"),
    );
  }
}

function reconcileProjectedStringArray(
  projected: unknown,
  sessionJsonValue: string[] | undefined,
  location: string,
  references: SessionIdMigrationReferenceInput[],
): void {
  if (projected === null || projected === undefined) {
    if (sessionJsonValue !== undefined) {
      references.push(
        unclassifiedReference(
          location,
          "projected trace list is absent while session JSON has evidence",
        ),
      );
    }
    return;
  }
  const parsed = parseStringArray(projected);
  if (!parsed || !arraysEqual(parsed, sessionJsonValue ?? [])) {
    references.push(
      unclassifiedReference(
        location,
        "projected trace list is malformed or disagrees with session JSON evidence",
      ),
    );
  }
}

function stringField(
  record: Record<string, unknown>,
  field: string,
  location: string,
  references: SessionIdMigrationReferenceInput[],
): string | undefined {
  const value = record[field];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") {
    references.push(unclassifiedReference(`${location}:${field}`, "field is not a string"));
    return undefined;
  }
  return value;
}

function stringArrayField(
  record: Record<string, unknown>,
  field: string,
  location: string,
  references: SessionIdMigrationReferenceInput[],
): string[] | undefined {
  const value = record[field];
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    references.push(unclassifiedReference(`${location}:${field}`, "field is not a string array"));
    return undefined;
  }
  return [...value];
}

function parseOptionalRecord(
  rawJson: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
): Record<string, unknown> | undefined {
  if (rawJson === null || rawJson === undefined) return undefined;
  return parseRecord(rawJson, location, references);
}

function parseRecord(
  rawJson: unknown,
  location: string,
  references: SessionIdMigrationReferenceInput[],
  policy: SessionIdMigrationReferencePolicy = "rewrite",
): Record<string, unknown> | undefined {
  if (typeof rawJson !== "string") {
    references.push(unclassifiedReference(location, "JSON column is not a string", policy));
    return undefined;
  }
  try {
    const value = JSON.parse(rawJson) as unknown;
    if (!isRecord(value)) {
      references.push(unclassifiedReference(location, "JSON value is not an object", policy));
      return undefined;
    }
    return value;
  } catch {
    references.push(unclassifiedReference(location, "JSON value is malformed", policy));
    return undefined;
  }
}

function inspectTrace(
  path: string,
  roots: readonly AllowedTraceRoot[],
  listing?: ReadonlyMap<string, SessionIdMigrationFileEvidence>,
): SessionIdMigrationFileEvidence {
  if (!isAbsolute(path)) {
    return rejectedTrace(path, "trace path must be absolute");
  }
  const listed = listing?.get(path) ?? listing?.get(resolve(path));
  if (listed) return listed;
  const lexicalPath = resolve(path);
  if (!roots.some((root) => isWithinRoot(lexicalPath, root.lexical))) {
    return rejectedTrace(path, "trace path is outside caller-approved roots");
  }
  let entry: { dev: number; ino: number; isFile(): boolean; isSymbolicLink(): boolean };
  try {
    entry = lstatSync(lexicalPath);
  } catch {
    return { path: lexicalPath, availability: "unavailable", headerStatus: "unavailable" };
  }
  if (entry.isSymbolicLink() || !entry.isFile()) {
    return rejectedTrace(path, "trace path must name a regular non-symlink file");
  }

  let realPath: string;
  try {
    realPath = realpathSync(lexicalPath);
  } catch {
    return { path: lexicalPath, availability: "unavailable", headerStatus: "unavailable" };
  }
  if (!roots.some((root) => isWithinRoot(realPath, root.real))) {
    return rejectedTrace(path, "trace path resolves outside caller-approved roots");
  }

  const header = readTraceHeader(lexicalPath, entry);
  if (header.kind === "valid") {
    return {
      path: realPath,
      availability: "available",
      headerStatus: "valid",
      headerPiSessionId: header.id,
    };
  }
  return {
    path: realPath,
    availability: "available",
    headerStatus: "malformed",
    headerDetail: header.detail,
  };
}

function readTraceHeader(
  path: string,
  expectedEntry: { dev: number; ino: number },
): { kind: "valid"; id: string } | { kind: "malformed"; detail: string } {
  let fd: number | undefined;
  try {
    fd = openSync(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    const openedEntry = fstatSync(fd);
    if (
      !openedEntry.isFile() ||
      openedEntry.dev !== expectedEntry.dev ||
      openedEntry.ino !== expectedEntry.ino
    ) {
      return { kind: "malformed", detail: "trace entry changed before it could be read" };
    }
    const buffer = Buffer.alloc(64 * 1024);
    const count = readSync(fd, buffer, 0, buffer.length, 0);
    const firstLine = buffer.toString("utf8", 0, count).split("\n", 1)[0]?.trim();
    if (!firstLine) return { kind: "malformed", detail: "trace header is empty" };
    const header = JSON.parse(firstLine) as unknown;
    if (!isRecord(header) || header.type !== "session" || typeof header.id !== "string") {
      return { kind: "malformed", detail: "trace header is not a Pi session record" };
    }
    return { kind: "valid", id: header.id };
  } catch {
    return { kind: "malformed", detail: "trace header cannot be read or parsed" };
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

function normalizeAllowedTraceRoots(roots: readonly string[]): AllowedTraceRoot[] {
  return roots.map((root) => {
    if (!isAbsolute(root)) {
      throw new Error(`Allowed trace root must be absolute: ${root}`);
    }
    const lexical = resolve(root);
    return { lexical, real: realpathSync(lexical) };
  });
}

type TableAvailability = "present" | "absent" | "required columns unavailable";

function tableAvailability(
  db: SqliteDatabase,
  table: string,
  requiredColumns: readonly string[],
): TableAvailability {
  const tableExists = db
    .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(table);
  if (!tableExists) return "absent";
  const columns = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name?: unknown }>;
  const names = new Set(
    columns.flatMap((column) => (typeof column.name === "string" ? [column.name] : [])),
  );
  return requiredColumns.every((column) => names.has(column))
    ? "present"
    : "required columns unavailable";
}

function recordOptionalTableCoverage(
  table: string,
  availability: Exclude<TableAvailability, "present">,
  coverage: InventoryCoverage,
  references: SessionIdMigrationReferenceInput[],
): void {
  if (availability === "absent") {
    coverage.inspectedButAbsent.push(`sqlite:${table} (optional table absent)`);
    return;
  }
  coverage.unavailable.push(`sqlite:${table} (${availability}; not inventoried)`);
  references.push(
    unclassifiedReference(
      `sqlite:${table}`,
      "optional table is present but required columns are unavailable",
      "rewrite",
    ),
  );
}

const KNOWN_NO_SESSION_IDENTITY_TABLES = new Set([
  "session_state_schema",
  "app_state_migrations",
  "tui_session_catalog_state",
  "agent_definitions",
  "agent_definition_versions",
  "review_state_schema",
  "workspace_state_schema",
  "workspace_state_workspaces",
  "workspaces",
]);

const HANDLED_SESSION_TABLES = new Set([
  SESSION_TABLE,
  SCHEDULE_TABLE,
  SCHEDULE_RUN_TABLE,
  "review_state_comments",
  "server_agent_extension_audit_events",
  "tui_session_files",
  "local_session_files",
]);

function collectSqliteSchemaStores(
  db: SqliteDatabase,
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  const leftoverNoSession: string[] = [];
  const tables = listUserTables(db);
  collectReviewStateComments(db, tables, references, coverage);
  collectAuditEvents(db, tables, references, coverage);
  collectCatalogTable(
    db,
    tables,
    "tui_session_files",
    "copied SQLite tui_session_files catalog identities (not wrapper Session.id)",
    references,
    coverage,
  );
  collectCatalogTable(
    db,
    tables,
    "local_session_files",
    "copied SQLite leftover local_session_files catalog identities (not wrapper Session.id)",
    references,
    coverage,
  );

  for (const table of tables) {
    if (HANDLED_SESSION_TABLES.has(table) || table.startsWith("sqlite_")) continue;
    const columns = tableColumns(db, table);
    if (KNOWN_NO_SESSION_IDENTITY_TABLES.has(table) || !hasSessionIdentityColumn(columns)) {
      leftoverNoSession.push(table);
      continue;
    }
    coverage.unavailable.push(`sqlite:${table} (unknown leftover table with session identity)`);
    references.push(
      unclassifiedReference(
        `sqlite:${table}`,
        "unknown leftover table carries a session identity column",
        "rewrite",
      ),
    );
  }
  if (leftoverNoSession.length > 0) {
    coverage.acceptedInputs.push("copied SQLite leftover tables without session identity");
  }
}

function collectReviewStateComments(
  db: SqliteDatabase,
  tables: readonly string[],
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  if (!tables.includes("review_state_comments")) return;
  const availability = tableAvailability(db, "review_state_comments", ["id", "session_id"]);
  if (availability !== "present") {
    coverage.unavailable.push(`sqlite:review_state_comments (${availability})`);
    references.push(
      unclassifiedReference(
        "sqlite:review_state_comments",
        "leftover review_state_comments is present but required columns are unavailable",
        "observe_only",
      ),
    );
    return;
  }
  coverage.acceptedInputs.push("copied SQLite leftover review_state_comments as observe_only drop");
  const rows = db
    .prepare("SELECT id, session_id FROM review_state_comments ORDER BY id ASC")
    .all() as Array<{ id: unknown; session_id: unknown }>;
  for (const row of rows) {
    const location = `sqlite:review_state_comments:${stringLocation(row.id)}:session_id`;
    if (row.session_id === null || row.session_id === undefined) continue;
    addSessionReference(row.session_id, location, references, "observe_only");
  }
}

function collectAuditEvents(
  db: SqliteDatabase,
  tables: readonly string[],
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  if (!tables.includes("server_agent_extension_audit_events")) return;
  const availability = tableAvailability(db, "server_agent_extension_audit_events", [
    "id",
    "session_id",
  ]);
  if (availability !== "present") {
    coverage.unavailable.push(`sqlite:server_agent_extension_audit_events (${availability})`);
    references.push(
      unclassifiedReference(
        "sqlite:server_agent_extension_audit_events",
        "leftover audit table is present but required columns are unavailable",
        "observe_only",
      ),
    );
    return;
  }
  coverage.acceptedInputs.push("copied SQLite leftover server_agent_extension_audit_events");
  const rows = db
    .prepare("SELECT id, session_id FROM server_agent_extension_audit_events ORDER BY id ASC")
    .all() as Array<{ id: unknown; session_id: unknown }>;
  for (const row of rows) {
    if (row.session_id === null || row.session_id === undefined) continue;
    addSessionReference(
      row.session_id,
      `sqlite:server_agent_extension_audit_events:${stringLocation(row.id)}:session_id`,
      references,
      "observe_only",
    );
  }
}

function collectCatalogTable(
  db: SqliteDatabase,
  tables: readonly string[],
  table: "tui_session_files" | "local_session_files",
  acceptedInput: string,
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  if (!tables.includes(table)) return;
  const availability = tableAvailability(db, table, ["path", "pi_session_id"]);
  if (availability !== "present") {
    coverage.unavailable.push(`sqlite:${table} (${availability})`);
    references.push(
      unclassifiedReference(
        `sqlite:${table}`,
        "catalog table is present but required columns are unavailable",
        "observe_only",
      ),
    );
    return;
  }
  coverage.acceptedInputs.push(acceptedInput);
  const rows = db
    .prepare(`SELECT path, pi_session_id FROM ${table} ORDER BY path ASC`)
    .all() as Array<{ path: unknown; pi_session_id: unknown }>;
  for (const row of rows) {
    if (typeof row.pi_session_id === "string" && row.pi_session_id.trim()) continue;
    references.push(
      unclassifiedReference(
        `sqlite:${table}:${stringLocation(row.path)}:pi_session_id`,
        "catalog Pi identity is missing; this is not a wrapper Session.id dual-ID field",
        "observe_only",
      ),
    );
  }
}

function collectSearchReferences(
  options: SessionIdMigrationInventoryOptions,
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  if (!options.searchSnapshot) {
    coverage.notInventoried.push(
      "session-search.db session_fts.session_id and fts_meta.session_id",
    );
    return;
  }
  const snapshot = assertSealedSqliteSnapshot(options.searchSnapshot);
  const db = openReadOnlyDatabase(snapshot.databasePath);
  try {
    assertNormalizedSqliteSnapshotDatabase(db);
    coverage.acceptedInputs.push(
      "copied session-search.db session_fts.session_id and fts_meta.session_id",
    );
    collectSearchTable(db, "fts_meta", references);
    collectSearchTable(db, "session_fts", references);
  } finally {
    db.close();
  }
}

function collectSearchTable(
  db: SqliteDatabase,
  table: "fts_meta" | "session_fts",
  references: SessionIdMigrationReferenceInput[],
): void {
  const availability = tableAvailability(db, table, ["session_id"]);
  if (availability !== "present") {
    references.push(
      unclassifiedReference(
        `session-search:${table}`,
        "search table or session_id column is unavailable",
        "rewrite",
      ),
    );
    return;
  }
  const rows = db
    .prepare(`SELECT session_id FROM ${table} ORDER BY session_id ASC`)
    .all() as Array<{ session_id: unknown }>;
  for (const row of rows) {
    addSessionReference(
      row.session_id,
      `session-search:${table}:${stringLocation(row.session_id)}:session_id`,
      references,
      "rewrite",
    );
  }
}

function collectAttachmentManifests(
  root: string | undefined,
  references: SessionIdMigrationReferenceInput[],
  paths: SessionIdMigrationPathInput[],
  coverage: InventoryCoverage,
): void {
  if (!root) {
    coverage.notInventoried.push("session-attachments/<sessionId>/ manifests and media");
    return;
  }
  const realRoot = requireRealDirectory(root, "attachment-manifest-root", references);
  if (!realRoot) return;
  coverage.acceptedInputs.push(
    "copied session-attachments/<sessionId>/ manifests and storageKey path references",
  );
  for (const entryName of readdirSync(realRoot).sort(compareDeterministic)) {
    const sessionDir = join(realRoot, entryName);
    if (entryName === "." || entryName === ".." || entryName.includes("/") || entryName.includes("\\")) {
      references.push(
        unclassifiedReference(
          `session-attachments:${entryName}`,
          "attachment directory name is not a confined session id",
        ),
      );
      continue;
    }
    let entry;
    try {
      entry = lstatSync(sessionDir);
    } catch {
      references.push(
        unclassifiedReference(`session-attachments:${entryName}`, "attachment directory is unreadable"),
      );
      continue;
    }
    if (entry.isSymbolicLink() || !entry.isDirectory()) {
      references.push(
        unclassifiedReference(
          `session-attachments:${entryName}`,
          "attachment entry must be a real directory",
        ),
      );
      continue;
    }
    addSessionPath(
      entryName,
      `session-attachments:${entryName}`,
      `session-attachments/${entryName}`,
      paths,
    );
    const manifestFile = join(sessionDir, "manifest.json");
    let raw: string;
    try {
      raw = readFileSync(manifestFile, "utf8");
    } catch {
      continue;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw) as unknown;
    } catch {
      references.push(
        unclassifiedReference(
          `session-attachments:${entryName}:manifest.json`,
          "attachment manifest JSON is malformed",
        ),
      );
      continue;
    }
    if (!isRecord(parsed) || !Array.isArray(parsed.attachments)) {
      references.push(
        unclassifiedReference(
          `session-attachments:${entryName}:manifest.json`,
          "attachment manifest is not a versioned attachment list",
        ),
      );
      continue;
    }
    for (const [index, attachment] of parsed.attachments.entries()) {
      if (!isRecord(attachment)) {
        references.push(
          unclassifiedReference(
            `session-attachments:${entryName}:manifest.json:${index}`,
            "attachment record is not an object",
          ),
        );
        continue;
      }
      const storageKey = attachment.storageKey;
      const attachmentId =
        typeof attachment.id === "string" && attachment.id ? attachment.id : String(index);
      const location = `session-attachments:${entryName}:manifest.json:${attachmentId}:storageKey`;
      if (typeof storageKey !== "string" || !storageKey.startsWith(`${entryName}/`)) {
        references.push(
          unclassifiedReference(
            location,
            "storageKey does not stay under its session-attachments directory",
          ),
        );
        continue;
      }
      addSessionReference(entryName, location, references, "rewrite");
    }
  }
}

function collectUploadRecords(
  root: string | undefined,
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  if (!root) {
    coverage.notInventoried.push("configured upload-store records and blobs");
    return;
  }
  const realRoot = requireRealDirectory(root, "upload-record-root", references);
  if (!realRoot) return;
  coverage.acceptedInputs.push("copied upload-store records; blobs inventoried by record sessionId only");
  for (const entryName of readdirSync(realRoot).sort(compareDeterministic)) {
    if (!entryName.endsWith(".json")) continue;
    const recordPath = join(realRoot, entryName);
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(recordPath, "utf8")) as unknown;
    } catch {
      references.push(
        unclassifiedReference(`upload-store:${entryName}`, "upload record JSON is malformed"),
      );
      continue;
    }
    if (!isRecord(parsed)) {
      references.push(
        unclassifiedReference(`upload-store:${entryName}`, "upload record is not an object"),
      );
      continue;
    }
    if (parsed.sessionId === undefined || parsed.sessionId === null) continue;
    const recordId =
      typeof parsed.id === "string" && parsed.id ? parsed.id : entryName.replace(/\.json$/, "");
    addSessionReference(parsed.sessionId, `upload-store:${recordId}:sessionId`, references, "rewrite");
  }
}

function collectUnnamedTraces(
  root: string | undefined,
  sessionRows: readonly SessionIdMigrationSessionRowInput[],
  references: SessionIdMigrationReferenceInput[],
  coverage: InventoryCoverage,
): void {
  if (!root) {
    coverage.notInventoried.push(
      "server-owned trace-base session directories not named by a copied Session row",
    );
    return;
  }
  const realRoot = requireRealDirectory(root, "unnamed-trace-root", references);
  if (!realRoot) return;
  coverage.acceptedInputs.push(
    "copied server-owned traces not named by a copied Session row",
  );
  const named = new Set(sessionRows.map((row) => row.sourceRowId));
  for (const entryName of readdirSync(realRoot).sort(compareDeterministic)) {
    const sessionId = basename(entryName, extname(entryName));
    if (named.has(sessionId)) continue;
    references.push({
      location: `unnamed-trace:${entryName}`,
      classification: "classified",
      policy: "observe_only",
      detail: "server-owned trace is not named by a copied Session row",
    });
  }
}

function collectWorkspaceAttachmentListing(
  listingPath: string | undefined,
  references: SessionIdMigrationReferenceInput[],
  paths: SessionIdMigrationPathInput[],
  coverage: InventoryCoverage,
): void {
  if (!listingPath) {
    coverage.notInventoried.push("workspace .pi/attachments/<sessionId>/ materializations");
    return;
  }
  coverage.acceptedInputs.push(
    "copied listing of workspace .pi/attachments/<sessionId>/ materializations",
  );
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(listingPath, "utf8")) as unknown;
  } catch {
    references.push(
      unclassifiedReference(
        "workspace-attachments-listing",
        "workspace attachment listing JSON is malformed",
      ),
    );
    return;
  }
  if (!Array.isArray(parsed)) {
    references.push(
      unclassifiedReference(
        "workspace-attachments-listing",
        "workspace attachment listing is not an array",
      ),
    );
    return;
  }
  for (const [index, entry] of parsed.entries()) {
    if (
      !isRecord(entry) ||
      typeof entry.workspaceId !== "string" ||
      typeof entry.sessionId !== "string" ||
      typeof entry.path !== "string"
    ) {
      references.push(
        unclassifiedReference(
          `workspace-attachments:${index}`,
          "workspace attachment listing entry is missing workspaceId, sessionId, or path",
        ),
      );
      continue;
    }
    addSessionPath(
      entry.sessionId,
      `workspace-attachments:${entry.workspaceId}:${entry.sessionId}`,
      entry.path,
      paths,
    );
  }
}

function loadTraceEvidenceListing(
  listingPath: string | undefined,
  references: SessionIdMigrationReferenceInput[],
): Map<string, SessionIdMigrationFileEvidence> | undefined {
  if (!listingPath) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(listingPath, "utf8")) as unknown;
  } catch {
    references.push(
      unclassifiedReference("trace-evidence-listing", "named-trace evidence listing is malformed"),
    );
    return new Map();
  }
  if (!Array.isArray(parsed)) {
    references.push(
      unclassifiedReference("trace-evidence-listing", "named-trace evidence listing is not an array"),
    );
    return new Map();
  }
  const listing = new Map<string, SessionIdMigrationFileEvidence>();
  for (const [index, entry] of parsed.entries()) {
    if (!isRecord(entry) || typeof entry.path !== "string") {
      references.push(
        unclassifiedReference(
          `trace-evidence-listing:${index}`,
          "named-trace evidence entry is missing a path",
        ),
      );
      continue;
    }
    const evidence: SessionIdMigrationFileEvidence = {
      path: entry.path,
      availability: entry.availability === "available" ? "available" : "unavailable",
      ...(typeof entry.headerPiSessionId === "string"
        ? { headerPiSessionId: entry.headerPiSessionId }
        : {}),
      ...(entry.headerStatus === "valid" ||
      entry.headerStatus === "unavailable" ||
      entry.headerStatus === "malformed" ||
      entry.headerStatus === "path_rejected"
        ? { headerStatus: entry.headerStatus }
        : {}),
      ...(typeof entry.headerDetail === "string" ? { headerDetail: entry.headerDetail } : {}),
    };
    listing.set(entry.path, evidence);
    listing.set(resolve(entry.path), evidence);
  }
  return listing;
}

function addSessionPath(
  sourceSessionId: string,
  location: string,
  path: string,
  paths: SessionIdMigrationPathInput[],
): void {
  paths.push({
    location,
    path,
    sourceSessionId,
    classification: "classified",
    policy: "rewrite",
  });
}

function requireRealDirectory(
  path: string,
  label: string,
  references: SessionIdMigrationReferenceInput[],
): string | undefined {
  if (!isAbsolute(path)) {
    references.push(unclassifiedReference(label, `${label} must be an absolute directory`));
    return undefined;
  }
  try {
    const entry = lstatSync(path);
    if (entry.isSymbolicLink() || !entry.isDirectory()) {
      references.push(unclassifiedReference(label, `${label} must be a real directory`));
      return undefined;
    }
    return realpathSync(path);
  } catch {
    references.push(unclassifiedReference(label, `${label} is missing`));
    return undefined;
  }
}

function listUserTables(db: SqliteDatabase): string[] {
  const rows = db
    .prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name ASC",
    )
    .all() as Array<{ name?: unknown }>;
  return rows.flatMap((row) => (typeof row.name === "string" ? [row.name] : []));
}

function tableColumns(db: SqliteDatabase, table: string): Set<string> {
  const columns = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name?: unknown }>;
  return new Set(columns.flatMap((column) => (typeof column.name === "string" ? [column.name] : [])));
}

function hasSessionIdentityColumn(columns: ReadonlySet<string>): boolean {
  return ["session_id", "sessionId", "source_session_id", "parent_session_id"].some((column) =>
    columns.has(column),
  );
}

function compareDeterministic(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function parseStringArray(value: unknown): string[] | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed) && parsed.every((item) => typeof item === "string")
      ? parsed
      : undefined;
  } catch {
    return undefined;
  }
}

function arraysEqual(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function isWithinRoot(path: string, root: string): boolean {
  const relation = relative(root, path);
  return relation === "" || (!!relation && !relation.startsWith("..") && !isAbsolute(relation));
}

function rejectedTrace(path: string, detail: string): SessionIdMigrationFileEvidence {
  return { path, availability: "unavailable", headerStatus: "path_rejected", headerDetail: detail };
}

function unclassifiedReference(
  location: string,
  detail: string,
  policy: SessionIdMigrationReferencePolicy = "rewrite",
): SessionIdMigrationReferenceInput {
  return { location, classification: "unclassified", policy, detail };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringLocation(value: unknown): string {
  return typeof value === "string" && value ? value : "<invalid-id>";
}
