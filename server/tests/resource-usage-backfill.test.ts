import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  ResourceUsageBackfill,
  opaqueResourceUsageSourceKey,
  resolveRegisteredResourceUsageSources,
} from "../src/resource-usage-backfill.js";
import { resourceUsageActionId } from "../src/resource-usage-service.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";

const dirs: string[] = [];
const now = Date.UTC(2026, 6, 27, 12);

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-resource-history-"));
  dirs.push(dir);
  return dir;
}

function line(value: unknown): string {
  return `${JSON.stringify(value)}\n`;
}

function source(path: string, overrides: Record<string, unknown> = {}) {
  return {
    sourceKey: opaqueResourceUsageSourceKey(path),
    path,
    sessionId: "session-1",
    workspaceId: "workspace-1",
    runtime: "oppi" as const,
    ...overrides,
  };
}

const catalog = {
  skills: new Map([["testing", "skill_testing"]]),
  commands: new Map([["review", { ownerKind: "extension" as const, ownerId: "extension_review" }]]),
  tools: new Map([
    ["review_tool", { ownerKind: "extension" as const, ownerId: "extension_review" }],
  ]),
  builtInTools: new Set(["read", "bash"]),
};

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("ResourceUsageBackfill", () => {
  it.each(["history-first", "exact-first"] as const)(
    "reconciles a production-shaped Skill marker and its Pi user message %s",
    async (order) => {
      const dir = tempDir();
      const trace = join(dir, "skill-reconciliation.jsonl");
      const acceptedTurnId = "accepted-turn-1";
      const userEntryId = "pi-generated-message-id";
      const actionId = resourceUsageActionId(
        "oppi",
        "trace-skill",
        "explicit_activation",
        acceptedTurnId,
      );
      const header = line({
        type: "session",
        id: "trace-skill",
        timestamp: new Date(now - 2_000).toISOString(),
        cwd: "/private/work",
      });
      const marker = line({
        type: "custom",
        id: "marker-1",
        timestamp: new Date(now - 998).toISOString(),
        customType: "oppi-resource-usage",
        data: {
          version: 2,
          actionId,
          producerId: acceptedTurnId,
          messageEntryId: userEntryId,
          signal: "explicit_activation",
          itemName: "testing",
          ownerKind: "skill",
          ownerId: "skill_testing",
        },
      });
      const message = line({
        type: "message",
        id: userEntryId,
        timestamp: new Date(now - 999).toISOString(),
        message: { role: "user", content: "/skill:testing run tests" },
      });
      const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
      const backfill = new ResourceUsageBackfill(store, { now: () => now, batchSize: 1 });

      if (order === "history-first") {
        writeFileSync(trace, header + message);
        await backfill.run([source(trace)], catalog);
        writeFileSync(trace, marker, { flag: "a" });
      } else {
        store.recordBatch([
          {
            actionId,
            occurredAt: now - 999,
            signal: "explicit_activation",
            sessionId: "session-1",
            workspaceId: "workspace-1",
            runtime: "oppi",
            ownerKind: "skill",
            ownerId: "skill_testing",
            itemName: "testing",
          },
        ]);
        writeFileSync(trace, header + message + marker);
      }
      await backfill.run([source(trace)], catalog);

      const events = store.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      });
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({ actionId, attribution: "exact" });
      expect(events[0]?.actionId).not.toBe(
        resourceUsageActionId("oppi", "trace-skill", "explicit_activation", userEntryId),
      );
      store.close();
    },
  );

  it("consumes a checkpointed marker-first reconciliation before a distinct Skill activation", async () => {
    const dir = tempDir();
    const trace = join(dir, "checkpointed-marker-first.jsonl");
    const dbPath = join(dir, "usage.db");
    const actionId = resourceUsageActionId(
      "oppi",
      "trace-marker-first",
      "explicit_activation",
      "accepted-turn-marker-first",
    );
    const filler = Array.from({ length: 499 }, (_, index) =>
      line({
        type: "message",
        id: `filler-${index}`,
        timestamp: new Date(now - 900 + index).toISOString(),
        message: {
          role: "assistant",
          content: [{ type: "toolCall", id: `filler-call-${index}`, name: "read" }],
        },
      }),
    ).join("");
    const scanTail = Array.from({ length: 1_000 }, (_, index) =>
      line({ type: "custom", customType: "irrelevant", data: { index, padding: "x".repeat(64) } }),
    ).join("");
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-marker-first",
        timestamp: new Date(now - 2_000).toISOString(),
        cwd: "/private/work",
      }) +
        line({
          type: "custom",
          id: "marker-first",
          timestamp: new Date(now - 1_000).toISOString(),
          customType: "oppi-resource-usage",
          data: {
            version: 2,
            actionId,
            producerId: "accepted-turn-marker-first",
            signal: "explicit_activation",
            itemName: "testing",
            ownerKind: "skill",
            ownerId: "skill_testing",
          },
        }) +
        filler +
        scanTail,
    );
    const store = new ResourceUsageStore(dir, { dbPath, now: () => now });
    const sourceInput = source(trace);
    const recordBackfillBatch = store.recordBackfillBatch.bind(store);
    let appended = false;
    store.recordBackfillBatch = (input) => {
      const result = recordBackfillBatch(input);
      if (!appended && input.events.length === 500) {
        const checkpointed = openDatabase(dbPath);
        expect(
          (
            checkpointed
              .prepare("SELECT COUNT(*) AS count FROM resource_usage_backfill_reconciliations")
              .get() as { count: number }
          ).count,
        ).toBe(1);
        checkpointed.close();
        appended = true;
        writeFileSync(
          trace,
          line({
            type: "message",
            id: "pi-message-after-checkpoint",
            timestamp: new Date(now).toISOString(),
            message: { role: "user", content: "/skill:testing run tests" },
          }) +
            line({
              type: "message",
              id: "distinct-skill-activation",
              timestamp: new Date(now + 1).toISOString(),
              message: { role: "user", content: "/skill:testing run tests again" },
            }),
          { flag: "a" },
        );
      }
      return result;
    };

    await new ResourceUsageBackfill(store, { now: () => now }).run([sourceInput], catalog);

    expect(appended).toBe(true);
    expect(
      store.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toEqual([
      expect.objectContaining({ actionId, attribution: "exact" }),
      expect.objectContaining({
        actionId: resourceUsageActionId(
          "oppi",
          "trace-marker-first",
          "explicit_activation",
          "distinct-skill-activation",
        ),
        attribution: "inferred",
      }),
    ]);
    const db = openDatabase(dbPath);
    expect(
      (
        db
          .prepare("SELECT COUNT(*) AS count FROM resource_usage_backfill_reconciliations")
          .get() as { count: number }
      ).count,
    ).toBe(0);
    db.close();
    store.close();
  });

  it("resumes growing traces and reconciles exact-first and history-first without duplicates", async () => {
    const dir = tempDir();
    const trace = join(dir, "trace.jsonl");
    const exactAction = resourceUsageActionId("oppi", "trace-1", "command_invocation", "turn-1");
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-1",
        timestamp: new Date(now - 2_000).toISOString(),
        cwd: "/private/work",
      }) +
        line({
          type: "custom",
          id: "marker-1",
          timestamp: new Date(now - 1_000).toISOString(),
          customType: "oppi-resource-usage",
          data: {
            version: 1,
            actionId: exactAction,
            signal: "command_invocation",
            itemName: "review",
            ownerKind: "extension",
            ownerId: "extension_review",
          },
        }),
    );
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    store.recordBatch([
      {
        actionId: exactAction,
        occurredAt: now - 1_000,
        signal: "command_invocation",
        sessionId: "session-1",
        workspaceId: "workspace-1",
        runtime: "oppi",
        ownerKind: "extension",
        ownerId: "extension_review",
        itemName: "review",
      },
    ]);
    const backfill = new ResourceUsageBackfill(store, { now: () => now, batchSize: 1 });

    await backfill.run([source(trace)], catalog);
    writeFileSync(
      trace,
      line({
        type: "message",
        id: "turn-2",
        timestamp: new Date(now).toISOString(),
        message: { role: "user", content: "/review" },
      }),
      { flag: "a" },
    );
    await backfill.run([source(trace)], catalog);
    await backfill.run([source(trace)], catalog);

    const events = store.queryEvents({
      subject: { kind: "extension", id: "extension_review" },
      sinceMs: 0,
      untilMs: Infinity,
    });
    expect(events).toHaveLength(2);
    expect(events.find((event) => event.actionId === exactAction)).toMatchObject({
      attribution: "exact",
      origin: "live",
    });
    expect(events.find((event) => event.actionId !== exactAction)).toMatchObject({
      attribution: "inferred",
      origin: "history",
    });
    expect(
      store.getBackfillCheckpoint(opaqueResourceUsageSourceKey(trace))?.offset,
    ).toBeGreaterThan(0);
    store.close();
  });

  it("keeps two identical accepted commands distinct through persisted producer markers", async () => {
    const dir = tempDir();
    const trace = join(dir, "repeat.jsonl");
    const markers = ["accepted-1", "accepted-2"].map((producerId, index) => ({
      type: "custom",
      id: `marker-${index}`,
      timestamp: new Date(now + index).toISOString(),
      customType: "oppi-resource-usage",
      data: {
        version: 1,
        actionId: resourceUsageActionId("oppi", "trace-repeat", "command_invocation", producerId),
        signal: "command_invocation",
        itemName: "review",
        ownerKind: "extension",
        ownerId: "extension_review",
      },
    }));
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-repeat",
        timestamp: new Date(now).toISOString(),
        cwd: "/not/persisted",
      }) + markers.map(line).join(""),
    );
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });

    await new ResourceUsageBackfill(store, { now: () => now }).run([source(trace)], catalog);

    expect(
      store.queryEvents({
        subject: { kind: "extension", id: "extension_review" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toHaveLength(2);
    store.close();
  });

  it("bounds bad input, skips absent ownership evidence, retains 120 days, and yields", async () => {
    const dir = tempDir();
    const trace = join(dir, "bad.jsonl");
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-bad",
        timestamp: new Date(now).toISOString(),
        cwd: "/secret/cwd",
      }) +
        "{broken\n" +
        `${"x".repeat(512)}\n` +
        line({
          type: "message",
          id: "old",
          timestamp: new Date(now - 121 * 86_400_000).toISOString(),
          message: {
            role: "assistant",
            content: [{ type: "toolCall", id: "old-call", name: "read" }],
          },
        }) +
        line({
          type: "message",
          id: "unknown",
          timestamp: new Date(now).toISOString(),
          message: {
            role: "assistant",
            content: [{ type: "toolCall", id: "unknown-call", name: "not_cataloged" }],
          },
        }) +
        line({
          type: "message",
          id: "good",
          timestamp: new Date(now).toISOString(),
          message: {
            role: "assistant",
            content: [{ type: "toolCall", id: "good-call", name: "read" }],
          },
        }),
    );
    let yields = 0;
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    const result = await new ResourceUsageBackfill(store, {
      now: () => now,
      maxLineBytes: 400,
      batchSize: 1,
      yieldNow: async () => {
        yields += 1;
      },
    }).run([source(trace)], catalog);

    expect(result).toMatchObject({ corruptLines: 1, oversizedLines: 1 });
    expect(yields).toBeGreaterThan(0);
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([
      expect.objectContaining({ itemName: "read", attribution: "exact", origin: "history" }),
    ]);
    store.close();
  });

  it("does not reinsert events or checkpoints when purge wins an in-flight flush", async () => {
    const dir = tempDir();
    const trace = join(dir, "purge-race.jsonl");
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-race",
        timestamp: new Date(now).toISOString(),
        cwd: dir,
      }) +
        line({
          type: "message",
          id: "tool-race",
          timestamp: new Date(now).toISOString(),
          message: {
            role: "assistant",
            content: [{ type: "toolCall", id: "call-race", name: "read" }],
          },
        }),
    );
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    let purged = false;
    const originalRecordBackfillBatch = store.recordBackfillBatch.bind(store);
    store.recordBackfillBatch = (input) => {
      if (!purged) {
        purged = true;
        expect(store.requestSessionPurge("session-1").completed).toBe(true);
      }
      return originalRecordBackfillBatch(input);
    };

    await new ResourceUsageBackfill(store, { now: () => now, batchSize: 1 }).run(
      [source(trace)],
      catalog,
    );

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([]);
    expect(store.getBackfillCheckpoint(opaqueResourceUsageSourceKey(trace))).toBeUndefined();
    const db = openDatabase(join(dir, "usage.db"));
    expect(
      (
        db.prepare("SELECT COUNT(*) AS count FROM resource_usage_backfill_sources").get() as {
          count: number;
        }
      ).count,
    ).toBe(0);
    db.close();
    store.close();
  });

  it("never stores raw paths and purges historical enrollment/checkpoints with their owner", async () => {
    const dir = tempDir();
    const secret = join(dir, "private", "trace.jsonl");
    const trace = join(dir, "trace.jsonl");
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-private",
        timestamp: new Date(now).toISOString(),
        cwd: secret,
      }) +
        line({
          type: "message",
          id: "tool",
          timestamp: new Date(now).toISOString(),
          message: { role: "assistant", content: [{ type: "toolCall", id: "call", name: "read" }] },
        }),
    );
    const dbPath = join(dir, "usage.db");
    const store = new ResourceUsageStore(dir, { dbPath, now: () => now });
    await new ResourceUsageBackfill(store, { now: () => now }).run([source(trace)], catalog);
    expect(store.requestSessionPurge("session-1").completed).toBe(true);
    store.close();

    const db = openDatabase(dbPath);
    const tables = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'",
      )
      .all() as Array<{ name: string }>;
    for (const { name } of tables) {
      const rows = db.prepare(`SELECT * FROM ${name}`).all();
      expect(JSON.stringify({ name, rows })).not.toContain(dir);
      expect(JSON.stringify({ name, rows })).not.toContain(secret);
    }
    expect(
      (
        db.prepare("SELECT COUNT(*) AS count FROM resource_usage_backfill_sources").get() as {
          count: number;
        }
      ).count,
    ).toBe(0);
    expect(
      (
        db.prepare("SELECT COUNT(*) AS count FROM resource_usage_backfill_checkpoints").get() as {
          count: number;
        }
      ).count,
    ).toBe(0);
    expect(
      (
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM resource_usage_purges WHERE kind = 'session' AND target_id = 'session-1'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(1);
    db.close();
  });

  it("scans fork and parent ownership, then deletes only the parent's production sources", async () => {
    const dir = tempDir();
    const parent = join(dir, "parent.jsonl");
    const fork = join(dir, "fork.jsonl");
    writeFileSync(
      parent,
      line({
        type: "session",
        id: "trace-parent",
        timestamp: new Date(now).toISOString(),
        cwd: dir,
      }) +
        line({
          type: "message",
          id: "parent-tool",
          timestamp: new Date(now).toISOString(),
          message: { role: "assistant", content: [{ type: "toolCall", id: "p", name: "read" }] },
        }),
    );
    writeFileSync(
      fork,
      line({
        type: "session",
        id: "trace-fork",
        timestamp: new Date(now).toISOString(),
        cwd: dir,
      }) +
        line({
          type: "message",
          id: "fork-tool",
          timestamp: new Date(now).toISOString(),
          message: { role: "assistant", content: [{ type: "toolCall", id: "f", name: "read" }] },
        }),
    );
    const sources = resolveRegisteredResourceUsageSources([
      {
        id: "fork",
        createdAt: 20,
        runtime: "oppi",
        workspaceId: "workspace",
        piSessionFiles: [parent, fork],
        piSessionFile: fork,
      },
      {
        id: "parent",
        createdAt: 10,
        runtime: "oppi",
        workspaceId: "workspace",
        piSessionFiles: [parent],
        piSessionFile: parent,
      },
    ] as never);
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    await new ResourceUsageBackfill(store, { now: () => now }).run(sources, catalog);

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([
      expect.objectContaining({ sessionId: "parent", itemName: "read" }),
      expect.objectContaining({ sessionId: "fork", itemName: "read" }),
    ]);
    expect(store.requestSessionPurge("parent").completed).toBe(true);
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([expect.objectContaining({ sessionId: "fork" })]);
    expect(store.getBackfillCheckpoint(opaqueResourceUsageSourceKey(parent))).toBeUndefined();
    expect(store.getBackfillCheckpoint(opaqueResourceUsageSourceKey(fork))).toBeDefined();
    store.close();
  });

  it("assigns shared ancestor traces to the parent using the complete authoritative set", () => {
    const parent = join("/tmp", "parent.jsonl");
    const fork = join("/tmp", "fork.jsonl");
    const resolved = resolveRegisteredResourceUsageSources([
      {
        id: "fork",
        createdAt: 20,
        runtime: "oppi",
        workspaceId: "workspace",
        piSessionFiles: [parent, fork],
        piSessionFile: fork,
      },
      {
        id: "parent",
        createdAt: 10,
        runtime: "oppi",
        workspaceId: "workspace",
        piSessionFiles: [parent],
        piSessionFile: parent,
      },
    ] as never);

    expect(resolved.find((item) => item.path === parent)?.sessionId).toBe("parent");
    expect(resolved.find((item) => item.path === fork)?.sessionId).toBe("fork");
  });
});
