import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

import {
  ResourceUsageStore,
  type ResourceUsageEvent,
  type ResourceUsageStoreMigrationFaultPhase,
} from "../src/storage/resource-usage-store.js";
import {
  aggregateResourceUsage,
  resourceUsageActionId,
  resourceUsageRuntimeActionAliases,
} from "../src/resource-usage-service.js";
import { createSandboxSkillBindingToken } from "../src/sandbox-resource-paths.js";
import { openDatabase } from "../src/sqlite-compat.js";

const dirs: string[] = [];

function makeStore(nowMs = Date.UTC(2026, 6, 27, 12)): ResourceUsageStore {
  const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-store-"));
  dirs.push(dir);
  return new ResourceUsageStore(dir, { now: () => nowMs });
}

function event(overrides: Partial<ResourceUsageEvent> = {}): ResourceUsageEvent {
  return {
    actionId: "action-1",
    occurredAt: Date.UTC(2026, 6, 27, 10),
    signal: "tool_invocation",
    sessionId: "session-1",
    workspaceId: "workspace-opaque-1",
    runtime: "oppi",
    ownerKind: "builtin",
    ownerId: "builtin",
    itemName: "read",
    ...overrides,
  };
}

function createPathBearingBindingDatabase(
  dir: string,
  options: { contaminateMetadata?: boolean } = {},
): { dbPath: string; forbiddenPath: string } {
  const dbPath = join(dir, "resource-usage.db");
  const initial = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
  initial.close();
  const prior = openDatabase(dbPath);
  prior.exec(`
    DROP TABLE resource_usage_backfill_skill_bindings;
    CREATE TABLE resource_usage_backfill_skill_bindings (
      source_key TEXT NOT NULL,
      session_id TEXT NOT NULL,
      workspace_id TEXT,
      guest_locator TEXT NOT NULL,
      skill_id TEXT NOT NULL,
      skill_name TEXT NOT NULL,
      ambiguous INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(source_key, guest_locator)
    );
  `);
  const forbiddenPath = "/workspace/private/NEEDLE/.pi/skills/testing/SKILL.md";
  const insert = prior.prepare(
    `INSERT INTO resource_usage_backfill_skill_bindings
       (source_key, session_id, workspace_id, guest_locator, skill_id, skill_name, ambiguous)
     VALUES (?, 'session-old', 'workspace-old', ?, 'skill_testing', 'testing', 0)`,
  );
  const transaction = prior.transaction(() => {
    for (let index = 0; index < 20_000; index += 1) {
      insert.run(
        `source-${index}`,
        index === 12_345
          ? forbiddenPath
          : `/workspace/private/${index}/.pi/skills/testing/SKILL.md`,
      );
    }
  });
  transaction();
  if (options.contaminateMetadata) {
    prior.exec(`
      ALTER TABLE resource_usage_metadata ADD COLUMN source_path TEXT;
      UPDATE resource_usage_metadata
      SET source_path = '/workspace/private/metadata/trace.jsonl';
    `);
  }
  prior.close();
  return { dbPath, forbiddenPath };
}

function physicalSqliteBytesContain(dbPath: string, value: string): boolean {
  return [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]
    .filter(existsSync)
    .some((path) => readFileSync(path).includes(Buffer.from(value)));
}

function physicalScrubState(dbPath: string): string | undefined {
  const db = openDatabase(dbPath);
  try {
    const row = db
      .prepare(
        `SELECT state FROM resource_usage_privacy_state
         WHERE state_key = 'physical_scrub_v1'`,
      )
      .get() as { state?: string } | undefined;
    return row?.state;
  } finally {
    db.close();
  }
}

