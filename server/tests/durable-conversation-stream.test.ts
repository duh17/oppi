import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { applyImmutable, type Op } from "@earendil-works/chord/delta";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import {
  Harness,
  createRegistry,
  defineExtension,
  defineTask,
  type Conversation,
  type EntryId,
  type Extension,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import {
  DurableInputCards,
  DurableUI,
  DurableUIClientDoc,
} from "../extensions/durable/durable-ui.js";
import {
  CONVERSATION_SNAPSHOT_LIMIT,
  attachConversationStream,
  readOlderConversationEntries,
  type ConversationStreamSubscription,
} from "../src/durable-conversation-stream.js";
import { readDurableTrace } from "../src/durable-history.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import type { ConversationEntryView, ConversationStreamServerMessage } from "../src/types.js";
import {
  conversationReference,
  shownEntries,
  upsertEntries,
} from "./harness/conversation-stream-reference.js";

const harnesses = new Set<Harness>();
const subscriptions = new Set<ConversationStreamSubscription>();
afterEach(async () => {
  for (const subscription of subscriptions) subscription.dispose();
  subscriptions.clear();
  await Promise.all([...harnesses].map((harness) => harness.close(context)));
  harnesses.clear();
});

const LONG_ANSWER = Array.from({ length: 40 }, (_, index) => `word${index}`).join(" ");

async function fixture(
  responses: FauxResponseStep[],
  options?: { slow?: boolean; extensions?: Extension[] },
) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-conversation-stream-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider(
    options?.slow ? { tokensPerSecond: 60, tokenSize: { min: 3, max: 3 } } : {},
  );
  faux.setResponses(responses);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  const registry = createRegistry();
  registry.install(CodingTools);
  for (const extension of options?.extensions ?? []) registry.install(extension);
  const open = async () => {
    const opened = await Harness.open(
      await openNodeSqliteStorage(join(dir, "stream.sqlite")),
      {
        models,
        registry,
        env: () => new NodeExecutionEnv({ cwd: dir }),
        settings: { compaction: { enabled: false } },
      },
      context,
    );
    harnesses.add(opened);
    return opened;
  };
  const harness = await open();
  const conversation = await harness.createConversation(
    {
      ownership: { kind: "ownerless" },
      agent: {
        model: { provider: "faux", modelId: "faux-1" },
        tools: [...(CodingTools.tools ?? [])],
        cwd: dir,
      },
    },
    context,
  );
  return { harness, conversation, faux, open };
}

type Frame = ConversationStreamServerMessage & { receivedAt: number };

/** A client: wire-roundtripped frames applied to a replica the way the iOS step will. */
class Client {
  readonly frames: Frame[] = [];
  entries: ConversationEntryView[] = [];
  docs: Record<string, unknown> = {};
  head = 0;
  subscription!: ConversationStreamSubscription;

  apply(frame: ConversationStreamServerMessage): void {
    if (frame.type === "snapshot") {
      this.entries = [...frame.entries];
      this.docs = { ...frame.docs };
      this.head = frame.head;
      return;
    }
    if (frame.type === "older") {
      this.entries = [...frame.entries, ...this.entries];
      return;
    }
    this.entries = upsertEntries(this.entries, this.head, frame.entries ?? []);
    for (const [kind, ops] of Object.entries(frame.docs ?? {})) {
      if (ops === null) delete this.docs[kind];
      else this.docs[kind] = applyImmutable(this.docs[kind], ops as Op[]);
    }
  }

  get tip(): number {
    return Math.max(0, ...this.entries.map((entry) => entry.id));
  }

  live(): Record<string, unknown> | undefined {
    return this.docs["pi.live"] as Record<string, unknown> | undefined;
  }
}

