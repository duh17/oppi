import { stat } from "node:fs/promises";
import type { ConversationId, Harness } from "@earendil-works/pi-durable";
import type { DurableHarness } from "./durable-harness.js";
import type { DurableSearchSource } from "./search-index.js";
import { DURABLE_STORE_MISSING, requireDurableStoreId } from "./session-runtime-capabilities.js";
import type { Storage } from "./storage.js";

/** Read-only Harness access for the search index. */
export function createDurableSearchSource(
  storage: Storage,
  runtime: () => Promise<DurableHarness>,
): DurableSearchSource {
  const withConversation = async <T>(
    sessionId: string,
    read: (harness: Harness, id: ConversationId) => Promise<T>,
  ): Promise<T> => {
    const session = storage.getSession(sessionId);
    const conversationId = session?.serverDurable?.conversationId;
    if (!session || conversationId === undefined) throw new Error(DURABLE_STORE_MISSING);
    return (await runtime()).withSession(session, (harness) =>
      read(harness, conversationId as ConversationId),
    );
  };
  return {
    readTipEntryId: async (sessionId) => {
      const { readDurableTipEntryId } = await import("./durable-history.js");
      return withConversation(sessionId, readDurableTipEntryId);
    },
    readTranscript: async (sessionId, throughEntryId) => {
      const { readDurableSearchTranscript } = await import("./durable-history.js");
      return withConversation(sessionId, (harness, id) =>
        readDurableSearchTranscript(harness, id, throughEntryId),
      );
    },
    readTranscriptAddition: async (sessionId, afterEntryId, throughEntryId) => {
      const { readDurableSearchAddition } = await import("./durable-history.js");
      return withConversation(sessionId, (harness, id) =>
        readDurableSearchAddition(harness, id, afterEntryId, throughEntryId),
      );
    },
    holdStore: async (sessionId) => {
      const session = storage.getSession(sessionId);
      if (!session) throw new Error(DURABLE_STORE_MISSING);
      const host = await (await runtime()).openHost(requireDurableStoreId(session));
      return host.retain("search-index");
    },
    storeModifiedAtMs: async (storeId) => {
      const { durableStoreSqlitePath } = await import("./durable-harness.js");
      const sqlite = durableStoreSqlitePath(storage.getDataDir(), storeId);
      const mtime = (path: string, missing: number): Promise<number> =>
        stat(path).then(
          (file) => file.mtimeMs,
          () => missing,
        );
      return Math.max(await mtime(sqlite, Infinity), await mtime(`${sqlite}-wal`, 0));
    },
  };
}
