/**
 * Real-socket proof of the durable conversation stream: a real `Server` with the
 * server-durable flag, its own process Harness, a faux provider, and the focused
 * session WebSocket. Clients apply frames with Chord's own applier.
 */
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocket, type RawData } from "ws";
import { applyImmutable, type Op } from "@earendil-works/chord/delta";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxProviderHandle,
} from "@earendil-works/pi-ai/providers/faux";
import type { ConversationId } from "@earendil-works/pi-durable";

import type { DurableHarness } from "../src/durable-harness.js";
import { Server } from "../src/server.js";
import type { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ConversationEntryView, Session, Workspace } from "../src/types.js";
import {
  conversationReference,
  shownEntries,
  upsertEntries,
} from "./harness/conversation-stream-reference.js";

type Frame = Record<string, unknown> & { type: string };

const LONG_ANSWER = Array.from({ length: 40 }, (_, index) => `word${index}`).join(" ");

/**
 * One focused-stream socket and the replica built from its conversation frames: those of the
 * first conversation it receives a frame of. `liveDocs` replays another one's.
 */
class StreamClient {
  readonly frames: Frame[] = [];
  readonly opened: Promise<void>;
  entries: ConversationEntryView[] = [];
  docs: Record<string, unknown> = {};
  head = 0;
  conversationId: number | undefined;
  private readonly waiters = new Set<{
    predicate: (frame: Frame) => boolean;
    resolve: (frame: Frame) => void;
  }>();

  constructor(readonly ws: WebSocket) {
    this.opened = new Promise((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", reject);
      ws.once("unexpected-response", (_req, res) =>
        reject(new Error(`WS upgrade failed with HTTP ${res.statusCode ?? "unknown"}`)),
      );
    });
    ws.on("message", (data: RawData) => {
      const frame = JSON.parse(Buffer.from(data as Buffer).toString("utf8")) as Frame;
      this.frames.push(frame);
      this.apply(frame);
      for (const waiter of this.waiters)
        if (waiter.predicate(frame)) {
          this.waiters.delete(waiter);
          waiter.resolve(frame);
        }
    });
  }

  private apply(frame: Frame): void {
    if (typeof frame.conversationId !== "number") return;
    this.conversationId ??= frame.conversationId;
    if (frame.conversationId !== this.conversationId) return;
    if (frame.type === "snapshot") {
      this.entries = [...(frame.entries as ConversationEntryView[])];
      this.docs = { ...(frame.docs as Record<string, unknown>) };
      this.head = frame.head as number;
    } else if (frame.type === "older") {
      this.entries = [...(frame.entries as ConversationEntryView[]), ...this.entries];
    } else if (frame.type === "update") {
      this.entries = upsertEntries(
        this.entries,
        this.head,
        (frame.entries as ConversationEntryView[] | undefined) ?? [],
      );
      for (const [kind, ops] of Object.entries((frame.docs ?? {}) as Record<string, Op[] | null>)) {
        if (ops === null) delete this.docs[kind];
        else this.docs[kind] = applyImmutable(this.docs[kind], ops);
      }
    }
  }

  get tip(): number {
    return Math.max(0, ...this.entries.map((entry) => entry.id));
  }

  conversationFrames(): Frame[] {
    return this.frames.filter((frame) => frame.type === "snapshot" || frame.type === "update");
  }

  /** The documents of `conversationId` its frames build, from its newest snapshot on. */
  liveDocs(conversationId: number): Record<string, unknown> {
    let docs: Record<string, unknown> = {};
    for (const frame of this.conversationFrames()) {
      if (frame.conversationId !== conversationId) continue;
      if (frame.type === "snapshot") docs = { ...(frame.docs as Record<string, unknown>) };
      else
        for (const [kind, ops] of Object.entries(
          (frame.docs ?? {}) as Record<string, Op[] | null>,
        )) {
          if (ops === null) delete docs[kind];
          else docs[kind] = applyImmutable(docs[kind], ops);
        }
    }
    return docs;
  }

  /** Send `message` with a request id; resolves with its `command_result`. */
  async request(message: Record<string, unknown>): Promise<Frame> {
    const requestId = randomUUID();
    const from = this.frames.length;
    this.send({ ...message, requestId });
    return this.next(
      (frame) => frame.type === "command_result" && frame.requestId === requestId,
      from,
    );
  }

