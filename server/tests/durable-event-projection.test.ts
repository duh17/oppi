import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import {
  fauxAssistantMessage,
  fauxProvider,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import {
  Harness,
  MemoryStorage,
  createRegistry,
  watchEvents,
  type AgentEvent,
  type HarnessSettings,
} from "@earendil-works/pi-durable";
import { DurableEventProjection } from "../src/durable-event-projection.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";

const harnesses: Harness[] = [];
afterEach(async () => {
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
  vi.restoreAllMocks();
});

function heldAnswer(text: string) {
  let entered!: () => void;
  let release!: () => void;
  const started = new Promise<void>((resolve) => {
    entered = resolve;
  });
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  const response: FauxResponseStep = async (_transcript, options) => {
    entered();
    await Promise.race([
      held,
      new Promise<void>((_resolve, reject) => {
        options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
          once: true,
        });
      }),
    ]);
    return fauxAssistantMessage(text);
  };
  return { response, started, release };
}

async function fixture(responses: FauxResponseStep[], settings: HarnessSettings) {
  const faux = fauxProvider({ tokensPerSecond: 2000, tokenSize: { min: 16, max: 16 } });
  faux.setResponses(responses);
  const models = createModels();
  models.setProvider(faux.provider);
  const harness = await Harness.open(
    new MemoryStorage(),
    { models, registry: createRegistry(), settings },
    context,
  );
  harnesses.push(harness);
  const conversation = await harness.root(context, {
    agent: { model: { provider: "faux", modelId: "faux-1" } },
  });
  const projection = new DurableEventProjection(harness, () => settings.retry ?? {});
  const stream = await watchEvents(harness, conversation.id, context);
  projection.snapshot(stream.snapshot, false);
  const ctx: TranslationContext = {
    sessionId: "projection-proof",
    mobileRenderers: new MobileRendererRegistry(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
  };
  const messages = [] as ReturnType<typeof translatePiEvent>;
  const pending = new Set<{
    predicate: (events: readonly AgentEvent[]) => boolean;
    resolve: () => void;
  }>();
  stream.start(async (events) => {
    const projected = await projection.batch(events);
    messages.push(...projected.flatMap((event) => translatePiEvent(event, ctx)));
    for (const waiter of pending)
      if (waiter.predicate(events)) {
        pending.delete(waiter);
        waiter.resolve();
      }
  });
  const next = (predicate: (events: readonly AgentEvent[]) => boolean) =>
    new Promise<void>((resolve, reject) => {
      const waiter = {
        predicate,
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
      };
      const timer = setTimeout(() => {
        pending.delete(waiter);
        reject(
          new Error(
            `Missing watch batch; projected ${messages.map((message) => message.type).join(",")}`,
          ),
        );
      }, 6000);
      pending.add(waiter);
    });
  const answer = async (text: string) => {
    const end = next((events) => events.some((event) => event.type === "run_end"));
    await conversation.submit({ type: "input", content: text }, context);
    await end;
  };
  const snapshot = async () => {
    const tap = await watchEvents(harness, conversation.id, context);
    const value = tap.snapshot;
    await tap.stop();
    return value;
  };
  return { harness, conversation, projection, stream, messages, ctx, next, answer, snapshot };
}

const compaction = { enabled: true, keepRecentTokens: 1, reserveTokens: 100, backgroundTokens: 0 };

describe("durable watch projection", () => {
  it.each(["success", "failed", "aborted"] as const)(
    "closes a %s compaction exactly once when a real watch backlog swallows its receipt",
    async (outcome) => {
      const summary = heldAnswer(outcome === "failed" ? "" : "Summary recovered from backlog");
      const nextRun = heldAnswer("Answer after backlog");
      const f = await fixture(
        [
          fauxAssistantMessage("Earlier context ".repeat(50)),
          fauxAssistantMessage("Recent"),
          outcome === "failed"
            ? async (transcript, options) => {
                await summary.response(transcript, options);
                return fauxAssistantMessage("", {
                  stopReason: "error",
                  errorMessage: "summary provider failed",
                });
              }
            : summary.response,
          nextRun.response,
        ],
        { compaction, retry: { enabled: false } },
      );
      await f.answer("first");
      await f.answer("second");
      const tap = await watchEvents(f.harness, f.conversation.id, context);
      const projection = new DurableEventProjection(f.harness, () => ({}));
      projection.snapshot(tap.snapshot, false);
      let started!: () => void;
      let unblock!: () => void;
      let replaced!: () => void;
      const start = new Promise<void>((resolve) => (started = resolve));
      const blocked = new Promise<void>((resolve) => (unblock = resolve));
      const replacement = new Promise<void>((resolve) => (replaced = resolve));
      const delivered: AgentEvent[] = [];
      const messages = [] as ReturnType<typeof translatePiEvent>;
      tap.start(async (events) => {
        delivered.push(...events);
        messages.push(
          ...(await projection.batch(events)).flatMap((event) => translatePiEvent(event, f.ctx)),
        );
        if (events.some((event) => event.type === "compaction_start")) {
          started();
          await blocked;
        }
        if (events.some((event) => event.type === "snapshot")) replaced();
      });
      try {
        const taskId = await f.conversation.compact(undefined, context);
        await Promise.all([start, summary.started]);
        if (outcome === "aborted") await f.harness.abortTask(taskId, context);
        else summary.release();
        const task = await f.harness.waitForTask(taskId, context);
        expect(task.state.outcome.status).toBe(outcome === "success" ? "completed" : outcome);
        await f.conversation.submit({ type: "input", content: "new run" }, context);
        await nextRun.started;
        // The real CommittedWatch replaces >100 undelivered publications. Hold
        // its consumer after start so the terminal receipt is among those lost.
        for (let index = 0; index < 101; index++)
          await f.conversation.configure({ instructions: `backlog-${index}` }, context);
        unblock();
        await replacement;
        expect(delivered.some((event) => event.type === "compaction_end")).toBe(false);
        const snapshot = delivered.find((event) => event.type === "snapshot")!;
        expect(snapshot.compactions).toEqual([]);
        expect(snapshot.run).toBeDefined();
        const ends = messages.filter((message) => message.type === "compaction_end");
        expect(ends).toHaveLength(1);
        expect(messages.findIndex((message) => message.type === "compaction_end")).toBeLessThan(
          messages.findIndex((message) => message.type === "agent_start"),
        );
        if (outcome === "success") {
          expect(ends[0]).toMatchObject({
            aborted: false,
            summary: "Summary recovered from backlog",
          });
          expect(ends[0]!.tokensBefore).toBeGreaterThan(0);
        } else if (outcome === "failed") {
          expect(ends[0]).toMatchObject({
            aborted: false,
            errorMessage: "Summarization failed: summary provider failed",
          });
        } else expect(ends[0]).toMatchObject({ aborted: true });
        expect(
          (await projection.batch([snapshot])).filter((event) => event.type === "compaction_end"),
        ).toEqual([]);
      } finally {
        unblock();
        await tap.stop();
        await f.conversation.abort(context);
        await f.stream.stop();
      }
    },
    10000,
  );

  it("does not read queued summary receipts on pure partial-update batches", async () => {
    const held = heldAnswer("Streaming body ".repeat(1500));
    const f = await fixture(
      [
        fauxAssistantMessage("Earlier context ".repeat(50)),
        fauxAssistantMessage("Recent"),
        held.response,
        fauxAssistantMessage("Queued summary"),
      ],
      { compaction },
    );
    await f.answer("first");
    await f.answer("second");
    await f.conversation.submit(
      { type: "input", content: "stream after summary is queued" },
      context,
    );
    await held.started;
    const finishedCompact = f.next((events) =>
      events.some((event) => event.type === "compaction_end"),
    );
    const taskId = await f.conversation.compact(undefined, context);
    await f.harness.waitForTask(taskId, context);
    await finishedCompact;
    expect(f.messages.filter((message) => message.type === "compaction_end")).toHaveLength(0);
    const reads = vi.spyOn(f.harness, "submission");
    const partialOnly = (events: readonly AgentEvent[]) =>
      events.some((event) => event.type === "message_update") &&
      events.every((event) => event.type === "message_start" || event.type === "message_update");
    const first = f.next(partialOnly);
    held.release();
    await first;
    await f.next(partialOnly);
    await f.next(partialOnly);
    expect(reads).not.toHaveBeenCalled();
    await f.conversation.abort(context);
    await f.stream.stop();
  });

  it("does not re-emit retry or compaction starts after a backlog snapshot", async () => {
    const summary = heldAnswer("Summary after hold");
    const f = await fixture(
      [
        fauxAssistantMessage("Earlier context ".repeat(50)),
        fauxAssistantMessage("Recent"),
        summary.response,
        fauxAssistantMessage("", { stopReason: "error", errorMessage: "429 overloaded" }),
      ],
      { compaction, retry: { enabled: true, maxRetries: 1, baseDelayMs: 20000 } },
    );
    await f.answer("first");
    await f.answer("second");
    await f.conversation.compact(undefined, context);
    await summary.started;
    const retry = f.next((events) => events.some((event) => event.type === "auto_retry_start"));
    await f.conversation.submit({ type: "input", content: "retry while compacting" }, context);
    await retry;
    expect(f.messages.filter((message) => message.type === "retry_start")).toHaveLength(1);
    expect(f.messages.filter((message) => message.type === "compaction_start")).toHaveLength(1);
    const snapshot = await f.snapshot();
    expect(snapshot.compactions).toHaveLength(1);
    expect(snapshot.generation?.retry).toBeDefined();
    const replay = (await f.projection.batch([snapshot])).flatMap((event) =>
      translatePiEvent(event, f.ctx),
    );
    expect(
      replay.filter(
        (message) => message.type === "retry_start" || message.type === "compaction_start",
      ),
    ).toEqual([]);
    await f.conversation.abort(context);
    await f.stream.stop();
  });

  it("does not duplicate a committed partial when the same live snapshot is replayed", async () => {
    const f = await fixture([fauxAssistantMessage("Snapshot partial ".repeat(1500))], {
      compaction: { enabled: false },
    });
    const partial = f.next((events) => events.some((event) => event.type === "message_update"));
    await f.conversation.submit({ type: "input", content: "stream" }, context);
    await partial;
    const snapshot = await f.snapshot();
    expect(snapshot.generation?.message).toBeDefined();
    const projection = new DurableEventProjection(f.harness, () => ({}));
    const initial = projection
      .snapshot(snapshot, false)
      .flatMap((event) => translatePiEvent(event, f.ctx));
    expect(initial.some((message) => message.type === "text_delta")).toBe(true);
    const replay = (await projection.batch([snapshot])).flatMap((event) =>
      translatePiEvent(event, f.ctx),
    );
    expect(
      replay.filter((message) => message.type === "text_delta" || message.type === "agent_start"),
    ).toEqual([]);
    await f.next((events) => events.some((event) => event.type === "message_update"));
    const advanced = await f.snapshot();
    const text = (value: typeof snapshot) =>
      value
        .generation!.message!.content.flatMap((block) =>
          block.type === "text" ? [block.text] : [],
        )
        .join("");
    expect(text(advanced).length).toBeGreaterThan(text(snapshot).length);
    const additions = (await projection.batch([advanced])).flatMap((event) =>
      translatePiEvent(event, f.ctx),
    );
    const delta = additions
      .flatMap((message) => (message.type === "text_delta" ? [message.delta] : []))
      .join("");
    expect(delta).toBe(text(advanced).slice(text(snapshot).length));
    expect(additions.some((message) => message.type === "agent_start")).toBe(false);
    await f.conversation.abort(context);
    await f.stream.stop();
  });
});
