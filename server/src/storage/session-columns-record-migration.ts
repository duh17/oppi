import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type { SqliteDatabase } from "../sqlite-compat.js";
import {
  ensureMigrationsTable,
  hasCompletedMigration,
  recordMigration,
  tableColumns,
  writePreMigrationBackup,
} from "./session-state-cleanup-migration.js";

const log = createLogger({ base: { component: "session_columns_record_migration" } });

export const SESSION_COLUMNS_RECORD_MIGRATION_KEY = "session_state_columns_record_v1";

/**
 * `session_state_sessions` after this migration: the typed columns are the only record of a
 * session. Conversation stats the list shows but never filters or sorts on in SQL live in one
 * `summary_json` cache column. The durable binding is three columns so `(store, conversation)`
 * is an indexed lookup. The workspace name is not stored; readers resolve it from the workspace
 * store.
 */
export function createSessionStateSessionsTable(db: SqliteDatabase, table: string): void {
  db.exec(`
    CREATE TABLE ${table} (
      id TEXT PRIMARY KEY,
      workspace_id TEXT,
      worktree_id TEXT,
      name TEXT,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      last_activity INTEGER NOT NULL,
      current_turn_started_at INTEGER,
      warnings_json TEXT,
      runtime TEXT,
      mirror_json TEXT,
      pi_session_file TEXT,
      pi_session_files_json TEXT,
      ephemeral INTEGER NOT NULL DEFAULT 0,
      launch_status TEXT,
      launch_lease_owner TEXT,
      launch_lease_until_ms INTEGER,
      launch_idempotency_key TEXT,
      launch_metadata_json TEXT,
      durable_store_id TEXT,
      durable_conversation_id INTEGER,
      durable_role TEXT,
      control_json TEXT,
      program_status_json TEXT,
      summary_json TEXT NOT NULL
    );
  `);
}

/**
 * Rebuilds `session_state_sessions` from the dual-copy shape (typed columns plus `session_json`)
 * into the columns-only shape, in one transaction keyed in `app_state_migrations`.
 *
 * Irreversible: drops `session_json` (after copying `$.control` into `control_json`),
 * `server_durable_json` (split into `durable_*`), `workspace_name`, and the per-stat columns
 * (packed into `summary_json`). A `VACUUM INTO` backup is written first; a failed backup aborts
 * before any change. A failure inside the transaction rolls back to the old table. The file is
 * vacuumed once after the commit. Returns whether the rebuild ran.
 *
 * The source is the table a release kept complete (it added any missing column on every open).
 * oppi-server 0.51.0 predates `program_status_json`; its rows copy NULL there, and startup
 * derives the status from the lifecycle. A file last opened by a release older than 0.51.0 fails
 * here with a SQL error; open it once with oppi-server 0.51.0, or restore a backup.
 */
export function runSessionColumnsRecordMigration(db: SqliteDatabase, dataDir: string): boolean {
  const key = SESSION_COLUMNS_RECORD_MIGRATION_KEY;
  ensureMigrationsTable(db);
  if (hasCompletedMigration(db, key)) {
    return false;
  }

  const sourceColumns = tableColumns(db, "session_state_sessions");
  if (sourceColumns.has("summary_json")) {
    // Created in the current shape; nothing to rebuild.
    recordMigration(db, key);
    return false;
  }

  const backupPath = writePreMigrationBackup(db, dataDir, key);
  const counts = db.transaction(() => {
    refuseUnreadableSources(db);
    createSessionStateSessionsTable(db, "session_state_sessions_next");
    db.exec(copySessionsSql(sourceColumns.has("program_status_json")));
    const copied = count(db, "SELECT COUNT(*) AS count FROM session_state_sessions_next");
    const source = count(db, "SELECT COUNT(*) AS count FROM session_state_sessions");
    if (copied !== source) {
      throw new Error(`session row copy mismatch: ${copied} of ${source}`);
    }
    // Indexes on the old table go with it; the store recreates the current set.
    db.exec("DROP TABLE session_state_sessions");
    db.exec("ALTER TABLE session_state_sessions_next RENAME TO session_state_sessions");
    recordMigration(db, key);
    return {
      sessions: copied,
      control: count(
        db,
        "SELECT COUNT(*) AS count FROM session_state_sessions WHERE control_json IS NOT NULL",
      ),
      durable: count(
        db,
        `SELECT COUNT(*) AS count FROM session_state_sessions
         WHERE durable_store_id IS NOT NULL OR durable_conversation_id IS NOT NULL
            OR durable_role IS NOT NULL`,
      ),
    };
  })();

  log.info("session_columns_record.completed", { key, backupPath, ...counts });

  // Reclaims the dropped columns. Outside the transaction, once. The migration has committed,
  // so a failed compaction leaves a correct but larger file rather than blocking startup.
  try {
    db.exec("VACUUM");
  } catch (error) {
    log.warn("session_columns_record.vacuum_failed", { key, error: safeErrorMessage(error) });
  }
  return true;
}

