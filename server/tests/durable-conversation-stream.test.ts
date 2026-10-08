import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
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
  type Conversation,
  type EntryId,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { DurableInputCards, DurableUI } from "../extensions/durable/durable-ui.js";
import {
  attachConversationStream,
  type ConversationStreamSubscription,
} from "../src/durable-conversation-stream.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import type { ConversationEntryView, ConversationStreamServerMessage } from "../src/types.js";

const harnesses = new Set<Harness>();
const subscriptions = new Set<ConversationStreamSubscription>();
afterEach(async () => {
  for (const subscription of subscriptions) subscription.dispose();
  subscriptions.clear();
  await Promise.all([...harnesses].map((harness) => harness.close(context)));
  harnesses.clear();
});

const LONG_ANSWER = Array.from({ length: 40 }, (_, index) => `word${index}`).join(" ");

async function fixture(responses: FauxResponseStep[], options?: { slow?: boolean }) {
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
  const harness = await Harness.open(
    await openNodeSqliteStorage(join(dir, "stream.sqlite")),
    {
      models,
      registry,
      env: () => new NodeExecutionEnv({ cwd: dir }),
      settings: { compaction: { enabled: false } },
    },
    context,
  );
  harnesses.add(harness);
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
  return { harness, conversation, faux };
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
    for (const entry of frame.entries ?? []) {
      const index = this.entries.findIndex((candidate) => candidate.id === entry.id);
      if (index >= 0) this.entries[index] = entry;
      else this.entries.push(entry);
    }
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

/** A fresh attach is the reference: every replica must converge to it. */
async function expectConverged(
  f: { harness: Harness; conversation: Conversation },
  client: Client,
): Promise<void> {
  const reference = await attach(f);
  expect(reference.frames[0]?.type).toBe("snapshot");
  expect(client.entries).toEqual(reference.entries);
  expect(client.docs).toEqual(reference.docs);
  expect(client.head).toBe(reference.head);
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
});
