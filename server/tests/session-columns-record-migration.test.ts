import { randomBytes } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { openDatabase } from "../src/sqlite-compat.js";
import { SESSION_COLUMNS_RECORD_MIGRATION_KEY } from "../src/storage/session-columns-record-migration.js";
import { SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY } from "../src/storage/session-state-cleanup-migration.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import type { Session } from "../src/types.js";

const DROPPED_COLUMNS = [
  "session_json",
  "server_durable_json",
  "workspace_name",
  "model",
  "thinking_level",
  "message_count",
  "tokens_input",
  "tokens_output",
  "tokens_cache_read",
  "tokens_cache_write",
  "cost",
  "first_message",
  "last_message",
  "context_tokens",
  "context_window",
  "last_agent_reply_at",
  "change_stats_json",
];

const CONTROL_SESSION: Session = {
  id: "sess-control",
  name: "Revise Sensei",
  status: "stopped",
  createdAt: 1_000,
  lastActivity: 5_000,
  model: "anthropic/claude",
  messageCount: 3,
  tokens: { input: 10, output: 20, cacheRead: 30, cacheWrite: 40 },
  cost: 0.5,
  contextTokens: 100,
  runtime: "oppi",
  serverDurable: { storeId: "store-control", conversationId: 9, role: "control" },
  control: { domain: "agents", intent: "revise", targetId: "agent-1", targetName: "Sensei" },
};

const DURABLE_SESSION: Session = {
  id: "sess-durable",
  workspaceId: "ws-1",
  workspaceName: "Old name",
  worktreeId: "wt-1",
  name: "Durable",
  status: "stopped",
  createdAt: 1_000,
  lastActivity: 4_000,
  lastAgentReplyAt: 3_900,
  programStatus: { state: "done", since: 3_900 },
  model: "openai/gpt-5",
  thinkingLevel: "high",
  messageCount: 12,
  tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
  cost: 0.25,
  changeStats: {
    mutatingToolCalls: 2,
    filesChanged: 1,
    changedFiles: ["src/a.ts"],
    addedLines: 5,
    removedLines: 1,
    _fileLineCounts: { "src/a.ts": 42 },
    _sessionCreatedFiles: ["src/a.ts"],
  },
  contextTokens: 900,
  contextWindow: 200_000,
  firstMessage: "first",
  lastMessage: "last",
  warnings: ["Spawn failed once"],
  runtime: "oppi",
  piSessionFiles: ["/tmp/a.jsonl"],
  piSessionFile: "/tmp/a.jsonl",
  serverDurable: { storeId: "store-1", conversationId: 3 },
  launch: {
    source: "agent",
    agentId: "agent-1",
    agentIcon: { kind: "symbol", name: "sparkles" },
    idempotencyKey: "idem-durable",
    status: "accepted",
    requestedAt: 1_000,
  },
};

const CLASSIC_SESSION: Session = {
  id: "sess-classic",
  workspaceId: "ws-1",
  workspaceName: "Old name",
  status: "stopped",
  createdAt: 1_000,
  lastActivity: 3_000,
  messageCount: 0,
  tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  cost: 0,
  runtime: "pi-tui",
  mirror: { status: "disconnected" } as Session["mirror"],
};

const LEGACY_SESSIONS = [CONTROL_SESSION, DURABLE_SESSION, CLASSIC_SESSION];

// Lets a test force the backup filename another process already took.
vi.mock("node:crypto", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:crypto")>();
  return { ...actual, randomBytes: vi.fn(actual.randomBytes) };
});

