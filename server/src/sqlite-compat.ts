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

/**
 * Open a SQLite database file using the best available built-in driver.
 */
export function openDatabase(path: string): SqliteDatabase {
  if (isBun) {
    return openBunDatabase(path);
  }
  return openNodeSqliteDatabase(path);
}

// ---------------------------------------------------------------------------
// Bun runtime
// ---------------------------------------------------------------------------

function openBunDatabase(path: string): SqliteDatabase {
  // bun:sqlite is a Bun built-in — always available under Bun.
  // Use cjsRequire because this file is ESM and dynamic import() is async.
  const { Database } = cjsRequire("bun:sqlite") as {
    Database: new (path: string) => BunSqliteDb;
  };
  const db = new Database(path);

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

function openNodeSqliteDatabase(path: string): SqliteDatabase {
  const { DatabaseSync } = cjsRequire("node:sqlite") as {
    DatabaseSync: new (path: string) => NodeSqliteDb;
  };
  const db = new DatabaseSync(path);

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