  next(predicate: (frame: Frame) => boolean, fromIndex = 0, timeoutMs = 20_000): Promise<Frame> {
    const existing = this.frames.slice(fromIndex).find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve };
      this.waiters.add(waiter);
      setTimeout(() => {
        if (!this.waiters.delete(waiter)) return;
        reject(
          new Error(`Timed out; frames seen: ${this.frames.map((frame) => frame.type).join(",")}`),
        );
      }, timeoutMs);
    });
  }

  send(message: Record<string, unknown>): void {
    this.ws.send(JSON.stringify(message));
  }

  async attach(afterEntryId?: number): Promise<Frame> {
    const requestId = randomUUID();
    const from = this.frames.length;
    this.send({
      type: "attach",
      requestId,
      ...(afterEntryId !== undefined ? { afterEntryId } : {}),
    });
    const result = await this.next(
      (frame) => frame.type === "command_result" && frame.requestId === requestId,
      from,
    );
    expect(result).toMatchObject({ command: "attach", success: true });
    // The first conversation frame precedes the acknowledgement.
    return this.conversationFrames().find((frame) => this.frames.indexOf(frame) >= from)!;
  }

  async close(): Promise<void> {
    if (this.ws.readyState === WebSocket.CLOSED) return;
    await new Promise<void>((resolve) => {
      this.ws.once("close", () => resolve());
      this.ws.close();
    });
  }
}

let dataDir: string;
let storage: Storage;
let server: Server;
let token: string;
let baseUrl: string;
let workspace: Workspace;
let session: Session;
let clients: StreamClient[] = [];
let faux: FauxProviderHandle;
let previousTls: string | undefined;
let previousAgentDir: string | undefined;

beforeAll(() => {
  previousTls = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
});
afterAll(() => {
  if (previousTls === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTls;
});

beforeEach(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-conversation-stream-ws-"));
  console.info(`Conversation stream integration artifacts: ${dataDir}`);
  previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = join(dataDir, "agent");
  const models = await ModelRuntime.create({
    authPath: join(dataDir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dataDir, "models-cache.json"),
    refreshOnCreate: false,
  });
  faux = fauxProvider({ tokensPerSecond: 60, tokenSize: { min: 3, max: 3 } });
  faux.setResponses([
    fauxAssistantMessage(LONG_ANSWER),
    fauxAssistantMessage(LONG_ANSWER),
    fauxAssistantMessage("## Goal\nSummarized"),
  ]);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
  vi.spyOn(SettingsManager, "create").mockImplementation(() =>
    SettingsManager.inMemory({
      defaultProvider: "faux",
      defaultModel: "faux-1",
      defaultThinkingLevel: "off",
      compaction: { enabled: true, keepRecentTokens: 1, reserveTokens: 100 },
    }),
  );

  storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "self-signed" },
    experimental: { serverDurable: true },
  });
  storage.ensurePaired();
  token = enrollTestDevice(storage);
  workspace = storage.createWorkspace({ name: "Conversation stream", hostMount: dataDir });
  session = storage.createSession("Conversation stream", "faux/faux-1");
  session.workspaceId = workspace.id;
  session.serverDurable = { storeId: session.id };
  storage.saveSession(session);

  server = new Server(storage);
  await server.start();
  baseUrl = `https://127.0.0.1:${server.port}`;
  // Server start (TLS, harness, model catalog) is slow on a loaded host.
}, 60_000);

afterEach(async () => {
  await Promise.all(clients.map((client) => client.close().catch(() => {})));
  clients = [];
  await server.stop().catch(() => {});
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  rmSync(dataDir, { recursive: true, force: true });
}, 60_000);

function enrollTestDevice(target: Storage): string {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  const result = target.enrollViaPairing(target.issuePairingToken(), {
    name: "conversation-stream-test",
    publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
  });
  if (!result) throw new Error("test device enrollment failed");
  return result.accessToken;
}

