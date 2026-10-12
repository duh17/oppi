import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { AgentScheduleStore } from "../src/agent-schedules.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY } from "../src/storage/session-state-cleanup-migration.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import type { Session } from "../src/types.js";

const DEAD_TABLES = [
  "local_session_files",
  "workspaces",
  "workspace_state_workspaces",
  "workspace_state_schema",
  "review_state_comments",
  "review_state_schema",
  "server_agent_extension_audit_events",
];

const DEAD_INDEXES = [
  "session_state_sessions_workspace_worktree_activity_idx",
  "session_state_sessions_parent_idx",
  "session_state_sessions_launch_schedule_idx",
  "session_state_sessions_status_activity_idx",
  "tui_session_files_cwd_idx",
  "agent_definitions_status_updated_idx",
  "agent_schedules_status_idx",
];

const DEAD_SESSION_COLUMNS = [
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
];

describe("session-state.db dead schema cleanup", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("drops dead objects after a backup and leaves read paths unchanged", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-session-state-cleanup-"));
    dirs.push(dataDir);
    seedLegacySessionState(join(dataDir, "session-state.db"));

    const before = readPathsFromSqlite(join(dataDir, "session-state.db"));
    expect(before.deadTables.sort()).toEqual([...DEAD_TABLES].sort());
    expect(before.deadIndexes.sort()).toEqual([...DEAD_INDEXES].sort());

    let sessions = new SessionSqliteStore(dataDir);
    let schedules = new AgentScheduleStore(dataDir);
    let agents = new AgentDefinitionStore(dataDir);
    try {
      expectReadPaths(sessions, schedules, agents, before);
      expectDropped(join(dataDir, "session-state.db"));
      const backups = listBackups(dataDir);
      expect(backups).toHaveLength(1);
      expect(existsSync(join(dataDir, "backups", backups[0]))).toBe(true);

      const claimed = sessions.claimSessionLaunchRecovery(
        sessions.getSession("sess-launch")!,
        "owner-2",
        10_000,
        1_000,
      );
      expect(claimed?.launch?.status).toBe("launching");
      expect(claimed?.launch?.lease?.owner).toBe("owner-2");
    } finally {
      sessions.close();
      schedules.close();
      agents.close();
    }

    sessions = new SessionSqliteStore(dataDir);
    schedules = new AgentScheduleStore(dataDir);
    agents = new AgentDefinitionStore(dataDir);
    try {
      expect(sessions.getSession("sess-kept")?.name).toBe("Kept");
      expect(sessions.findSessionByLaunchIdempotencyKey("idem-kept")?.id).toBe("sess-kept");
      expect(schedules.getSchedule("sched-1")?.name).toBe("Morning");
      expect(agents.getAgent("agent-1")?.name).toBe("Reviewer");
      expectDropped(join(dataDir, "session-state.db"));
      expect(listBackups(dataDir)).toHaveLength(1);
    } finally {
      sessions.close();
      schedules.close();
      agents.close();
    }
  });
});

