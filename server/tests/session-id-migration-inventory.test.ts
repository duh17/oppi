import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  linkSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { inventorySessionIdMigration } from "../src/storage/session-id-migration-inventory.js";
import { planSessionIdMigration } from "../src/storage/session-id-migration-planner.js";
import { FIELD_AUTHORITY_DUPLICATE_REASON_ID } from "../src/storage/session-id-migration-merge.js";
import {
  DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
  normalizeDisposableCopiedSqliteSnapshot,
} from "../src/storage/session-id-migration-snapshot.js";
import { openDatabase, openReadOnlyDatabase } from "../src/sqlite-compat.js";

const PI_A = "11111111-1111-4111-8111-111111111111";
const PI_B = "22222222-2222-4222-8222-222222222222";

interface Fixture {
  root: string;
  snapshotDirectory: string;
  dbPath: string;
  traceRoot: string;
  prepared: boolean;
}

function createFixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), "oppi-session-id-inventory-"));
  const snapshotDirectory = join(root, "snapshot");
  mkdirSync(snapshotDirectory);
  const dbPath = join(snapshotDirectory, "session-state.db");
  const db = openDatabase(dbPath);
  try {
    db.exec(`
      CREATE TABLE session_state_sessions (
        id TEXT PRIMARY KEY,
        session_json TEXT NOT NULL,
        pi_session_id TEXT,
        pi_session_file TEXT,
        pi_session_files_json TEXT,
        parent_session_id TEXT,
        launch_metadata_json TEXT
      );
      CREATE TABLE agent_schedules (id TEXT PRIMARY KEY, action_json TEXT NOT NULL);
      CREATE TABLE agent_schedule_runs (
        id TEXT PRIMARY KEY,
        action_snapshot_json TEXT NOT NULL,
        result_json TEXT
      );
    `);
  } finally {
    db.close();
  }
  const traceRoot = join(root, "traces");
  mkdirSync(traceRoot);
  return { root, snapshotDirectory, dbPath, traceRoot, prepared: false };
}