async function connect(target: Session = session): Promise<StreamClient> {
  const url = `${baseUrl.replace(/^https:/, "wss:")}/workspaces/${target.workspaceId}/sessions/${target.id}/stream`;
  const client = new StreamClient(
    new WebSocket(url, {
      headers: { Authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
    }),
  );
  clients.push(client);
  await client.opened;
  await client.next((frame) => frame.type === "state");
  return client;
}

async function prompt(client: StreamClient, message: string): Promise<void> {
  const from = client.frames.length;
  client.send({ type: "prompt", message, clientTurnId: randomUUID(), requestId: randomUUID() });
  await client.next((frame) => frame.type === "agent_end", from);
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 300));

/** Classic events an attached socket must not get: its entries and documents restate them. */
const RESTATED_EVENTS = new Set([
  "text_delta",
  "thinking_delta",
  "message_end",
  "tool_start",
  "tool_update",
  "tool_output",
  "tool_end",
  "queue_state",
  "queue_item_started",
]);

type QueueView = { steering: Array<{ message: string }>; followUp: Array<{ message: string }> };

/** `pi.live.run` is present exactly while the conversation is busy. */
function isRunning(client: StreamClient): boolean {
  return (client.docs["pi.live"] as { run?: unknown } | undefined)?.run !== undefined;
}

function liveTextOps(frame: Frame): Op[] {
  if (frame.type !== "update") return [];
  const ops = ((frame.docs as Record<string, Op[] | null> | undefined)?.["pi.live"] ?? []) as Op[];
  return ops.filter((op) => op.length >= 2 && Array.isArray(op[1]) && op[1].at(-1) === "text");
}

function frameBytes(frames: Frame[]): number[] {
  return frames.map((frame) => Buffer.byteLength(JSON.stringify(frame)));
}

/** The replica must converge to the conversation as the server's Harness reads it, without a room. */
async function expectConverged(client: StreamClient): Promise<void> {
  const sessions = (server as unknown as { sessions: SessionManager }).sessions;
  const durable = await (sessions as unknown as { durableHarness: Promise<DurableHarness> })
    .durableHarness;
  const storeId = storage.getSession(session.id)?.serverDurable?.storeId ?? session.id;
  const { harness } = await (await durable.openHost(storeId)).open();
  const conversationId = storage.getSession(session.id)?.serverDurable?.conversationId;
  const reference = await conversationReference(
    harness,
    conversationId as ConversationId,
    sessions.mobileRenderer,
  );
  expect(shownEntries(client.entries)).toEqual(reference.entries);
  expect(client.docs).toEqual(reference.docs);
  expect(client.head).toBe(reference.head);
}

