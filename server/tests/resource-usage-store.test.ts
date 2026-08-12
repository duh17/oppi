import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  ResourceUsageStore,
  type ResourceUsageEvent,
} from "../src/storage/resource-usage-store.js";
import { aggregateResourceUsage } from "../src/resource-usage-service.js";
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

  it("initializes only the exact-live schema with deletion indexes", () => {
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
    ]);
    expect(tables).toContain("resource_usage_pending_purges");
    expect(tables).not.toEqual(
      expect.arrayContaining([
        "resource_usage_backfill_checkpoints",
        "resource_usage_backfill_sources",
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

  it("drops obsolete inferred draft rows and recording timestamps instead of importing them", () => {
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
    ).toEqual([]);
    expect(store.getMetadata("recording_started_at_v1")).toBeUndefined();
    expect(store.getMetadata("exact_live_schema")).toBe("1");
    const reopened = openDatabase(dbPath);
    const tables = (
      reopened.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as Array<{
        name: string;
      }>
    ).map((row) => row.name);
    expect(tables).not.toContain("resource_usage_backfill_sources");
    reopened.close();
    store.close();
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