function insertSession(
  fixture: Fixture,
  input: {
    id: string;
    piSessionId?: string;
    piSessionFile?: string;
    piSessionFiles?: string[];
    launchParentSessionId?: string;
    sessionJson?: string;
    parentSessionId?: string | null;
    launchMetadata?: string | null;
  },
): void {
  const session = {
    id: input.id,
    status: "stopped",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...(input.piSessionId !== undefined ? { piSessionId: input.piSessionId } : {}),
    ...(input.piSessionFile !== undefined ? { piSessionFile: input.piSessionFile } : {}),
    ...(input.piSessionFiles !== undefined ? { piSessionFiles: input.piSessionFiles } : {}),
    ...(input.launchParentSessionId !== undefined
      ? { launch: { parentSessionId: input.launchParentSessionId } }
      : {}),
  };
  const db = openDatabase(fixture.dbPath);
  try {
    db.prepare(
      `INSERT INTO session_state_sessions (
        id, session_json, pi_session_id, pi_session_file, pi_session_files_json,
        parent_session_id, launch_metadata_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      input.id,
      input.sessionJson ?? JSON.stringify(session),
      input.piSessionId ?? null,
      input.piSessionFile ?? null,
      input.piSessionFiles ? JSON.stringify(input.piSessionFiles) : null,
      input.parentSessionId ?? null,
      input.launchMetadata ?? null,
    );
  } finally {
    db.close();
  }
}

function writeTrace(path: string, id: string): void {
  writeFileSync(path, `${JSON.stringify({ type: "session", id, cwd: "/fixture" })}\n`);
}

function fingerprint(path: string): { sha256: string; size: number; mtimeMs: number; ino: number } {
  const info = statSync(path);
  return {
    sha256: createHash("sha256").update(readFileSync(path)).digest("hex"),
    size: info.size,
    mtimeMs: info.mtimeMs,
    ino: info.ino,
  };
}

function sealSnapshot(fixture: Fixture): void {
  normalizeDisposableCopiedSqliteSnapshot({
    snapshotDirectory: fixture.snapshotDirectory,
    databasePath: fixture.dbPath,
    acknowledgement: DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
  });
  fixture.prepared = true;
}

function cleanupFixture(fixture: Fixture): void {
  try {
    chmodSync(fixture.snapshotDirectory, 0o700);
    chmodSync(fixture.dbPath, 0o600);
  } catch {
    // Best-effort test cleanup after a rejected/incomplete fixture.
  }
  rmSync(fixture.root, { recursive: true, force: true });
}

function inventoryFixture(
  fixture: Fixture,
  decisions: Omit<
    Parameters<typeof inventorySessionIdMigration>[0],
    "snapshotDirectory" | "databasePath" | "allowedTraceRoots"
  > = {},
) {
  if (!fixture.prepared) sealSnapshot(fixture);
  return inventorySessionIdMigration({
    snapshotDirectory: fixture.snapshotDirectory,
    databasePath: fixture.dbPath,
    allowedTraceRoots: [fixture.traceRoot],
    ...decisions,
  });
}

describe("session ID migration inventory", () => {
  it("inventories a normalized sealed SQLite copy without changing it or explicit traces", () => {
    const fixture = createFixture();
    try {
      const current = join(fixture.traceRoot, "current.jsonl");
      const historical = join(fixture.traceRoot, "historical.jsonl");
      const missing = join(fixture.traceRoot, "missing.jsonl");
      writeTrace(current, PI_A);
      writeTrace(historical, PI_B);
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        piSessionFile: current,
        piSessionFiles: [current, historical, missing],
      });
      const db = openDatabase(fixture.dbPath);
      try {
        db.prepare("INSERT INTO agent_schedules (id, action_json) VALUES (?, ?)").run(
          "schedule-a",
          JSON.stringify({ type: "existing_session", workspaceId: "ws", sessionId: "wrapper-a" }),
        );
        db.prepare(
          "INSERT INTO agent_schedule_runs (id, action_snapshot_json, result_json) VALUES (?, ?, ?)",
        ).run(
          "run-a",
          JSON.stringify({ type: "existing_session", workspaceId: "ws", sessionId: "wrapper-a" }),
          JSON.stringify({ sessionId: "wrapper-a" }),
        );
      } finally {
        db.close();
      }
      sealSnapshot(fixture);
      expect(statSync(fixture.dbPath).mode & 0o777).toBe(0o400);
      expect(statSync(fixture.snapshotDirectory).mode & 0o777).toBe(0o500);
      const before = [fingerprint(fixture.dbPath), fingerprint(current), fingerprint(historical)];
      const beforeEntries = readdirSync(fixture.snapshotDirectory).sort();

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("ready");
      expect(manifest.rows[0]).toMatchObject({
        sourceRowId: "wrapper-a",
        canonicalSessionId: PI_A,
        disposition: "adopt_stored_pi_id",
      });
      expect(manifest.historicalIdentityLosses).toEqual([
        expect.objectContaining({
          discardedIdentities: [
            expect.objectContaining({
              piSessionId: PI_B,
              availableTracePaths: [expect.stringMatching(/\/historical\.jsonl$/)],
            }),
          ],
          unavailableTraceCount: 1,
          unattributedUnavailableTracePaths: [missing],
        }),
      ]);
      expect(manifest.plannedOperations.references).toEqual([
        expect.objectContaining({
          location: "sqlite:agent_schedule_runs:run-a:action_snapshot_json.sessionId",
          policy: "observe_only",
          outcome: "observe_only",
        }),
        expect.objectContaining({
          location: "sqlite:agent_schedule_runs:run-a:result_json.sessionId",
          policy: "observe_only",
          outcome: "observe_only",
        }),
        expect.objectContaining({
          location: "sqlite:agent_schedules:schedule-a:action_json.sessionId",
          policy: "rewrite",
          outcome: "rewrite",
        }),
      ]);
      expect(manifest.metadata.inventoryCoverage.notInventoried).toEqual(
        expect.arrayContaining([
          "configured upload-store records and blobs",
          "session-attachments/<sessionId>/ manifests and media",
          "session-search.db session_fts.session_id and fts_meta.session_id",
          "workspace .pi/attachments/<sessionId>/ materializations",
        ]),
      );
      expect([fingerprint(fixture.dbPath), fingerprint(current), fingerprint(historical)]).toEqual(
        before,
      );
      expect(readdirSync(fixture.snapshotDirectory).sort()).toEqual(beforeEntries);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("normalizes a WAL copied snapshot without changing its source, then inventories it read-only", () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-session-id-wal-copy-"));
    const sourceDirectory = join(root, "source");
    const snapshotDirectory = join(root, "snapshot");
    const sourceDatabasePath = join(sourceDirectory, "live-source.db");
    const databasePath = join(snapshotDirectory, "session-state.db");
    const traceRoot = join(root, "traces");
    mkdirSync(sourceDirectory);
    mkdirSync(snapshotDirectory);
    mkdirSync(traceRoot);
    try {
      const source = openDatabase(sourceDatabasePath);
      try {
        source.exec(`
          CREATE TABLE session_state_sessions (
            id TEXT PRIMARY KEY,
            session_json TEXT NOT NULL,
            pi_session_id TEXT,
            pi_session_file TEXT,
            pi_session_files_json TEXT,
            parent_session_id TEXT,
            launch_metadata_json TEXT
          );
          CREATE TABLE agent_schedules (id TEXT PRIMARY KEY, action_json TEXT NOT NULL);
          CREATE TABLE agent_schedule_runs (
            id TEXT PRIMARY KEY,
            action_snapshot_json TEXT NOT NULL,
            result_json TEXT
          );
          PRAGMA journal_mode = WAL;
        `);
        source
          .prepare(
            `INSERT INTO session_state_sessions (
              id, session_json, pi_session_id, pi_session_file, pi_session_files_json,
              parent_session_id, launch_metadata_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
          )
          .run(
            "wrapper-a",
            JSON.stringify({ id: "wrapper-a", piSessionId: PI_A }),
            PI_A,
            null,
            null,
            null,
            null,
          );
        expect(statSync(`${sourceDatabasePath}-wal`).isFile()).toBe(true);
        expect(statSync(`${sourceDatabasePath}-shm`).isFile()).toBe(true);
        copyFileSync(sourceDatabasePath, databasePath);
        copyFileSync(`${sourceDatabasePath}-wal`, `${databasePath}-wal`);
        copyFileSync(`${sourceDatabasePath}-shm`, `${databasePath}-shm`);
      } finally {
        source.close();
      }

      const sourceBefore = fingerprint(sourceDatabasePath);
      normalizeDisposableCopiedSqliteSnapshot({
        snapshotDirectory,
        databasePath,
        acknowledgement: DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
      });
      expect(() => statSync(`${databasePath}-wal`)).toThrow();
      expect(() => statSync(`${databasePath}-shm`)).toThrow();
      const normalized = openReadOnlyDatabase(databasePath);
      try {
        expect(normalized.prepare("PRAGMA journal_mode").get()).toMatchObject({
          journal_mode: "delete",
        });
      } finally {
        normalized.close();
      }

      const snapshotBeforeInventory = fingerprint(databasePath);
      const manifest = inventorySessionIdMigration({
        snapshotDirectory,
        databasePath,
        allowedTraceRoots: [traceRoot],
      });
      expect(manifest.status).toBe("ready");
      expect(fingerprint(databasePath)).toEqual(snapshotBeforeInventory);
      expect(fingerprint(sourceDatabasePath)).toEqual(sourceBefore);

      const writeAttempt = openDatabase(databasePath);
      try {
        expect(() => writeAttempt.prepare("DELETE FROM session_state_sessions").run()).toThrow();
      } finally {
        writeAttempt.close();
      }
    } finally {
      try {
        chmodSync(snapshotDirectory, 0o700);
        chmodSync(databasePath, 0o600);
      } catch {
        // Best-effort cleanup after a failed normalization.
      }
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("requires an explicit acknowledgement before mutating a copied snapshot", () => {
    const fixture = createFixture();
    try {
      expect(() =>
        normalizeDisposableCopiedSqliteSnapshot({
          snapshotDirectory: fixture.snapshotDirectory,
          databasePath: fixture.dbPath,
          acknowledgement: "no" as typeof DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
        }),
      ).toThrow("Disposable copied SQLite snapshot acknowledgement is required");
      expect(statSync(fixture.dbPath).mode & 0o222).not.toBe(0);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("observes stale parent and historical run references without rewriting or blocking them", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-parent", piSessionId: PI_B });
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        parentSessionId: "removed-parent",
        launchParentSessionId: "wrapper-parent",
        launchMetadata: JSON.stringify({ parentSessionId: "wrapper-parent" }),
      });
      const db = openDatabase(fixture.dbPath);
      try {
        db.prepare("INSERT INTO agent_schedules (id, action_json) VALUES (?, ?)").run(
          "schedule-a",
          JSON.stringify({ type: "existing_session", workspaceId: "ws", sessionId: "wrapper-a" }),
        );
        db.prepare(
          "INSERT INTO agent_schedule_runs (id, action_snapshot_json, result_json) VALUES (?, ?, ?)",
        ).run(
          "run-a",
          JSON.stringify({ type: "existing_session", workspaceId: "ws", sessionId: "removed-run" }),
          JSON.stringify({ sessionId: "removed-result" }),
        );
      } finally {
        db.close();
      }

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("ready");
      expect(manifest.plannedOperations.references).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
            sourceSessionId: "removed-parent",
            policy: "observe_only",
            outcome: "observe_only",
          }),
          expect.objectContaining({
            location: "sqlite:session_state_sessions:wrapper-a:session_json.launch.parentSessionId",
            sourceSessionId: "wrapper-parent",
            targetSessionId: PI_B,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location:
              "sqlite:session_state_sessions:wrapper-a:launch_metadata_json.parentSessionId",
            sourceSessionId: "wrapper-parent",
            targetSessionId: PI_B,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "sqlite:agent_schedule_runs:run-a:action_snapshot_json.sessionId",
            sourceSessionId: "removed-run",
            policy: "observe_only",
            outcome: "observe_only",
          }),
          expect.objectContaining({
            location: "sqlite:agent_schedule_runs:run-a:result_json.sessionId",
            sourceSessionId: "removed-result",
            policy: "observe_only",
            outcome: "observe_only",
          }),
        ]),
      );
      expect(manifest.findings).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "stale_reference",
            severity: "warning",
            location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
          }),
          expect.objectContaining({
            kind: "dangling_reference",
            severity: "warning",
            location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
          }),
          expect.objectContaining({
            kind: "dangling_reference",
            severity: "warning",
            location: "sqlite:agent_schedule_runs:run-a:action_snapshot_json.sessionId",
          }),
          expect.objectContaining({
            kind: "dangling_reference",
            severity: "warning",
            location: "sqlite:agent_schedule_runs:run-a:result_json.sessionId",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("keeps a parent_session_id with no launch evidence as stale observe-only audit evidence", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A, parentSessionId: "old-parent" });

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("ready");
      expect(manifest.plannedOperations.references).toContainEqual(
        expect.objectContaining({
          location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
          sourceSessionId: "old-parent",
          policy: "observe_only",
          outcome: "observe_only",
        }),
      );
      expect(manifest.findings).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "stale_reference",
            severity: "warning",
            location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
          }),
          expect.objectContaining({
            kind: "dangling_reference",
            severity: "warning",
            location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("blocks one-sided parent presence when both launch objects exist", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        launchParentSessionId: "parent-only-in-session-json",
        launchMetadata: JSON.stringify({}),
      });

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({
          kind: "unclassified_reference",
          severity: "blocking",
          location: "sqlite:session_state_sessions:wrapper-a:launch-parent-reconciliation",
        }),
      );
      expect(manifest.plannedOperations.references).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "sqlite:session_state_sessions:wrapper-a:session_json.launch.parentSessionId",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("allows one-sided parent evidence for older rows that have only one launch object", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-parent", piSessionId: PI_B });
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        parentSessionId: "wrapper-parent",
        launchParentSessionId: "wrapper-parent",
      });

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("ready");
      expect(manifest.plannedOperations.references).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "sqlite:session_state_sessions:wrapper-a:session_json.launch.parentSessionId",
            targetSessionId: PI_B,
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "sqlite:session_state_sessions:wrapper-a:parent_session_id",
            targetSessionId: PI_B,
            policy: "rewrite",
            outcome: "rewrite",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("keeps current schedule actions required and blocking when their session row is absent", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const db = openDatabase(fixture.dbPath);
      try {
        db.prepare("INSERT INTO agent_schedules (id, action_json) VALUES (?, ?)").run(
          "schedule-missing",
          JSON.stringify({ type: "existing_session", workspaceId: "ws", sessionId: "missing" }),
        );
      } finally {
        db.close();
      }

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.plannedOperations.references).toContainEqual(
        expect.objectContaining({
          location: "sqlite:agent_schedules:schedule-missing:action_json.sessionId",
          policy: "rewrite",
          outcome: "dangling",
        }),
      );
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({
          kind: "dangling_reference",
          severity: "blocking",
          location: "sqlite:agent_schedules:schedule-missing:action_json.sessionId",
        }),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("blocks malformed historical schedule evidence while retaining a well-formed dangling run as observe-only", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const db = openDatabase(fixture.dbPath);
      try {
        db.prepare(
          "INSERT INTO agent_schedule_runs (id, action_snapshot_json, result_json) VALUES (?, ?, ?)",
        ).run("bad-run", "{not-json", JSON.stringify({ sessionId: "removed-result" }));
      } finally {
        db.close();
      }

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "unclassified_reference",
            severity: "blocking",
            location: "sqlite:agent_schedule_runs:bad-run:action_snapshot_json",
          }),
          expect.objectContaining({
            kind: "dangling_reference",
            severity: "warning",
            location: "sqlite:agent_schedule_runs:bad-run:result_json.sessionId",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("blocks invalid schedule action shapes and contradictory launch parent evidence", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        launchParentSessionId: "parent-one",
        launchMetadata: JSON.stringify({ parentSessionId: "parent-two" }),
      });
      const db = openDatabase(fixture.dbPath);
      try {
        db.prepare("INSERT INTO agent_schedules (id, action_json) VALUES (?, ?)").run(
          "bad-new",
          JSON.stringify({ type: "new_session", workspaceId: "ws", prompt: "x", sessionId: "bad" }),
        );
        db.prepare("INSERT INTO agent_schedules (id, action_json) VALUES (?, ?)").run(
          "bad-kind",
          JSON.stringify({ type: "other", sessionId: "bad" }),
        );
      } finally {
        db.close();
      }

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "sqlite:session_state_sessions:wrapper-a:launch-parent-reconciliation",
            severity: "blocking",
          }),
          expect.objectContaining({
            location: "sqlite:agent_schedules:bad-new:action_json.sessionId",
            severity: "blocking",
          }),
          expect.objectContaining({
            location: "sqlite:agent_schedules:bad-kind:action_json",
            severity: "blocking",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("fails closed for malformed session JSON and malformed projected JSON", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "bad-session", sessionJson: "{not-json" });
      insertSession(fixture, { id: "bad-projection", piSessionId: PI_A, piSessionFiles: [] });
      const db = openDatabase(fixture.dbPath);
      try {
        db.prepare("UPDATE session_state_sessions SET pi_session_files_json = ? WHERE id = ?").run(
          "{not-json",
          "bad-projection",
        );
      } finally {
        db.close();
      }
      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "unclassified_reference",
            severity: "blocking",
            location: "sqlite:session_state_sessions:bad-session:session_json",
          }),
          expect.objectContaining({
            kind: "unclassified_reference",
            severity: "blocking",
            location: "sqlite:session_state_sessions:bad-projection:pi_session_files_json",
          }),
          expect.objectContaining({ kind: "unclassified_session", severity: "blocking" }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("rejects a trace path outside explicit roots rather than reading it", () => {
    const fixture = createFixture();
    const outside = join(fixture.root, "outside.jsonl");
    try {
      writeTrace(outside, PI_A);
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        piSessionFile: outside,
        piSessionFiles: [outside],
      });

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({
          kind: "unclassified_trace",
          severity: "blocking",
          location: `session-row:wrapper-a:current-file:${outside}`,
        }),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("rejects FIFO trace entries without opening them", () => {
    const fixture = createFixture();
    try {
      const fifo = join(fixture.traceRoot, "trace.fifo");
      execFileSync("mkfifo", [fifo]);
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A, piSessionFile: fifo });

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({
          kind: "unclassified_trace",
          severity: "blocking",
          location: `session-row:wrapper-a:current-file:${fifo}`,
          detail: "trace path must name a regular non-symlink file",
        }),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("retains malformed nonempty current header evidence as a blocking finding", () => {
    const manifest = planSessionIdMigration({
      sessionRows: [
        {
          sourceRowId: "wrapper-a",
          piSessionId: PI_A,
          piSessionFile: {
            path: "/fixture/bad.jsonl",
            availability: "available",
            headerPiSessionId: "not-a-uuid",
            headerStatus: "valid",
          },
        },
      ],
    });

    expect(manifest.status).toBe("blocked");
    expect(manifest.findings).toContainEqual(
      expect.objectContaining({
        kind: "unclassified_trace",
        severity: "blocking",
        detail: "current trace is marked valid without a valid Pi session UUID",
      }),
    );
  });

  it("passes caller-approved UUID assignments and duplicate dispositions to the planner", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "needs-assignment" });
      insertSession(fixture, { id: "duplicate-a", piSessionId: PI_A });
      insertSession(fixture, { id: "duplicate-b", piSessionId: PI_A });

      const manifest = inventoryFixture(fixture, {
        plannedUuidsBySourceRowId: { "needs-assignment": PI_B },
        duplicateDispositions: [
          {
            targetSessionId: PI_A,
            survivorSourceRowId: "duplicate-a",
            decisionId: "review-1",
            reasonId: "field-authority",
          },
        ],
      });

      expect(manifest.status).toBe("ready");
      expect(manifest.rows).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            sourceRowId: "needs-assignment",
            canonicalSessionId: PI_B,
            disposition: "use_planned_uuid",
          }),
        ]),
      );
      expect(manifest.duplicateGroups).toEqual([
        expect.objectContaining({
          canonicalSessionId: PI_A,
          resolution: "approved",
          survivorSourceRowId: "duplicate-a",
          decisionId: "review-1",
        }),
      ]);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("records absent optional schedule tables without claiming they were inventoried", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const db = openDatabase(fixture.dbPath);
      try {
        db.exec("DROP TABLE agent_schedules; DROP TABLE agent_schedule_runs;");
      } finally {
        db.close();
      }

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("ready");
      expect(manifest.metadata.inventoryCoverage.acceptedInputs).not.toContain(
        "copied SQLite agent_schedules existing-session actions",
      );
      expect(manifest.metadata.inventoryCoverage.inspectedButAbsent).toEqual([
        "sqlite:agent_schedule_runs (optional table absent)",
        "sqlite:agent_schedules (optional table absent)",
      ]);
      expect(manifest.metadata.inventoryCoverage.unavailable).toEqual([]);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("rejects writable snapshots and leaves no SQLite sidecars after normalization", () => {
    const writable = createFixture();
    const sidecar = createFixture();
    const shm = createFixture();
    try {
      insertSession(writable, { id: "wrapper-a", piSessionId: PI_A });
      expect(() =>
        inventorySessionIdMigration({
          snapshotDirectory: writable.snapshotDirectory,
          databasePath: writable.dbPath,
          allowedTraceRoots: [writable.traceRoot],
        }),
      ).toThrow("SQLite snapshot file must have owner-only mode 400");

      insertSession(sidecar, { id: "wrapper-a", piSessionId: PI_A });
      writeFileSync(`${sidecar.dbPath}-wal`, "not a WAL");
      sealSnapshot(sidecar);
      expect(() => statSync(`${sidecar.dbPath}-wal`)).toThrow();

      insertSession(shm, { id: "wrapper-a", piSessionId: PI_A });
      writeFileSync(`${shm.dbPath}-shm`, "not shared memory");
      expect(() => sealSnapshot(shm)).toThrow("Disposable copied SQLite snapshot sealing failed");
    } finally {
      cleanupFixture(writable);
      cleanupFixture(sidecar);
      cleanupFixture(shm);
    }
  });

  it("rejects hard-linked WAL and SHM sidecars before normalization", () => {
    const wal = createFixture();
    const shm = createFixture();
    try {
      const walSource = join(wal.root, "wal-source");
      writeFileSync(walSource, "sidecar");
      linkSync(walSource, `${wal.dbPath}-wal`);
      expect(() => sealSnapshot(wal)).toThrow(
        "Disposable copied SQLite snapshot sidecar must not be hard-linked",
      );

      const shmSource = join(shm.root, "shm-source");
      writeFileSync(shmSource, "sidecar");
      linkSync(shmSource, `${shm.dbPath}-shm`);
      expect(() => sealSnapshot(shm)).toThrow(
        "Disposable copied SQLite snapshot sidecar must not be hard-linked",
      );
    } finally {
      cleanupFixture(wal);
      cleanupFixture(shm);
    }
  });

  it("rejects a symlinked database path before opening SQLite", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const alias = join(fixture.snapshotDirectory, "session-state-alias.db");
      symlinkSync(fixture.dbPath, alias);
      chmodSync(fixture.dbPath, 0o444);
      chmodSync(fixture.snapshotDirectory, 0o555);

      expect(() =>
        inventorySessionIdMigration({
          snapshotDirectory: fixture.snapshotDirectory,
          databasePath: alias,
          allowedTraceRoots: [fixture.traceRoot],
        }),
      ).toThrow("Disposable copied SQLite snapshot database must be a real regular file");
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("keeps a sealed snapshot immutable to SQL writes and rejects trace symlink escape", () => {
    const fixture = createFixture();
    try {
      const outside = join(fixture.root, "outside.jsonl");
      const linked = join(fixture.traceRoot, "linked.jsonl");
      writeTrace(outside, PI_A);
      symlinkSync(outside, linked);
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A, piSessionFile: linked });
      const before = fingerprint(fixture.dbPath);
      sealSnapshot(fixture);

      const db = openDatabase(fixture.dbPath);
      try {
        expect(() => db.prepare("DELETE FROM session_state_sessions").run()).toThrow();
      } finally {
        db.close();
      }
      expect(fingerprint(fixture.dbPath)).toEqual(before);
      const manifest = inventoryFixture(fixture);
      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({ kind: "unclassified_trace", severity: "blocking" }),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("produces a deterministic manifest from unordered fixture rows", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-b", piSessionId: PI_B });
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });

      const first = inventoryFixture(fixture);
      const second = inventoryFixture(fixture);

      expect(first).toEqual(second);
      expect(first.rows.map((row) => row.sourceRowId)).toEqual(["wrapper-a", "wrapper-b"]);
    } finally {
      cleanupFixture(fixture);
    }
  });
});


