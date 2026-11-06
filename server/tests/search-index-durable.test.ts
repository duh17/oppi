import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import {
  Harness,
  createRegistry,
  type ConversationId,
  type EntryId,
  type EntryRecord,
} from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { commitWrites } from "@earendil-works/pi-durable/testing";
import type { Message } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { readDurableSearchTranscript, readDurableTipEntryId } from "../src/durable-history.js";
import { SearchIndex, type DurableSearchSource } from "../src/search-index.js";
import { updateSearchIndexForSessionEvent } from "../src/session-search-indexing.js";
import type { Session } from "../src/types.js";

const cleanups: Array<() => Promise<void> | void> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function makeSession(conversationId: number, overrides: Partial<Session> = {}): Session {
  return {
    id: "durable-1",
    workspaceId: "ws-1",
    name: "Durable search session",
    status: "stopped",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    serverDurable: { storeId: "root-1", conversationId },
    ...overrides,
  };
}

function assistant(text: string, tool?: string): Message {
  return {
    role: "assistant",
    content: [
      { type: "text", text },
      ...(tool
        ? [{ type: "toolCall" as const, id: `call-${tool}`, name: tool, arguments: {} }]
        : []),
    ],
    api: "faux",
    provider: "faux",
    model: "faux-1",
    timestamp: 2,
    stopReason: "stop",
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

/** Real SQLite-backed Harness; `turn` appends entries through the storage boundary. */
async function durableFixture() {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-search-"));
  const storage = await openNodeSqliteStorage(join(dir, "history.sqlite"));
  const id = await storage.mintId<ConversationId>();
  await commitWrites(storage, [{ type: "conversation", value: { id } }], context);
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const harness = await Harness.open(storage, { models, registry: createRegistry() }, context);
  cleanups.push(
    () => harness.close(context),
    () => rmSync(dir, { recursive: true, force: true }),
  );

  async function turn(user: string, reply: string, tool?: string) {
    const entries: EntryRecord[] = [];
    for (const [role, model] of [
      ["user", { role: "user", content: user, timestamp: 1 } as Message],
      ["assistant", assistant(reply, tool)],
    ] as const) {
      entries.push({
        id: await storage.mintId<EntryId>(),
        conversationId: id,
        kind: `pi.${role}`,
        model: [model],
      });
    }
    await commitWrites(
      storage,
      entries.map((value) => ({ type: "entry" as const, value })),
      context,
    );
  }

  const resume = vi.spyOn(harness, "resume");
  const readTranscript = vi.fn((conversationId: number) =>
    readDurableSearchTranscript(harness, conversationId as ConversationId),
  );
  const source: DurableSearchSource = {
    readTipEntryId: () => readDurableTipEntryId(harness, id),
    readTranscript: () => readTranscript(id as number),
    holdStore: async () => () => {},
    storeModifiedAtMs: async () => Infinity,
  };
  return { id: id as number, turn, source, readTranscript, resume };
}

function openIndex(session: (id: string) => Session | undefined, source: DurableSearchSource) {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-search-index-"));
  const index = new SearchIndex(dir, session);
  index.durableSource = source;
  cleanups.push(
    () => index.close(),
    () => rmSync(dir, { recursive: true, force: true }),
  );
  return index;
}

describe("SearchIndex durable sessions", () => {
  it("finds user text, assistant text, and tool names, re-indexes new turns, and skips unchanged", async () => {
    const f = await durableFixture();
    await f.turn("zebrafish question", "marmoset answer", "quokka_tool");
    const session = makeSession(f.id);
    const index = openIndex(() => session, f.source);

    const first = await index.syncDurableSession(session.id);
    expect(first).toMatchObject({ added: 1, transcriptsRead: 1 });
    for (const term of ["zebrafish", "marmoset", "quokka_tool"]) {
      expect(index.search(term).map((hit) => hit.sessionId)).toEqual([session.id]);
    }
    expect(index.search("zebrafish", "other-workspace")).toEqual([]);

    // Unchanged conversation, title, and workspace: no second extraction.
    expect(await index.syncDurableSession(session.id)).toMatchObject({
      skipped: 1,
      transcriptsRead: 0,
    });
    expect(f.readTranscript).toHaveBeenCalledTimes(1);

    // A new turn is picked up through the agent_end path.
    await f.turn("pangolin follow-up", "axolotl reply");
    updateSearchIndexForSessionEvent(index, session.id, { type: "agent_end" } as never);
    await vi.waitFor(() => expect(index.search("axolotl")).toHaveLength(1));
    expect(index.search("pangolin")).toHaveLength(1);
    expect(index.search("zebrafish")).toHaveLength(1);
    expect(f.readTranscript).toHaveBeenCalledTimes(2);
    expect(f.resume).not.toHaveBeenCalled();
  });

  it("covers durable sessions in startup background sync and reuses text on a rename", async () => {
    const f = await durableFixture();
    await f.turn("narwhal prompt", "okapi reply");
    const session = makeSession(f.id);
    const index = openIndex(() => session, f.source);

    const warmed = await index.startBackgroundSync([session]);
    expect(warmed).toMatchObject({ added: 1, transcriptsRead: 1, sessionsChecked: 1 });
    expect(index.search("narwhal")).toHaveLength(1);

    const again = await index.startBackgroundSync([session]);
    expect(again).toMatchObject({ skipped: 1, transcriptsRead: 0 });

    session.name = "Renamed durable";
    const renamed = await index.startBackgroundSync([session]);
    expect(renamed).toMatchObject({ reindexed: 1, reusedIndexedTranscript: 1, transcriptsRead: 0 });
    expect(index.search("Renamed")).toHaveLength(1);
    expect(index.search("okapi")).toHaveLength(1);
    expect(f.readTranscript).toHaveBeenCalledTimes(1);
  });

  it("keeps a durable row written while the startup file walk is yielded", async () => {
    const f = await durableFixture();
    await f.turn("lemur prompt", "tapir reply");
    // Snapshot: a durable shell with no conversation yet looks file-backed.
    const filler = makeSession(0, { id: "filler", serverDurable: undefined, name: "Filler" });
    const shell = makeSession(f.id, { serverDurable: {} });
    const sessions = new Map([filler, shell].map((session) => [session.id, session]));
    const index = openIndex((id) => sessions.get(id), f.source);

    const result = await index.startBackgroundSync([filler, shell], {
      batchSize: 1,
      // The server accepts traffic while the walk yields: the first turn binds
      // the conversation and agent_end indexes it before the walk reaches it.
      yieldToEventLoop: async () => {
        shell.serverDurable = { storeId: "root-1", conversationId: f.id };
        await index.syncDurableSession(shell.id);
      },
    });

    expect(index.search("lemur").map((hit) => hit.sessionId)).toEqual([shell.id]);
    expect(index.search("tapir")).toHaveLength(1);
    // The durable marker survived: the next pass skips instead of re-reading.
    expect(await index.syncDurableSession(shell.id)).toMatchObject({ skipped: 1 });
    expect(f.readTranscript).toHaveBeenCalledTimes(1);
    expect(result.cancelled).toBe(false);
  });

  it("indexes the other durable sessions when one session's store cannot open", async () => {
    const f = await durableFixture();
    await f.turn("gharial prompt", "saola reply");
    const broken = makeSession(f.id, {
      id: "broken",
      serverDurable: { storeId: "locked", conversationId: f.id },
    });
    const good = makeSession(f.id, { id: "good" });
    const sessions = new Map([broken, good].map((session) => [session.id, session]));
    const lockError = new Error("Durable store locked could not take its lock: ENOTEMPTY");
    const index = openIndex((id) => sessions.get(id), {
      readTipEntryId: (id) =>
        id === broken.id ? Promise.reject(lockError) : f.source.readTipEntryId(id),
      readTranscript: (id) =>
        id === broken.id ? Promise.reject(lockError) : f.source.readTranscript(id),
      holdStore: (id) => (id === broken.id ? Promise.reject(lockError) : f.source.holdStore(id)),
      storeModifiedAtMs: f.source.storeModifiedAtMs,
    });

    const result = await index.startBackgroundSync([broken, good]);

    expect(result).toMatchObject({ cancelled: false, sessionsChecked: 2, added: 1 });
    expect(index.search("saola").map((hit) => hit.sessionId)).toEqual([good.id]);
  });

  it("opens each store once in startup sync and reads its sessions while it is held", async () => {
    const f = await durableFixture();
    await f.turn("ibex prompt", "tarsier reply");
    // Interleaved stores: each store open fences all of its conversations, so a
    // reopen per session made catch-up quadratic in the store's size.
    const sessions = [
      makeSession(f.id, { id: "a1", serverDurable: { storeId: "A", conversationId: f.id } }),
      makeSession(f.id, { id: "b1", serverDurable: { storeId: "B", conversationId: f.id } }),
      makeSession(f.id, { id: "a2", serverDurable: { storeId: "A", conversationId: f.id } }),
      makeSession(f.id, { id: "b2", serverDurable: { storeId: "B", conversationId: f.id } }),
      makeSession(f.id, { id: "a3", serverDurable: { storeId: "A", conversationId: f.id } }),
    ];
    const byId = new Map(sessions.map((session) => [session.id, session]));
    const storeOf = (id: string) => byId.get(id)?.serverDurable?.storeId ?? "";
    const held = new Set<string>();
    const holds: string[] = [];
    const readOutsideHold: string[] = [];
    const index = openIndex((id) => byId.get(id), {
      readTipEntryId: (id) => {
        if (!held.has(storeOf(id))) readOutsideHold.push(id);
        return f.source.readTipEntryId(id);
      },
      readTranscript: (id) => f.source.readTranscript(id),
      holdStore: async (id) => {
        holds.push(storeOf(id));
        held.add(storeOf(id));
        return () => held.delete(storeOf(id));
      },
      storeModifiedAtMs: f.source.storeModifiedAtMs,
    });

    const result = await index.startBackgroundSync(sessions, { budgetMs: 0 });

    expect(result).toMatchObject({ cancelled: false, sessionsChecked: 5, added: 5 });
    expect(holds.sort()).toEqual(["A", "B"]);
    expect(readOutsideHold).toEqual([]);
    expect(held.size).toBe(0);
    expect(index.search("tarsier")).toHaveLength(5);
  });

  describe("catch-up of unchanged stores", () => {
    /** Stores A (two sessions) and B (one) over one index directory; `modifiedAt` stands in for their file mtimes. */
    async function servers() {
      const f = await durableFixture();
      await f.turn("okapi prompt", "dikdik reply");
      const sessions = ["A", "A", "B"].map((storeId, n) =>
        makeSession(f.id, { id: `s${n}`, serverDurable: { storeId, conversationId: f.id } }),
      );
      const dir = mkdtempSync(join(tmpdir(), "oppi-durable-search-index-"));
      cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
      const s = {
        f,
        sessions,
        holds: [] as string[],
        failing: new Set<string>(),
        cutOff: false,
        modifiedAt: { A: 1, B: 1 } as Record<string, number>,
        /** One server start: a new index over the same directory, synced once, then closed. */
        async boot(query = "dikdik") {
          s.holds = [];
          const index = new SearchIndex(dir, (id) => sessions.find((x) => x.id === id));
          let closed = false;
          const close = () => {
            if (!closed) index.close();
            closed = true;
          };
          index.durableSource = {
            ...f.source,
            readTipEntryId: (id) => {
              if (s.cutOff) close();
              return s.failing.has(id)
                ? Promise.reject(new Error("x"))
                : f.source.readTipEntryId(id);
            },
            holdStore: async (id) => {
              s.holds.push(sessions.find((x) => x.id === id)!.serverDurable!.storeId!);
              return () => {};
            },
            storeModifiedAtMs: async (storeId) => s.modifiedAt[storeId]!,
          };
          const result = await index.startBackgroundSync(sessions, { budgetMs: 0 });
          const hits = closed ? [] : index.search(query).map((hit) => hit.sessionId);
          close();
          return { result, hits: hits.sort() };
        },
      };
      return s;
    }

    it("leaves a store closed when its files predate the last complete sync", async () => {
      const s = await servers();
      await s.boot();
      const reads = s.f.readTranscript.mock.calls.length;

      const { result, hits } = await s.boot();
      expect(result).toMatchObject({ skipped: 3, added: 0, sessionsChecked: 3 });
      expect(s.holds).toEqual([]);
      expect(s.f.readTranscript.mock.calls.length).toBe(reads);
      expect(hits).toHaveLength(3);
    });

    it("catches up a store written after the last sync, such as while the server was down", async () => {
      const s = await servers();
      await s.boot();
      await s.f.turn("numbat prompt", "aardwolf reply");
      s.modifiedAt.A = Date.now() + 60_000;

      const { result, hits } = await s.boot("aardwolf");
      expect(result).toMatchObject({ reindexed: 2, skipped: 1 });
      expect(s.holds).toEqual(["A"]);
      expect(hits).toEqual(["s0", "s1"]);
    });

    it("retries a store whose sync had a failed session", async () => {
      const s = await servers();
      s.failing.add("s1");
      expect((await s.boot()).result).toMatchObject({ added: 2 });
      s.failing.clear();

      expect((await s.boot()).result).toMatchObject({ added: 1, skipped: 2 });
      expect(s.holds).toEqual(["A"]);
    });

    it("retries every store when the sync was cut off mid-pass", async () => {
      const s = await servers();
      s.cutOff = true;
      expect((await s.boot()).result).toMatchObject({ cancelled: true });
      s.cutOff = false;

      expect((await s.boot()).result).toMatchObject({ cancelled: false, added: 3 });
      expect(s.holds.sort()).toEqual(["A", "B"]);
    });

    it("checks a store again when a session's title changed", async () => {
      const s = await servers();
      await s.boot();
      s.sessions[2]!.name = "Renamed";

      expect((await s.boot()).result).toMatchObject({ reindexed: 1, skipped: 2 });
      expect(s.holds).toEqual(["B"]);
    });

    it("checks a store again when a session joined it after the sync listed sessions", async () => {
      // A fork lands in store A while catch-up works through store B: it is not in this sync, its
      // first turn is indexed live, and its second turn reaches the store before A's pass starts
      // but never ends (the server crashes). Nothing writes A again before the next start.
      vi.useFakeTimers({ toFake: ["Date"] });
      cleanups.push(() => vi.useRealTimers());
      vi.setSystemTime(1_000);
      const f = await durableFixture();
      const g = await durableFixture();
      await f.turn("okapi prompt", "dikdik reply");
      const listed = [
        makeSession(f.id, { id: "b0", serverDurable: { storeId: "B", conversationId: f.id } }),
        makeSession(f.id, { id: "a0", serverDurable: { storeId: "A", conversationId: f.id } }),
      ];
      const fork = makeSession(g.id, {
        id: "a1",
        serverDurable: { storeId: "A", conversationId: g.id },
      });
      const modifiedAt: Record<string, number> = { A: 0, B: 0 };
      const dir = mkdtempSync(join(tmpdir(), "oppi-durable-search-index-"));
      cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
      const sourceOf = (id: string) => (id === fork.id ? g.source : f.source);
      const boot = async (sessions: Session[], during?: (index: SearchIndex) => Promise<void>) => {
        const index = new SearchIndex(dir, (id) => [...listed, fork].find((x) => x.id === id));
        index.durableSource = {
          readTipEntryId: async (id) => {
            const hook = during;
            during = undefined;
            await hook?.(index);
            return sourceOf(id).readTipEntryId(id);
          },
          readTranscript: (id) => sourceOf(id).readTranscript(id),
          holdStore: async () => () => {},
          storeModifiedAtMs: async (storeId) => modifiedAt[storeId]!,
        };
        await index.startBackgroundSync(sessions, { budgetMs: 0 });
        const hits = index.search("pangolin").map((hit) => hit.sessionId);
        index.close();
        return hits;
      };

      await boot(listed, async (index) => {
        vi.setSystemTime(2_000);
        await g.turn("first prompt", "first reply");
        await index.syncDurableSession(fork.id);
        vi.setSystemTime(5_000);
        await g.turn("pangolin prompt", "pangolin reply");
        modifiedAt.A = Date.now();
        vi.setSystemTime(10_000);
      });

      vi.setSystemTime(60_000);
      expect(await boot([...listed, fork])).toEqual(["a1"]);
    });
  });

  it("does not index ephemeral durable sessions", async () => {
    const f = await durableFixture();
    await f.turn("incognito secret", "hidden reply");
    const session = makeSession(f.id, { ephemeral: true });
    const index = openIndex(() => session, f.source);

    await index.startBackgroundSync([session]);
    await index.syncDurableSession(session.id);
    expect(index.search("incognito")).toEqual([]);
    expect(f.readTranscript).not.toHaveBeenCalled();
  });
});