describe("session_state_sessions columns-only migration", () => {
  const dirs: string[] = [];

  afterEach(() => {
    vi.restoreAllMocks();
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  function legacyDataDir(
    schema = PREVIOUS_RELEASE_SCHEMA,
    sessions: readonly Session[] = LEGACY_SESSIONS,
  ): string {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-columns-record-"));
    dirs.push(dataDir);
    seedLegacySessions(join(dataDir, "session-state.db"), schema, sessions);
    return dataDir;
  }

  it("upgrades the table oppi-server 0.51.0 wrote, which has no program_status_json", () => {
    // 0.51.0 predates program status; its session_json never carried one.
    const sessions = LEGACY_SESSIONS.map((session) => ({ ...session, programStatus: undefined }));
    const dataDir = legacyDataDir(OPPI_SERVER_0_51_0_SCHEMA, sessions);

    const store = new SessionSqliteStore(dataDir);
    try {
      for (const legacy of sessions) {
        expect(store.getSession(legacy.id)).toEqual(expectedAfterMigration(legacy));
      }
      expect(store.findSessionByDurableConversation("store-1", 3)?.id).toBe("sess-durable");
      expect(store.findSessionByDurableConversation("store-control", 9)?.control).toEqual(
        CONTROL_SESSION.control,
      );
      expect(store.findSessionByLaunchIdempotencyKey("idem-durable")?.id).toBe("sess-durable");
    } finally {
      store.close();
    }

    const migrated = readShape(join(dataDir, "session-state.db"));
    expect(migrated.completedAt).toBeTypeOf("number");
    expect(migrated.columns).toContain("program_status_json");
    for (const column of [...DROPPED_COLUMNS, "agent_id", "schedule_id", "updated_at"]) {
      expect(migrated.columns).not.toContain(column);
    }
  });

  it("keeps every session, its control metadata, binding, and stats; a second open is a no-op", () => {
    const dataDir = legacyDataDir();

    let store = new SessionSqliteStore(dataDir);
    try {
      for (const legacy of LEGACY_SESSIONS) {
        expect(store.getSession(legacy.id)).toEqual(expectedAfterMigration(legacy));
      }
      expect(store.listSessions().map((session) => session.id)).toEqual([
        "sess-control",
        "sess-durable",
        "sess-classic",
      ]);
      expect(store.listAllWorkspaceSessionSnapshots("ws-1").map((session) => session.id)).toEqual([
        "sess-durable",
        "sess-classic",
      ]);
      expect(store.findSessionByDurableConversation("store-1", 3)?.id).toBe("sess-durable");
      expect(store.findSessionByDurableConversation("store-control", 9)?.control).toEqual(
        CONTROL_SESSION.control,
      );
      expect(store.findSessionByLaunchIdempotencyKey("idem-durable")?.id).toBe("sess-durable");
    } finally {
      store.close();
    }

    const migrated = readShape(join(dataDir, "session-state.db"));
    for (const column of DROPPED_COLUMNS) {
      expect(migrated.columns).not.toContain(column);
    }
    expect(migrated.columns).toEqual(
      expect.arrayContaining([
        "control_json",
        "summary_json",
        "durable_store_id",
        "durable_conversation_id",
        "durable_role",
      ]),
    );
    expect(migrated.indexes).toContain("session_state_sessions_durable_idx");
    // Change-stat bookkeeping survives in the cache so later writes keep computing deltas.
    expect(JSON.parse(migrated.summaries.get("sess-durable") ?? "{}").changeStats).toEqual(
      DURABLE_SESSION.changeStats,
    );
    expect(migrated.completedAt).toBeTypeOf("number");
    expect(listBackups(dataDir)).toHaveLength(1);

    store = new SessionSqliteStore(dataDir);
    try {
      for (const legacy of LEGACY_SESSIONS) {
        expect(store.getSession(legacy.id)).toEqual(expectedAfterMigration(legacy));
      }
    } finally {
      store.close();
    }
    const reopened = readShape(join(dataDir, "session-state.db"));
    expect(reopened.completedAt).toBe(migrated.completedAt);
    expect(reopened.columns).toEqual(migrated.columns);
    expect(listBackups(dataDir)).toHaveLength(1);
  });

  it("rolls back to the old table when the migration fails inside its transaction", () => {
    const dataDir = legacyDataDir();
    const dbPath = join(dataDir, "session-state.db");
    const db = openDatabase(dbPath);
    try {
      // Fires on the ledger write, the last statement of the transaction: after the copy,
      // the DROP, and the RENAME.
      db.exec(`
        CREATE TRIGGER fail_columns_record BEFORE INSERT ON app_state_migrations
        WHEN NEW.key = '${SESSION_COLUMNS_RECORD_MIGRATION_KEY}'
        BEGIN SELECT RAISE(ABORT, 'injected migration failure'); END;
      `);
    } finally {
      db.close();
    }

    expect(() => new SessionSqliteStore(dataDir)).toThrow(/injected migration failure/);
    // The file is unchanged, so the backup taken for this attempt is gone too.
    expect(listBackups(dataDir)).toEqual([]);

    const failed = readShape(dbPath);
    expect(failed.columns).toEqual(expect.arrayContaining(DROPPED_COLUMNS));
    expect(failed.tables).not.toContain("session_state_sessions_next");
    expect(failed.completedAt).toBeUndefined();
    expect(failed.legacySessions).toEqual(new Map(LEGACY_SESSIONS.map((s) => [s.id, s])));

    const repair = openDatabase(dbPath);
    try {
      repair.exec("DROP TRIGGER fail_columns_record");
    } finally {
      repair.close();
    }
    const store = new SessionSqliteStore(dataDir);
    try {
      expect(store.getSession("sess-control")?.control).toEqual(CONTROL_SESSION.control);
    } finally {
      store.close();
    }
  });

  it.each([
    { name: "malformed durable binding", column: "server_durable_json", value: '{"storeId":' },
    {
      name: "non-integer conversation id",
      column: "server_durable_json",
      value: '{"storeId":"store-1","conversationId":"3"}',
    },
    { name: "malformed session JSON", column: "session_json", value: "{not-json" },
  ])("rolls back instead of dropping a $name", ({ column, value }) => {
    const dataDir = legacyDataDir();
    const dbPath = join(dataDir, "session-state.db");
    const db = openDatabase(dbPath);
    try {
      db.prepare(`UPDATE session_state_sessions SET ${column} = ? WHERE id = 'sess-durable'`).run(
        value,
      );
    } finally {
      db.close();
    }

    expect(() => new SessionSqliteStore(dataDir)).toThrow(/sess-durable/);

    const unchanged = readShape(dbPath);
    expect(unchanged.columns).toEqual(expect.arrayContaining(DROPPED_COLUMNS));
    expect(unchanged.completedAt).toBeUndefined();
    const raw = openDatabase(dbPath);
    try {
      expect(
        raw
          .prepare(
            `SELECT ${column} AS value FROM session_state_sessions WHERE id = 'sess-durable'`,
          )
          .get(),
      ).toEqual({ value });
      expect(raw.prepare("SELECT COUNT(*) AS count FROM session_state_sessions").get()).toEqual({
        count: LEGACY_SESSIONS.length,
      });
    } finally {
      raw.close();
    }
  });

  it("refuses to migrate when the backup cannot be written", () => {
    const dataDir = legacyDataDir();
    // A file where the backup directory belongs makes the backup fail.
    writeFileSync(join(dataDir, "backups"), "not a directory");

    expect(() => new SessionSqliteStore(dataDir)).toThrow(/refusing to migrate/);

    const unchanged = readShape(join(dataDir, "session-state.db"));
    expect(unchanged.columns).toEqual(expect.arrayContaining(DROPPED_COLUMNS));
    expect(unchanged.completedAt).toBeUndefined();
    expect(unchanged.legacySessions).toEqual(new Map(LEGACY_SESSIONS.map((s) => [s.id, s])));
  });

  it("leaves another process's backup in place when its backup path is already taken", () => {
    const dataDir = legacyDataDir();
    // Two starts in the same millisecond with the same suffix pick the same path; the first
    // already wrote its backup there and may go on to commit the irreversible rebuild.
    vi.spyOn(Date, "now").mockReturnValue(1_700_000_000_000);
    vi.mocked(randomBytes).mockImplementation(() => Buffer.alloc(4));
    const taken = join(
      dataDir,
      "backups",
      `session-state-pre-${SESSION_COLUMNS_RECORD_MIGRATION_KEY}-1700000000000-00000000.db`,
    );
    mkdirSync(join(dataDir, "backups"), { mode: 0o700 });
    writeFileSync(taken, "the other process's backup");

    expect(() => new SessionSqliteStore(dataDir)).toThrow(/refusing to migrate/);

    expect(readFileSync(taken, "utf8")).toBe("the other process's backup");
    // Nor does this attempt leave its own copy behind.
    expect(readdirSync(join(dataDir, "backups"))).toEqual([basename(taken)]);
    const unchanged = readShape(join(dataDir, "session-state.db"));
    expect(unchanged.columns).toEqual(expect.arrayContaining(DROPPED_COLUMNS));
    expect(unchanged.completedAt).toBeUndefined();
  });
});

/** What a full read returned before, minus the stored workspace name and change-stat bookkeeping. */
function expectedAfterMigration(legacy: Session): Session {
  const { workspaceName: _, ...session } = legacy;
  if (!session.changeStats) return session;
  const { _fileLineCounts: __, _sessionCreatedFiles: ___, ...changeStats } = session.changeStats;
  return { ...session, changeStats };
}

/** The table as the previous server wrote it, after the dead-schema cleanup. */
const PREVIOUS_RELEASE_SCHEMA = `
      CREATE TABLE session_state_sessions (
        id TEXT PRIMARY KEY,
        workspace_id TEXT,
        workspace_name TEXT,
        worktree_id TEXT,
        name TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_activity INTEGER NOT NULL,
        last_agent_reply_at INTEGER,
        current_turn_started_at INTEGER,
        model TEXT,
        message_count INTEGER NOT NULL,
        tokens_input INTEGER NOT NULL,
        tokens_output INTEGER NOT NULL,
        tokens_cache_read INTEGER NOT NULL,
        tokens_cache_write INTEGER NOT NULL,
        cost REAL NOT NULL,
        change_stats_json TEXT,
        context_tokens INTEGER,
        context_window INTEGER,
        first_message TEXT,
        last_message TEXT,
        warnings_json TEXT,
        thinking_level TEXT,
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
        server_durable_json TEXT,
        program_status_json TEXT,
        session_json TEXT NOT NULL
      );
      CREATE INDEX session_state_sessions_workspace_activity_idx
        ON session_state_sessions (workspace_id, last_activity DESC, id ASC);
      CREATE UNIQUE INDEX session_state_sessions_launch_idempotency_idx
        ON session_state_sessions (launch_idempotency_key)
        WHERE launch_idempotency_key IS NOT NULL;
      CREATE TABLE app_state_migrations (key TEXT PRIMARY KEY, completed_at INTEGER NOT NULL);
      INSERT INTO app_state_migrations (key, completed_at)
        VALUES ('${SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY}', 1);
`;

/**
 * The table and indexes published oppi-server 0.51.0 (`b747bb59c`) created: before the
 * dead-schema cleanup, and before `program_status_json` existed.
 */
const OPPI_SERVER_0_51_0_SCHEMA = `
      CREATE TABLE session_state_sessions (
        id TEXT PRIMARY KEY,
        workspace_id TEXT,
        workspace_name TEXT,
        worktree_id TEXT,
        name TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_activity INTEGER NOT NULL,
        last_agent_reply_at INTEGER,
        current_turn_started_at INTEGER,
        model TEXT,
        message_count INTEGER NOT NULL,
        tokens_input INTEGER NOT NULL,
        tokens_output INTEGER NOT NULL,
        tokens_cache_read INTEGER NOT NULL,
        tokens_cache_write INTEGER NOT NULL,
        cost REAL NOT NULL,
        change_stats_json TEXT,
        context_tokens INTEGER,
        context_window INTEGER,
        first_message TEXT,
        last_message TEXT,
        warnings_json TEXT,
        thinking_level TEXT,
        runtime TEXT,
        mirror_json TEXT,
        pi_session_file TEXT,
        pi_session_files_json TEXT,
        ephemeral INTEGER NOT NULL DEFAULT 0,
        agent_id TEXT,
        agent_version INTEGER,
        launch_source TEXT,
        launch_status TEXT,
        launch_lease_owner TEXT,
        launch_lease_until_ms INTEGER,
        parent_session_id TEXT,
        todo_id TEXT,
        goal_id TEXT,
        schedule_id TEXT,
        schedule_run_id TEXT,
        launch_idempotency_key TEXT,
        launch_metadata_json TEXT,
        server_durable_json TEXT,
        session_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX session_state_sessions_workspace_activity_idx
        ON session_state_sessions (workspace_id, last_activity DESC, id ASC);
      CREATE INDEX session_state_sessions_workspace_worktree_activity_idx
        ON session_state_sessions (workspace_id, worktree_id, last_activity DESC, id ASC);
      CREATE INDEX session_state_sessions_status_activity_idx
        ON session_state_sessions (status, last_activity DESC, id ASC);
      CREATE UNIQUE INDEX session_state_sessions_launch_idempotency_idx
        ON session_state_sessions (launch_idempotency_key)
        WHERE launch_idempotency_key IS NOT NULL;
      CREATE INDEX session_state_sessions_launch_schedule_idx
        ON session_state_sessions (schedule_id, schedule_run_id)
        WHERE schedule_id IS NOT NULL;
      CREATE TABLE app_state_migrations (key TEXT PRIMARY KEY, completed_at INTEGER NOT NULL);
`;

/** Writes `sessions` into `schema`, setting only the columns that schema has. */
function seedLegacySessions(dbPath: string, schema: string, sessions: readonly Session[]): void {
  const db = openDatabase(dbPath);
  try {
    db.exec(schema);
    const columns = new Set(
      (
        db.prepare("PRAGMA table_info(session_state_sessions)").all() as Array<{ name: string }>
      ).map((row) => row.name),
    );
    const json = (value: unknown): string | null =>
      value === undefined ? null : JSON.stringify(value);
    for (const s of sessions) {
      const row = Object.entries({
        id: s.id,
        workspace_id: s.workspaceId ?? null,
        workspace_name: s.workspaceName ?? null,
        worktree_id: s.worktreeId ?? null,
        name: s.name ?? null,
        status: s.status,
        created_at: s.createdAt,
        last_activity: s.lastActivity,
        last_agent_reply_at: s.lastAgentReplyAt ?? null,
        current_turn_started_at: s.currentTurnStartedAt ?? null,
        model: s.model ?? null,
        message_count: s.messageCount,
        tokens_input: s.tokens.input,
        tokens_output: s.tokens.output,
        tokens_cache_read: s.tokens.cacheRead,
        tokens_cache_write: s.tokens.cacheWrite,
        cost: s.cost,
        change_stats_json: json(s.changeStats),
        context_tokens: s.contextTokens ?? null,
        context_window: s.contextWindow ?? null,
        first_message: s.firstMessage ?? null,
        last_message: s.lastMessage ?? null,
        warnings_json: json(s.warnings),
        thinking_level: s.thinkingLevel ?? null,
        runtime: s.runtime ?? null,
        mirror_json: json(s.mirror),
        pi_session_file: s.piSessionFile ?? null,
        pi_session_files_json: json(s.piSessionFiles),
        ephemeral: s.ephemeral ? 1 : 0,
        agent_id: s.launch?.agentId ?? null,
        launch_source: s.launch?.source ?? null,
        launch_status: s.launch?.status ?? null,
        launch_lease_owner: s.launch?.lease?.owner ?? null,
        launch_lease_until_ms: s.launch?.lease?.expiresAt ?? null,
        launch_idempotency_key: s.launch?.idempotencyKey ?? null,
        launch_metadata_json: json(s.launch),
        server_durable_json: json(s.serverDurable),
        program_status_json: json(s.programStatus),
        session_json: JSON.stringify(s),
        updated_at: s.lastActivity,
      }).filter(([column]) => columns.has(column));
      db.prepare(
        `INSERT INTO session_state_sessions (${row.map(([column]) => column).join(", ")})
         VALUES (${row.map(() => "?").join(", ")})`,
      ).run(...row.map(([, value]) => value));
    }
  } finally {
    db.close();
  }
}

function readShape(dbPath: string): {
  tables: string[];
  columns: string[];
  indexes: string[];
  completedAt: number | undefined;
  summaries: Map<string, string>;
  legacySessions: Map<string, Session>;
} {
  const db = openDatabase(dbPath);
  try {
    const names = (type: string): string[] =>
      (
        db.prepare("SELECT name FROM sqlite_master WHERE type = ?").all(type) as Array<{
          name: string;
        }>
      ).map((row) => row.name);
    const columns = (
      db.prepare("PRAGMA table_info(session_state_sessions)").all() as Array<{ name: string }>
    ).map((row) => row.name);
    const completed = db
      .prepare("SELECT completed_at FROM app_state_migrations WHERE key = ?")
      .get(SESSION_COLUMNS_RECORD_MIGRATION_KEY) as { completed_at: number } | undefined;
    const summaries = new Map<string, string>();
    const legacySessions = new Map<string, Session>();
    if (columns.includes("summary_json")) {
      for (const row of db
        .prepare("SELECT id, summary_json FROM session_state_sessions")
        .all() as Array<{ id: string; summary_json: string }>) {
        summaries.set(row.id, row.summary_json);
      }
    }
    if (columns.includes("session_json")) {
      for (const row of db
        .prepare(
          "SELECT id, session_json FROM session_state_sessions WHERE json_valid(session_json)",
        )
        .all() as Array<{ id: string; session_json: string }>) {
        legacySessions.set(row.id, JSON.parse(row.session_json) as Session);
      }
    }
    return {
      tables: names("table"),
      columns,
      indexes: names("index"),
      completedAt: completed?.completed_at,
      summaries,
      legacySessions,
    };
  } finally {
    db.close();
  }
}

function listBackups(dataDir: string): string[] {
  const backupDir = join(dataDir, "backups");
  if (!existsSync(backupDir)) return [];
  return readdirSync(backupDir).filter((name) =>
    name.startsWith(`session-state-pre-${SESSION_COLUMNS_RECORD_MIGRATION_KEY}-`),
  );
}
