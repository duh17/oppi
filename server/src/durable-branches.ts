/**
 * Tree navigation for a durable session, after p2's `/tree`: a durable conversation is a linear
 * list of entries, so every branch is a conversation of its own, forked from another at an entry
 * (`SessionHost.forkConversation`). The session's branches and which one is current live in
 * `DurableBranchesDoc`; the session follows the current one (`serverDurable.conversationId`).
 */
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
  defineDocFamily,
  type ConversationId,
  type EntryId,
  type Harness,
} from "@earendil-works/pi-durable";
import type { SessionHost } from "./durable-harness.js";
import { readDurableSessionEntries } from "./durable-history.js";
import {
  sessionTreeManagerFromTree,
  type SessionTreeEntry,
  type SessionTreeManager,
  type SessionTreeNode,
} from "./session-tree.js";

/**
 * One Oppi session's branches: `conversation` is the current one, the one the session is bound
 * to and the only one that takes input; `branches` lists every branch in creation order, the
 * session's first conversation first. Session-scoped and keyed by the Oppi session id, because
 * the sessions forked from one another share a store, and each has its own branches. Absent
 * until the session first navigates: then its bound conversation is its only branch. The seed is
 * that conversation.
 */
export const DurableBranchesDoc = defineDocFamily<
  { conversation: number; branches: number[] },
  number
>({
  kind: "oppi.branches",
  version: 1,
  family: true,
  scope: "session",
  initial: (root) => ({ conversation: root, branches: [root] }),
  // Written only when the session navigates.
  checkpointWhen: () => true,
});

export interface DurableBranches {
  /** The current branch. */
  conversation: ConversationId;
  /** Every branch, the session's first conversation first. */
  branches: ConversationId[];
}

/** `sessionId`'s branches; `bound` is its conversation, its only branch until it navigates. */
export async function readDurableBranches(
  harness: Harness,
  sessionId: string,
  bound: ConversationId,
): Promise<DurableBranches> {
  const state = await harness.snapshot(DurableBranchesDoc, sessionId, BACKGROUND_CONTEXT);
  return state
    ? {
        conversation: state.conversation as ConversationId,
        branches: state.branches as ConversationId[],
      }
    : { conversation: bound, branches: [bound] };
}

/**
 * A branch's whole history as the tree shows it, oldest first: the session's trace entries
 * without system prompts, each hung below the entry the tree shows before it. Its last entry
 * is where the branch ends, for the tree's leaf and for finding a branch to switch back to.
 */
async function treeEntries(harness: Harness, id: ConversationId): Promise<SessionTreeEntry[]> {
  const entries: SessionTreeEntry[] = [];
  /** System prompt entries, which are no messages of the tree, by the entry before each. */
  const skipped = new Map<string, string | null>();
  for (const entry of await readDurableSessionEntries(harness, id)) {
    const parentId =
      entry.parentId && skipped.has(entry.parentId)
        ? (skipped.get(entry.parentId) ?? null)
        : (entry.parentId ?? null);
    if (entry.type === "message" && (entry.message as { role: string }).role === "system")
      skipped.set(entry.id, parentId);
    else entries.push({ ...entry, parentId } as SessionTreeEntry);
  }
  return entries;
}

/**
 * The tree of every branch's entries. A shared history has the same entries (entry ids are
 * store-wide), so each branch adds only the entries after its fork point, hung below the entry
 * it continues from. The leaf is the current branch's last entry. Reads every branch's whole
 * history per call.
 */
export async function readDurableSessionTree(
  harness: Harness,
  sessionId: string,
  bound: ConversationId,
): Promise<SessionTreeManager> {
  const { conversation, branches } = await readDurableBranches(harness, sessionId, bound);
  const nodes = new Map<string, SessionTreeNode>();
  const roots: SessionTreeNode[] = [];
  let leafId: string | null = null;
  for (const id of branches) {
    const entries = await treeEntries(harness, id);
    for (const entry of entries) {
      if (nodes.has(entry.id)) continue;
      const node: SessionTreeNode = { entry, children: [] };
      nodes.set(entry.id, node);
      const parent = entry.parentId ? nodes.get(entry.parentId) : undefined;
      (parent ? parent.children : roots).push(node);
    }
    if (id === conversation) leafId = entries.at(-1)?.id ?? null;
  }
  return sessionTreeManagerFromTree(roots, leafId);
}

/**
 * Move `sessionId`'s current branch so the session continues at tree entry `targetId`, by pi's
 * rule: before a user message (its text comes back for the editor), after any other entry. A
 * branch already ending there becomes current (the current one first: nothing changes);
 * otherwise a fork of the branch showing the entry, or a fresh conversation before the first
 * message, is created and made current in the same commit. The branch left keeps its history.
 * Returns the current branch; the caller rebinds the session to it.
 */
export async function navigateDurableBranch(
  host: SessionHost,
  sessionId: string,
  bound: ConversationId,
  targetId: string,
): Promise<{ conversation: ConversationId; editorText?: string }> {
  const { harness } = await host.open();
  const { conversation: current, branches } = await readDurableBranches(harness, sessionId, bound);
  const order = [current, ...branches.filter((id) => id !== current)];
  const histories = new Map<ConversationId, SessionTreeEntry[]>();
  for (const id of order) histories.set(id, await treeEntries(harness, id));
  // The branch showing the entry.
  let source: ConversationId | undefined;
  let chosen: SessionTreeEntry | undefined;
  for (const [id, entries] of histories) {
    chosen = entries.find((entry) => entry.id === targetId);
    if (!chosen) continue;
    source = id;
    break;
  }
  if (source === undefined || !chosen)
    throw new Error(`Entry ${targetId} is not in this session's tree`);
  const message = chosen.type === "message" ? (chosen.message as UserMessage) : undefined;
  const user = message?.role === "user";
  const point = user ? (chosen.parentId ?? null) : chosen.id;
  const editorText = user ? messageText(message.content) : undefined;
  const result = (
    conversation: ConversationId,
  ): { conversation: ConversationId; editorText?: string } => ({
    conversation,
    ...(editorText !== undefined ? { editorText } : {}),
  });
  for (const [id, entries] of histories) {
    if ((entries.at(-1)?.id ?? null) !== point) continue;
    if (id !== current)
      await harness.commit(async (tx) => {
        (await tx.doc(DurableBranchesDoc, sessionId, bound)).conversation = id;
      }, BACKGROUND_CONTEXT);
    return result(id);
  }
  const fork = await host.forkAt(
    source,
    point === null ? undefined : (Number(point) as EntryId),
    async (tx, id) => {
      const state = await tx.doc(DurableBranchesDoc, sessionId, bound);
      state.conversation = id;
      state.branches.push(id);
    },
  );
  return result(fork);
}

type UserMessage = {
  role: string;
  content: string | ReadonlyArray<{ type: string; text?: string }>;
};

function messageText(content: UserMessage["content"]): string {
  if (typeof content === "string") return content;
  return content
    .flatMap((block) => (block.type === "text" && block.text ? [block.text] : []))
    .join("\n");
}
