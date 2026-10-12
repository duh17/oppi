import { chmodSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import { createLogger } from "../logger.js";
import type { SqliteDatabase } from "../sqlite-compat.js";

const log = createLogger({ base: { component: "session_state_cleanup_migration" } });

export const SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY =
  "session_state_dead_schema_cleanup_v1";

const DEAD_TABLES = [
  "local_session_files",
  "workspaces",
  "workspace_state_workspaces",
  "workspace_state_schema",
  "review_state_comments",
  "review_state_schema",
  "server_agent_extension_audit_events",
] as const;

const DEAD_INDEXES = [
  "session_state_sessions_workspace_worktree_activity_idx",
  "session_state_sessions_parent_idx",
  "session_state_sessions_launch_schedule_idx",
  "session_state_sessions_status_activity_idx",
  "tui_session_files_cwd_idx",
  "agent_definitions_status_updated_idx",
  "agent_schedules_status_idx",
] as const;

const DEAD_COLUMNS: Record<string, readonly string[]> = {
  session_state_sessions: [
    "recent_cache_read_at",
    "recent_cache_write_at",
    "recent_cache_read_tokens",
    "recent_cache_write_tokens",
    "pi_session_id",
    "todo_id",
    "goal_id",
    "agent_id",
    "agent_version",
    "launch_source",
    "parent_session_id",
    "schedule_id",
    "schedule_run_id",
    "updated_at",
  ],
  tui_session_files: ["is_subagent"],
  agent_schedule_runs: ["approval_refs_json"],
};

const TOMBSTONE_PREFIX = "sessions_json_import_sqlite_backend_v2:%";

/**
 * One guarded, transactional cleanup of dead session-state.db objects.
 * Second open is a no-op. A failed backup aborts before any DROP.
 */
export function runSessionStateDeadSchemaCleanup(db: SqliteDatabase, dataDir: string): void {
  ensureMigrationsTable(db);
  if (hasCompleted(db)) {
    return;
  }

  const work = inspectCleanupWork(db);
  if (!hasCleanupWork(work)) {
    recordCompletion(db);
    return;
  }

  const backupPath = writePreMigrationBackup(db, dataDir);
  db.transaction(() => {
    if (hasCompleted(db)) {
      return;
    }
    applyCleanup(db);
    recordCompletion(db);
  })();

  log.info("session_state_cleanup.completed", {
    key: SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY,
    backupPath,
    droppedTables: work.tables,
    droppedIndexes: work.indexes,
    droppedColumns: work.columns,
    tuiManagedRowsDeleted: work.tuiManagedRowCount,
    tombstonesDeleted: work.tombstoneCount,
  });
}

function ensureMigrationsTable(db: SqliteDatabase): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS app_state_migrations (
      key TEXT PRIMARY KEY,
      completed_at INTEGER NOT NULL
    );
  `);
}

function hasCompleted(db: SqliteDatabase): boolean {
  const row = db
    .prepare("SELECT 1 AS present FROM app_state_migrations WHERE key = ?")
    .get(SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY) as { present?: number } | undefined;
  return row !== undefined;
}

function recordCompletion(db: SqliteDatabase): void {
  db.prepare("INSERT OR IGNORE INTO app_state_migrations (key, completed_at) VALUES (?, ?)").run(
    SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY,
    Date.now(),
  );
}

function inspectCleanupWork(db: SqliteDatabase): CleanupWork {
  const tables = DEAD_TABLES.filter((name) => sqliteObjectExists(db, "table", name));
  const indexes = DEAD_INDEXES.filter((name) => sqliteObjectExists(db, "index", name));
  const columns: Array<{ table: string; column: string }> = [];
  for (const [table, names] of Object.entries(DEAD_COLUMNS)) {
    const existing = tableColumns(db, table);
    for (const column of names) {
      if (existing.has(column)) {
        columns.push({ table, column });
      }
    }
  }
  return {
    tables,
    indexes,
    columns,
    tuiManagedRowCount: countManagedTuiRows(db),
    tombstoneCount: countTombstones(db),
  };
}

function hasCleanupWork(work: CleanupWork): boolean {
  return (
    work.tables.length > 0 ||
    work.indexes.length > 0 ||
    work.columns.length > 0 ||
    work.tuiManagedRowCount > 0 ||
    work.tombstoneCount > 0
  );
}

function applyCleanup(db: SqliteDatabase): void {
  // DROP COLUMN fails when the column is still indexed.
  for (const name of DEAD_INDEXES) {
    db.exec(`DROP INDEX IF EXISTS ${name}`);
  }
  for (const name of DEAD_TABLES) {
    db.exec(`DROP TABLE IF EXISTS ${name}`);
  }
  for (const [table, names] of Object.entries(DEAD_COLUMNS)) {
    const existing = tableColumns(db, table);
    for (const column of names) {
      if (existing.has(column)) {
        db.exec(`ALTER TABLE ${table} DROP COLUMN ${column}`);
      }
    }
  }
  deleteManagedTuiRows(db);
  db.prepare("DELETE FROM app_state_migrations WHERE key LIKE ?").run(TOMBSTONE_PREFIX);
}

function writePreMigrationBackup(db: SqliteDatabase, dataDir: string): string {
  const backupDir = join(dataDir, "backups");
  mkdirSync(backupDir, { recursive: true, mode: 0o700 });
  const backupPath = join(
    backupDir,
    `session-state-pre-${SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY}-${Date.now()}.db`,
  );
  try {
    db.exec(`VACUUM INTO ${sqlLiteral(backupPath)}`);
    chmodSync(backupPath, 0o600);
  } catch (error) {
    throw new Error(
      `session-state cleanup backup failed; refusing to migrate (${backupPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      { cause: error },
    );
  }
  return backupPath;
}

