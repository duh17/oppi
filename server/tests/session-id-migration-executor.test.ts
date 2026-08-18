import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { describe, expect, it } from "vitest";

import { openDatabase, openReadOnlyDatabase } from "../src/sqlite-compat.js";
import {
  DISPOSABLE_COPIED_SESSION_ID_EXECUTOR_ACKNOWLEDGEMENT,
  classifySessionIdMigrationFindings,
  executeSessionIdMigration,
} from "../src/storage/session-id-migration-executor.js";
import { FIELD_AUTHORITY_DUPLICATE_REASON_ID } from "../src/storage/session-id-migration-merge.js";
import { inventorySessionIdMigration } from "../src/storage/session-id-migration-inventory.js";
import {
  DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
  normalizeDisposableCopiedSqliteSnapshot,
} from "../src/storage/session-id-migration-snapshot.js";

const PI_A = "11111111-1111-4111-8111-111111111111";
const PI_B = "22222222-2222-4222-8222-222222222222";
const PI_C = "33333333-3333-4333-8333-333333333333";
const PLANNED = "44444444-4444-4444-8444-444444444444";
const SMOKE_ID = "-V_70A3o";

interface Fixture {
  root: string;
  snapshotDirectory: string;
  dbPath: string;
  searchSnapshotDirectory: string;
  searchPath: string;
  attachmentRoot: string;
  uploadRoot: string;
  workspaceAttachmentRoot: string;
  listingPath: string;
  workspaceDirectory: string;
  traceRoot: string;
}

function fingerprint(path: string): { sha256: string; size: number; mode: number } {
  const info = statSync(path);
  return {
    sha256: createHash("sha256").update(readFileSync(path)).digest("hex"),
    size: info.size,
    mode: info.mode & 0o777,
  };
}

function writeTrace(path: string, id: string): void {
  writeFileSync(path, `${JSON.stringify({ type: "session", id, cwd: "/fixture" })}\n`);
}

