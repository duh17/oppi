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
    serverDurable: { conversationId },
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
  await storage.commit([{ type: "conversation", value: { id } }], context);
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
    await storage.commit(
      entries.map((value) => ({ type: "entry" as const, value })),
      context,
    );
  }

  const resume = vi.spyOn(harness, "resume");
  const readTranscript = vi.fn((conversationId: number) =>
    readDurableSearchTranscript(harness, conversationId as ConversationId),
  );
  const source: DurableSearchSource = {
    readTipEntryId: (conversationId) =>
      readDurableTipEntryId(harness, conversationId as ConversationId),
    readTranscript,
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
    updateSearchIndexForSessionEvent(index, { getSession: () => session }, session.id, {
      type: "agent_end",
    } as never);
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
        shell.serverDurable = { conversationId: f.id };
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