function sqliteObjectExists(db: SqliteDatabase, type: "table" | "index", name: string): boolean {
  const row = db
    .prepare("SELECT 1 AS present FROM sqlite_master WHERE type = ? AND name = ?")
    .get(type, name) as { present?: number } | undefined;
  return row !== undefined;
}

function tableColumns(db: SqliteDatabase, table: string): Set<string> {
  if (!sqliteObjectExists(db, "table", table)) {
    return new Set();
  }
  const rows = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>;
  return new Set(rows.map((row) => row.name));
}

function countManagedTuiRows(db: SqliteDatabase): number {
  if (
    !sqliteObjectExists(db, "table", "tui_session_files") ||
    !sqliteObjectExists(db, "table", "session_state_sessions")
  ) {
    return 0;
  }
  const row = db
    .prepare(
      `SELECT COUNT(*) AS count
       FROM tui_session_files
       WHERE path IN (
         SELECT pi_session_file FROM session_state_sessions WHERE pi_session_file IS NOT NULL
       )
          OR pi_session_id IN (SELECT id FROM session_state_sessions)`,
    )
    .get() as { count: number };
  return row.count;
}

function deleteManagedTuiRows(db: SqliteDatabase): void {
  if (
    !sqliteObjectExists(db, "table", "tui_session_files") ||
    !sqliteObjectExists(db, "table", "session_state_sessions")
  ) {
    return;
  }
  db.exec(`
    DELETE FROM tui_session_files
    WHERE path IN (
      SELECT pi_session_file FROM session_state_sessions WHERE pi_session_file IS NOT NULL
    )
       OR pi_session_id IN (SELECT id FROM session_state_sessions)
  `);
}

function countTombstones(db: SqliteDatabase): number {
  const row = db
    .prepare("SELECT COUNT(*) AS count FROM app_state_migrations WHERE key LIKE ?")
    .get(TOMBSTONE_PREFIX) as { count: number };
  return row.count;
}

function sqlLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

interface CleanupWork {
  tables: string[];
  indexes: string[];
  columns: Array<{ table: string; column: string }>;
  tuiManagedRowCount: number;
  tombstoneCount: number;
}
