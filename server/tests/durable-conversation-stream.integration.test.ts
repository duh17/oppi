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
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai/providers/faux";
import type { ConversationId } from "@earendil-works/pi-durable";

import type { DurableHarness } from "../src/durable-harness.js";
import { Server } from "../src/server.js";
import type { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ConversationEntryView, Session, Workspace } from "../src/types.js";
import { conversationReference } from "./harness/conversation-stream-reference.js";

type Frame = Record<string, unknown> & { type: string };

const LONG_ANSWER = Array.from({ length: 40 }, (_, index) => `word${index}`).join(" ");

/** One focused-stream socket and the replica built from its conversation frames. */
class StreamClient {
  readonly frames: Frame[] = [];
  readonly opened: Promise<void>;
  entries: ConversationEntryView[] = [];
  docs: Record<string, unknown> = {};
  head = 0;
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
    if (frame.type === "snapshot") {
      this.entries = [...(frame.entries as ConversationEntryView[])];
      this.docs = { ...(frame.docs as Record<string, unknown>) };
      this.head = frame.head as number;
    } else if (frame.type === "update") {
      for (const entry of (frame.entries as ConversationEntryView[] | undefined) ?? []) {
        const index = this.entries.findIndex((candidate) => candidate.id === entry.id);
        if (index >= 0) this.entries[index] = entry;
        else this.entries.push(entry);
      }
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
  const faux = fauxProvider({ tokensPerSecond: 60, tokenSize: { min: 3, max: 3 } });
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
  session.serverDurable = {};
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
  const { harness } = await durable.open();
  const conversationId = storage.getSession(session.id)?.serverDurable?.conversationId;
  const reference = await conversationReference(
    harness,
    conversationId as ConversationId,
    sessions.mobileRenderer,
  );
  expect(client.entries).toEqual(reference.entries);
  expect(client.docs).toEqual(reference.docs);
  expect(client.head).toBe(reference.head);
}

describe("durable conversation stream over the focused session socket", { timeout: 60_000 }, () => {
  it("advertises the capability and streams snapshot, appends, and one landing frame", async () => {
    const info = (await (
      await fetch(`${baseUrl}/server/info`, { headers: { Authorization: `Bearer ${token}` } })
    ).json()) as { capabilities: Record<string, unknown> };
    expect(info.capabilities.conversationStream).toEqual({ version: 1 });

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
    expect(plain.frames.some((frame) => frame.type === "message_end")).toBe(true);
    expect(plain.conversationFrames()).toEqual([]);
    expect(attached.frames.some((frame) => frame.type === "message_end")).toBe(true);

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
    const textEvents = attached.frames.filter(
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

    const late = await connect();
    expect((await late.attach(stale)).type).toBe("snapshot");
    await expectConverged(client);
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
});