async function attach(
  f: { harness: Harness; conversation: Conversation },
  afterEntryId?: number,
  client = new Client(),
): Promise<Client> {
  client.subscription = await attachConversationStream({
    harness: f.harness,
    conversationId: f.conversation.id,
    renderers: new MobileRendererRegistry(),
    ...(afterEntryId !== undefined ? { afterEntryId } : {}),
    send: (frame) => {
      const wire = JSON.parse(JSON.stringify(frame)) as ConversationStreamServerMessage;
      client.frames.push({ ...wire, receivedAt: Date.now() });
      client.apply(wire);
    },
  });
  subscriptions.add(client.subscription);
  return client;
}

async function prompt(conversation: Conversation, content: string): Promise<void> {
  const submission = await conversation.submit({ type: "input", content }, context);
  expect((await submission.wait(context)).status).toBe("done");
  await conversation.waitForIdle(context);
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 300));

/** Every replica must converge to the conversation as the Harness reads it, without a room. */
async function expectConverged(
  f: { harness: Harness; conversation: Conversation },
  client: Client,
): Promise<void> {
  const reference = await conversationReference(
    f.harness,
    f.conversation.id,
    new MobileRendererRegistry(),
  );
  expect(shownEntries(client.entries)).toEqual(reference.entries);
  expect(client.docs).toEqual(reference.docs);
  expect(client.head).toBe(reference.head);
}

/** Entry ids the trace shows as cards, and every entry id it shows. */
async function traceCards(f: { harness: Harness; conversation: Conversation }) {
  const trace = await readDurableTrace(f.harness, f.conversation.id, "full");
  return {
    cards: trace.filter((event) => event.presentation).map((event) => Number(event.id)),
    ids: new Set(trace.map((event) => Number(/^(?:result-)?(\d+)/.exec(event.id)?.[1]))),
  };
}

function wire(frame: ConversationStreamServerMessage): ConversationStreamServerMessage {
  return JSON.parse(JSON.stringify(frame)) as ConversationStreamServerMessage;
}

function liveTextOps(frame: Frame): Op[] {
  if (frame.type !== "update") return [];
  const ops = (frame.docs?.["pi.live"] ?? []) as Op[];
  return ops.filter((op) => op.length >= 2 && Array.isArray(op[1]) && op[1].at(-1) === "text");
}