/**
 * `session_json` is read only for `control`, which has no column. Every other field is copied
 * from its column. JSON is read through `json_valid` (nested CASE, since `json_type` throws on
 * malformed text and AND does not promise evaluation order), so one corrupt value is dropped
 * instead of failing every start. `json_patch` onto '{}' drops null members, so absent stats
 * stay absent.
 */
const copySessionsSql = (hasProgramStatus: boolean): string => `
  INSERT INTO session_state_sessions_next (
    id, workspace_id, worktree_id, name, status, created_at, last_activity,
    current_turn_started_at, warnings_json, runtime, mirror_json, pi_session_file,
    pi_session_files_json, ephemeral, launch_status, launch_lease_owner, launch_lease_until_ms,
    launch_idempotency_key, launch_metadata_json, durable_store_id, durable_conversation_id,
    durable_role, control_json, program_status_json, summary_json
  )
  SELECT
    id, workspace_id, worktree_id, name, status, created_at, last_activity,
    current_turn_started_at, warnings_json, runtime, mirror_json, pi_session_file,
    pi_session_files_json, ephemeral, launch_status, launch_lease_owner, launch_lease_until_ms,
    launch_idempotency_key, launch_metadata_json,
    CASE WHEN json_type(durable, '$.storeId') = 'text' THEN json_extract(durable, '$.storeId') END,
    CASE WHEN json_type(durable, '$.conversationId') = 'integer'
      THEN json_extract(durable, '$.conversationId') END,
    CASE WHEN json_extract(durable, '$.role') = 'control' THEN 'control' END,
    CASE WHEN json_valid(session_json) THEN
      CASE WHEN json_type(session_json, '$.control') = 'object'
        THEN json_extract(session_json, '$.control') END END,
    ${hasProgramStatus ? "program_status_json" : "NULL"},
    json_patch('{}', json_object(
      'model', model,
      'thinkingLevel', thinking_level,
      'messageCount', message_count,
      'tokens', json_object(
        'input', tokens_input,
        'output', tokens_output,
        'cacheRead', tokens_cache_read,
        'cacheWrite', tokens_cache_write
      ),
      'cost', cost,
      'firstMessage', first_message,
      'lastMessage', last_message,
      'contextTokens', context_tokens,
      'contextWindow', context_window,
      'lastAgentReplyAt', last_agent_reply_at,
      'changeStats', CASE WHEN json_valid(change_stats_json) THEN json(change_stats_json) END
    ))
  FROM (
    SELECT *,
      CASE WHEN json_valid(server_durable_json) THEN
        CASE WHEN json_type(server_durable_json) = 'object' THEN server_durable_json END END
        AS durable
    FROM session_state_sessions
  )
`;

/**
 * The copy turns unreadable JSON into NULL. For the durable binding or `control` that would
 * silently make a session classic or drop its control metadata, so such rows stop the
 * migration instead (the transaction rolls back to the old table) and are named in the error.
 */
function refuseUnreadableSources(db: SqliteDatabase): void {
  const rows = db
    .prepare(
      `SELECT id FROM session_state_sessions
       WHERE (
         server_durable_json IS NOT NULL AND server_durable_json <> '' AND
         CASE WHEN json_valid(server_durable_json) THEN
           CASE WHEN json_type(server_durable_json) = 'object' THEN
             COALESCE(json_type(server_durable_json, '$.conversationId') <> 'integer', 0)
             OR COALESCE(json_type(server_durable_json, '$.storeId') <> 'text', 0)
           ELSE 0 END
         ELSE 1 END
       ) OR (
         session_json IS NOT NULL AND session_json <> '' AND NOT json_valid(session_json)
       )
       ORDER BY id
       LIMIT 10`,
    )
    .all() as Array<{ id: string }>;
  if (rows.length > 0) {
    throw new Error(
      `session-state migration refused: unreadable durable binding or session JSON in ${rows
        .map((row) => row.id)
        .join(", ")}`,
    );
  }
}

function count(db: SqliteDatabase, sql: string): number {
  return (db.prepare(sql).get() as { count: number }).count;
}
