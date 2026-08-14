import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

import {
  ResourceUsageBackfill,
  opaqueResourceUsageSourceKey,
  resolveRegisteredResourceUsageSources,
} from "../src/resource-usage-backfill.js";
import {
  resourceUsageActionId,
  resourceUsageToolOccurrenceId,
} from "../src/resource-usage-service.js";
import { canonicalServerResourcePath } from "../src/server-resource-id.js";
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
  skillPrimaryFiles: new Map<string, { id: string; name: string }>(),
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
  it("attributes only successful canonical primary Skill Markdown reads and keeps replay idempotent", async () => {
    const dir = tempDir();
    const skillDir = join(dir, "testing");
    mkdirSync(join(skillDir, "references"), { recursive: true });
    const primary = join(skillDir, "SKILL.md");
    const supporting = join(skillDir, "references", "guide.md");
    writeFileSync(primary, "# Testing\n");
    writeFileSync(supporting, "support\n");
    const trace = join(dir, "skill-reads.jsonl");
    const toolCall = (id: string, path: string) =>
      line({
        type: "message",
        id: `assistant-${id}`,
        timestamp: new Date(now).toISOString(),
        message: {
          role: "assistant",
          content: [{ type: "toolCall", id, name: "read", arguments: { path } }],
        },
      });
    const toolResult = (id: string, isError = false) =>
      line({
        type: "message",
        id: `result-${id}`,
        timestamp: new Date(now + 1).toISOString(),
        message: {
          role: "toolResult",
          toolCallId: id,
          toolName: "read",
          content: [{ type: "text", text: isError ? "read failed" : "contents" }],
          isError,
        },
      });
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-skill-reads",
        timestamp: new Date(now - 1_000).toISOString(),
        cwd: dir,
      }) +
        toolCall("primary-1", primary) +
        toolResult("primary-1") +
        toolCall("supporting", supporting) +
        toolResult("supporting") +
        toolCall("failed-primary", primary) +
        toolResult("failed-primary", true) +
        toolCall("primary-2", primary) +
        toolResult("primary-2"),
    );
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    const primaryCatalog = {
      ...catalog,
      skillPrimaryFiles: new Map([
        [canonicalServerResourcePath(primary), { id: "skill_testing", name: "testing" }],
      ]),
    };
    const backfill = new ResourceUsageBackfill(store, { now: () => now, batchSize: 1 });

    await backfill.run([source(trace)], primaryCatalog);
    await backfill.run([source(trace)], primaryCatalog);

    const skillEvents = store.queryEvents({
      subject: { kind: "skill", id: "skill_testing" },
      sinceMs: 0,
      untilMs: Infinity,
    });
    expect(skillEvents).toHaveLength(2);
    expect(skillEvents).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          actionId: resourceUsageActionId(
            "oppi",
            "trace-skill-reads",
            "skill_instruction_read",
            resourceUsageToolOccurrenceId("primary-1", 1),
          ),
          signal: "skill_instruction_read",
          itemName: "testing",
          attribution: "exact",
          origin: "history",
        }),
        expect.objectContaining({
          actionId: resourceUsageActionId(
            "oppi",
            "trace-skill-reads",
            "skill_instruction_read",
            resourceUsageToolOccurrenceId("primary-2", 1),
          ),
        }),
      ]),
    );
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toHaveLength(4);
    expect(JSON.stringify(skillEvents)).not.toContain(dir);
    store.close();
  });

  it("deduplicates live Mirror activity when the same trace is promoted and backfilled", async () => {
    const dir = tempDir();
    const primary = join(dir, "testing", "SKILL.md");
    mkdirSync(join(dir, "testing"));
    writeFileSync(primary, "# Testing\n");
    const trace = join(dir, "mirror-promotion.jsonl");
    const eventId = `trace-event-v1_${"f".repeat(64)}`;
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-promoted",
        timestamp: new Date(now - 1).toISOString(),
        cwd: dir,
      }) +
        line({
          type: "message",
          id: "assistant-promoted",
          timestamp: new Date(now).toISOString(),
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "provider-call",
                name: "read",
                arguments: { path: primary },
              },
            ],
          },
        }) +
        line({
          type: "custom",
          id: "lifecycle-promoted",
          timestamp: new Date(now + 1).toISOString(),
          customType: "oppi-lifecycle",
          data: {
            version: 2,
            event: "tool_execution_start",
            toolCallId: "provider-call",
            toolName: "read",
            eventId,
          },
        }) +
        line({
          type: "message",
          id: "result-promoted",
          timestamp: new Date(now + 2).toISOString(),
          message: {
            role: "toolResult",
            toolCallId: "provider-call",
            toolName: "read",
            content: [],
            isError: false,
          },
        }),
    );
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    store.recordBatch([
      {
        actionId: resourceUsageActionId("pi-tui", "trace-promoted", "tool_invocation", eventId),
        occurredAt: now,
        signal: "tool_invocation",
        sessionId: "session-promoted",
        workspaceId: "workspace-1",
        runtime: "pi-tui",
        ownerKind: "builtin",
        ownerId: "builtin",
        itemName: "read",
      },
      {
        actionId: resourceUsageActionId(
          "pi-tui",
          "trace-promoted",
          "skill_instruction_read",
          eventId,
        ),
        occurredAt: now + 2,
        signal: "skill_instruction_read",
        sessionId: "session-promoted",
        workspaceId: "workspace-1",
        runtime: "pi-tui",
        ownerKind: "skill",
        ownerId: "skill_testing",
        itemName: "testing",
      },
    ]);
    await new ResourceUsageBackfill(store, { now: () => now + 3 }).run(
      [source(trace, { sessionId: "session-promoted", runtime: "oppi" })],
      {
        ...catalog,
        skillPrimaryFiles: new Map([
          [canonicalServerResourcePath(primary), { id: "skill_testing", name: "testing" }],
        ]),
      },
    );

    expect(
      store.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toEqual([expect.objectContaining({ runtime: "pi-tui", origin: "live" })]);
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([expect.objectContaining({ runtime: "pi-tui", origin: "live" })]);
    store.close();
  });

  it("keeps forked traces distinct while deduplicating unchanged runtime replay", async () => {
    const dir = tempDir();
    const makeTrace = (traceId: string) => {
      const path = join(dir, `${traceId}.jsonl`);
      writeFileSync(
        path,
        line({ type: "session", id: traceId, timestamp: new Date(now).toISOString(), cwd: dir }) +
          line({
            type: "message",
            id: `assistant-${traceId}`,
            timestamp: new Date(now + 1).toISOString(),
            message: {
              role: "assistant",
              content: [{ type: "toolCall", id: "same-id", name: "read", arguments: {} }],
            },
          }),
      );
      return path;
    };
    const parent = makeTrace("trace-parent");
    const fork = makeTrace("trace-fork");
    const store = new ResourceUsageStore(dir, { dbPath: join(dir, "usage.db"), now: () => now });
    const backfill = new ResourceUsageBackfill(store, { now: () => now });

    await backfill.run(
      [source(parent, { runtime: "pi-tui" }), source(fork, { runtime: "pi-tui" })],
      catalog,
    );
    await backfill.run(
      [source(parent, { runtime: "pi-tui" }), source(fork, { runtime: "pi-tui" })],
      catalog,
    );

    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toHaveLength(2);
    store.close();
  });

  it("keeps reused provider IDs distinct and pairs two interleaved read queues in order", async () => {
    const dir = tempDir();
    const skills = ["alpha", "beta", "gamma", "delta"].map((name) => {
      const primary = join(dir, name, "SKILL.md");
      mkdirSync(join(dir, name));
      writeFileSync(primary, `# ${name}\n`);
      return { id: `skill_${name}`, name, primary };
    });
    const trace = join(dir, "reused-interleaved.jsonl");
    const call = (id: string, skill: (typeof skills)[number], offset: number) =>
      line({
        type: "message",
        id: `call-${id}-${offset}`,
        timestamp: new Date(now + offset).toISOString(),
        message: {
          role: "assistant",
          content: [{ type: "toolCall", id, name: "read", arguments: { path: skill.primary } }],
        },
      });
    const result = (id: string, offset: number) =>
      line({
        type: "message",
        id: `result-${id}-${offset}`,
        timestamp: new Date(now + offset).toISOString(),
        message: {
          role: "toolResult",
          toolCallId: id,
          toolName: "read",
          content: [],
          isError: false,
        },
      });
    writeFileSync(
      trace,
      line({
        type: "session",
        id: "trace-reused",
        timestamp: new Date(now - 1).toISOString(),
        cwd: dir,
      }) +
        call("reused-a", skills[0]!, 1) +
        call("reused-b", skills[1]!, 2) +
        call("reused-a", skills[2]!, 3) +
        call("reused-b", skills[3]!, 4) +
        result("reused-b", 5) +
        result("reused-a", 6) +
        result("reused-b", 7) +
        result("reused-a", 8),
    );
    const store = new ResourceUsageStore(dir, {
      dbPath: join(dir, "usage.db"),
      now: () => now + 10,
    });
    const inputCatalog = {
      ...catalog,
      skillPrimaryFiles: new Map(
        skills.map((skill) => [
          canonicalServerResourcePath(skill.primary),
          { id: skill.id, name: skill.name },
        ]),
      ),
    };
    const backfill = new ResourceUsageBackfill(store, { now: () => now + 10, batchSize: 1 });

    await backfill.run([source(trace)], inputCatalog);
    const firstSkillIds = skills.flatMap((skill) =>
      store
        .queryEvents({ subject: { kind: "skill", id: skill.id }, sinceMs: 0, untilMs: Infinity })
        .map((event) => event.actionId),
    );
    const firstToolIds = store
      .queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity })
      .map((event) => event.actionId);
    await backfill.run([source(trace)], inputCatalog);

    expect(firstSkillIds).toHaveLength(4);
    expect(new Set(firstSkillIds)).toHaveLength(4);
    expect(firstToolIds).toHaveLength(4);
    expect(new Set(firstToolIds)).toHaveLength(4);
    expect(
      skills.map(
        (skill) =>
          store.queryEvents({
            subject: { kind: "skill", id: skill.id },
            sinceMs: 0,
            untilMs: Infinity,
          }).length,
      ),
    ).toEqual([1, 1, 1, 1]);
    expect(
      store
        .queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity })
        .map((event) => event.actionId),
    ).toEqual(firstToolIds);
    store.close();
  });

  it.each([
    "canonical",
    "relative",
    "symlink",
    "leading-at",
    "file-url",
    "unicode-space",
    "narrow-cwd",
    "nfd",
    "curly-quote",
    "tilde",
  ] as const)(
    "maps a successful %s primary-file path using Pi read normalization without storing the path",
    async (pathKind) => {
      const dir =
        pathKind === "tilde" ? mkdtempSync(join(homedir(), ".oppi-resource-history-")) : tempDir();
      if (pathKind === "tilde") dirs.push(dir);
      const cwd = pathKind === "narrow-cwd" ? join(dir, "review\u202fworkspace") : dir;
      if (cwd !== dir) mkdirSync(cwd);
      const skillDirectoryName =
        pathKind === "unicode-space"
          ? "Skill 10 AM."
          : pathKind === "nfd"
            ? "Cafe\u0301"
            : pathKind === "curly-quote"
              ? "Tester’s Guide"
              : "actual-skill";
      const skillDir = join(cwd, skillDirectoryName);
      mkdirSync(skillDir);
      const primary = join(skillDir, "SKILL.md");
      writeFileSync(primary, "# Testing\n");
      const aliasDir = join(dir, "skill-alias");
      symlinkSync(skillDir, aliasDir);
      const readPath = (() => {
        switch (pathKind) {
          case "canonical":
            return primary;
          case "relative":
            return "actual-skill/SKILL.md";
          case "narrow-cwd":
            return "actual-skill/SKILL.md";
          case "symlink":
            return join(aliasDir, "SKILL.md");
          case "leading-at":
            return `@${primary}`;
          case "file-url":
            return pathToFileURL(primary).href;
          case "unicode-space":
            return join(dir, "Skill 10\u202fAM.", "SKILL.md");
          case "nfd":
            return join(dir, "Café", "SKILL.md");
          case "curly-quote":
            return join(dir, "Tester's Guide", "SKILL.md");
          case "tilde":
            return `~/${primary.slice(homedir().length + 1)}`;
        }
      })();
      const trace = join(dir, `${pathKind}.jsonl`);
      writeFileSync(
        trace,
        line({
          type: "session",
          id: `trace-${pathKind}`,
          timestamp: new Date(now).toISOString(),
          cwd,
        }) +
          line({
            type: "message",
            id: `assistant-${pathKind}`,
            timestamp: new Date(now).toISOString(),
            message: {
              role: "assistant",
              content: [
                {
                  type: "toolCall",
                  id: `read-${pathKind}`,
                  name: "read",
                  arguments: { path: readPath },
                },
              ],
            },
          }) +
          line({
            type: "message",
            id: `result-${pathKind}`,
            timestamp: new Date(now + 1).toISOString(),
            message: {
              role: "toolResult",
              toolCallId: `read-${pathKind}`,
              toolName: "read",
              content: [],
              isError: false,
            },
          }),
      );
      const dbPath = join(dir, "usage.db");
      const store = new ResourceUsageStore(dir, { dbPath, now: () => now });
      await new ResourceUsageBackfill(store, { now: () => now }).run([source(trace)], {
        ...catalog,
        skillPrimaryFiles: new Map([
          [canonicalServerResourcePath(primary), { id: "skill_testing", name: "testing" }],
        ]),
      });

      expect(
        store.queryEvents({
          subject: { kind: "skill", id: "skill_testing" },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toEqual([expect.objectContaining({ signal: "skill_instruction_read" })]);
      store.close();
      const db = openDatabase(dbPath);
      for (const { name } of db
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'",
        )
        .all() as Array<{ name: string }>) {
        expect(JSON.stringify(db.prepare(`SELECT * FROM ${name}`).all())).not.toContain(dir);
      }
      db.close();
    },
  );

  it("resumes after checkpointing a relevant read call and counts its later result exactly once", async () => {
    const dir = tempDir();
    const skillDir = join(dir, "testing");
    mkdirSync(skillDir);
    const primary = join(skillDir, "SKILL.md");
    writeFileSync(primary, "# Testing\n");
    const trace = join(dir, "resume-read-result.jsonl");
    const call = line({
      type: "message",
      id: "assistant-read",
      timestamp: new Date(now).toISOString(),
      message: {
        role: "assistant",
        content: [
          { type: "toolCall", id: "read-resume", name: "read", arguments: { path: primary } },
        ],
      },
    });
    const result = line({
      type: "message",
      id: "result-read",
      timestamp: new Date(now + 1).toISOString(),
      message: {
        role: "toolResult",
        toolCallId: "read-resume",
        toolName: "read",
        content: [],
        isError: false,
      },
    });
    const header = line({
      type: "session",
      id: "trace-read-resume",
      timestamp: new Date(now - 1).toISOString(),
      cwd: dir,
    });
    writeFileSync(trace, header + call + result);
    const dbPath = join(dir, "usage.db");
    const firstStore = new ResourceUsageStore(dir, { dbPath, now: () => now });
    const controller = new AbortController();
    const record = firstStore.recordBackfillBatch.bind(firstStore);
    let checkpointAfterCall: number | undefined;
    firstStore.recordBackfillBatch = (input) => {
      const written = record(input);
      checkpointAfterCall = input.checkpoint.offset;
      controller.abort();
      return written;
    };
    const primaryCatalog = {
      ...catalog,
      skillPrimaryFiles: new Map([
        [canonicalServerResourcePath(primary), { id: "skill_testing", name: "testing" }],
      ]),
    };

    const interrupted = await new ResourceUsageBackfill(firstStore, {
      now: () => now,
      batchSize: 1,
      signal: controller.signal,
    }).run([source(trace)], primaryCatalog);
    expect(interrupted.cancelled).toBe(true);
    expect(checkpointAfterCall).toBe(Buffer.byteLength(header));
    firstStore.close();

    const resumedStore = new ResourceUsageStore(dir, { dbPath, now: () => now });
    const resumed = new ResourceUsageBackfill(resumedStore, { now: () => now, batchSize: 1 });
    await resumed.run([source(trace)], primaryCatalog);
    await resumed.run([source(trace)], primaryCatalog);

    expect(
      resumedStore.queryEvents({
        subject: { kind: "skill", id: "skill_testing" },
        sinceMs: 0,
        untilMs: Infinity,
      }),
    ).toEqual([
      expect.objectContaining({
        actionId: resourceUsageActionId(
          "oppi",
          "trace-read-resume",
          "skill_instruction_read",
          resourceUsageToolOccurrenceId("read-resume", 1),
        ),
      }),
    ]);
    resumedStore.close();
  });

  it("rewinds the default batch checkpoint for a generic Tool until its lifecycle identity arrives", async () => {
    const dir = tempDir();
    const trace = join(dir, "generic-tool-default-batch.jsonl");
    const dbPath = join(dir, "usage.db");
    const traceId = "trace-generic-default-batch";
    const eventId = `trace-event-v1_${"a".repeat(64)}`;
    const header = line({
      type: "session",
      id: traceId,
      timestamp: new Date(now - 2_000).toISOString(),
      cwd: dir,
    });
    const fillers = Array.from({ length: 499 }, (_, index) =>
      line({
        type: "custom",
        id: `filler-${index}`,
        timestamp: new Date(now - 1_000 + index).toISOString(),
        customType: "oppi-resource-usage",
        data: {
          version: 1,
          actionId: resourceUsageActionId("oppi", traceId, "command_invocation", `filler-${index}`),
          signal: "command_invocation",
          itemName: "review",
          ownerKind: "extension",
          ownerId: "extension_review",
        },
      }),
    ).join("");
    const call = line({
      type: "message",
      id: "assistant-bash",
      timestamp: new Date(now).toISOString(),
      message: {
        role: "assistant",
        content: [{ type: "toolCall", id: "bash-restart", name: "bash", arguments: {} }],
      },
    });
    const marker = line({
      type: "custom",
      id: "lifecycle-bash",
      timestamp: new Date(now + 1).toISOString(),
      customType: "oppi-lifecycle",
      data: {
        version: 2,
        event: "tool_execution_start",
        toolCallId: "bash-restart",
        toolName: "bash",
        eventId,
      },
    });
    writeFileSync(trace, header + fillers + call + marker);

    const sourceInput = source(trace);
    const firstStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
    const controller = new AbortController();
    const record = firstStore.recordBackfillBatch.bind(firstStore);
    let checkpointAfterCall: number | undefined;
    firstStore.recordBackfillBatch = (input) => {
      const written = record(input);
      expect(input.events).toHaveLength(500);
      checkpointAfterCall = input.checkpoint.offset;
      controller.abort();
      return written;
    };

    const interrupted = await new ResourceUsageBackfill(firstStore, {
      now: () => now + 2,
      signal: controller.signal,
    }).run([sourceInput], catalog);
    expect(interrupted.cancelled).toBe(true);
    expect(checkpointAfterCall).toBe(Buffer.byteLength(header + fillers));
    firstStore.close();

    const resumedStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
    const resumedBackfill = new ResourceUsageBackfill(resumedStore, { now: () => now + 2 });
    expect((await resumedBackfill.run([sourceInput], catalog)).completedSources).toBe(1);
    await resumedBackfill.run([sourceInput], catalog);

    expect(
      resumedStore.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([
      expect.objectContaining({
        actionId: resourceUsageActionId("oppi", traceId, "tool_invocation", eventId),
        itemName: "bash",
      }),
    ]);
    resumedStore.close();
  });

  it.each(["call-before-marker", "marker-before-call"] as const)(
    "keeps a checkpointed non-primary read exact with the lifecycle %s",
    async (order) => {
      const dir = tempDir();
      const trace = join(dir, `non-primary-${order}.jsonl`);
      const dbPath = join(dir, "usage.db");
      const traceId = `trace-non-primary-${order}`;
      const eventId = `trace-event-v1_${(order === "call-before-marker" ? "b" : "c").repeat(64)}`;
      const header = line({
        type: "session",
        id: traceId,
        timestamp: new Date(now - 1).toISOString(),
        cwd: dir,
      });
      const call = line({
        type: "message",
        id: `assistant-${order}`,
        timestamp: new Date(now).toISOString(),
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id: "read-reused",
              name: "read",
              arguments: { path: join(dir, "supporting.md") },
            },
          ],
        },
      });
      const marker = line({
        type: "custom",
        id: `marker-${order}`,
        timestamp: new Date(now).toISOString(),
        customType: "oppi-lifecycle",
        data: {
          version: 2,
          event: "tool_execution_start",
          toolCallId: "read-reused",
          toolName: "read",
          eventId,
        },
      });
      const result = line({
        type: "message",
        id: `result-${order}`,
        timestamp: new Date(now + 1).toISOString(),
        message: {
          role: "toolResult",
          toolCallId: "read-reused",
          toolName: "read",
          content: [],
          isError: false,
        },
      });
      writeFileSync(
        trace,
        header + (order === "call-before-marker" ? call + marker : marker + call) + result,
      );

      const sourceInput = source(trace);
      const firstStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
      const controller = new AbortController();
      const record = firstStore.recordBackfillBatch.bind(firstStore);
      firstStore.recordBackfillBatch = (input) => {
        const written = record(input);
        controller.abort();
        return written;
      };
      expect(
        (
          await new ResourceUsageBackfill(firstStore, {
            now: () => now + 2,
            batchSize: 1,
            signal: controller.signal,
          }).run([sourceInput], catalog)
        ).cancelled,
      ).toBe(true);
      firstStore.close();

      const resumedStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
      const resumedBackfill = new ResourceUsageBackfill(resumedStore, {
        now: () => now + 2,
        batchSize: 1,
      });
      expect((await resumedBackfill.run([sourceInput], catalog)).completedSources).toBe(1);
      await resumedBackfill.run([sourceInput], catalog);

      expect(
        resumedStore.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
      ).toEqual([
        expect.objectContaining({
          actionId: resourceUsageActionId("oppi", traceId, "tool_invocation", eventId),
          itemName: "read",
        }),
      ]);
      expect(
        resumedStore.queryEvents({
          subject: { kind: "skill", id: "skill_testing" },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toEqual([]);
      resumedStore.close();
    },
  );

  it("correlates reused and interleaved Tool IDs in both lifecycle orders", async () => {
    const dir = tempDir();
    const trace = join(dir, "reused-tool-lifecycle-order.jsonl");
    const traceId = "trace-reused-tool-lifecycle-order";
    const eventIds = ["d", "e", "f"].map((character) => `trace-event-v1_${character.repeat(64)}`);
    const call = (entryId: string, toolName: string) =>
      line({
        type: "message",
        id: entryId,
        timestamp: new Date(now).toISOString(),
        message: {
          role: "assistant",
          content: [{ type: "toolCall", id: "provider-reused", name: toolName, arguments: {} }],
        },
      });
    const marker = (entryId: string, toolName: string, eventId: string) =>
      line({
        type: "custom",
        id: entryId,
        timestamp: new Date(now + 1).toISOString(),
        customType: "oppi-lifecycle",
        data: {
          version: 2,
          event: "tool_execution_start",
          toolCallId: "provider-reused",
          toolName,
          eventId,
        },
      });
    writeFileSync(
      trace,
      line({
        type: "session",
        id: traceId,
        timestamp: new Date(now - 1).toISOString(),
        cwd: dir,
      }) +
        marker("marker-read-first", "read", eventIds[0]!) +
        call("assistant-read-first", "read") +
        call("assistant-bash", "bash") +
        call("assistant-read-second", "read") +
        marker("marker-read-second", "read", eventIds[2]!) +
        marker("marker-bash", "bash", eventIds[1]!),
    );
    const dbPath = join(dir, "usage.db");
    const sourceInput = source(trace);
    const firstStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
    const controller = new AbortController();
    const record = firstStore.recordBackfillBatch.bind(firstStore);
    let flushes = 0;
    firstStore.recordBackfillBatch = (input) => {
      const written = record(input);
      flushes += 1;
      if (flushes === 2) controller.abort();
      return written;
    };
    expect(
      (
        await new ResourceUsageBackfill(firstStore, {
          now: () => now + 2,
          batchSize: 1,
          signal: controller.signal,
        }).run([sourceInput], catalog)
      ).cancelled,
    ).toBe(true);
    firstStore.close();

    const store = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
    const result = await new ResourceUsageBackfill(store, {
      now: () => now + 2,
      batchSize: 1,
    }).run([sourceInput], catalog);

    expect(result.completedSources).toBe(1);
    expect(
      store
        .queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity })
        .map((event) => event.actionId),
    ).toEqual(
      expect.arrayContaining(
        eventIds.map((eventId) =>
          resourceUsageActionId("oppi", traceId, "tool_invocation", eventId),
        ),
      ),
    );
    expect(
      store.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toHaveLength(3);
    store.close();
  });

  it("leaves an end-of-file Tool call retryable until its lifecycle marker is appended", async () => {
    const dir = tempDir();
    const trace = join(dir, "unresolved-tool-eof.jsonl");
    const dbPath = join(dir, "usage.db");
    const traceId = "trace-unresolved-tool-eof";
    const eventId = `trace-event-v1_${"1".repeat(64)}`;
    const header = line({
      type: "session",
      id: traceId,
      timestamp: new Date(now - 1).toISOString(),
      cwd: dir,
    });
    const call = line({
      type: "message",
      id: "assistant-unresolved",
      timestamp: new Date(now).toISOString(),
      message: {
        role: "assistant",
        content: [{ type: "toolCall", id: "unresolved", name: "bash", arguments: {} }],
      },
    });
    writeFileSync(trace, header + call);
    const sourceInput = source(trace);
    const firstStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });

    const partial = await new ResourceUsageBackfill(firstStore, { now: () => now + 2 }).run(
      [sourceInput],
      catalog,
    );

    expect(partial).toMatchObject({ completedSources: 0, failedSources: 1 });
    expect(firstStore.getBackfillCheckpoint(sourceInput.sourceKey)).toMatchObject({
      offset: Buffer.byteLength(header),
    });
    expect(firstStore.getBackfillCheckpoint(sourceInput.sourceKey)?.completedAt).toBeUndefined();
    firstStore.close();

    writeFileSync(
      trace,
      line({
        type: "custom",
        id: "marker-unresolved",
        timestamp: new Date(now + 1).toISOString(),
        customType: "oppi-lifecycle",
        data: {
          version: 2,
          event: "tool_execution_start",
          toolCallId: "unresolved",
          toolName: "bash",
          eventId,
        },
      }),
      { flag: "a" },
    );
    const resumedStore = new ResourceUsageStore(dir, { dbPath, now: () => now + 2 });
    expect(
      (
        await new ResourceUsageBackfill(resumedStore, { now: () => now + 2 }).run(
          [sourceInput],
          catalog,
        )
      ).completedSources,
    ).toBe(1);
    expect(
      resumedStore.queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity }),
    ).toEqual([
      expect.objectContaining({
        actionId: resourceUsageActionId("oppi", traceId, "tool_invocation", eventId),
      }),
    ]);
    resumedStore.close();
  });

  it("restores occurrence ordinals with the same retention eligibility as uninterrupted replay", async () => {
    const dir = tempDir();
    const primary = join(dir, "testing", "SKILL.md");
    mkdirSync(join(dir, "testing"));
    writeFileSync(primary, "# Testing\n");
    const trace = join(dir, "retention-resume.jsonl");
    const expiredAt = now - 120 * 86_400_000 - 1;
    const header = line({
      type: "session",
      id: "trace-retention-resume",
      timestamp: new Date(expiredAt).toISOString(),
      cwd: dir,
    });
    const call = (id: string, name: string, path: string | undefined, at: number) =>
      line({
        type: "message",
        id: `call-${id}-${at}`,
        timestamp: new Date(at).toISOString(),
        message: {
          role: "assistant",
          content: [
            {
              type: "toolCall",
              id,
              name,
              arguments: path ? { path } : {},
            },
          ],
        },
      });
    const result = (id: string, at: number) =>
      line({
        type: "message",
        id: `result-${id}-${at}`,
        timestamp: new Date(at).toISOString(),
        message: {
          role: "toolResult",
          toolCallId: id,
          toolName: "read",
          content: [],
          isError: false,
        },
      });
    writeFileSync(
      trace,
      header +
        call("reused", "read", primary, expiredAt) +
        result("reused", expiredAt) +
        call("filler", "bash", undefined, now - 2) +
        call("reused", "read", primary, now - 1) +
        result("reused", now),
    );
    const inputCatalog = {
      ...catalog,
      skillPrimaryFiles: new Map([
        [canonicalServerResourcePath(primary), { id: "skill_testing", name: "testing" }],
      ]),
    };
    const sourceInput = source(trace);
    const actionIds = (store: ResourceUsageStore) => ({
      skill: store
        .queryEvents({
          subject: { kind: "skill", id: "skill_testing" },
          sinceMs: 0,
          untilMs: Infinity,
        })
        .map((event) => event.actionId),
      tools: store
        .queryEvents({ subject: { kind: "tools" }, sinceMs: 0, untilMs: Infinity })
        .map((event) => event.actionId),
    });

    const uninterruptedStore = new ResourceUsageStore(dir, {
      dbPath: join(dir, "uninterrupted.db"),
      now: () => now,
    });
    await new ResourceUsageBackfill(uninterruptedStore, { now: () => now, batchSize: 1 }).run(
      [sourceInput],
      inputCatalog,
    );
    const uninterrupted = actionIds(uninterruptedStore);
    uninterruptedStore.close();

    const resumedDbPath = join(dir, "resumed.db");
    const interruptedStore = new ResourceUsageStore(dir, {
      dbPath: resumedDbPath,
      now: () => now,
    });
    const controller = new AbortController();
    const record = interruptedStore.recordBackfillBatch.bind(interruptedStore);
    let flushes = 0;
    interruptedStore.recordBackfillBatch = (input) => {
      const written = record(input);
      flushes += 1;
      if (flushes === 1) controller.abort();
      return written;
    };
    const interrupted = await new ResourceUsageBackfill(interruptedStore, {
      now: () => now,
      batchSize: 1,
      signal: controller.signal,
    }).run([sourceInput], inputCatalog);
    expect(interrupted.cancelled).toBe(true);
    interruptedStore.close();

    const resumedStore = new ResourceUsageStore(dir, { dbPath: resumedDbPath, now: () => now });
    await new ResourceUsageBackfill(resumedStore, { now: () => now, batchSize: 1 }).run(
      [sourceInput],
      inputCatalog,
    );
    const resumed = actionIds(resumedStore);
    expect(resumed.skill).toEqual(uninterrupted.skill);
    expect(resumed.tools).toEqual(uninterrupted.tools);
    expect(resumed.skill).toHaveLength(1);
    expect(resumed.tools).toHaveLength(2);
    resumedStore.close();
  });

  it.each(["durable", "absent", "ambiguous"] as const)(
    "%s sandbox history uses only a journaled random binding token",
    async (mapping) => {
      const dir = tempDir();
      const currentReplacement = join(dir, "current", "testing", "SKILL.md");
      mkdirSync(join(dir, "current", "testing"), { recursive: true });
      writeFileSync(currentReplacement, "# Replacement\n");
      const guestPrimary = "/workspace/review/.pi/skills/testing/SKILL.md";
      const bindingToken = `sandbox-binding-v1_${"a".repeat(64)}`;
      const producerId = resourceUsageToolOccurrenceId("read-sandbox", 1);
      const trace = join(dir, `sandbox-${mapping}.jsonl`);
      writeFileSync(
        trace,
        line({
          type: "session",
          id: `trace-sandbox-${mapping}`,
          timestamp: new Date(now).toISOString(),
          cwd: "/workspace/review",
        }) +
          line({
            type: "message",
            id: "assistant-sandbox",
            timestamp: new Date(now).toISOString(),
            message: {
              role: "assistant",
              content: [
                {
                  type: "toolCall",
                  id: "read-sandbox",
                  name: "read",
                  arguments: { path: guestPrimary },
                },
              ],
            },
          }) +
          line({
            type: "message",
            id: "result-sandbox",
            timestamp: new Date(now + 1).toISOString(),
            message: {
              role: "toolResult",
              toolCallId: "read-sandbox",
              toolName: "read",
              content: [],
              isError: false,
            },
          }) +
          line({
            type: "custom",
            id: "skill-read-marker",
            timestamp: new Date(now + 2).toISOString(),
            customType: "oppi-resource-usage",
            data: {
              version: 3,
              signal: "skill_instruction_read",
              bindingToken,
              producerId,
            },
          }),
      );
      const dbPath = join(dir, "usage.db");
      const store = new ResourceUsageStore(dir, { dbPath, now: () => now });
      const sandboxSource = source(trace);
      if (mapping !== "absent") {
        store.mergeBackfillSkillBindings({
          sourceKey: sandboxSource.sourceKey,
          sessionId: sandboxSource.sessionId,
          workspaceId: sandboxSource.workspaceId,
          bindings: [
            {
              bindingToken,
              skillId: "skill_removed",
              skillName: "removed-skill",
            },
            ...(mapping === "ambiguous"
              ? [
                  {
                    bindingToken,
                    skillId: "skill_replacement",
                    skillName: "testing",
                  },
                ]
              : []),
          ],
        });
      }
      const durableBindings = store.getBackfillSkillBindings(sandboxSource.sourceKey);
      if (mapping === "durable") {
        expect([...durableBindings.keys()]).toEqual([bindingToken]);
      } else {
        expect(durableBindings).toEqual(new Map());
      }
      await new ResourceUsageBackfill(store, { now: () => now }).run(
        [{ ...sandboxSource, sandboxSkillBindings: durableBindings }],
        {
          ...catalog,
          skillPrimaryFiles: new Map([
            [
              canonicalServerResourcePath(currentReplacement),
              { id: "skill_replacement", name: "testing" },
            ],
          ]),
        },
      );

      expect(
        store.queryEvents({
          subject: { kind: "skill", id: "skill_removed" },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toHaveLength(mapping === "durable" ? 1 : 0);
      expect(
        store.queryEvents({
          subject: { kind: "skill", id: "skill_replacement" },
          sinceMs: 0,
          untilMs: Infinity,
        }),
      ).toHaveLength(0);
      store.close();
      const audited = openDatabase(dbPath);
      for (const { name } of audited
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'resource_usage_%'",
        )
        .all() as Array<{ name: string }>) {
        const columns = (
          audited.prepare(`PRAGMA table_info(${name})`).all() as Array<{ name: string }>
        ).map((row) => row.name);
        expect(
          columns.filter((column) => /(^|_)(path|file|cwd|locator)($|_)/i.test(column)),
        ).toEqual([]);
        const rows = JSON.stringify(audited.prepare(`SELECT * FROM ${name}`).all());
        expect(rows).not.toContain(currentReplacement);
        expect(rows).not.toContain(guestPrimary);
        expect(rows).not.toMatch(/\/(?:Users|workspace|private|tmp)\//);
        expect(rows).not.toMatch(/[A-Za-z]:\\/);
        expect(rows).not.toContain("file://");
      }
      audited.close();
    },
  );

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
    ).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ sessionId: "parent", itemName: "read" }),
        expect.objectContaining({ sessionId: "fork", itemName: "read" }),
      ]),
    );
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