describe("durable conversation stream", { timeout: 30_000 }, () => {
  it("streams grown text as append ops and lands the answer with the live clear in one frame", async () => {
    const f = await fixture([fauxAssistantMessage(LONG_ANSWER)], { slow: true });
    const client = await attach(f);
    expect(client.frames[0]).toMatchObject({ type: "snapshot", head: 0, hasOlder: false });
    // Pi's private provider state never reaches clients.
    expect(Object.keys(client.docs).sort()).toEqual([
      "pi.agent",
      "pi.inbox",
      "pi.live",
      "pi.usage",
    ]);

    await prompt(f.conversation, "stream please");
    await settle();

    const appends = client.frames.flatMap(liveTextOps).filter((op) => op[0] === "a");
    expect(appends.length).toBeGreaterThanOrEqual(2);
    // Once the text exists, growth never resends it whole.
    const textSets = client.frames.flatMap(liveTextOps).filter((op) => op[0] === "s");
    expect(textSets).toEqual([]);

    // Replay frame by frame: the answer entry appears in exactly the frame that clears
    // the streaming partial, so there is never a gap or a duplicate.
    const replay = new Client();
    let landed = 0;
    for (const frame of client.frames) {
      const hadPartial = Boolean(replay.live()?.generation);
      const hadAnswer = replay.entries.some((entry) => entry.kind === "pi.assistant");
      replay.apply(frame);
      const hasPartial = Boolean(replay.live()?.generation);
      const hasAnswer = replay.entries.some((entry) => entry.kind === "pi.assistant");
      if (hadPartial && !hasPartial) {
        expect(hasAnswer && !hadAnswer).toBe(true);
        landed += 1;
      }
      if (hasAnswer && !hadAnswer) expect(hadPartial && !hasPartial).toBe(true);
    }
    expect(landed).toBe(1);
    const answer = client.entries.find((entry) => entry.kind === "pi.assistant");
    expect(JSON.stringify(answer?.model)).toContain("word39");

    // Coalesced: updates are at least one frame interval apart.
    const updates = client.frames.filter((frame) => frame.type === "update");
    for (let index = 1; index < updates.length; index += 1)
      expect(updates[index]!.receivedAt - updates[index - 1]!.receivedAt).toBeGreaterThanOrEqual(
        95,
      );
    await expectConverged(f, client);
  });

  it("decorates committed and live tool calls with renderer segments", async () => {
    const f = await fixture([
      // Slow enough that the running round reaches a frame.
      fauxAssistantMessage(
        [fauxToolCall("bash", { command: "sleep 0.4; echo streamed" }, { id: "call-1" })],
        {
          stopReason: "toolUse",
        },
      ),
      fauxAssistantMessage("done"),
    ]);
    const client = await attach(f);
    await prompt(f.conversation, "run it");
    await settle();

    const call = client.entries.find((entry) => entry.toolCalls?.["call-1"]);
    expect(call?.kind).toBe("pi.assistant");
    expect(JSON.stringify(call?.toolCalls?.["call-1"]?.callSegments)).toContain("echo streamed");
    const result = client.entries.find((entry) => entry.kind === "pi.tool-result");
    expect(result?.toolResult?.outputAvailability).toBeDefined();
    expect(result).not.toHaveProperty("conversationId");
    expect(result).not.toHaveProperty("byTaskId");
    // The running round named the call with the same presentation as the committed entry.
    const replay = new Client();
    const liveCalls = [];
    for (const frame of client.frames) {
      replay.apply(frame);
      const toolCalls = replay.live()?.toolCalls as Record<string, unknown> | undefined;
      if (toolCalls?.["call-1"]) liveCalls.push(toolCalls["call-1"]);
    }
    expect(liveCalls[0]).toEqual(call?.toolCalls?.["call-1"]);
    await expectConverged(f, client);
  });

  it("resumes after a disconnect mid-turn with the missing entries and no snapshot", async () => {
    const f = await fixture(
      [fauxAssistantMessage("first answer"), fauxAssistantMessage(LONG_ANSWER)],
      { slow: true },
    );
    const first = await attach(f);
    await prompt(f.conversation, "one");
    await settle();
    const cursor = first.tip;
    expect(cursor).toBeGreaterThan(0);

    // Disconnect after the second turn starts streaming.
    const streamed = first.frames.length;
    const running = prompt(f.conversation, "two");
    await expect
      .poll(() => first.frames.slice(streamed).some((frame) => liveTextOps(frame).length > 0), {
        timeout: 15_000,
      })
      .toBe(true);
    first.subscription.dispose();
    const before = first.frames.length;
    const heldTip = first.tip;
    expect(heldTip).toBeGreaterThan(cursor);
    await running;
    await settle();
    expect(first.frames).toHaveLength(before);

    const resumed = await attach(f, heldTip, first);
    expect(resumed.frames).toHaveLength(before + 1);
    const frame = resumed.frames[before];
    expect(frame?.type).toBe("update");
    // The prompt's user entry arrived before the disconnect; only the answer is missing.
    const missing = frame?.type === "update" ? (frame.entries ?? []) : [];
    expect(missing.map((entry) => entry.kind)).toEqual(["pi.assistant"]);
    expect(missing.every((entry) => entry.id > heldTip)).toBe(true);
    // Documents are resent whole because the client's copies are unknown.
    expect(frame?.type === "update" && frame.docs?.["pi.live"]?.[0]?.[0]).toBe("r");
    await expectConverged(f, resumed);
  });

  it("sends a snapshot when the head moves and for cursors before the head or unknown", async () => {
    const f = await fixture([fauxAssistantMessage("one"), fauxAssistantMessage("two")]);
    const client = await attach(f);
    await prompt(f.conversation, "first");
    await settle();
    const stale = client.tip;
    expect(stale).toBeGreaterThan(0);
    await prompt(f.conversation, "second");
    await settle();
    const kept = client.entries.find((entry) => entry.id > stale)!.id;

    await f.conversation.commit(async (tx) => {
      await tx.appendEntry(f.conversation.id, {
        kind: "pi.compaction",
        head: kept as EntryId,
        model: [{ role: "user", content: "<summary>first</summary>", timestamp: 1 }],
      });
    }, context);
    await settle();
    const snapshot = client.frames.at(-1)!;
    expect(snapshot.type).toBe("snapshot");
    if (snapshot.type !== "snapshot") return;
    expect(snapshot.entries[0]?.kind).toBe("pi.compaction");
    expect(snapshot.head).toBe(snapshot.entries[0]?.id);
    expect(snapshot.hasOlder).toBe(true);
    expect(snapshot.entries.slice(1).every((entry) => entry.id >= kept)).toBe(true);

    expect((await attach(f, stale)).frames[0]?.type).toBe("snapshot");
    expect((await attach(f, 999_999)).frames[0]?.type).toBe("snapshot");
    const current = await attach(f, client.tip);
    expect(current.frames[0]).toMatchObject({ type: "update", entries: [] });
    await expectConverged(f, client);
  });

  it("loads a closed room's successor with the head marker and the entries it keeps", async () => {
    const f = await fixture([fauxAssistantMessage("one"), fauxAssistantMessage("two")]);
    const live = await attach(f);
    await prompt(f.conversation, "first");
    await prompt(f.conversation, "second");
    await settle();
    // Compaction keeps the second turn, whose ids are below the compaction entry's.
    const kept = live.entries.filter((entry) => entry.kind === "pi.user").at(-1)!.id;
    await f.conversation.commit(async (tx) => {
      await tx.appendEntry(f.conversation.id, {
        kind: "pi.compaction",
        head: kept as EntryId,
        model: [{ role: "user", content: "<summary>first</summary>", timestamp: 1 }],
      });
    }, context);
    await settle();
    const ids = live.entries.map((entry) => entry.id);
    expect(ids.length).toBeGreaterThan(2);
    expect(ids.slice(1).every((id) => id >= kept && id < live.head)).toBe(true);

    // The last subscriber leaving closes the room; the next attach loads a new one.
    live.subscription.dispose();
    const cold = await attach(f);
    expect(cold.frames[0]).toMatchObject({ type: "snapshot", head: live.head, hasOlder: true });
    expect(cold.entries.map((entry) => entry.id)).toEqual(ids);
    await expectConverged(f, cold);

    // A reset keeps nothing before it; the entries after it are kept.
    const reset = await f.conversation.commit(async (tx) => {
      const marker = await tx.appendEntry(f.conversation.id, {
        kind: "pi.reset",
        head: "self",
        model: [{ role: "user", content: "fresh start", timestamp: 2 }],
      });
      await tx.appendEntry(f.conversation.id, {
        kind: "pi.user",
        model: [{ role: "user", content: "after reset", timestamp: 3 }],
      });
      return marker.id;
    }, context);
    cold.subscription.dispose();
    const afterReset = await attach(f);
    expect(afterReset.head).toBe(reset);
    expect(afterReset.entries.map((entry) => entry.kind)).toEqual(["pi.reset", "pi.user"]);
    await expectConverged(f, afterReset);
  });

  it("fails an attach whose room closes while it loads, without retrying it", async () => {
    const f = await fixture([]);
    let reached!: () => void;
    const atGate = new Promise<void>((resolve) => (reached = resolve));
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    // Holds the room's last load read (the extension UI document) until the Harness closed.
    const gated = new Proxy(f.harness, {
      get(target, property) {
        if (property === "snapshot")
          return async (...args: Parameters<Harness["snapshot"]>) => {
            const value = await target.snapshot(...args);
            if (args[0] === DurableUIClientDoc.doc) {
              reached();
              await gate;
            }
            return value;
          };
        const value: unknown = Reflect.get(target, property, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    const attaching = attach({ harness: gated, conversation: f.conversation });
    await atGate;
    const closing = f.harness.close(context);
    release();
    await expect(attaching).rejects.toThrow("closed while it loaded");
    await closing;
  });

  it("replicates only client-visible documents, projected for clients", async () => {
    const f = await fixture([]);
    const client = await attach(f);
    await f.conversation.commit(async (tx) => {
      const ui = await tx.doc(DurableUI, f.conversation.id);
      ui.requests.open = {
        taskId: 7 as never,
        request: { id: "open", method: "confirm", title: "Proceed?" },
      };
      ui.requests.answered = {
        taskId: 8 as never,
        request: { id: "answered", method: "confirm", title: "Done?" },
        response: { id: "answered", confirmed: true },
      };
      ui.notifications.status = {
        id: "status",
        method: "setStatus",
        statusKey: "k",
        statusText: "busy",
      };
      const cards = await tx.doc(DurableInputCards, f.conversation.id);
      cards.requests.secret = { title: "private", at: 1 } as never;
    }, context);
    await settle();
    expect(Object.keys(client.docs).sort()).toEqual([
      "oppi.extension-ui",
      "pi.agent",
      "pi.inbox",
      "pi.live",
      "pi.usage",
    ]);
    expect(client.docs["oppi.extension-ui"]).toEqual({
      requests: { open: { id: "open", method: "confirm", title: "Proceed?" } },
      notifications: {
        status: { id: "status", method: "setStatus", statusKey: "k", statusText: "busy" },
      },
    });
    await expectConverged(f, client);
  });

  it("ends the room instead of sending undecided presentation when a pass fails", async () => {
    const f = await fixture([fauxAssistantMessage("ack")]);
    const id = f.conversation.id;
    let lost = 0;
    const client = new Client();
    client.subscription = await attachConversationStream({
      harness: f.harness,
      conversationId: id,
      renderers: new MobileRendererRegistry(),
      send: (frame) => client.apply(wire(frame)),
      onLost: () => (lost += 1),
    });
    subscriptions.add(client.subscription);
    await f.conversation.commit(async (tx) => {
      const cards = await tx.doc(DurableInputCards, id);
      cards.requests["job-1"] = { title: "Background job 1", at: 1 };
    }, context);
    await settle();
    // The input-card read of the next pass fails, as a store error would.
    const snapshot = f.harness.snapshot.bind(f.harness);
    let failed = false;
    vi.spyOn(f.harness, "snapshot").mockImplementation(((doc, conversationId, ctx) => {
      if (doc === DurableInputCards && !failed) {
        failed = true;
        return Promise.reject(new Error("store busy"));
      }
      return snapshot(doc, conversationId, ctx);
    }) as typeof f.harness.snapshot);
    const submission = await f.conversation.submit(
      { type: "input", content: "raw job output", requestId: "job-1" },
      context,
    );
    await submission.wait(context);
    await f.conversation.waitForIdle(context);
    await settle();

    expect(failed).toBe(true);
    expect(lost).toBe(1);
    // The raw extension input never reached the client.
    expect(JSON.stringify(client.entries)).not.toContain("raw job output");
    // Re-attaching from the cursor, as SessionHost does, shows it as its card.
    const resumed = await attach(f, client.tip, client);
    expect(resumed.entries.find((entry) => entry.inputCard)?.card?.title).toBe("Background job 1");
    await expectConverged(f, resumed);
  });

  it("shows input and display cards like trace history, including card metadata that lands late", async () => {
    const f = await fixture([fauxAssistantMessage("ack one"), fauxAssistantMessage("ack two")]);
    const client = await attach(f);
    const id = f.conversation.id;
    const at = 1_791_650_000_000;
    const display = await f.conversation.commit(async (tx) => {
      const entry = await tx.appendEntry(id, {
        kind: "oppi.notice",
        data: { card: { title: "  Job done ", body: "ok", accent: "success", at }, extra: 1 },
      });
      // Not a card: the trace shows nothing for it, and the stream adds no card.
      await tx.appendEntry(id, { kind: "oppi.notice", data: { card: { title: "" } } });
      return entry.id;
    }, context);
    // Extension-generated input: metadata first, as producers publish it.
    await f.conversation.commit(async (tx) => {
      const cards = await tx.doc(DurableInputCards, id);
      cards.requests["job-1"] = {
        title: "Background job 1",
        output: { kind: "terminal", offset: 0, length: 5, command: "make" },
        at,
      };
    }, context);
    const first = await f.conversation.submit(
      { type: "input", content: "hello from the job", requestId: "job-1" },
      context,
    );
    await first.wait(context);
    await f.conversation.waitForIdle(context);
    // A late card still applies to the input it names.
    const second = await f.conversation.submit(
      { type: "input", content: "second job output", requestId: "job-2" },
      context,
    );
    await second.wait(context);
    await f.conversation.waitForIdle(context);
    await settle();
    const plain = client.entries.find(
      (entry) =>
        entry.kind === "pi.user" && (JSON.stringify(entry.model) ?? "").includes("second job"),
    )!;
    expect(plain.card).toBeUndefined();
    const sent = client.frames.length;
    await f.conversation.commit(async (tx) => {
      const cards = await tx.doc(DurableInputCards, id);
      cards.requests["job-2"] = { title: "Background job 2", at: at + 1 };
    }, context);
    await settle();

    // Only the sanitized card leaves the server, never the entry's raw data.
    expect(client.entries.find((entry) => entry.id === display)).toEqual({
      id: display,
      kind: "oppi.notice",
      card: { kind: "custom", title: "Job done", body: "ok", accent: "success", at },
    });
    const inputs = client.entries.filter((entry) => entry.inputCard);
    expect(inputs).toEqual([
      {
        id: expect.any(Number),
        kind: "pi.user",
        card: {
          kind: "custom",
          title: "Background job 1",
          output: { kind: "terminal", offset: 0, length: 5, command: "make" },
          at,
        },
        inputCard: true,
      },
      {
        id: plain.id,
        kind: "pi.user",
        card: { kind: "custom", title: "Background job 2", at: at + 1 },
        inputCard: true,
      },
    ]);
    // The late card arrived as an upsert of the entry the client already held.
    const restated = client.frames
      .slice(sent)
      .flatMap((frame) => (frame.type === "update" ? (frame.entries ?? []) : []));
    expect(restated.map((entry) => entry.id)).toEqual([plain.id]);
    // The trace shows exactly these entries as cards.
    const { cards } = await traceCards(f);
    expect(cards.sort()).toEqual(
      client.entries
        .filter((entry) => entry.card)
        .map((entry) => entry.id)
        .sort(),
    );
    await expectConverged(f, client);

    // A resumed client gets the input cards it may hold as plain inputs.
    const resumed = await attach(f, client.tip);
    const frame = resumed.frames[0];
    expect(frame?.type === "update" && frame.entries?.map((entry) => entry.id)).toEqual(
      inputs.map((entry) => entry.id),
    );
  });

  it("never sends a partial answer that a restarted generation retried", async () => {
    const f = await fixture([fauxAssistantMessage(LONG_ANSWER)], { slow: true });
    const client = await attach(f);
    const submission = await f.conversation.submit(
      { type: "input", content: "interrupted" },
      context,
    );
    await expect
      .poll(() => client.frames.some((frame) => liveTextOps(frame).length > 0), {
        timeout: 15_000,
      })
      .toBe(true);
    void submission.wait(context).catch(() => undefined);
    // A restart mid-stream: the room closes with the Harness.
    await f.harness.close(context);
    harnesses.delete(f.harness);
    const cursor = client.tip;
    f.faux.setResponses([fauxAssistantMessage("fresh complete")]);
    const harness = await f.open();
    const conversation = (await harness.conversation(f.conversation.id, context))!;
    const reopened = { harness, conversation };
    const resumed = await attach(reopened, cursor, client);
    harness.resume();
    await conversation.waitForIdle(context);
    await settle();

    const assistants = await (async () => {
      const page = await conversation.entries({}, 50, undefined, context);
      return page.items.filter((entry) => entry.kind === "pi.assistant");
    })();
    const partial = assistants.find(
      (entry) => entry.model?.[0]?.role === "assistant" && entry.model[0].stopReason === "aborted",
    )!;
    expect(partial).toBeDefined();
    const sentIds = resumed.frames.flatMap((frame) =>
      frame.type === "snapshot" || frame.type === "update"
        ? (frame.entries ?? []).map((entry) => entry.id)
        : [],
    );
    expect(sentIds).not.toContain(partial.id);
    expect(JSON.stringify(shownEntries(resumed.entries))).toContain("fresh complete");
    expect((await traceCards(reopened)).ids.has(partial.id)).toBe(false);
    await expectConverged(reopened, resumed);
    // A cold snapshot omits it too.
    expect((await attach(reopened)).entries.map((entry) => entry.id)).not.toContain(partial.id);
  });

  it("upserts an attempt the client holds as hidden once its task retries", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    const message = (text: string, stopReason: "aborted" | "stop") => ({
      role: "assistant" as const,
      content: [{ type: "text" as const, text }],
      api: "faux",
      provider: "faux",
      model: "faux-1",
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason,
      timestamp: 1,
    });
    // Attributed attempts without a Pi generation: only the later answer of the same task
    // hides the first, exactly the rule the trace applies.
    const Retry = defineTask<null, { phase: "first" } | { phase: "second" }, null>({
      name: "oppi.test-retry",
      version: 1,
      initial: () => ({ phase: "first" }),
      phases: {
        first: (_task, runtime, callContext) =>
          runtime.commit(async (tx) => {
            await tx.appendEntry(runtime.conversationId, {
              kind: "pi.assistant",
              model: [message("first attempt", "aborted")],
            });
            return { status: "running", checkpoint: { phase: "second" } };
          }, callContext),
        second: async (_task, runtime, callContext) => {
          await gate;
          await runtime.commit(async (tx) => {
            await tx.appendEntry(runtime.conversationId, {
              kind: "pi.assistant",
              model: [message("second attempt", "stop")],
            });
            return { status: "terminal", outcome: { status: "completed", result: null } };
          }, callContext);
        },
      },
      abort: (_task, runtime, callContext) =>
        runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), callContext),
    });
    const f = await fixture([], {
      extensions: [defineExtension({ name: "oppi.test-retry", tasks: [Retry] })],
    });
    const client = await attach(f);
    const task = await f.conversation.commit(
      (tx) => tx.createTask(Retry, null, { ownership: { kind: "conversation" } }),
      context,
    );
    f.harness.resume();
    await expect
      .poll(() => JSON.stringify(client.entries).includes("first attempt"), { timeout: 5_000 })
      .toBe(true);
    const attempt = client.entries.find((entry) =>
      JSON.stringify(entry).includes("first attempt"),
    )!;
    const sent = client.frames.length;
    release();
    await f.harness.waitForTask(task, context);
    await settle();

    const restated = client.frames
      .slice(sent)
      .flatMap((frame) => (frame.type === "update" ? (frame.entries ?? []) : []));
    expect(restated).toContainEqual({ id: attempt.id, kind: "pi.assistant", hidden: true });
    expect(client.entries.find((entry) => entry.id === attempt.id)).toEqual({
      id: attempt.id,
      kind: "pi.assistant",
      hidden: true,
    });
    expect((await traceCards(f)).ids.has(attempt.id)).toBe(false);
    await expectConverged(f, client);
    // A fresh snapshot omits it.
    expect((await attach(f)).entries.map((entry) => entry.id)).not.toContain(attempt.id);
  });

  it("pages older entries before the replica, oldest first, with the same presentation", async () => {
    const f = await fixture([
      fauxAssistantMessage("one"),
      fauxAssistantMessage("two"),
      fauxAssistantMessage("three"),
    ]);
    await prompt(f.conversation, "first");
    await prompt(f.conversation, "second");
    const id = f.conversation.id;
    await f.conversation.commit(async (tx) => {
      await tx.appendEntry(id, {
        kind: "oppi.notice",
        data: { card: { title: "Old card", at: 1 } },
      });
    }, context);
    await prompt(f.conversation, "third");
    const all = (await f.conversation.entries({}, 100, undefined, context)).items.reverse();
    const kept = all.filter((entry) => entry.kind === "pi.user").at(-1)!.id;
    await f.conversation.commit(async (tx) => {
      await tx.appendEntry(id, {
        kind: "pi.compaction",
        head: kept as EntryId,
        model: [{ role: "user", content: "<summary>earlier</summary>", timestamp: 1 }],
      });
    }, context);
    const client = await attach(f);
    expect(client.frames[0]).toMatchObject({ type: "snapshot", hasOlder: true });
    const oldest = Math.min(...client.entries.map((entry) => entry.id));
    expect(oldest).toBe(kept);

    const renderers = new MobileRendererRegistry();
    const page = (beforeEntryId: number, limit?: number) =>
      readOlderConversationEntries({
        harness: f.harness,
        conversationId: id,
        renderers,
        beforeEntryId,
        ...(limit !== undefined ? { limit } : {}),
      }).then(wire);
    const first = await page(oldest, 2);
    expect(first).toMatchObject({ type: "older", conversationId: id, hasOlder: true });
    const firstIds = first.type === "older" ? first.entries.map((entry) => entry.id) : [];
    expect(firstIds).toEqual(
      all
        .filter((entry) => entry.id < oldest)
        .map((entry) => entry.id)
        .slice(-2),
    );
    const rest = await page(firstIds[0]!);
    expect(rest).toMatchObject({ type: "older", hasOlder: false });
    if (rest.type !== "older" || first.type !== "older") return;
    const paged = [...rest.entries, ...first.entries];
    expect(paged.map((entry) => entry.id)).toEqual(
      all.filter((entry) => entry.id < oldest).map((entry) => entry.id),
    );
    // Same decorations as the stream gives entries: the card, and tool presentation.
    expect(paged.find((entry) => entry.kind === "oppi.notice")?.card).toMatchObject({
      title: "Old card",
    });
    expect(await page(1)).toEqual({
      type: "older",
      conversationId: id,
      entries: [],
      hasOlder: false,
    });
  });

  it("cuts a long snapshot to its window and pages the rest back to the whole context", async () => {
    const f = await fixture([fauxAssistantMessage("one"), fauxAssistantMessage("two")]);
    const id = f.conversation.id;
    await prompt(f.conversation, "first");
    await f.conversation.commit(async (tx) => {
      for (let index = 0; index < CONVERSATION_SNAPSHOT_LIMIT + 20; index += 1)
        await tx.appendEntry(id, {
          kind: "oppi.notice",
          data: { card: { title: `Card ${index}`, at: index } },
        });
    }, context);
    const client = await attach(f);
    expect(client.frames[0]).toMatchObject({ type: "snapshot", hasOlder: true });
    expect(client.entries).toHaveLength(CONVERSATION_SNAPSHOT_LIMIT);
    const sentIds = client.entries.map((entry) => entry.id);

    // A new entry still appends after the window.
    await prompt(f.conversation, "second");
    await settle();
    expect(client.entries.slice(0, CONVERSATION_SNAPSHOT_LIMIT).map((entry) => entry.id)).toEqual(
      sentIds,
    );

    const renderers = new MobileRendererRegistry();
    let more = true;
    while (more) {
      const page = wire(
        await readOlderConversationEntries({
          harness: f.harness,
          conversationId: id,
          renderers,
          beforeEntryId: Math.min(...client.entries.map((entry) => entry.id)),
        }),
      );
      client.apply(page);
      more = page.type === "older" && page.hasOlder;
    }
    await expectConverged(f, client);
  });
});