function expectPathFreeResourceUsageDatabase(
  db: ReturnType<typeof openDatabase>,
  forbiddenValues: readonly string[] = [],
): void {
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'")
    .all() as Array<{ name: string }>;
  for (const { name } of tables) {
    const columns = (db.prepare(`PRAGMA table_info(${name})`).all() as Array<{ name: string }>).map(
      (row) => row.name,
    );
    expect(columns.filter((column) => /(^|_)(path|file|cwd|locator)($|_)/i.test(column))).toEqual(
      [],
    );
    const persisted = JSON.stringify(db.prepare(`SELECT * FROM ${name}`).all());
    for (const forbidden of forbiddenValues) expect(persisted).not.toContain(forbidden);
    expect(persisted).not.toMatch(/\/(?:Users|workspace|private|tmp)\//);
    expect(persisted).not.toMatch(/[A-Za-z]:\\/);
    expect(persisted).not.toContain("file://");
  }
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("ResourceUsageStore", () => {
  it("deduplicates a replayed exact live action without rewriting it", () => {
    const store = makeStore();
    store.recordBatch([
      event({ provider: "anthropic", model: "sonnet", manifestRevision: "manifest-1" }),
    ]);
    store.recordBatch([
      event({ itemName: "wrong", provider: "openai", model: "wrong", manifestRevision: "wrong" }),
    ]);

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([
      expect.objectContaining({
        actionId: "action-1",
        itemName: "read",
        provider: "anthropic",
        model: "sonnet",
        manifestRevision: "manifest-1",
      }),
    ]);
    store.close();
  });

  it("keeps same-named tools separated by semantic owner", () => {
    const store = makeStore();
    store.recordBatch([
      event({ actionId: "a", ownerKind: "extension", ownerId: "extension_a" }),
      event({ actionId: "b", ownerKind: "extension", ownerId: "extension_b" }),
    ]);

    expect(
      store.queryEvents({
        subject: { kind: "extension", id: "extension_a" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toHaveLength(1);
    expect(
      store.queryEvents({
        subject: { kind: "extension", id: "extension_b" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toHaveLength(1);
    store.close();
  });

  it("returns only tool invocations for global Tool Activity", () => {
    const store = makeStore();
    store.recordBatch([
      event({ actionId: "tool" }),
      event({
        actionId: "command",
        signal: "command_invocation",
        ownerKind: "extension",
        ownerId: "extension_a",
        itemName: "review",
      }),
    ]);

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([expect.objectContaining({ actionId: "tool", signal: "tool_invocation" })]);
    store.close();
  });

  it("enforces 120-day retention and supports ordinary session and workspace deletion", () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const store = makeStore(now);
    store.recordBatch([
      event({ actionId: "expired", occurredAt: now - 121 * 86_400_000 }),
      event({ actionId: "session", occurredAt: now - 119 * 86_400_000 }),
      event({ actionId: "workspace", sessionId: "session-2" }),
      event({
        actionId: "other",
        sessionId: "session-3",
        workspaceId: "workspace-opaque-2",
      }),
    ]);

    expect(store.deleteSession("session-1")).toBe(1);
    expect(store.deleteWorkspace("workspace-opaque-1")).toBe(1);
    expect(store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: now })).toEqual([
      expect.objectContaining({ actionId: "other" }),
    ]);
    store.close();
  });

  it("fails closed under SQLite contention without unbounded retry behavior", () => {
    const store = makeStore();
    const db = openDatabase(join(dirs.at(-1)!, "resource-usage.db"));
    db.exec("BEGIN IMMEDIATE");
    expect(() => store.recordBatch([event({ actionId: "contended" })])).toThrow();
    db.exec("ROLLBACK");
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([]);
    db.close();
    store.close();
  });

  it("generates random binding tokens that resist workspace and Skill-name dictionaries", () => {
    const first = createSandboxSkillBindingToken();
    const second = createSandboxSkillBindingToken();
    expect(first).toMatch(/^sandbox-binding-v1_[a-f0-9]{64}$/);
    expect(second).toMatch(/^sandbox-binding-v1_[a-f0-9]{64}$/);
    expect(second).not.toBe(first);

    const dictionary = [
      "private-project",
      "testing",
      "/workspace/private-project/.pi/skills/testing/SKILL.md",
      JSON.stringify(["source-1", "session-1", "private-project", "testing"]),
    ];
    expect(
      dictionary.map((value) => createHash("sha256").update(value).digest("hex")),
    ).not.toContain(first.slice("sandbox-binding-v1_".length));
  });

  it("persists only random sandbox binding tokens and omits colliding tokens", () => {
    const store = makeStore();
    const testingToken = `sandbox-binding-v1_${"a".repeat(64)}`;
    const writingToken = `sandbox-binding-v1_${"b".repeat(64)}`;
    store.mergeBackfillSkillBindings({
      sourceKey: "source-1",
      sessionId: "session-1",
      workspaceId: "workspace-opaque-1",
      bindings: [
        {
          bindingToken: testingToken,
          skillId: "skill_testing",
          skillName: "testing",
        },
        {
          bindingToken: testingToken,
          skillId: "skill_replacement",
          skillName: "replacement",
        },
        {
          bindingToken: writingToken,
          skillId: "skill_writing",
          skillName: "writing",
        },
      ],
    });

    expect([...store.getBackfillSkillBindings("source-1")]).toEqual([
      [writingToken, { id: "skill_writing", name: "writing" }],
    ]);
    const db = openDatabase(join(dirs.at(-1)!, "resource-usage.db"));
    expectPathFreeResourceUsageDatabase(db);
    const persisted = JSON.stringify(
      db.prepare("SELECT * FROM resource_usage_backfill_skill_bindings").all(),
    );
    expect(persisted).not.toContain("skill_testing");
    expect(persisted).not.toContain("workspace/review/.pi/skills/testing");
    db.close();
    expect(store.requestSessionPurge("session-1").completed).toBe(true);
    expect(store.getBackfillSkillBindings("source-1")).toEqual(new Map());
    store.close();
  });

  it("initializes privacy-minimized history schema with deletion indexes", () => {
    const store = makeStore();
    const db = openDatabase(join(dirs.at(-1)!, "resource-usage.db"));
    const columns = (
      db.prepare("PRAGMA table_info(resource_usage_events)").all() as Array<{ name: string }>
    ).map((row) => row.name);
    const tables = (
      db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    const indexes = (
      db.prepare("PRAGMA index_list(resource_usage_events)").all() as Array<{ name: string }>
    ).map((row) => row.name);

    expect(columns).toEqual([
      "action_id",
      "occurred_at",
      "signal",
      "session_id",
      "workspace_id",
      "runtime",
      "owner_kind",
      "owner_id",
      "item_name",
      "provider",
      "model",
      "manifest_revision",
      "attribution",
      "origin",
      "source_key",
    ]);
    expect(tables).toEqual(
      expect.arrayContaining([
        "resource_usage_pending_purges",
        "resource_usage_backfill_checkpoints",
        "resource_usage_backfill_sources",
        "resource_usage_backfill_skill_bindings",
        "resource_usage_purges",
      ]),
    );
    expect(indexes).toEqual(
      expect.arrayContaining([
        "resource_usage_events_session_idx",
        "resource_usage_events_workspace_idx",
      ]),
    );
    db.close();
    store.close();
  });

  it("scrubs path-bearing columns and tables even when exact_live_schema is already set", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-exact-paths-"));
    dirs.push(dir);
    const dbPath = join(dir, "resource-usage.db");
    const initial = new ResourceUsageStore(dir, { now: () => 5_000 });
    initial.recordBatch([event({ actionId: "preserved-exact-event", occurredAt: 4_000 })]);
    initial.close();

    const contaminated = openDatabase(dbPath);
    const tables = (
      contaminated
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'",
        )
        .all() as Array<{ name: string }>
    ).map((row) => row.name);
    for (const table of tables) {
      contaminated.exec(`ALTER TABLE ${table} ADD COLUMN source_path TEXT`);
      contaminated.exec(`UPDATE ${table} SET source_path = '/Users/private/trace.jsonl'`);
    }
    contaminated.exec(`
      CREATE TABLE resource_usage_abandoned_paths (
        id TEXT PRIMARY KEY,
        trace_path TEXT NOT NULL
      );
      INSERT INTO resource_usage_abandoned_paths VALUES ('old', '/Users/private/old.jsonl');
    `);
    contaminated.close();

    const repaired = new ResourceUsageStore(dir, { now: () => 5_000 });
    expect(
      repaired.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([expect.objectContaining({ actionId: "preserved-exact-event" })]);
    repaired.close();

    const audited = openDatabase(dbPath);
    const auditedTables = (
      audited
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'",
        )
        .all() as Array<{ name: string }>
    ).map((row) => row.name);
    expect(auditedTables).not.toContain("resource_usage_abandoned_paths");
    for (const table of auditedTables) {
      const columns = (
        audited.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name: string }>
      ).map((row) => row.name);
      expect(columns).not.toContain("source_path");
      expect(JSON.stringify(audited.prepare(`SELECT * FROM ${table}`).all())).not.toContain(
        "/Users/private",
      );
    }
    audited.close();
  });

  it("keeps privacy-minimized draft events but drops path-bearing enrollment state", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-draft-"));
    dirs.push(dir);
    const dbPath = join(dir, "resource-usage.db");
    const draft = openDatabase(dbPath);
    draft.exec(`
      CREATE TABLE resource_usage_events (
        action_id TEXT PRIMARY KEY,
        occurred_at INTEGER NOT NULL,
        signal TEXT NOT NULL,
        session_id TEXT NOT NULL,
        workspace_id TEXT,
        runtime TEXT NOT NULL,
        owner_kind TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        item_name TEXT,
        provider TEXT,
        model TEXT,
        manifest_revision TEXT,
        attribution TEXT NOT NULL
      );
      CREATE TABLE resource_usage_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE resource_usage_backfill_sources (id TEXT PRIMARY KEY);
      INSERT INTO resource_usage_events VALUES (
        'imported', 1, 'tool_invocation', 'session-old', NULL, 'oppi',
        'builtin', 'builtin', 'read', NULL, NULL, NULL, 'exact'
      );
      INSERT INTO resource_usage_metadata VALUES ('recording_started_at_v1', '1');
    `);
    draft.close();

    const store = new ResourceUsageStore(dir, { now: () => 5_000 });
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([expect.objectContaining({ actionId: "imported", attribution: "exact" })]);
    expect(store.getMetadata("recording_started_at_v1")).toBe("1");
    expect(store.getMetadata("exact_live_schema")).toBe("4");
    const reopened = openDatabase(dbPath);
    const tables = (
      reopened.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    expect(tables).toContain("resource_usage_backfill_sources");
    const sourceColumns = (
      reopened.prepare("PRAGMA table_info(resource_usage_backfill_sources)").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    expect(sourceColumns).not.toContain("path");
    reopened.close();
    store.close();
  });

  it("atomically scrubs the prior path-bearing sandbox binding schema and values", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-binding-migration-"));
    dirs.push(dir);
    const dbPath = join(dir, "resource-usage.db");
    const initial = new ResourceUsageStore(dir, { now: () => 10_000 });
    initial.close();
    const prior = openDatabase(dbPath);
    prior.exec(`
      DROP TABLE resource_usage_backfill_skill_bindings;
      CREATE TABLE resource_usage_backfill_skill_bindings (
        source_key TEXT NOT NULL,
        session_id TEXT NOT NULL,
        workspace_id TEXT,
        guest_locator TEXT NOT NULL,
        skill_id TEXT NOT NULL,
        skill_name TEXT NOT NULL,
        ambiguous INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(source_key, guest_locator)
      );
      INSERT INTO resource_usage_backfill_skill_bindings VALUES (
        'source-old', 'session-old', 'workspace-old',
        '/workspace/private/.pi/skills/testing/SKILL.md',
        'skill_testing', 'testing', 0
      );
    `);
    prior.close();

    let migrationError: unknown;
    let unexpectedStore: ResourceUsageStore | undefined;
    try {
      unexpectedStore = new ResourceUsageStore(dir, {
        dbPath,
        now: () => 10_000,
        migrationFaultInjector: (phase: ResourceUsageStoreMigrationFaultPhase) => {
          if (String(phase) === "after_binding_drop") {
            throw new Error("injected binding migration failure");
          }
        },
      });
    } catch (error) {
      migrationError = error;
    }
    unexpectedStore?.close();
    expect(migrationError).toEqual(
      expect.objectContaining({ message: "injected binding migration failure" }),
    );

    const rolledBack = openDatabase(dbPath);
    expect(
      (
        rolledBack
          .prepare("PRAGMA table_info(resource_usage_backfill_skill_bindings)")
          .all() as Array<{ name: string }>
      ).map((row) => row.name),
    ).toContain("guest_locator");
    expect(
      JSON.stringify(
        rolledBack.prepare("SELECT * FROM resource_usage_backfill_skill_bindings").all(),
      ),
    ).toContain("/workspace/private/.pi/skills/testing/SKILL.md");
    rolledBack.close();

    // Simulate an unclean prior owner so path-bearing frames are genuinely left in WAL.
    const crashedWriter = spawnSync(
      process.execPath,
      [
        "--input-type=module",
        "--eval",
        `import { DatabaseSync } from "node:sqlite";
         const db = new DatabaseSync(process.argv[1]);
         db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0");
         db.exec("UPDATE resource_usage_backfill_skill_bindings SET skill_name = 'testing-wal'");
         process.kill(process.pid, "SIGKILL");`,
        dbPath,
      ],
      { encoding: "utf8" },
    );
    expect(crashedWriter.signal).toBe("SIGKILL");
    const walPath = `${dbPath}-wal`;
    expect(existsSync(walPath)).toBe(true);
    expect(
      Buffer.concat([readFileSync(dbPath), readFileSync(walPath)]).includes(
        Buffer.from("guest_locator"),
      ),
    ).toBe(true);
    expect(
      readFileSync(walPath).includes(Buffer.from("/workspace/private/.pi/skills/testing/SKILL.md")),
    ).toBe(true);

    const migrated = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    migrated.close();
    const audited = openDatabase(dbPath);
    expectPathFreeResourceUsageDatabase(audited, [
      "/workspace/private/.pi/skills/testing/SKILL.md",
    ]);
    audited.close();

    for (const path of [dbPath, walPath, `${dbPath}-shm`]) {
      if (!existsSync(path)) continue;
      const bytes = readFileSync(path);
      expect(bytes.includes(Buffer.from("guest_locator")), `${path} retained guest_locator`).toBe(
        false,
      );
      expect(
        bytes.includes(Buffer.from("/workspace/private/.pi/skills/testing/SKILL.md")),
        `${path} retained a guest path`,
      ).toBe(false);
    }
  });

  it("recovers a committed logical scrub after an injected VACUUM failure", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-scrub-recovery-"));
    dirs.push(dir);
    const { dbPath, forbiddenPath } = createPathBearingBindingDatabase(dir, {
      contaminateMetadata: true,
    });

    expect(
      () =>
        new ResourceUsageStore(dir, {
          dbPath,
          now: () => 10_000,
          migrationFaultInjector: (phase: ResourceUsageStoreMigrationFaultPhase) => {
            if (phase === "before_vacuum") throw new Error("injected VACUUM failure");
          },
        }),
    ).toThrow("injected VACUUM failure");

    const logicallyMigrated = openDatabase(dbPath);
    const bindingColumns = (
      logicallyMigrated
        .prepare("PRAGMA table_info(resource_usage_backfill_skill_bindings)")
        .all() as Array<{ name: string }>
    ).map((row) => row.name);
    const metadataColumns = (
      logicallyMigrated.prepare("PRAGMA table_info(resource_usage_metadata)").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    logicallyMigrated.close();
    expect(bindingColumns).toContain("binding_token");
    expect(bindingColumns).not.toContain("guest_locator");
    expect(metadataColumns).not.toContain("source_path");
    expect(physicalScrubState(dbPath)).toBe("pending");
    expect(physicalSqliteBytesContain(dbPath, forbiddenPath)).toBe(true);

    const recovered = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    recovered.close();
    expect(physicalScrubState(dbPath)).toBeUndefined();
    expect(physicalSqliteBytesContain(dbPath, forbiddenPath)).toBe(false);

    const idempotent = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    idempotent.close();
    expect(physicalScrubState(dbPath)).toBeUndefined();
    for (const path of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      if (!existsSync(path)) continue;
      expect(readFileSync(path).includes(Buffer.from(forbiddenPath))).toBe(false);
      expect(readFileSync(path).includes(Buffer.from("guest_locator"))).toBe(false);
    }
  });

  it("keeps the marker pending after VACUUM until physical verification completes", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-scrub-verification-"));
    dirs.push(dir);
    const { dbPath, forbiddenPath } = createPathBearingBindingDatabase(dir);

    expect(
      () =>
        new ResourceUsageStore(dir, {
          dbPath,
          now: () => 10_000,
          migrationFaultInjector: (phase: ResourceUsageStoreMigrationFaultPhase) => {
            if (phase === "after_vacuum") {
              throw new Error("injected post-VACUUM termination window");
            }
          },
        }),
    ).toThrow("injected post-VACUUM termination window");
    expect(physicalScrubState(dbPath)).toBe("pending");
    expect(physicalSqliteBytesContain(dbPath, forbiddenPath)).toBe(false);

    const recovered = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    recovered.close();
    expect(physicalScrubState(dbPath)).toBeUndefined();
    expect(physicalSqliteBytesContain(dbPath, forbiddenPath)).toBe(false);
  });

  it("recovers automatically after process termination between logical scrub and VACUUM", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-scrub-termination-"));
    dirs.push(dir);
    const { dbPath, forbiddenPath } = createPathBearingBindingDatabase(dir);
    const storeModule = pathToFileURL(
      join(process.cwd(), "src", "storage", "resource-usage-store.ts"),
    ).href;
    const terminated = spawnSync(
      process.execPath,
      [
        "--import",
        "tsx",
        "--input-type=module",
        "--eval",
        `import { ResourceUsageStore } from ${JSON.stringify(storeModule)};
         new ResourceUsageStore(${JSON.stringify(dir)}, {
           dbPath: ${JSON.stringify(dbPath)},
           migrationFaultInjector: (phase) => {
             if (phase === "before_vacuum") process.kill(process.pid, "SIGKILL");
           },
         });`,
      ],
      { cwd: process.cwd(), encoding: "utf8" },
    );
    expect(terminated.signal).toBe("SIGKILL");
    expect(physicalScrubState(dbPath)).toBe("pending");
    expect(physicalSqliteBytesContain(dbPath, forbiddenPath)).toBe(true);

    const recovered = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    recovered.close();
    expect(physicalScrubState(dbPath)).toBeUndefined();
    expect(physicalSqliteBytesContain(dbPath, forbiddenPath)).toBe(false);
    for (const path of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      if (!existsSync(path)) continue;
      const bytes = readFileSync(path);
      expect(bytes.includes(Buffer.from("guest_locator"))).toBe(false);
      expect(bytes.includes(Buffer.from(forbiddenPath))).toBe(false);
    }
  });

  it("fails closed without altering a path-bearing database owned by another reader", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-binding-owner-"));
    dirs.push(dir);
    const dbPath = join(dir, "resource-usage.db");
    const setup = openDatabase(dbPath);
    setup.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE resource_usage_backfill_skill_bindings (
        source_key TEXT NOT NULL,
        session_id TEXT NOT NULL,
        workspace_id TEXT,
        guest_locator TEXT NOT NULL,
        skill_id TEXT NOT NULL,
        skill_name TEXT NOT NULL,
        ambiguous INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(source_key, guest_locator)
      );
      INSERT INTO resource_usage_backfill_skill_bindings VALUES (
        'source-old', 'session-old', 'workspace-old',
        '/workspace/private/.pi/skills/testing/SKILL.md',
        'skill_testing', 'testing', 0
      );
      PRAGMA wal_checkpoint(TRUNCATE);
    `);
    setup.close();

    const reader = openDatabase(dbPath);
    reader.exec("BEGIN");
    expect(
      reader.prepare("SELECT COUNT(*) AS count FROM resource_usage_backfill_skill_bindings").get(),
    ).toEqual({ count: 1 });
    const writer = openDatabase(dbPath);
    writer.exec("UPDATE resource_usage_backfill_skill_bindings SET skill_name = 'testing-in-wal'");
    writer.close();

    expect(() => new ResourceUsageStore(dir, { dbPath, now: () => 10_000 })).toThrow(
      "could not acquire exclusive WAL ownership",
    );
    expect(
      JSON.stringify(reader.prepare("SELECT * FROM resource_usage_backfill_skill_bindings").all()),
    ).toContain("/workspace/private/.pi/skills/testing/SKILL.md");
    reader.exec("ROLLBACK");
    reader.close();
    expect(physicalScrubState(dbPath)).toBe("pending");

    const migrated = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    migrated.close();
    for (const path of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`]) {
      if (!existsSync(path)) continue;
      expect(readFileSync(path).includes(Buffer.from("guest_locator"))).toBe(false);
      expect(
        readFileSync(path).includes(Buffer.from("/workspace/private/.pi/skills/testing/SKILL.md")),
      ).toBe(false);
    }
  });

  it("rolls back an interrupted v1 signal migration before applying final replay semantics", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-schema-rollback-"));
    dirs.push(dir);
    const dbPath = join(dir, "resource-usage.db");
    const v1 = openDatabase(dbPath);
    v1.exec(`
      CREATE TABLE resource_usage_events (
        action_id TEXT PRIMARY KEY,
        occurred_at INTEGER NOT NULL,
        signal TEXT NOT NULL CHECK(signal IN (
          'agent_load', 'explicit_activation', 'tool_invocation', 'command_invocation'
        )),
        session_id TEXT NOT NULL,
        workspace_id TEXT,
        runtime TEXT NOT NULL CHECK(runtime IN ('oppi', 'pi-tui')),
        owner_kind TEXT NOT NULL CHECK(owner_kind IN ('skill', 'extension', 'builtin')),
        owner_id TEXT NOT NULL,
        item_name TEXT,
        provider TEXT,
        model TEXT,
        manifest_revision TEXT,
        attribution TEXT NOT NULL DEFAULT 'exact' CHECK(attribution IN ('exact', 'inferred')),
        origin TEXT NOT NULL DEFAULT 'live' CHECK(origin IN ('live', 'history')),
        source_key TEXT
      );
      CREATE TABLE resource_usage_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO resource_usage_metadata VALUES ('exact_live_schema', '1');
      INSERT INTO resource_usage_metadata VALUES ('resource_usage_backfill_semantics_generation', '2');
      INSERT INTO resource_usage_events VALUES
        ('live-skill', 9000, 'explicit_activation', 's1', 'w1', 'oppi', 'skill', 'skill_testing', 'testing', NULL, NULL, NULL, 'exact', 'live', NULL),
        ('history-tool', 9001, 'tool_invocation', 's2', 'w1', 'oppi', 'builtin', 'builtin', 'read', NULL, NULL, NULL, 'exact', 'history', 'source-1'),
        ('live-extension', 9002, 'command_invocation', 's3', 'w1', 'oppi', 'extension', 'extension_review', 'review', NULL, NULL, NULL, 'exact', 'live', NULL);
    `);
    v1.close();
    let injected = false;

    expect(
      () =>
        new ResourceUsageStore(dir, {
          dbPath,
          now: () => 10_000,
          migrationFaultInjector: (phase: ResourceUsageStoreMigrationFaultPhase) => {
            if (phase === "after_signal_copy") {
              injected = true;
              throw new Error("injected migration failure");
            }
          },
        }),
    ).toThrow("injected migration failure");
    expect(injected).toBe(true);

    const rolledBack = openDatabase(dbPath);
    expect(
      (
        rolledBack
          .prepare("SELECT value FROM resource_usage_metadata WHERE key = 'exact_live_schema'")
          .get() as { value: string }
      ).value,
    ).toBe("1");
    expect(
      (
        rolledBack.prepare("SELECT COUNT(*) AS count FROM resource_usage_events").get() as {
          count: number;
        }
      ).count,
    ).toBe(3);
    const tablesAfterFailure = (
      rolledBack.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    expect(tablesAfterFailure).not.toContain("resource_usage_events_signal_v1");
    rolledBack.close();

    const reopened = new ResourceUsageStore(dir, { dbPath, now: () => 10_000 });
    expect(reopened.getMetadata("exact_live_schema")).toBe("4");
    expect(
      reopened.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toEqual([expect.objectContaining({ actionId: "live-skill" })]);
    expect(
      reopened.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([]);
    expect(
      reopened.queryEvents({
        subject: { kind: "extension", id: "extension_review" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toEqual([expect.objectContaining({ actionId: "live-extension" })]);
    reopened.close();
  });

  it("migrates prior backfill semantics to generation 4 and rebuilds stable trace identities", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-semantics-"));
    dirs.push(dir);
    const dbPath = join(dir, "resource-usage.db");
    const first = new ResourceUsageStore(dir, { now: () => 10_000 });
    first.recordBatch([
      event({
        actionId: "historical-skill",
        signal: "explicit_activation",
        ownerKind: "skill",
        ownerId: "skill_testing",
        itemName: "testing",
        origin: "history",
        sourceKey: "source-1",
      }),
      event({ actionId: "historical-tool", origin: "history", sourceKey: "source-1" }),
      event({
        actionId: "live-skill",
        signal: "explicit_activation",
        ownerKind: "skill",
        ownerId: "skill_testing",
        itemName: "testing",
        origin: "live",
      }),
    ]);
    first.enrollBackfillSource({ sourceKey: "source-1", sessionId: "session-1", runtime: "oppi" });
    first.saveBackfillCheckpoint({
      sourceKey: "source-1",
      offset: 100,
      size: 100,
      fingerprint: "old",
      completedAt: 9_000,
      corruptLines: 0,
      oversizedLines: 0,
      lines: 3,
    });
    first.setBackfillState({
      semanticsGeneration: 2,
      status: "complete",
      totalSources: 1,
      processedSources: 1,
      completedSources: 1,
      failedSources: 0,
      processedBytes: 100,
      processedLines: 3,
      historicalEvents: 2,
      corruptLines: 0,
      oversizedLines: 0,
      updatedAt: 9_000,
      lastCompletedAt: 9_000,
    });
    first.setMetadata("resource_usage_backfill_semantics_generation", "2");
    first.close();

    const migrated = new ResourceUsageStore(dir, { now: () => 10_000 });

    expect(migrated.getBackfillState()).toMatchObject({
      semanticsGeneration: 4,
      status: "available",
    });
    expect(migrated.getBackfillCheckpoint("source-1")).toBeUndefined();
    expect(
      migrated.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toEqual([expect.objectContaining({ actionId: "live-skill", origin: "live" })]);
    expect(
      migrated.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([]);
    migrated.close();

    const audited = openDatabase(dbPath);
    expect(
      (
        audited
          .prepare(
            "SELECT value FROM resource_usage_metadata WHERE key = 'resource_usage_backfill_semantics_generation'",
          )
          .get() as { value: string }
      ).value,
    ).toBe("4");
    audited.close();
  });

  it("rekeys runtime-scoped live rows without losing Mirror ownership metadata", () => {
    const store = makeStore();
    const traceId = "trace-promoted";
    const producerId = `trace-event-v1_${"a".repeat(64)}`;
    const [oldOppiId, oldMirrorId] = resourceUsageRuntimeActionAliases(
      traceId,
      "tool_invocation",
      producerId,
    );
    expect(oldOppiId).not.toBe(oldMirrorId);
    store.recordBatch([
      event({
        actionId: oldMirrorId!,
        sessionId: "mirror-session",
        workspaceId: "mirror-workspace",
        runtime: "pi-tui",
        origin: "live",
      }),
    ]);

    store.recordBatch([
      event({
        actionId: resourceUsageActionId("oppi", traceId, "tool_invocation", producerId),
        sessionId: "managed-session",
        workspaceId: "managed-workspace",
        runtime: "oppi",
        origin: "history",
        sourceKey: "source-promoted",
        supersedesActionIds: [oldOppiId!, oldMirrorId!],
      }),
    ]);

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([
      expect.objectContaining({
        actionId: resourceUsageActionId("oppi", traceId, "tool_invocation", producerId),
        sessionId: "mirror-session",
        workspaceId: "mirror-workspace",
        runtime: "pi-tui",
        origin: "live",
      }),
    ]);
    store.close();
  });

  it("restores interrupted durable backfill state as partial and retryable", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-backfill-restart-"));
    dirs.push(dir);
    const first = new ResourceUsageStore(dir, { now: () => 10_000 });
    first.setBackfillState({
      semanticsGeneration: 2,
      status: "running",
      totalSources: 10,
      processedSources: 4,
      completedSources: 4,
      failedSources: 0,
      processedBytes: 1_024,
      processedLines: 20,
      historicalEvents: 0,
      corruptLines: 0,
      oversizedLines: 0,
      startedAt: 9_000,
      updatedAt: 9_500,
    });
    first.close();

    const second = new ResourceUsageStore(dir, { now: () => 10_000 });
    expect(second.getBackfillState()).toMatchObject({
      status: "partial",
      totalSources: 10,
      processedSources: 4,
      completedSources: 4,
      lastError: expect.stringContaining("restarted"),
    });
    second.close();
  });

  it("allocates runtime-instance identities monotonically across store recreation", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-runtime-id-"));
    dirs.push(dir);
    const first = new ResourceUsageStore(dir);
    expect(first.nextRuntimeInstanceId()).toBe("runtime-1");
    first.close();

    const second = new ResourceUsageStore(dir);
    expect(second.nextRuntimeInstanceId()).toBe("runtime-2");
    second.close();
  });

  it("retries pending purges at startup", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-resource-usage-startup-purge-"));
    dirs.push(dir);
    const first = new ResourceUsageStore(dir);
    first.recordBatch([event({ actionId: "startup-purge", sessionId: "session-startup" })]);
    const deleteSession = first.deleteSession.bind(first);
    first.deleteSession = () => {
      throw new Error("delete unavailable");
    };
    expect(first.requestSessionPurge("session-startup").completed).toBe(false);
    first.deleteSession = deleteSession;
    first.close();

    const second = new ResourceUsageStore(dir);
    expect(second.listPendingPurges()).toEqual([]);
    expect(
      second.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([]);
    second.close();
  });

  it.each([
    ["session", () => event({ actionId: "late-session", sessionId: "deleted-session" })],
    [
      "workspace",
      () =>
        event({
          actionId: "late-workspace",
          sessionId: "other-session",
          workspaceId: "deleted-workspace",
        }),
    ],
  ] as const)("rejects delayed live writes after a durable %s purge", (kind, lateEvent) => {
    const store = makeStore();
    if (kind === "session") {
      expect(store.requestSessionPurge("deleted-session").completed).toBe(true);
    } else {
      expect(store.requestWorkspacePurge("deleted-workspace").completed).toBe(true);
    }

    store.recordBatch([lateEvent()]);

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([]);
    store.close();
  });

  it.each(["session", "workspace"] as const)(
    "fences delayed sandbox binding writes after a durable %s purge",
    (kind) => {
      const store = makeStore();
      if (kind === "session") {
        expect(store.requestSessionPurge("deleted-session").completed).toBe(true);
      } else {
        expect(store.requestWorkspacePurge("deleted-workspace").completed).toBe(true);
      }

      store.mergeBackfillSkillBindings({
        sourceKey: `source-after-${kind}-purge`,
        sessionId: kind === "session" ? "deleted-session" : "other-session",
        workspaceId: kind === "workspace" ? "deleted-workspace" : "other-workspace",
        bindings: [
          {
            bindingToken: `sandbox-binding-v1_${"d".repeat(64)}`,
            skillId: "skill_testing",
            skillName: "testing",
          },
        ],
      });

      expect(store.getBackfillSkillBindings(`source-after-${kind}-purge`)).toEqual(new Map());
      store.close();
    },
  );

  it("persists failed purges and retries them on the next write", () => {
    const store = makeStore();
    store.recordBatch([event({ actionId: "purge-me", sessionId: "session-purge" })]);
    const deleteSession = store.deleteSession.bind(store);
    let fail = true;
    store.deleteSession = (sessionId) => {
      if (fail) throw new Error("delete unavailable");
      return deleteSession(sessionId);
    };

    expect(store.requestSessionPurge("session-purge")).toEqual({ completed: false, records: 0 });
    expect(store.listPendingPurges()).toEqual([
      expect.objectContaining({ kind: "session", targetId: "session-purge" }),
    ]);

    fail = false;
    store.recordBatch([event({ actionId: "next-write", sessionId: "session-other" })]);
    expect(store.listPendingPurges()).toEqual([]);
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([expect.objectContaining({ actionId: "next-write" })]);
    store.close();
  });
});

describe("resource usage aggregation", () => {
  it("excludes Skill loads from actual-use totals, dates, attribution, and last use", () => {
    const now = Date.UTC(2026, 6, 27, 12);
    const result = aggregateResourceUsage({
      events: [
        event({
          actionId: "activation",
          occurredAt: now + 1,
          signal: "explicit_activation",
          ownerKind: "skill",
          ownerId: "skill_testing",
          itemName: "testing",
        }),
        event({
          actionId: "load",
          occurredAt: now,
          signal: "agent_load",
          ownerKind: "skill",
          ownerId: "skill_testing",
          itemName: "testing",
        }),
        event({
          actionId: "read",
          occurredAt: now - 1_000,
          signal: "skill_instruction_read",
          ownerKind: "skill",
          ownerId: "skill_testing",
          itemName: "testing",
          origin: "history",
        }),
      ],
      retainedBounds: { lastRecordedAt: now - 1_000 },
      subject: { kind: "skill", id: "skill_testing" },
      rangeDays: 7,
      timezone: "UTC",
      nowMs: now,
      recordingStartedAt: now - 86_400_000,
      capture: { status: "active", failedWrites: 0, droppedEvents: 0 },
    });

    expect(result.recordedActions).toBe(1);
    expect(result.lastRecordedAt).toBe(now - 1_000);
    expect(result.loadedSessionSignal).toMatchObject({
      actions: 1,
      sessions: 1,
      lastLoadedAt: now,
    });
    expect(result.attribution).toMatchObject({
      exactActions: 1,
      historicalActions: 1,
      liveActions: 0,
    });
    expect(result.breakdown).toEqual([
      expect.objectContaining({ signal: "explicit_activation", actions: 1 }),
      expect.objectContaining({ signal: "skill_instruction_read", actions: 1 }),
    ]);
  });

  it("uses IANA local calendar days across DST and zero-fills daily rows", () => {
    const now = Date.parse("2026-03-10T16:00:00.000Z");
    const result = aggregateResourceUsage({
      events: [
        event({ actionId: "before", occurredAt: Date.parse("2026-03-08T07:30:00.000Z") }),
        event({
          actionId: "after",
          occurredAt: Date.parse("2026-03-08T10:30:00.000Z"),
          sessionId: "session-2",
        }),
      ],
      retainedBounds: {
        oldestRecordedAt: Date.parse("2026-03-08T07:30:00.000Z"),
        lastRecordedAt: Date.parse("2026-03-08T10:30:00.000Z"),
      },
      subject: { kind: "tools" },
      rangeDays: 7,
      timezone: "America/Los_Angeles",
      nowMs: now,
      recordingStartedAt: now - 86_400_000,
      capture: { status: "active", failedWrites: 0, droppedEvents: 0 },
    });

    expect(result.daily).toHaveLength(7);
    expect(result.daily.map((row) => row.date)).toEqual([
      "2026-03-04",
      "2026-03-05",
      "2026-03-06",
      "2026-03-07",
      "2026-03-08",
      "2026-03-09",
      "2026-03-10",
    ]);
    expect(result.daily.find((row) => row.date === "2026-03-07")).toMatchObject({
      actions: 1,
      sessions: 1,
    });
    expect(result.daily.find((row) => row.date === "2026-03-08")).toMatchObject({
      actions: 1,
      sessions: 1,
    });
    expect(result.recordedActions).toBe(2);
    expect(result.distinctSessions).toBe(2);
    expect(result.activeDays).toBe(2);
    expect(result.recordingStartedAt).toBe(now - 86_400_000);
  });
});
