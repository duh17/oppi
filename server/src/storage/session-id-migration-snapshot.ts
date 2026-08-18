import {
  accessSync,
  chmodSync,
  constants,
  lstatSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { basename, dirname, isAbsolute, relative, resolve } from "node:path";

import { openDatabase, type SqliteDatabase } from "../sqlite-compat.js";

/**
 * Required explicit acknowledgement for the only operation in this slice that
 * mutates data. The target must be a caller-designated disposable DB copy.
 */
export const DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT =
  "I_UNDERSTAND_THIS_MUTATES_A_DISPOSABLE_COPIED_SQLITE_SNAPSHOT" as const;

export interface DisposableCopiedSqliteSnapshotOptions {
  /** Dedicated directory containing only the copied SQLite DB and its sidecars. */
  snapshotDirectory: string;
  /** Copied database directly inside snapshotDirectory; never a live-data path. */
  databasePath: string;
  /** Explicit acknowledgement that normalization mutates this disposable copy. */
  acknowledgement: typeof DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT;
}

export interface SealedSqliteSnapshotOptions {
  snapshotDirectory: string;
  databasePath: string;
}

/**
 * Mutate and seal a caller-designated disposable database copy. This function
 * intentionally has no configured-data discovery, rollback, or file cleanup:
 * SQLite owns checkpoint/journal cleanup, and any remaining sidecar fails. If
 * chmod fails partway through sealing, the copy can be partially sealed but is
 * never returned or represented as a sealed snapshot.
 */
export function normalizeDisposableCopiedSqliteSnapshot(
  options: DisposableCopiedSqliteSnapshotOptions,
): SealedSqliteSnapshotOptions {
  if (options.acknowledgement !== DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT) {
    throw new Error("Disposable copied SQLite snapshot acknowledgement is required");
  }

  const snapshot = validateDedicatedSnapshotPaths(options);
  let db: SqliteDatabase | undefined;
  let normalizationFailed = false;
  try {
    db = openDatabase(snapshot.databasePath);
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    setAndAssertJournalModeDelete(db);
    assertIntegrityOk(db, "normalization");
  } catch {
    normalizationFailed = true;
  } finally {
    try {
      db?.close();
    } catch {
      normalizationFailed = true;
    }
  }
  if (normalizationFailed) {
    throw new Error("Disposable copied SQLite snapshot normalization failed");
  }

  try {
    assertNoSidecars(snapshot.databasePath);
    chmodSync(snapshot.databasePath, 0o400);
    chmodSync(snapshot.snapshotDirectory, 0o500);
    assertSealedSqliteSnapshot(snapshot);
    return snapshot;
  } catch {
    throw new Error("Disposable copied SQLite snapshot sealing failed");
  }
}

/**
 * Verify filesystem sealing before the inventory opens the database. It does
 * not modify the copy and rejects non-dedicated, escaped, or writable paths.
 */
export function assertSealedSqliteSnapshot(
  options: SealedSqliteSnapshotOptions,
): SealedSqliteSnapshotOptions {
  const snapshot = validateDedicatedSnapshotPaths(options);
  assertNoSidecars(snapshot.databasePath);
  assertOwnerOnlySealedMode(snapshot.databasePath, 0o400, "SQLite snapshot file");
  assertOwnerOnlySealedMode(snapshot.snapshotDirectory, 0o500, "SQLite snapshot directory");
  return snapshot;
}

/** Verify the sealed copy's SQLite invariants through an already read-only handle. */
export function assertNormalizedSqliteSnapshotDatabase(db: SqliteDatabase): void {
  assertJournalModeDelete(db, "sealed snapshot");
  assertIntegrityOk(db, "sealed snapshot");
}

function validateDedicatedSnapshotPaths(
  options: SealedSqliteSnapshotOptions,
): SealedSqliteSnapshotOptions {
  if (!isAbsolute(options.snapshotDirectory)) {
    throw new Error(
      `Disposable copied SQLite snapshot directory must be absolute: ${options.snapshotDirectory}`,
    );
  }
  if (!isAbsolute(options.databasePath)) {
    throw new Error(
      `Disposable copied SQLite snapshot database path must be absolute: ${options.databasePath}`,
    );
  }

  const snapshotDirectory = resolve(options.snapshotDirectory);
  const databasePath = resolve(options.databasePath);
  const realSnapshotDirectory = assertDirectoryIsReal(snapshotDirectory);
  if (dirname(databasePath) !== snapshotDirectory) {
    throw new Error(
      `Disposable copied SQLite snapshot database must be directly inside its dedicated directory: ${databasePath}`,
    );
  }
  if (!isWithinDirectory(databasePath, snapshotDirectory)) {
    throw new Error(
      `Disposable copied SQLite snapshot database escapes its dedicated directory: ${databasePath}`,
    );
  }
  assertRegularFileIsReal(databasePath, realSnapshotDirectory);

  const allowedEntries = new Set([
    basename(databasePath),
    `${basename(databasePath)}-wal`,
    `${basename(databasePath)}-shm`,
  ]);
  const unexpectedEntry = readdirSync(snapshotDirectory)
    .sort()
    .find((entry) => !allowedEntries.has(entry));
  if (unexpectedEntry) {
    throw new Error(
      `Disposable copied SQLite snapshot directory must contain only the database and SQLite sidecars: ${unexpectedEntry}`,
    );
  }
  assertSidecarsAreRegular(databasePath);
  return { snapshotDirectory, databasePath };
}

function assertDirectoryIsReal(path: string): string {
  let entry;
  try {
    entry = lstatSync(path);
  } catch {
    throw new Error(`Disposable copied SQLite snapshot directory is missing: ${path}`);
  }
  if (entry.isSymbolicLink() || !entry.isDirectory()) {
    throw new Error(
      `Disposable copied SQLite snapshot directory must be a real directory: ${path}`,
    );
  }
  return realpathSync(path);
}

function assertRegularFileIsReal(path: string, realSnapshotDirectory: string): void {
  let entry;
  try {
    entry = lstatSync(path);
  } catch {
    throw new Error(`Disposable copied SQLite snapshot database is missing: ${path}`);
  }
  if (entry.isSymbolicLink() || !entry.isFile()) {
    throw new Error(
      `Disposable copied SQLite snapshot database must be a real regular file: ${path}`,
    );
  }
  const stats = statSync(path);
  if (dirname(realpathSync(path)) !== realSnapshotDirectory || !stats.isFile()) {
    throw new Error(
      `Disposable copied SQLite snapshot database escapes its dedicated directory: ${path}`,
    );
  }
  if (stats.nlink > 1) {
    throw new Error(`Disposable copied SQLite snapshot database must not be hard-linked: ${path}`);
  }
}

function assertSidecarsAreRegular(databasePath: string): void {
  for (const sidecar of [`${databasePath}-wal`, `${databasePath}-shm`]) {
    let entry;
    try {
      entry = lstatSync(sidecar);
    } catch {
      continue;
    }
    if (entry.isSymbolicLink() || !entry.isFile()) {
      throw new Error(
        `Disposable copied SQLite snapshot sidecar must be a real regular file: ${sidecar}`,
      );
    }
    if (entry.nlink > 1) {
      throw new Error(
        `Disposable copied SQLite snapshot sidecar must not be hard-linked: ${sidecar}`,
      );
    }
  }
}

function assertNoSidecars(databasePath: string): void {
  for (const sidecar of [`${databasePath}-wal`, `${databasePath}-shm`]) {
    try {
      lstatSync(sidecar);
    } catch {
      continue;
    }
    throw new Error(`Disposable copied SQLite snapshot has an unnormalized sidecar: ${sidecar}`);
  }
}

function assertOwnerOnlySealedMode(path: string, expectedMode: number, label: string): void {
  if ((statSync(path).mode & 0o777) !== expectedMode) {
    throw new Error(`${label} must have owner-only mode ${expectedMode.toString(8)}: ${path}`);
  }
  try {
    accessSync(path, constants.W_OK);
  } catch {
    return;
  }
  throw new Error(`${label} is writable by the inventory process: ${path}`);
}

function setAndAssertJournalModeDelete(db: SqliteDatabase): void {
  const row = db.prepare("PRAGMA journal_mode = DELETE").get() as
    | { journal_mode?: unknown }
    | undefined;
  if (row?.journal_mode !== "delete") {
    throw new Error("Disposable copied SQLite snapshot normalization requires journal_mode=delete");
  }
}

function assertJournalModeDelete(db: SqliteDatabase, phase: string): void {
  const row = db.prepare("PRAGMA journal_mode").get() as { journal_mode?: unknown } | undefined;
  if (row?.journal_mode !== "delete") {
    throw new Error(`Disposable copied SQLite snapshot ${phase} requires journal_mode=delete`);
  }
}

function assertIntegrityOk(db: SqliteDatabase, phase: string): void {
  const rows = db.prepare("PRAGMA integrity_check").all() as Array<{ integrity_check?: unknown }>;
  if (rows.length !== 1 || rows[0]?.integrity_check !== "ok") {
    throw new Error(`Disposable copied SQLite snapshot ${phase} requires integrity_check=ok`);
  }
}

function isWithinDirectory(path: string, directory: string): boolean {
  const relation = relative(directory, path);
  return !!relation && !relation.startsWith("..") && !isAbsolute(relation);
}