function seedLegacySessionState(dbPath: string): void {
  const db = openDatabase(dbPath);
  try {
    db.exec(`
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
        recent_cache_read_at INTEGER,
        recent_cache_write_at INTEGER,
        recent_cache_read_tokens INTEGER,
        recent_cache_write_tokens INTEGER,
        pi_session_id TEXT,
        todo_id TEXT,
        goal_id TEXT,
        agent_id TEXT,
        agent_version INTEGER,
        launch_source TEXT,
        launch_status TEXT,
        launch_lease_owner TEXT,
        launch_lease_until_ms INTEGER,
        parent_session_id TEXT,
        schedule_id TEXT,
        schedule_run_id TEXT,
        launch_idempotency_key TEXT,
        launch_metadata_json TEXT,
        server_durable_json TEXT,
        program_status_json TEXT,
        session_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX session_state_sessions_workspace_activity_idx
        ON session_state_sessions (workspace_id, last_activity DESC, id ASC);
      CREATE INDEX session_state_sessions_workspace_worktree_activity_idx
        ON session_state_sessions (workspace_id, worktree_id, last_activity DESC, id ASC);
      CREATE INDEX session_state_sessions_status_activity_idx
        ON session_state_sessions (status, last_activity DESC, id ASC);
      CREATE INDEX session_state_sessions_parent_idx
        ON session_state_sessions (parent_session_id);
      CREATE INDEX session_state_sessions_launch_schedule_idx
        ON session_state_sessions (schedule_id, schedule_run_id)
        WHERE schedule_id IS NOT NULL;
      CREATE UNIQUE INDEX session_state_sessions_launch_idempotency_idx
        ON session_state_sessions (launch_idempotency_key)
        WHERE launch_idempotency_key IS NOT NULL;

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
        updated_at INTEGER NOT NULL,
        is_subagent INTEGER
      );
      CREATE INDEX tui_session_files_mtime_idx ON tui_session_files (last_modified DESC, path ASC);
      CREATE INDEX tui_session_files_cwd_idx ON tui_session_files (cwd);

      CREATE TABLE agent_definitions (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        version INTEGER NOT NULL DEFAULT 1,
        definition_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        archived_at INTEGER
      );
      CREATE INDEX agent_definitions_status_updated_idx
        ON agent_definitions (status, updated_at DESC);

      CREATE TABLE agent_schedules (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL,
        trigger_json TEXT NOT NULL,
        action_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        archived_at INTEGER
      );
      CREATE INDEX agent_schedules_status_idx ON agent_schedules(status, created_at);

      CREATE TABLE agent_schedule_runs (
        id TEXT PRIMARY KEY,
        schedule_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        slot_key TEXT NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL,
        action_snapshot_json TEXT NOT NULL,
        approval_refs_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        claimed_at INTEGER,
        lease_owner TEXT,
        lease_expires_at INTEGER,
        started_at INTEGER,
        completed_at INTEGER,
        error TEXT,
        result_json TEXT
      );

      CREATE TABLE local_session_files (path TEXT PRIMARY KEY);
      CREATE TABLE workspaces (id TEXT PRIMARY KEY, workspace_json TEXT);
      CREATE TABLE workspace_state_workspaces (id TEXT PRIMARY KEY);
      CREATE TABLE workspace_state_schema (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE review_state_comments (id TEXT PRIMARY KEY);
      CREATE TABLE review_state_schema (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE server_agent_extension_audit_events (id TEXT PRIMARY KEY);

      CREATE TABLE app_state_migrations (
        key TEXT PRIMARY KEY,
        completed_at INTEGER NOT NULL
      );
    `);

    const kept = makeSession({
      id: "sess-kept",
      workspaceId: "ws-1",
      workspaceName: "Workspace",
      name: "Kept",
      status: "stopped",
      lastActivity: 2000,
      piSessionFile: "/tmp/managed.jsonl",
      launch: {
        source: "agent",
        agentId: "agent-1",
        agentVersion: 2,
        parentSessionId: "sess-parent",
        schedule: { scheduleId: "sched-1", runId: "run-1" },
        idempotencyKey: "idem-kept",
        status: "accepted",
        requestedAt: 1000,
      },
    });
    const launching = makeSession({
      id: "sess-launch",
      workspaceId: "ws-1",
      workspaceName: "Workspace",
      name: "Launching",
      status: "starting",
      lastActivity: 3000,
      launch: {
        source: "agent",
        idempotencyKey: "idem-launch",
        status: "launching",
        requestedAt: 1000,
        lease: { owner: "owner-1", acquiredAt: 1000, expiresAt: 5000 },
      },
    });

    insertSession(db, kept, {
      agentId: "agent-1",
      agentVersion: 2,
      launchSource: "agent",
      parentSessionId: "sess-parent",
      scheduleId: "sched-1",
      scheduleRunId: "run-1",
    });
    insertSession(db, launching, {});

    db.exec(`
      INSERT INTO tui_session_files (
        path, pi_session_id, cwd, name, message_count, created_at, last_modified,
        size_bytes, mtime_ms, updated_at, is_subagent
      ) VALUES
        ('/tmp/managed.jsonl', 'other-id', '/tmp', 'Managed by path', 1, 1, 1, 10, 1, 1, 1),
        ('/tmp/managed-by-id.jsonl', 'sess-kept', '/tmp', 'Managed by id', 1, 1, 1, 10, 1, 1, 0),
        ('/tmp/unmanaged.jsonl', 'uuid-tui', '/tmp', 'Unmanaged', 1, 1, 1, 10, 1, 1, 0);

      INSERT INTO agent_definitions (id, name, status, version, definition_json, created_at, updated_at)
      VALUES ('agent-1', 'Reviewer', 'active', 1, '{"name":"Reviewer"}', 1, 1);

      INSERT INTO agent_schedules (id, name, status, trigger_json, action_json, created_at, updated_at)
      VALUES (
        'sched-1',
        'Morning',
        'active',
        '{"type":"at","at":1000,"timeZone":"UTC"}',
        '{"type":"new_session","workspaceId":"ws-1","prompt":"Run checks"}',
        1,
        1
      );

      INSERT INTO agent_schedule_runs (
        id, schedule_id, kind, slot_key, idempotency_key, status,
        action_snapshot_json, approval_refs_json, created_at, updated_at
      ) VALUES (
        'run-1', 'sched-1', 'manual', 'manual:1', 'schedule:sched-1:manual:1', 'pending',
        '{"type":"new_session","workspaceId":"ws-1","prompt":"Run checks"}', '[]', 1, 1
      );

      INSERT INTO local_session_files (path) VALUES ('/tmp/old.jsonl');
      INSERT INTO workspaces (id, workspace_json) VALUES ('ws-1', '{}');
      INSERT INTO workspace_state_workspaces (id) VALUES ('ws-1');
      INSERT INTO workspace_state_schema (key, value) VALUES ('version', '1');
      INSERT INTO review_state_comments (id) VALUES ('c1');
      INSERT INTO review_state_schema (key, value) VALUES ('version', '1');
      INSERT INTO server_agent_extension_audit_events (id) VALUES ('e1');
      INSERT INTO app_state_migrations (key, completed_at) VALUES
        ('sessions_json_import_sqlite_backend_v2:deleted:abc', 1),
        ('keep-me', 1);
    `);
  } finally {
    db.close();
  }
}

