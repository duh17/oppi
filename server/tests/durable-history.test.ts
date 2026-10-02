import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import {
  Harness,
  createRegistry,
  type ConversationId,
  type EntryId,
  type EntryRecord,
  type TaskId,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import type { AssistantMessage, Message } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  readDurableTrace,
  readDurableTracePage,
  readDurableTraceOutline,
} from "../src/durable-history.js";
import { createLiveEntryRendererSet, type TraceEvent } from "../src/trace.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";

const harnesses: Harness[] = [];
afterEach(async () => {
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
});

function assistant(
  text: string,
  stopReason: AssistantMessage["stopReason"],
  tool = false,
): AssistantMessage {
  return {
    role: "assistant",
    content: [
      { type: "text", text },
      ...(tool
        ? [
            {
              type: "toolCall" as const,
              id: "stub-tool",
              name: "bash",
              arguments: { command: "echo output" },
            },
          ]
        : []),
    ],
    api: "faux",
    provider: "faux",
    model: "faux-1",
    timestamp: 1,
    stopReason,
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
  };
}

async function history(options: {
  stopped: boolean;
  tool?: boolean;
  prefix?: number;
  card?: boolean;
}) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-history-"));
  const storage = await openNodeSqliteStorage(join(dir, "history.sqlite"));
  const id = await storage.mintId<ConversationId>();
  const taskId = await storage.mintId<TaskId>();
  const records: EntryRecord[] = [];
  async function append(model: Message[], byTaskId?: TaskId) {
    records.push({
      id: await storage.mintId<EntryId>(),
      conversationId: id,
      kind: `pi.${model[0]!.role}`,
      model,
      ...(byTaskId ? { byTaskId } : {}),
    });
  }
  for (let index = 0; index < (options.prefix ?? 0); index++)
    await append([{ role: "user", content: `older ${index}`, timestamp: index }]);
  await append([assistant("crash stub", "aborted", options.tool)], taskId);
  if (options.tool)
    await append([
      {
        role: "toolResult",
        toolCallId: "stub-tool",
        toolName: "bash",
        content: [{ type: "text", text: "retained result" }],
        isError: false,
        timestamp: 2,
      },
    ]);
  await append([{ role: "user", content: "between one", timestamp: 3 }]);
  await append([{ role: "user", content: "between two", timestamp: 4 }]);
  if (options.card)
    records.push({
      id: await storage.mintId<EntryId>(),
      conversationId: id,
      kind: "transcript-card",
      data: { text: "saved card" },
    });
  await append([assistant("retry", options.stopped ? "aborted" : "stop")], taskId);
  // Seed immutable crash/recovery records through the real storage boundary;
  // no scheduler or simulated page/trace implementation is involved.
  await storage.commit(
    [
      { type: "conversation", value: { id } },
      {
        type: "task",
        value: {
          id: taskId,
          conversationId: id,
          kind: "pi.generation",
          version: 1,
          input: null,
          background: false,
          abortRequested: options.stopped,
          state: {
            status: "terminal",
            outcome: options.stopped
              ? { status: "aborted" }
              : { status: "completed", result: null },
          },
        },
      },
      ...records.map((value) => ({ type: "entry" as const, value })),
    ],
    context,
  );
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const harness = await Harness.open(storage, { models, registry: createRegistry() }, context);
  harnesses.push(harness);
  const conversation = (await harness.conversation(id, context))!;
  vi.spyOn(harness, "conversation").mockResolvedValue(conversation);
  const reads = vi.spyOn(conversation, "entries");
  const resume = vi.spyOn(harness, "resume");
  return { id, harness, reads, resume, records };
}

async function pages(f: Awaited<ReturnType<typeof history>>) {
  const trace: TraceEvent[] = [];
  let cursor: string | undefined;
  do {
    const page = await readDurableTracePage(f.harness, f.id, { targetEvents: 2, cursor });
    expect(page.page.staleCursor).toBe(false);
    expect(page.trace.length).toBeGreaterThan(0);
    trace.unshift(...page.trace);
    cursor = page.page.olderCursor ?? undefined;
  } while (cursor);
  return trace;
}

it.each([false, true])(
  "keeps crash retry history identical across a cursor between attempts (stopped=%s)",
  async (stopped) => {
    const f = await history({ stopped });
    const full = await readDurableTrace(f.harness, f.id, "full");
    expect(full.filter((event) => event.type === "assistant").map((event) => event.text)).toEqual([
      "retry",
    ]);
    expect(await pages(f)).toEqual(full);
    expect(f.resume).not.toHaveBeenCalled();
  },
);

it("retains a hidden stub's tool result without scanning the whole newest history", async () => {
  const f = await history({ stopped: true, tool: true, prefix: 2000 });
  const newest = await readDurableTracePage(f.harness, f.id, { targetEvents: 2 });
  expect(newest.trace.map((event) => event.text)).toEqual(["between two", "retry"]);
  expect(f.reads).toHaveBeenCalledTimes(2);
  expect(f.reads.mock.results.filter((result) => result.type === "return")).toHaveLength(2);
  const rowCounts = await Promise.all(
    f.reads.mock.results.map(async (result) => (await result.value).items.length),
  );
  expect(rowCounts.reduce((a, b) => a + b, 0)).toBeLessThanOrEqual(33);
  const full = await readDurableTrace(f.harness, f.id, "full");
  const result = full.find((event) => event.type === "toolResult");
  expect(result).toMatchObject({ toolCallId: "stub-tool", output: "retained result" });
  expect(await pages(f)).toEqual(full);
  expect(f.resume).not.toHaveBeenCalled();
});

it("uses the same renderer set for cards and invalidates cursors when its version changes", async () => {
  const f = await history({ stopped: true, card: true });
  const entryRenderers = createLiveEntryRendererSet([
    ["transcript-card", () => ({ render: () => ["saved card"] })],
  ]);
  const full = await readDurableTrace(f.harness, f.id, "full", entryRenderers);
  const page = await readDurableTracePage(f.harness, f.id, { targetEvents: 2, entryRenderers });
  const outline = await readDurableTraceOutline(
    f.harness,
    f.id,
    new MobileRendererRegistry(),
    entryRenderers,
  );
  expect(full.some((event) => event.presentation?.kind === "custom")).toBe(true);
  expect(page.trace).toEqual(full.slice(-2));
  expect(outline.outline.entries.some((entry) => entry.kind === "custom")).toBe(true);
  expect(page.page.traceVersion).toContain(`:r${entryRenderers.version}`);
  expect(outline.outline.traceVersion).toBe(page.page.traceVersion);
  const changed = createLiveEntryRendererSet([
    ["transcript-card", () => ({ render: () => ["new card renderer"] })],
  ]);
  const stale = await readDurableTracePage(f.harness, f.id, {
    cursor: page.page.olderCursor!,
    entryRenderers: changed,
  });
  expect(stale.page.staleCursor).toBe(true);
});