function createFixture(): Fixture {
  const root = mkdtempSync(join(tmpdir(), "oppi-session-id-executor-"));
  const snapshotDirectory = join(root, "snapshot");
  const searchSnapshotDirectory = join(root, "search-snapshot");
  const attachmentRoot = join(root, "attachment-manifests");
  const uploadRoot = join(root, "upload-records");
  const workspaceAttachmentRoot = join(root, "workspace-attachments");
  const workspaceDirectory = join(root, "executor-workspace");
  const traceRoot = join(root, "traces");
  mkdirSync(snapshotDirectory);
  mkdirSync(searchSnapshotDirectory);
  mkdirSync(attachmentRoot);
  mkdirSync(uploadRoot);
  mkdirSync(workspaceAttachmentRoot);
  mkdirSync(workspaceDirectory);
  mkdirSync(traceRoot);
  const dbPath = join(snapshotDirectory, "session-state.db");
  const searchPath = join(searchSnapshotDirectory, "session-search.db");
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
        launch_metadata_json TEXT,
        name TEXT,
        created_at INTEGER,
        last_activity INTEGER,
        message_count INTEGER
      );
      CREATE TABLE agent_schedules (id TEXT PRIMARY KEY, action_json TEXT NOT NULL);
      CREATE TABLE agent_schedule_runs (
        id TEXT PRIMARY KEY,
        action_snapshot_json TEXT NOT NULL,
        result_json TEXT
      );
      CREATE TABLE review_state_comments (
        id TEXT PRIMARY KEY,
        session_id TEXT,
        body TEXT
      );
    `);
  } finally {
    db.close();
  }
  const search = openDatabase(searchPath);
  try {
    search.exec(`
      CREATE VIRTUAL TABLE session_fts USING fts5(
        session_id UNINDEXED,
        workspace_id UNINDEXED,
        title,
        user_messages
      );
      CREATE TABLE fts_meta (
        session_id TEXT PRIMARY KEY,
        jsonl_path TEXT,
        title TEXT
      );
    `);
  } finally {
    search.close();
  }
  return {
    root,
    snapshotDirectory,
    dbPath,
    searchSnapshotDirectory,
    searchPath,
    attachmentRoot,
    uploadRoot,
    workspaceAttachmentRoot,
    listingPath: join(root, "workspace-attachments.json"),
    workspaceDirectory,
    traceRoot,
  };
}

function insertSession(
  fixture: Fixture,
  input: {
    id: string;
    piSessionId?: string;
    piSessionFile?: string;
    piSessionFiles?: string[];
    launchParentSessionId?: string;
    parentSessionId?: string | null;
    launchMetadata?: string | null;
    name?: string;
    createdAt?: number;
    lastActivity?: number;
    messageCount?: number;
    workspaceId?: string;
  },
): void {
  const session = {
    id: input.id,
    status: "stopped",
    createdAt: input.createdAt ?? 1,
    lastActivity: input.lastActivity ?? 1,
    messageCount: input.messageCount ?? 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...(input.name !== undefined ? { name: input.name } : {}),
    ...(input.workspaceId !== undefined ? { workspaceId: input.workspaceId } : {}),
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
        parent_session_id, launch_metadata_json, name, created_at, last_activity, message_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      input.id,
      JSON.stringify(session),
      input.piSessionId ?? null,
      input.piSessionFile ?? null,
      input.piSessionFiles ? JSON.stringify(input.piSessionFiles) : null,
      input.parentSessionId ?? null,
      input.launchMetadata ??
        (input.launchParentSessionId
          ? JSON.stringify({ parentSessionId: input.launchParentSessionId })
          : null),
      input.name ?? null,
      input.createdAt ?? 1,
      input.lastActivity ?? 1,
      input.messageCount ?? 0,
    );
  } finally {
    db.close();
  }
}

function addSearchRow(fixture: Fixture, sessionId: string, title = "title"): void {
  const db = openDatabase(fixture.searchPath);
  try {
    db.prepare(
      "INSERT INTO session_fts (session_id, workspace_id, title, user_messages) VALUES (?, ?, ?, ?)",
    ).run(sessionId, "ws", title, "hello");
    db.prepare("INSERT INTO fts_meta (session_id, jsonl_path, title) VALUES (?, ?, ?)").run(
      sessionId,
      `/traces/${sessionId}.jsonl`,
      title,
    );
  } finally {
    db.close();
  }
}

function addAttachment(fixture: Fixture, sessionId: string): void {
  const dir = join(fixture.attachmentRoot, sessionId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "blob.png"), "png");
  writeFileSync(
    join(dir, "manifest.json"),
    JSON.stringify({
      version: 1,
      attachments: [
        {
          id: "att-1",
          kind: "image",
          mimeType: "image/png",
          fileName: "blob.png",
          sizeBytes: 3,
          storageKey: `${sessionId}/blob.png`,
          createdAt: 1,
        },
      ],
    }),
  );
}

function addUpload(fixture: Fixture, recordId: string, sessionId: string | undefined): void {
  writeFileSync(
    join(fixture.uploadRoot, `${recordId}.json`),
    JSON.stringify({
      id: recordId,
      ...(sessionId !== undefined ? { sessionId } : {}),
      status: "complete",
    }),
  );
}

function addWorkspaceAttachment(fixture: Fixture, sessionId: string): string {
  const path = join(fixture.workspaceAttachmentRoot, sessionId);
  mkdirSync(path, { recursive: true });
  writeFileSync(join(path, "note.txt"), sessionId);
  return path;
}

function sealSources(fixture: Fixture): void {
  normalizeDisposableCopiedSqliteSnapshot({
    snapshotDirectory: fixture.snapshotDirectory,
    databasePath: fixture.dbPath,
    acknowledgement: DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
  });
  normalizeDisposableCopiedSqliteSnapshot({
    snapshotDirectory: fixture.searchSnapshotDirectory,
    databasePath: fixture.searchPath,
    acknowledgement: DISPOSABLE_COPIED_SQLITE_SNAPSHOT_ACKNOWLEDGEMENT,
  });
}

function cleanupFixture(fixture: Fixture): void {
  for (const [directory, file] of [
    [fixture.snapshotDirectory, fixture.dbPath],
    [fixture.searchSnapshotDirectory, fixture.searchPath],
  ] as const) {
    try {
      chmodSync(directory, 0o700);
      chmodSync(file, 0o600);
    } catch {
      // Best-effort cleanup after a sealed source.
    }
  }
  rmSync(fixture.root, { recursive: true, force: true });
}

function defaultPolicy(overrides: Record<string, unknown> = {}) {
  return {
    acceptUnavailableCurrentTracesAsAlreadyLost: true,
    dropSourceRowIds: [SMOKE_ID],
    ...overrides,
  };
}

function executeFixture(
  fixture: Fixture,
  extra: Partial<Parameters<typeof executeSessionIdMigration>[0]> = {},
) {
  return executeSessionIdMigration({
    acknowledgement: DISPOSABLE_COPIED_SESSION_ID_EXECUTOR_ACKNOWLEDGEMENT,
    workspaceDirectory: fixture.workspaceDirectory,
    sessionState: {
      snapshotDirectory: fixture.snapshotDirectory,
      databasePath: fixture.dbPath,
    },
    searchSnapshot: {
      snapshotDirectory: fixture.searchSnapshotDirectory,
      databasePath: fixture.searchPath,
    },
    attachmentManifestRoot: fixture.attachmentRoot,
    uploadRecordRoot: fixture.uploadRoot,
    workspaceAttachmentRoot: fixture.workspaceAttachmentRoot,
    workspaceAttachmentListingPath: fixture.listingPath,
    allowedTraceRoots: [fixture.traceRoot],
    ...defaultPolicy(),
    ...extra,
  });
}

function workingStatePath(fixture: Fixture): string {
  return join(fixture.workspaceDirectory, "session-state", "session-state.db");
}

function workingSearchPath(fixture: Fixture): string {
  return join(fixture.workspaceDirectory, "session-search", "session-search.db");
}

describe("session ID migration executor", () => {
  it("rekeys identities on a disposable copy and leaves the sealed source untouched", () => {
    const fixture = createFixture();
    try {
      const current = join(fixture.traceRoot, "current.jsonl");
      const historical = join(fixture.traceRoot, "historical.jsonl");
      writeTrace(current, PI_A);
      writeTrace(historical, PI_B);
      insertSession(fixture, {
        id: "parent",
        piSessionId: PI_C,
        name: "parent",
      });
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        piSessionFile: current,
        piSessionFiles: [current, historical],
        launchParentSessionId: "parent",
        parentSessionId: "removed-parent",
        name: "child",
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
        db.prepare("INSERT INTO review_state_comments (id, session_id, body) VALUES (?, ?, ?)").run(
          "comment-1",
          "wrapper-a",
          "drop me",
        );
      } finally {
        db.close();
      }
      addSearchRow(fixture, "wrapper-a", "child");
      addSearchRow(fixture, "parent", "parent");
      addAttachment(fixture, "wrapper-a");
      addUpload(fixture, "up-1", "wrapper-a");
      const workspacePath = addWorkspaceAttachment(fixture, "wrapper-a");
      writeFileSync(
        fixture.listingPath,
        JSON.stringify([{ workspaceId: "ws", sessionId: "wrapper-a", path: workspacePath }]),
      );
      sealSources(fixture);
      const sourceBefore = fingerprint(fixture.dbPath);
      const searchBefore = fingerprint(fixture.searchPath);

      const result = executeFixture(fixture);

      expect(result.status).toBe("completed");
      expect(result.alreadyCompleted).toBe(false);
      expect(result.counts.rekeyedSessionRows).toBe(2);
      expect(result.counts.droppedReviewComments).toBe(1);
      expect(result.historicalIdentityLoss.discardedIdentities).toBe(1);
      expect(result.historicalIdentityLoss.availableTraces).toBe(1);
      expect(result.tablesCreated).not.toEqual(
        expect.arrayContaining([expect.stringMatching(/alias|archiv/i)]),
      );
      expect(fingerprint(fixture.dbPath)).toEqual(sourceBefore);
      expect(fingerprint(fixture.searchPath)).toEqual(searchBefore);

      const working = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        const rows = working
          .prepare(
            "SELECT id, session_json, pi_session_id, parent_session_id, launch_metadata_json FROM session_state_sessions ORDER BY id",
          )
          .all() as Array<{
          id: string;
          session_json: string;
          pi_session_id: string | null;
          parent_session_id: string | null;
          launch_metadata_json: string | null;
        }>;
        expect(rows.map((row) => row.id).sort()).toEqual([PI_A, PI_C]);
        const child = rows.find((row) => row.id === PI_A);
        expect(child?.pi_session_id).toBe(PI_A);
        expect(child?.parent_session_id).toBe("removed-parent");
        const session = JSON.parse(child?.session_json ?? "{}") as Record<string, unknown>;
        expect(session.id).toBe(PI_A);
        expect(session.piSessionId).toBe(PI_A);
        expect(session.piSessionFile).toBe(current);
        expect((session.launch as { parentSessionId?: string }).parentSessionId).toBe(PI_C);
        expect(JSON.parse(child?.launch_metadata_json ?? "{}")).toMatchObject({
          parentSessionId: PI_C,
        });
        expect(
          working.prepare("SELECT COUNT(*) AS n FROM review_state_comments").get() as { n: number },
        ).toEqual({ n: 0 });
        const schedule = working
          .prepare("SELECT action_json FROM agent_schedules WHERE id = ?")
          .get("schedule-a") as { action_json: string };
        expect(JSON.parse(schedule.action_json)).toMatchObject({ sessionId: PI_A });
        const run = working
          .prepare("SELECT action_snapshot_json, result_json FROM agent_schedule_runs WHERE id = ?")
          .get("run-a") as { action_snapshot_json: string; result_json: string };
        expect(JSON.parse(run.action_snapshot_json)).toMatchObject({ sessionId: "wrapper-a" });
        expect(JSON.parse(run.result_json)).toMatchObject({ sessionId: "wrapper-a" });
      } finally {
        working.close();
      }

      const search = openReadOnlyDatabase(workingSearchPath(fixture));
      try {
        expect(
          (
            search.prepare("SELECT session_id FROM fts_meta ORDER BY session_id").all() as Array<{
              session_id: string;
            }>
          ).map((row) => row.session_id),
        ).toEqual([PI_A, PI_C]);
        expect(
          (
            search
              .prepare("SELECT session_id FROM session_fts ORDER BY session_id")
              .all() as Array<{
              session_id: string;
            }>
          ).map((row) => row.session_id),
        ).toEqual([PI_A, PI_C]);
      } finally {
        search.close();
      }

      expect(
        existsSync(join(fixture.workspaceDirectory, "session-attachments", PI_A, "blob.png")),
      ).toBe(true);
      expect(existsSync(join(fixture.workspaceDirectory, "session-attachments", "wrapper-a"))).toBe(
        false,
      );
      const manifest = JSON.parse(
        readFileSync(
          join(fixture.workspaceDirectory, "session-attachments", PI_A, "manifest.json"),
          "utf8",
        ),
      ) as { attachments: Array<{ storageKey: string }> };
      expect(manifest.attachments[0]?.storageKey).toBe(`${PI_A}/blob.png`);
      const upload = JSON.parse(
        readFileSync(join(fixture.workspaceDirectory, "upload-records", "up-1.json"), "utf8"),
      ) as { sessionId: string };
      expect(upload.sessionId).toBe(PI_A);
      expect(
        existsSync(join(fixture.workspaceDirectory, "workspace-attachments", PI_A, "note.txt")),
      ).toBe(true);
      expect(readFileSync(current, "utf8")).toContain(PI_A);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("is a no-op on a second completed run", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      addSearchRow(fixture, "wrapper-a");
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const first = executeFixture(fixture);
      expect(first.status).toBe("completed");
      const afterFirst = fingerprint(workingStatePath(fixture));
      const journalBefore = readFileSync(join(fixture.workspaceDirectory, "journal.json"), "utf8");
      const second = executeFixture(fixture);
      expect(second.status).toBe("completed");
      expect(second.alreadyCompleted).toBe(true);
      expect(fingerprint(workingStatePath(fixture))).toEqual(afterFirst);
      expect(readFileSync(join(fixture.workspaceDirectory, "journal.json"), "utf8")).toBe(
        journalBefore,
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("drops the permission-gate smoke row instead of keeping that identity as Session.id", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      insertSession(fixture, {
        id: SMOKE_ID,
        piSessionId: "permission-gate-smoke-escalate",
        piSessionFile: join(fixture.traceRoot, "smoke.jsonl"),
      });
      writeTrace(join(fixture.traceRoot, "smoke.jsonl"), "permission-gate-smoke-escalate");
      addSearchRow(fixture, SMOKE_ID, "smoke");
      addSearchRow(fixture, "wrapper-a");
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);

      const blocked = classifySessionIdMigrationFindings(
        inventorySessionIdMigration({
          snapshotDirectory: fixture.snapshotDirectory,
          databasePath: fixture.dbPath,
          allowedTraceRoots: [fixture.traceRoot],
          searchSnapshot: {
            snapshotDirectory: fixture.searchSnapshotDirectory,
            databasePath: fixture.searchPath,
          },
        }),
        { acceptUnavailableCurrentTracesAsAlreadyLost: true, dropSourceRowIds: [] },
      );
      expect(blocked.status).toBe("blocked");
      expect(blocked.blockers.some((item) => item.location.includes(SMOKE_ID))).toBe(true);

      const result = executeFixture(fixture);
      expect(result.status).toBe("completed");
      expect(result.counts.droppedSmokeSessions).toBe(1);
      const working = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        const ids = (
          working.prepare("SELECT id, session_json FROM session_state_sessions").all() as Array<{
            id: string;
            session_json: string;
          }>
        ).flatMap((row) => [row.id, JSON.parse(row.session_json).id]);
        expect(ids).toEqual([PI_A, PI_A]);
        expect(ids.join(" ")).not.toContain("permission-gate-smoke-escalate");
        expect(ids).not.toContain(SMOKE_ID);
      } finally {
        working.close();
      }
      const search = openReadOnlyDatabase(workingSearchPath(fixture));
      try {
        expect(
          search
            .prepare("SELECT COUNT(*) AS n FROM fts_meta WHERE session_id IN (?, ?)")
            .get(SMOKE_ID, "permission-gate-smoke-escalate") as {
            n: number;
          },
        ).toEqual({ n: 0 });
      } finally {
        search.close();
      }
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("treats unavailable current traces as already-lost files and still rekeys stored Pi UUIDs", () => {
    const fixture = createFixture();
    try {
      const missing = join(fixture.traceRoot, "missing.jsonl");
      insertSession(fixture, {
        id: "wrapper-a",
        piSessionId: PI_A,
        piSessionFile: missing,
        messageCount: 4,
      });
      addSearchRow(fixture, "wrapper-a");
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);

      const withoutAcceptance = executeFixture(fixture, {
        acceptUnavailableCurrentTracesAsAlreadyLost: false,
      });
      expect(withoutAcceptance.status).toBe("blocked");
      expect(withoutAcceptance.blockers).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "unclassified_trace",
            detail: "declared current trace is unavailable",
          }),
        ]),
      );
      expect(existsSync(workingStatePath(fixture))).toBe(false);

      const result = executeFixture(fixture);
      expect(result.status).toBe("completed");
      expect(result.acceptedLosses).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "already_lost_current_trace",
            sourceRowId: "wrapper-a",
          }),
        ]),
      );
      const working = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        const row = working
          .prepare("SELECT id, session_json FROM session_state_sessions")
          .get() as { id: string; session_json: string };
        expect(row.id).toBe(PI_A);
        expect(JSON.parse(row.session_json).id).toBe(PI_A);
        expect(JSON.parse(row.session_json).piSessionFile).toBe(missing);
      } finally {
        working.close();
      }
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("does not invent identities for missing-ID rows and fails closed without an approved planned UUID", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "orphan" });
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const result = executeFixture(fixture);
      expect(result.status).toBe("blocked");
      expect(result.blockers).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "unclassified_session",
            location: "session-row:orphan",
          }),
        ]),
      );

      const planned = executeFixture(fixture, {
        plannedUuidsBySourceRowId: { orphan: PLANNED },
      });
      expect(planned.status).toBe("completed");
      const working = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        expect(
          (working.prepare("SELECT id FROM session_state_sessions").get() as { id: string }).id,
        ).toBe(PLANNED);
      } finally {
        working.close();
      }
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("fails closed on an unclassified target collision", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: PI_A, piSessionId: PI_B });
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const result = executeFixture(fixture);
      expect(result.status).toBe("blocked");
      expect(result.blockers).toEqual(
        expect.arrayContaining([expect.objectContaining({ kind: "target_collision" })]),
      );
      expect(existsSync(workingStatePath(fixture))).toBe(false);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("fails closed on a path that escapes the disposable workspace", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      const escaped = join(fixture.root, "outside-wrapper-a");
      mkdirSync(escaped);
      symlinkSync(escaped, join(fixture.attachmentRoot, "wrapper-a"));
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const result = executeFixture(fixture);
      expect(result.status).toBe("blocked");
      expect(result.blockers).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: "path_escape",
          }),
        ]),
      );
      expect(existsSync(escaped)).toBe(true);
      expect(readdirSync(escaped)).toEqual([]);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("fails closed on an unknown leftover table with session identity", () => {
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
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const result = executeFixture(fixture);
      expect(result.status).toBe("blocked");
      expect(result.blockers).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            location: "sqlite:mystery_session_bits",
          }),
        ]),
      );
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("merges the approved duplicate survivor and discards the other row", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, {
        id: "cGEcSBwD",
        piSessionId: PI_A,
        name: "survivor",
        createdAt: 10,
        lastActivity: 30,
        messageCount: 2,
      });
      insertSession(fixture, {
        id: "aEY7oaE8",
        piSessionId: PI_A,
        name: "discard",
        createdAt: 5,
        lastActivity: 20,
        messageCount: 8,
      });
      addSearchRow(fixture, "cGEcSBwD", "survivor");
      addSearchRow(fixture, "aEY7oaE8", "discard");
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const result = executeFixture(fixture, {
        duplicateDispositions: [
          {
            targetSessionId: PI_A,
            survivorSourceRowId: "cGEcSBwD",
            decisionId: "duplicate-review-2026-08-17-01",
            reasonId: FIELD_AUTHORITY_DUPLICATE_REASON_ID,
          },
        ],
      });
      expect(result.status).toBe("completed");
      expect(result.counts.discardedDuplicateRows).toBe(1);
      const working = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        const rows = working
          .prepare(
            "SELECT id, name, created_at, last_activity, message_count, session_json FROM session_state_sessions",
          )
          .all() as Array<{
          id: string;
          name: string | null;
          created_at: number | null;
          last_activity: number | null;
          message_count: number | null;
          session_json: string;
        }>;
        expect(rows).toHaveLength(1);
        expect(rows[0]?.id).toBe(PI_A);
        expect(rows[0]?.name).toBe("survivor");
        expect(rows[0]?.created_at).toBe(5);
        expect(rows[0]?.last_activity).toBe(30);
        expect(rows[0]?.message_count).toBe(8);
        expect(JSON.parse(rows[0]?.session_json ?? "{}")).toMatchObject({
          id: PI_A,
          name: "survivor",
          createdAt: 5,
          lastActivity: 30,
          messageCount: 8,
        });
      } finally {
        working.close();
      }
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("rolls back a crashed rewrite from the WAL-safe backup", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A, name: "original" });
      addSearchRow(fixture, "wrapper-a");
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      expect(() => executeFixture(fixture, { crashAfter: "rewrite_session_state" })).toThrow(
        /injected crash after rewrite_session_state/,
      );
      const crashed = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        expect(
          (crashed.prepare("SELECT id FROM session_state_sessions").get() as { id: string }).id,
        ).toBe(PI_A);
      } finally {
        crashed.close();
      }
      const rolled = executeFixture(fixture, { rollback: true });
      expect(rolled.status).toBe("rolled_back");
      const restored = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        const row = restored.prepare("SELECT id, name FROM session_state_sessions").get() as {
          id: string;
          name: string;
        };
        expect(row.id).toBe("wrapper-a");
        expect(row.name).toBe("original");
      } finally {
        restored.close();
      }
      const completed = executeFixture(fixture);
      expect(completed.status).toBe("completed");
      expect(completed.alreadyCompleted).toBe(false);
      const working = openReadOnlyDatabase(workingStatePath(fixture));
      try {
        expect(
          (working.prepare("SELECT id FROM session_state_sessions").get() as { id: string }).id,
        ).toBe(PI_A);
      } finally {
        working.close();
      }
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("takes an exclusive workspace lock", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      mkdirSync(fixture.workspaceDirectory, { recursive: true });
      const lockPath = join(fixture.workspaceDirectory, "executor.lock");
      const fd = openSync(
        lockPath,
        constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
        0o600,
      );
      try {
        writeFileSync(lockPath, "held");
        const result = executeFixture(fixture);
        expect(result.status).toBe("blocked");
        expect(result.blockers).toEqual(
          expect.arrayContaining([expect.objectContaining({ kind: "exclusive_lock" })]),
        );
      } finally {
        closeSync(fd);
      }
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("refuses the live Oppi data directory", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      writeFileSync(fixture.listingPath, "[]");
      sealSources(fixture);
      const live = resolve(homedir(), ".config/oppi");
      const result = executeFixture(fixture, { workspaceDirectory: live });
      expect(result.status).toBe("blocked");
      expect(result.blockers).toEqual(
        expect.arrayContaining([expect.objectContaining({ kind: "live_data_path" })]),
      );
      expect(existsSync(join(live, "executor.lock"))).toBe(false);
    } finally {
      cleanupFixture(fixture);
    }
  });

  it("drops leftover dangling uploads and leftover non-session workspace dirs without treating them as path escapes", () => {
    const fixture = createFixture();
    try {
      insertSession(fixture, { id: "wrapper-a", piSessionId: PI_A });
      addUpload(fixture, "up-dead", "ZytRQtDM");
      addUpload(fixture, "up-live", "wrapper-a");
      const leftover = addWorkspaceAttachment(fixture, "xhs");
      const mapped = addWorkspaceAttachment(fixture, "wrapper-a");
      writeFileSync(
        fixture.listingPath,
        JSON.stringify([
          { workspaceId: "ws", sessionId: "wrapper-a", path: mapped },
          { workspaceId: "ws", sessionId: "xhs", path: leftover },
        ]),
      );
      sealSources(fixture);
      const result = executeFixture(fixture);
      expect(result.status).toBe("completed");
      expect(result.acceptedLosses).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: "drop_dangling_upload_for_deleted_session" }),
          expect.objectContaining({ kind: "observe_only_non_session_workspace_path" }),
        ]),
      );
      expect(existsSync(join(fixture.workspaceDirectory, "upload-records", "up-dead.json"))).toBe(
        false,
      );
      const live = JSON.parse(
        readFileSync(join(fixture.workspaceDirectory, "upload-records", "up-live.json"), "utf8"),
      ) as { sessionId: string };
      expect(live.sessionId).toBe(PI_A);
      expect(
        existsSync(join(fixture.workspaceDirectory, "workspace-attachments", "xhs", "note.txt")),
      ).toBe(true);
    } finally {
      cleanupFixture(fixture);
    }
  });
});