function makeSession(
  overrides: Partial<Session> & Pick<Session, "id" | "name" | "status" | "lastActivity">,
): Session {
  return {
    createdAt: 1000,
    messageCount: 1,
    tokens: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4 },
    cost: 0.5,
    runtime: "oppi",
    ...overrides,
  };
}

function insertSession(
  db: ReturnType<typeof openDatabase>,
  session: Session,
  extras: {
    agentId?: string;
    agentVersion?: number;
    launchSource?: string;
    parentSessionId?: string;
    scheduleId?: string;
    scheduleRunId?: string;
  },
): void {
  db.prepare(
    `INSERT INTO session_state_sessions (
       id, workspace_id, workspace_name, worktree_id, name, status, created_at, last_activity,
       message_count, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write, cost,
       runtime, pi_session_file, ephemeral, recent_cache_read_at, pi_session_id, todo_id, goal_id,
       agent_id, agent_version, launch_source, launch_status, launch_lease_owner, launch_lease_until_ms,
       parent_session_id, schedule_id, schedule_run_id, launch_idempotency_key, launch_metadata_json,
       session_json, updated_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, 'fossil', NULL, NULL,
               ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`,
  ).run(
    session.id,
    session.workspaceId ?? null,
    session.workspaceName ?? null,
    session.worktreeId ?? null,
    session.name ?? null,
    session.status,
    session.createdAt,
    session.lastActivity,
    session.messageCount,
    session.tokens.input,
    session.tokens.output,
    session.tokens.cacheRead,
    session.tokens.cacheWrite,
    session.cost,
    session.runtime ?? null,
    session.piSessionFile ?? null,
    extras.agentId ?? null,
    extras.agentVersion ?? null,
    extras.launchSource ?? null,
    session.launch?.status ?? null,
    session.launch?.lease?.owner ?? null,
    session.launch?.lease?.expiresAt ?? null,
    extras.parentSessionId ?? null,
    extras.scheduleId ?? null,
    extras.scheduleRunId ?? null,
    session.launch?.idempotencyKey ?? null,
    session.launch ? JSON.stringify(session.launch) : null,
    JSON.stringify(session),
  );
}