describe("durable conversation stream over the focused session socket", { timeout: 60_000 }, () => {
  it("advertises the capability and streams snapshot, appends, and one landing frame", async () => {
    const info = (await (
      await fetch(`${baseUrl}/server/info`, { headers: { Authorization: `Bearer ${token}` } })
    ).json()) as { capabilities: Record<string, unknown> };
    expect(info.capabilities.conversationStream).toEqual({ version: 2 });

    const attached = await connect();
    const plain = await connect();
    const snapshot = await attached.attach();
    expect(snapshot).toMatchObject({ type: "snapshot", head: 0, hasOlder: false, entries: [] });
    expect(snapshot.conversationId).toBe(
      storage.getSession(session.id)?.serverDurable?.conversationId,
    );

    await prompt(attached, "stream please");
    await settle();

    // A socket that never attaches keeps the classic event path and gets no stream frames.
    // The attached one gets no event its entries and documents restate, and still gets the
    // run boundaries.
    expect(plain.frames.some((frame) => frame.type === "message_end")).toBe(true);
    expect(plain.frames.some((frame) => frame.type === "text_delta")).toBe(true);
    expect(plain.conversationFrames()).toEqual([]);
    expect(
      attached.frames.filter((frame) => RESTATED_EVENTS.has(frame.type)).map((frame) => frame.type),
    ).toEqual([]);
    expect(attached.frames.some((frame) => frame.type === "agent_end")).toBe(true);

    const textOps = attached.conversationFrames().flatMap(liveTextOps);
    expect(textOps.filter((op) => op[0] === "a").length).toBeGreaterThanOrEqual(2);
    expect(textOps.filter((op) => op[0] === "s")).toEqual([]);
    const landing = attached
      .conversationFrames()
      .filter((frame) =>
        ((frame.entries as ConversationEntryView[] | undefined) ?? []).some(
          (entry) => entry.kind === "pi.assistant",
        ),
      );
    expect(landing).toHaveLength(1);
    expect(
      ((landing[0]!.docs as Record<string, Op[]>)["pi.live"] ?? []).some(
        (op) => op[0] === "d" && JSON.stringify(op[1]) === '["generation"]',
      ),
    ).toBe(true);
    expect(attached.docs["pi.live"]).not.toHaveProperty("generation");
    const updates = attached.conversationFrames().filter((frame) => frame.type === "update");
    const probe = await connect();
    const after = await probe.attach();
    await probe.close();
    const textEvents = plain.frames.filter(
      (frame) => frame.type === "text_delta" || frame.type === "message_end",
    );
    // Retained run artifact: payload sizes for one streamed reply, both paths.
    writeFileSync(
      join(tmpdir(), "oppi-conversation-stream-payload.json"),
      JSON.stringify(
        {
          answerChars: LONG_ANSWER.length,
          updateFrames: updates.length,
          updateBytes: frameBytes(updates),
          snapshotAfterTurnBytes: frameBytes([after])[0],
          classicTextFrames: textEvents.length,
          classicTextBytes: frameBytes(textEvents),
        },
        null,
        2,
      ),
    );
    await expectConverged(attached);
  });

  it("shows a busy run and its steer and follow-up from documents, not queue events", async () => {
    faux.setResponses([
      fauxAssistantMessage(LONG_ANSWER),
      fauxAssistantMessage("steered"),
      fauxAssistantMessage("followed"),
    ]);
    const attached = await connect();
    const plain = await connect();
    await attached.attach();
    const from = attached.frames.length;
    attached.send({ type: "prompt", message: "go", clientTurnId: randomUUID() });
    await attached.next(() => isRunning(attached), from);

    attached.send({ type: "steer", message: "look here", clientTurnId: randomUUID() });
    attached.send({ type: "follow_up", message: "then this", clientTurnId: randomUUID() });
    await attached.next(() => {
      const queue = attached.docs["pi.inbox"] as QueueView | undefined;
      return queue?.steering.length === 1 && queue.followUp.length === 1;
    }, from);
    const queue = attached.docs["pi.inbox"] as QueueView;
    expect(queue.steering.map((item) => item.message)).toEqual(["look here"]);
    expect(queue.followUp.map((item) => item.message)).toEqual(["then this"]);
    expect(isRunning(attached)).toBe(true);

    // Both start once the answer in flight ends; the run ends after them.
    await attached.next(
      () =>
        !isRunning(attached) &&
        attached.entries.filter((entry) => entry.kind === "pi.user").length === 3,
      from,
    );
    expect(attached.docs["pi.inbox"]).toEqual({ steering: [], followUp: [] });
    // The classic socket got the queue as events; the attached one only as documents.
    expect(plain.frames.some((frame) => frame.type === "queue_state")).toBe(true);
    expect(
      attached.frames.filter((frame) => RESTATED_EVENTS.has(frame.type)).map((frame) => frame.type),
    ).toEqual([]);
    await expectConverged(attached);
  });

  it("resumes from afterEntryId after a disconnect while a turn ran", async () => {
    const driver = await connect();
    const first = await connect();
    await first.attach();
    await prompt(driver, "one");
    await settle();

    const from = first.frames.length;
    const driverFrom = driver.frames.length;
    driver.send({ type: "prompt", message: "two", clientTurnId: randomUUID() });
    await first.next((frame) => liveTextOps(frame).length > 0, from);
    const cursor = first.tip;
    const held = { entries: [...first.entries], docs: { ...first.docs } };
    await first.close();
    await driver.next((frame) => frame.type === "agent_end", driverFrom);
    await settle();

    const resumed = await connect();
    resumed.entries = held.entries;
    resumed.docs = held.docs;
    const frame = await resumed.attach(cursor);
    expect(frame.type).toBe("update");
    const missing = (frame.entries as ConversationEntryView[]).map((entry) => entry.kind);
    expect(missing).toEqual(["pi.assistant"]);
    expect((frame.entries as ConversationEntryView[])[0]!.id).toBeGreaterThan(cursor);
    await expectConverged(resumed);
  });

  it("sends a snapshot when compaction moves the head, and for a stale cursor", async () => {
    const client = await connect();
    await client.attach();
    await prompt(client, "one");
    await prompt(client, "two");
    await settle();
    const stale = client.tip;

    const from = client.frames.length;
    const requestId = randomUUID();
    client.send({ type: "compact", requestId });
    await client.next(
      (frame) => frame.type === "command_result" && frame.requestId === requestId,
      from,
    );
    const snapshot = await client.next((frame) => frame.type === "snapshot", from);
    const entries = snapshot.entries as ConversationEntryView[];
    expect(entries[0]?.kind).toBe("pi.compaction");
    expect(snapshot.head).toBe(entries[0]?.id);
    expect(snapshot.hasOlder).toBe(true);
    await settle();

    // Attaching again replaces this socket's subscription, the room's only one, so the
    // room closes and the new attach loads a new room from the Harness.
    const cold = await client.attach();
    expect(cold).toMatchObject({ type: "snapshot", head: snapshot.head });
    expect((cold.entries as ConversationEntryView[]).map((entry) => entry.id)).toEqual(
      entries.map((entry) => entry.id),
    );
    expect(entries.length).toBeGreaterThan(1);
    await expectConverged(client);

    // Paging restores what the compaction left out, oldest first, before the acknowledgement.
    const before = Math.min(...client.entries.map((entry) => entry.id));
    const olderId = randomUUID();
    const olderFrom = client.frames.length;
    client.send({ type: "older", beforeEntryId: before, requestId: olderId });
    const ack = await client.next(
      (frame) => frame.type === "command_result" && frame.requestId === olderId,
      olderFrom,
    );
    expect(ack).toMatchObject({ command: "older", success: true });
    const older = client.frames.slice(olderFrom).find((frame) => frame.type === "older")!;
    expect(client.frames.indexOf(older)).toBeLessThan(client.frames.indexOf(ack));
    expect(older).toMatchObject({ type: "older", hasOlder: false });
    const olderIds = (older.entries as ConversationEntryView[]).map((entry) => entry.id);
    expect(olderIds.length).toBeGreaterThan(0);
    expect(olderIds).toEqual([...olderIds].sort((left, right) => left - right));
    expect(olderIds.every((id) => id < before)).toBe(true);

    const late = await connect();
    expect((await late.attach(stale)).type).toBe("snapshot");
  });

  it("refuses attach on a classic session without sending stream frames", async () => {
    const classic = storage.createSession("Classic", "faux/faux-1");
    classic.workspaceId = workspace.id;
    storage.saveSession(classic);
    const client = await connect(classic);
    const requestId = randomUUID();
    client.send({ type: "attach", requestId });
    const result = await client.next(
      (frame) => frame.type === "command_result" && frame.requestId === requestId,
    );
    expect(result).toMatchObject({ command: "attach", success: false });
    expect(String(result.error)).toContain("durable session");
    expect(client.conversationFrames()).toEqual([]);
  });

  it("streams a subagent's live tail on its parent's socket, only within the parent's thread", async () => {
    let openChild!: () => void;
    const childGate = new Promise<void>((resolve) => (openChild = resolve));
    const childAnswer = Array.from({ length: 4 }, () => LONG_ANSWER).join("\n");
    faux.setResponses(
      Array.from(
        { length: 12 },
        () => async (transcript: { messages: Array<{ role: string; content: unknown }> }) => {
          const last = transcript.messages.findLast((message) => message.role !== "system")!;
          const text = JSON.stringify(last.content);
          if (last.role === "toolResult") return fauxAssistantMessage("STARTED");
          if (text.includes("Delegate"))
            return fauxAssistantMessage(
              [fauxToolCall("subagent", { action: "spawn", name: "Kid", task: "KID_TASK" })],
              { stopReason: "toolUse" },
            );
          if (text.includes("KID_TASK")) {
            await childGate;
            return fauxAssistantMessage(childAnswer);
          }
          return fauxAssistantMessage("NOTED");
        },
      ),
    );
    const parent = await connect();
    await parent.attach();
    await prompt(parent, "Delegate in the background");
    const child = storage.listSessions().find((candidate) => candidate.id !== session.id)!;
    const parentConversation = storage.getSession(session.id)!.serverDurable!.conversationId!;
    const childConversation = storage.getSession(child.id)!.serverDurable!.conversationId!;

    // Only the live tail of a conversation the parent owns, and only in live mode.
    expect(
      await parent.request({ type: "attach", conversationId: childConversation }),
    ).toMatchObject({ command: "attach", success: false });
    expect(
      await parent.request({ type: "attach", conversationId: 999, mode: "live" }),
    ).toMatchObject({ command: "attach", success: false });
    const childSocket = await connect(child);
    const upward = await childSocket.request({
      type: "attach",
      conversationId: parentConversation,
      mode: "live",
    });
    expect(upward).toMatchObject({ command: "attach", success: false });
    expect(String(upward.error)).toContain("thread");
    expect(childSocket.conversationFrames()).toEqual([]);

    const from = parent.frames.length;
    expect(
      await parent.request({ type: "attach", conversationId: childConversation, mode: "live" }),
    ).toMatchObject({ command: "attach", success: true });
    const snapshot = parent.frames
      .slice(from)
      .find((frame) => frame.conversationId === childConversation)!;
    expect(snapshot).toMatchObject({ type: "snapshot", head: 0, hasOlder: false, entries: [] });
    expect(Object.keys(snapshot.docs as object).sort()).toEqual(["pi.inbox", "pi.live"]);
    expect((snapshot.docs as Record<string, { run?: unknown }>)["pi.live"]?.run).toBeDefined();

    // The child's answer streams as live text; its frames never carry entries.
    openChild();
    const textAt = (docs: Record<string, unknown>) =>
      JSON.stringify(
        (docs["pi.live"] as { generation?: { message?: { content?: unknown } } } | undefined)
          ?.generation?.message?.content ?? "",
      );
    await parent.next(
      (frame) =>
        frame.conversationId === childConversation &&
        textAt(parent.liveDocs(childConversation)).includes("word5"),
      from,
    );

    // A reconnect while the child streams gets the tail so far in its first frame.
    const reconnected = await connect();
    await reconnected.request({ type: "attach", conversationId: childConversation, mode: "live" });
    expect(textAt(reconnected.liveDocs(childConversation))).toContain("word0");

    const detached = await parent.request({ type: "detach", conversationId: childConversation });
    expect(detached).toMatchObject({ command: "detach", success: true });
    const afterDetach = parent.frames.length;
    // The child lands its answer and goes idle; the other socket still follows it.
    await reconnected.next(
      (frame) =>
        frame.conversationId === childConversation &&
        (reconnected.liveDocs(childConversation)["pi.live"] as { run?: unknown } | undefined)
          ?.run === undefined,
    );
    // The child's report starts a parent turn; the parent's replica follows only its own frames.
    await parent.next((frame) => frame.type === "agent_end", afterDetach);
    await settle();
    const childFrames = parent
      .conversationFrames()
      .filter((frame) => frame.conversationId === childConversation);
    expect(childFrames.length).toBeGreaterThan(1);
    expect(
      childFrames.every((frame) => ((frame.entries as unknown[] | undefined) ?? []).length === 0),
    ).toBe(true);
    expect(childFrames.every((frame) => parent.frames.indexOf(frame) < afterDetach)).toBe(true);
    // Only a socket replicating the parent's own conversation in full drops the classic events
    // it restates; one that follows only a child's live tail still gets the parent's turn.
    expect(parent.frames.filter((frame) => RESTATED_EVENTS.has(frame.type))).toEqual([]);
    expect(reconnected.frames.some((frame) => frame.type === "message_end")).toBe(true);
    await expectConverged(parent);
  });

  it("refuses older on a socket that has not attached", async () => {
    const client = await connect();
    const requestId = randomUUID();
    client.send({ type: "older", beforeEntryId: 5, requestId });
    const result = await client.next(
      (frame) => frame.type === "command_result" && frame.requestId === requestId,
    );
    expect(result).toMatchObject({ command: "older", success: false });
    expect(String(result.error)).toContain("attach");
    expect(client.frames.some((frame) => frame.type === "older")).toBe(false);
  });
});