function createLeftoverTables(fixture: Fixture): void {
  const db = openDatabase(fixture.dbPath);
  try {
    db.exec(`
      CREATE TABLE review_state_comments (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        session_id TEXT,
        turn_id TEXT,
        author TEXT NOT NULL,
        status TEXT NOT NULL,
        severity TEXT,
        body TEXT NOT NULL,
        attachments_json TEXT,
        reference_json TEXT NOT NULL,
        reference_path TEXT,
        sent_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE review_state_schema (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE server_agent_extension_audit_events (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        workspace_id TEXT,
        schedule_id TEXT,
        run_id TEXT,
        session_id TEXT,
        event_type TEXT NOT NULL,
        approval_ref_id TEXT,
        extension_scope_id TEXT,
        extension_display_name TEXT,
        display_json TEXT,
        provenance_json TEXT,
        envelope_json TEXT NOT NULL
      );
      CREATE TABLE tui_session_files (
        path TEXT PRIMARY KEY,
        pi_session_id TEXT NOT NULL,
        cwd TEXT NOT NULL,
        name TEXT,
        first_message TEXT,
        model TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_modified INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        mtime_ms REAL NOT NULL,
        is_subagent INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE local_session_files (
        path TEXT PRIMARY KEY,
        pi_session_id TEXT NOT NULL,
        cwd TEXT NOT NULL,
        name TEXT,
        first_message TEXT,
        model TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_modified INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        mtime_ms REAL NOT NULL,
        is_subagent INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE workspaces (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        workspace_json TEXT NOT NULL
      );
    `);
    db.prepare(
      `INSERT INTO review_state_comments (
        id, workspace_id, session_id, author, status, body, reference_json, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run("comment-1", "ws", "wrapper-a", "user", "open", "nits", "{}", 1, 1);
    db.prepare(
      `INSERT INTO server_agent_extension_audit_events (
        id, created_at, session_id, event_type, envelope_json
      ) VALUES (?, ?, ?, ?, ?)`,
    ).run("audit-1", 1, null, "approval_ref.accepted", "{}");
    db.prepare(
      `INSERT INTO tui_session_files (
        path, pi_session_id, cwd, message_count, created_at, last_modified, size_bytes, mtime_ms, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run("/tui/current.jsonl", PI_A, "/ws", 1, 1, 1, 1, 1, 1);
    db.prepare(
      `INSERT INTO local_session_files (
        path, pi_session_id, cwd, message_count, created_at, last_modified, size_bytes, mtime_ms, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run("/tui/current.jsonl", PI_A, "/ws", 1, 1, 1, 1, 1, 1);
    db.prepare(
      "INSERT INTO workspaces (id, name, created_at, updated_at, workspace_json) VALUES (?, ?, ?, ?, ?)",
    ).run("ws", "Workspace", 1, 1, JSON.stringify({ id: "ws" }));
    db.prepare("INSERT INTO review_state_schema (key, value) VALUES (?, ?)").run("version", "1");
  } finally {
    db.close();
  }
}

describe("session ID migration remaining-store inventory", () => {
  it("inventories leftover shipped tables without treating TUI catalog Pi IDs as wrapper dual-IDs", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      createLeftoverTables(fixture);

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("ready");
      expect(manifest.metadata.inventoryCoverage.acceptedInputs).toEqual(
        expect.arrayContaining([
          "copied SQLite leftover review_state_comments as observe_only drop",
          "copied SQLite leftover server_agent_extension_audit_events",
          "copied SQLite tui_session_files catalog identities (not wrapper Session.id)",
          "copied SQLite leftover local_session_files catalog identities (not wrapper Session.id)",
          "copied SQLite leftover tables without session identity",
        ]),
      );
      expect(manifest.metadata.inventoryCoverage.notInventoried.join("\n")).not.toMatch(
        /review_state_comments|server_agent_extension_audit_events|local_session_files|tui_session_files/,
      );
      expect(manifest.plannedOperations.references).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "sqlite:review_state_comments:comment-1:session_id",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "observe_only",
            outcome: "observe_only",
          }),
        ]),
      );
      expect(manifest.plannedOperations.references).not.toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: expect.stringMatching(/tui_session_files|local_session_files/),
            policy: "rewrite",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("fails closed for an unknown leftover table that carries session_id", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const db = openDatabase(fixture.dbPath);
      try {
        db.exec("CREATE TABLE mystery_session_bits (id TEXT PRIMARY KEY, session_id TEXT)");
        db.prepare("INSERT INTO mystery_session_bits (id, session_id) VALUES (?, ?)").run(
          "mystery-1",
          "wrapper-a",
        );
      } finally {
        db.close();
      }

      const manifest = inventoryFixture(fixture);

      expect(manifest.status).toBe("blocked");
      expect(manifest.findings).toContainEqual(
        expect.objectContaining({
          kind: "unclassified_reference",
          severity: "blocking",
          location: "sqlite:mystery_session_bits",
        }),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("inventories attachment manifests, upload records, search keys, unnamed traces, and workspace listings", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const attachmentRoot = join(fixture.root, "attachment-manifests");
      const uploadRoot = join(fixture.root, "upload-records");
      const unnamedRoot = join(fixture.root, "server-traces");
      const listingPath = join(fixture.root, "workspace-attachments.json");
      mkdirSync(join(attachmentRoot, "wrapper-a"), { recursive: true });
      writeFileSync(
        join(attachmentRoot, "wrapper-a", "manifest.json"),
        JSON.stringify({
          version: 1,
          attachments: [
            {
              id: "att-1",
              kind: "image",
              mimeType: "image/png",
              fileName: "shot.png",
              sizeBytes: 1,
              storageKey: "wrapper-a/att-1.png",
              createdAt: 1,
            },
          ],
        }),
      );
      mkdirSync(uploadRoot);
      writeFileSync(
        join(uploadRoot, "up-1.json"),
        JSON.stringify({ id: "up-1", sessionId: "wrapper-a", status: "complete" }),
      );
      mkdirSync(unnamedRoot);
      writeFileSync(join(unnamedRoot, "orphan.json"), "{}\n");
      writeFileSync(join(unnamedRoot, "wrapper-a.json"), "{}\n");
      writeFileSync(
        listingPath,
        JSON.stringify([
          { workspaceId: "ws", sessionId: "wrapper-a", path: "/ws/.pi/attachments/wrapper-a" },
        ]),
      );

      const searchSnapshotDirectory = join(fixture.root, "search-snapshot");
      mkdirSync(searchSnapshotDirectory);
      const searchDatabasePath = join(searchSnapshotDirectory, "session-search.db");
      const search = openDatabase(searchDatabasePath);
      try {
        search.exec(`
          CREATE VIRTUAL TABLE session_fts USING fts5(
            session_id UNINDEXED,
            workspace_id UNINDEXED,
            title
          );
          CREATE TABLE fts_meta (session_id TEXT PRIMARY KEY, title TEXT);
        `);
        search.prepare("INSERT INTO session_fts (session_id, workspace_id, title) VALUES (?, ?, ?)").run(
          "wrapper-a",
          "ws",
          "title",
        );
        search.prepare("INSERT INTO fts_meta (session_id, title) VALUES (?, ?)").run("wrapper-a", "title");
      } finally {
        search.close();
      }
      normalizeDisposableCopiedSqliteSnapshot({
        snapshotDirectory: searchSnapshotDirectory,
        databasePath: searchDatabasePath,
        acknowledgement: DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
      });

      const manifest = inventoryFixture(fixture, {
        searchSnapshot: {
          snapshotDirectory: searchSnapshotDirectory,
          databasePath: searchDatabasePath,
        },
        attachmentManifestRoot: attachmentRoot,
        uploadRecordRoot: uploadRoot,
        unnamedTraceRoot: unnamedRoot,
        workspaceAttachmentListingPath: listingPath,
      });

      expect(manifest.status).toBe("ready");
      expect(manifest.metadata.inventoryCoverage.notInventoried).toEqual([
        "runtime memory, event rings, push/live-activity state, and Apple-only state",
      ]);
      expect(manifest.plannedOperations.paths).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "session-attachments:wrapper-a",
            path: "session-attachments/wrapper-a",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "workspace-attachments:ws:wrapper-a",
            path: "/ws/.pi/attachments/wrapper-a",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "rewrite",
            outcome: "rewrite",
          }),
        ]),
      );
      expect(manifest.plannedOperations.references).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "session-attachments:wrapper-a:manifest.json:att-1:storageKey",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "upload-store:up-1:sessionId",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "session-search:fts_meta:wrapper-a:session_id",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "session-search:session_fts:wrapper-a:session_id",
            sourceSessionId: "wrapper-a",
            targetSessionId: PI_A,
            policy: "rewrite",
            outcome: "rewrite",
          }),
          expect.objectContaining({
            location: "unnamed-trace:orphan.json",
            policy: "observe_only",
            outcome: "observe_only",
          }),
        ]),
      );
    } finally {
      try {
        chmodSync(join(fixture.root, "search-snapshot"), 0o700);
        chmodSync(join(fixture.root, "search-snapshot", "session-search.db"), 0o600);
      } catch {
        // Best-effort cleanup of the extra sealed search snapshot.
      }
      cleanupFixture(fixture);
    }
  });

  it("still requires caller-approved dispositions for live-shaped duplicate groups", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "cGEcSBwD", piSessionId: PI_A });
      insertSession(fixture, { id: "aEY7oaE8", piSessionId: PI_A });

      const blocked = inventoryFixture(fixture);
      expect(blocked.status).toBe("blocked");
      expect(blocked.duplicateGroups[0]).toMatchObject({ resolution: "unresolved" });

      const approved = inventoryFixture(fixture, {
        duplicateDispositions: [
          {
            targetSessionId: PI_A,
            survivorSourceRowId: "cGEcSBwD",
            decisionId: "duplicate-review-2026-08-17-01",
            reasonId: FIELD_AUTHORITY_DUPLICATE_REASON_ID,
          },
        ],
      });
      expect(approved.status).toBe("ready");
      expect(approved.duplicateGroups[0]).toMatchObject({
        survivorSourceRowId: "cGEcSBwD",
        reasonId: FIELD_AUTHORITY_DUPLICATE_REASON_ID,
      });
    } finally {
      cleanupFixture(fixture);
    }
  });
});