function readPathsFromSqlite(dbPath: string): BeforeSnapshot {
  const db = openDatabase(dbPath);
  try {
    const sessionRows = db
      .prepare("SELECT id, session_json FROM session_state_sessions ORDER BY id")
      .all() as Array<{ id: string; session_json: string }>;
    const sessions = sessionRows.map((row) => JSON.parse(row.session_json) as Session);
    const workspaceIds = db
      .prepare(
        "SELECT id FROM session_state_sessions WHERE workspace_id = 'ws-1' ORDER BY last_activity DESC, id ASC",
      )
      .all() as Array<{ id: string }>;
    const tui = db.prepare("SELECT path FROM tui_session_files ORDER BY path").all() as Array<{
      path: string;
    }>;
    const tables = (
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    const indexes = (
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'index'").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    return {
      sessions,
      workspaceSessionIds: workspaceIds.map((row) => row.id),
      tuiPaths: tui.map((row) => row.path),
      deadTables: tables.filter((name) => DEAD_TABLES.includes(name)),
      deadIndexes: indexes.filter((name) => DEAD_INDEXES.includes(name)),
      scheduleName: (
        db.prepare("SELECT name FROM agent_schedules WHERE id = 'sched-1'").get() as {
          name: string;
        }
      ).name,
      agentName: (
        db.prepare("SELECT name FROM agent_definitions WHERE id = 'agent-1'").get() as {
          name: string;
        }
      ).name,
    };
  } finally {
    db.close();
  }
}

function expectReadPaths(
  sessions: SessionSqliteStore,
  schedules: AgentScheduleStore,
  agents: AgentDefinitionStore,
  before: BeforeSnapshot,
): void {
  expect(
    sessions
      .listSessions()
      .map((session) => session.id)
      .sort(),
  ).toEqual(before.sessions.map((session) => session.id).sort());
  for (const session of before.sessions) {
    expect(sessions.getSession(session.id)).toMatchObject({
      id: session.id,
      name: session.name,
      status: session.status,
      lastActivity: session.lastActivity,
      launch: session.launch,
    });
  }
  expect(sessions.findSessionByLaunchIdempotencyKey("idem-kept")?.id).toBe("sess-kept");
  expect(sessions.listAllWorkspaceSessionSnapshots("ws-1").map((session) => session.id)).toEqual(
    before.workspaceSessionIds,
  );
  expect(schedules.getSchedule("sched-1")?.name).toBe(before.scheduleName);
  expect(agents.getAgent("agent-1")?.name).toBe(before.agentName);
}

function expectDropped(dbPath: string): void {
  const db = openDatabase(dbPath);
  try {
    const tables = new Set(
      (
        db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{
          name: string;
        }>
      ).map((row) => row.name),
    );
    const indexes = new Set(
      (
        db.prepare("SELECT name FROM sqlite_master WHERE type = 'index'").all() as Array<{
          name: string;
        }>
      ).map((row) => row.name),
    );
    for (const name of DEAD_TABLES) {
      expect(tables.has(name)).toBe(false);
    }
    for (const name of DEAD_INDEXES) {
      expect(indexes.has(name)).toBe(false);
    }
    const sessionColumns = new Set(
      (
        db.prepare("PRAGMA table_info(session_state_sessions)").all() as Array<{ name: string }>
      ).map((row) => row.name),
    );
    for (const column of DEAD_SESSION_COLUMNS) {
      expect(sessionColumns.has(column)).toBe(false);
    }
    expect(sessionColumns.has("session_json")).toBe(true);
    expect(sessionColumns.has("launch_idempotency_key")).toBe(true);
    expect(sessionColumns.has("launch_status")).toBe(true);
    const tuiColumns = new Set(
      (db.prepare("PRAGMA table_info(tui_session_files)").all() as Array<{ name: string }>).map(
        (row) => row.name,
      ),
    );
    expect(tuiColumns.has("is_subagent")).toBe(false);
    const runColumns = new Set(
      (db.prepare("PRAGMA table_info(agent_schedule_runs)").all() as Array<{ name: string }>).map(
        (row) => row.name,
      ),
    );
    expect(runColumns.has("approval_refs_json")).toBe(false);
    const tuiPaths = (
      db.prepare("SELECT path FROM tui_session_files ORDER BY path").all() as Array<{
        path: string;
      }>
    ).map((row) => row.path);
    expect(tuiPaths).toEqual(["/tmp/unmanaged.jsonl"]);
    const tombstones = db
      .prepare(
        "SELECT key FROM app_state_migrations WHERE key LIKE 'sessions_json_import_sqlite_backend_v2:%'",
      )
      .all();
    expect(tombstones).toEqual([]);
    expect(
      db
        .prepare("SELECT key FROM app_state_migrations WHERE key = ?")
        .get(SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY),
    ).toEqual({ key: SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY });
    expect(db.prepare("SELECT key FROM app_state_migrations WHERE key = 'keep-me'").get()).toEqual({
      key: "keep-me",
    });
  } finally {
    db.close();
  }
}

function listBackups(dataDir: string): string[] {
  const backupDir = join(dataDir, "backups");
  if (!existsSync(backupDir)) return [];
  return readdirSync(backupDir).filter((name) =>
    name.startsWith(`session-state-pre-${SESSION_STATE_DEAD_SCHEMA_CLEANUP_MIGRATION_KEY}-`),
  );
}

interface BeforeSnapshot {
  sessions: Session[];
  workspaceSessionIds: string[];
  tuiPaths: string[];
  deadTables: string[];
  deadIndexes: string[];
  scheduleName: string;
  agentName: string;
}
