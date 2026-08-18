/**
 * SQLite compatibility layer — abstracts over built-in drivers:
 *
 * - Bun:       bun:sqlite (built-in)
 * - Node 22+:  node:sqlite (built-in)
 *
 * No native addons required.
 */

import { createRequire } from "node:module";

const cjsRequire = createRequire(import.meta.url);

/** Minimal Database interface covering the API surface we actually use. */
export interface SqliteDatabase {
  exec(sql: string): void;
  prepare(sql: string): SqliteStatement;
  transaction<T>(fn: () => T): () => T;
  close(): void;
}

export interface SqliteStatement {
  run(...params: unknown[]): unknown;
  get(...params: unknown[]): unknown;
  all(...params: unknown[]): unknown[];
}

const isBun = typeof (globalThis as Record<string, unknown>).Bun !== "undefined";
const BUSY_TIMEOUT_MS = 5000;

/**
 * Open a SQLite database file using the best available built-in driver.
 */
export function openDatabase(path: string): SqliteDatabase {
  if (isBun) {
    return openBunDatabase(path);
  }
  return openNodeSqliteDatabase(path);
}

/**
 * Open an existing SQLite database without write capability. Callers that
 * inspect copied data must use this rather than the normal writable opener.
 */
export function openReadOnlyDatabase(path: string): SqliteDatabase {
  if (isBun) {
    return openBunDatabase(path, { readonly: true });
  }
  return openNodeSqliteDatabase(path, { readOnly: true });
}

// ---------------------------------------------------------------------------
// Bun runtime
// ---------------------------------------------------------------------------

function openBunDatabase(path: string, options?: { readonly?: boolean }): SqliteDatabase {
  // bun:sqlite is a Bun built-in — always available under Bun.
  // Use cjsRequire because this file is ESM and dynamic import() is async.
  const { Database } = cjsRequire("bun:sqlite") as {
    Database: new (path: string, options?: { readonly?: boolean }) => BunSqliteDb;
  };
  const db = options ? new Database(path, options) : new Database(path);
  try {
    configureDatabase(db, options?.readonly === true);
  } catch (error) {
    db.close();
    throw error;
  }

  return {
    exec: (sql: string) => db.exec(sql),
    prepare: (sql: string) => normalizeBunStatement(db.prepare(sql) as SqliteStatement),
    transaction: <T>(fn: () => T) => db.transaction(fn) as () => T,
    close: () => db.close(),
  };
}

function normalizeBunStatement(statement: SqliteStatement): SqliteStatement {
  return {
    run: (...params: unknown[]) => statement.run(...params),
    get: (...params: unknown[]) => {
      const row = statement.get(...params);
      return row === null ? undefined : row;
    },
    all: (...params: unknown[]) => statement.all(...params),
  };
}

/** Minimal bun:sqlite Database shape. */
interface BunSqliteDb {
  exec(sql: string): void;
  prepare(sql: string): SqliteStatement;
  transaction<T>(fn: () => T): () => T;
  close(): void;
}

// ---------------------------------------------------------------------------
// Node.js 22+ runtime (built-in node:sqlite)
// ---------------------------------------------------------------------------

function openNodeSqliteDatabase(path: string, options?: { readOnly?: boolean }): SqliteDatabase {
  const { DatabaseSync } = cjsRequire("node:sqlite") as {
    DatabaseSync: new (path: string, options?: { readOnly?: boolean }) => NodeSqliteDb;
  };
  const db = options ? new DatabaseSync(path, options) : new DatabaseSync(path);
  try {
    configureDatabase(db, options?.readOnly === true);
  } catch (error) {
    db.close();
    throw error;
  }

  return {
    exec: (sql: string) => db.exec(sql),
    prepare: (sql: string) => db.prepare(sql) as SqliteStatement,
    transaction: <T>(fn: () => T) => {
      // node:sqlite DatabaseSync lacks .transaction() — emulate with BEGIN/COMMIT/ROLLBACK
      return () => {
        db.exec("BEGIN");
        try {
          const result = fn();
          db.exec("COMMIT");
          return result;
        } catch (err) {
          db.exec("ROLLBACK");
          throw err;
        }
      };
    },
    close: () => db.close(),
  };
}

/** Minimal node:sqlite DatabaseSync shape. */
interface NodeSqliteDb {
  exec(sql: string): void;
  prepare(sql: string): SqliteStatement;
  close(): void;
}

function configureDatabase(db: Pick<SqliteDatabase, "exec">, readOnly = false): void {
  db.exec(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
  if (readOnly) {
    // Defense in depth for drivers whose open flags are platform-specific.
    db.exec("PRAGMA query_only = ON");
  }
}
