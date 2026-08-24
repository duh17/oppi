import type { SessionEntry } from "@earendil-works/pi-coding-agent";

import type { AssistantMessageContentPart } from "./types.js";
import type { PiMessage } from "./pi-events.js";

/** Session tree surface used to prove a persisted message after Pi appends. */
export interface CanonicalSessionTree {
  getLeafId(): string | null;
  getLeafEntry(): SessionEntry | undefined;
  getEntry(id: string): SessionEntry | undefined;
  getEntries?(): SessionEntry[];
}

export interface PendingCanonicalMessage {
  preAppendLeafId: string | null;
  event: {
    type: "message_end";
    message: PiMessage & { role?: string };
  };
}

export interface CanonicalBlockIdInput {
  entryId: string;
  kind: AssistantMessageContentPart["kind"];
  contentIndex: number;
  toolCallId?: string;
  /** True when the persisted assistant content is a bare string, not an array. */
  stringContent?: boolean;
}

const MAX_PARENT_WALK = 8;

/**
 * Server-owned rendered-block IDs. Trace and final live projection must call
 * this helper so Apple can upsert by exact identity.
 */
export function canonicalAssistantBlockId(input: CanonicalBlockIdInput): string | undefined {
  switch (input.kind) {
    case "text":
      return input.stringContent === true
        ? input.entryId
        : `${input.entryId}-text-${input.contentIndex}`;
    case "thinking":
      return `${input.entryId}-think-${input.contentIndex}`;
    case "tool":
      return input.toolCallId && input.toolCallId.length > 0
        ? input.toolCallId
        : `${input.entryId}-tool-${input.contentIndex}`;
    case "boundary":
      return undefined;
  }
}

export function renderableCanonicalBlockIds(parts: AssistantMessageContentPart[]): string[] {
  return parts.flatMap((part) =>
    typeof part.id === "string" && part.id.length > 0 ? [part.id] : [],
  );
}

function isMessageEntry(
  entry: SessionEntry | undefined,
): entry is Extract<SessionEntry, { type: "message" }> {
  return entry?.type === "message" && entry.message !== undefined;
}

function toolCallIds(message: PiMessage | undefined): string[] {
  const content = message?.content;
  if (!Array.isArray(content)) {
    return [];
  }
  return content.flatMap((part) => {
    if (!part || typeof part !== "object") {
      return [];
    }
    const record = part as { type?: unknown; id?: unknown };
    if (record.type !== "toolCall" || typeof record.id !== "string" || record.id.length === 0) {
      return [];
    }
    return [record.id];
  });
}

export function messageRole(message: PiMessage | undefined): string | undefined {
  return typeof message?.role === "string" ? message.role : undefined;
}

/**
 * Role plus tool-call structure must match. Content is not compared: a later
 * extension can replace callback text, and identical text can belong to two
 * entries.
 */
export function isMatchingPersistedMessage(
  entry: SessionEntry | undefined,
  expected: PiMessage,
): entry is Extract<SessionEntry, { type: "message" }> {
  if (!isMessageEntry(entry)) {
    return false;
  }
  if (messageRole(entry.message) !== messageRole(expected)) {
    return false;
  }
  const expectedTools = toolCallIds(expected);
  const persistedTools = toolCallIds(entry.message);
  if (expectedTools.length !== persistedTools.length) {
    return false;
  }
  return expectedTools.every((id, index) => id === persistedTools[index]);
}

function walkAncestors(
  tree: CanonicalSessionTree,
  start: SessionEntry | undefined,
  stopId: string | null,
): SessionEntry[] | null {
  const chain: SessionEntry[] = [];
  let current = start;
  for (let hops = 0; hops < MAX_PARENT_WALK && current; hops += 1) {
    if (stopId !== null && current.id === stopId) {
      return chain;
    }
    chain.push(current);
    if (stopId !== null && current.parentId === stopId) {
      return chain;
    }
    if (current.parentId === null || current.parentId === undefined) {
      return stopId === null ? chain : null;
    }
    current = tree.getEntry(current.parentId);
  }
  return stopId === null && current === undefined ? chain : null;
}

/**
 * Resolve the persisted message that Pi appended after a pre-append
 * `message_end` callback. Walks only entries added since the captured leaf.
 */
export function resolvePersistedMessageEntry(
  tree: CanonicalSessionTree,
  pending: PendingCanonicalMessage,
): Extract<SessionEntry, { type: "message" }> | null {
  const leaf = tree.getLeafEntry();
  // Persisted-before-notify: Pi appended the same message object already.
  // Do not match a previous sibling by role/content — identical text is two entries.
  if (isMessageEntry(leaf) && leaf.message === pending.event.message) {
    return leaf;
  }

  if (pending.preAppendLeafId !== null && leaf?.id === pending.preAppendLeafId) {
    return null;
  }

  const chain = walkAncestors(tree, leaf, pending.preAppendLeafId);
  if (!chain) {
    return null;
  }

  const descendants = [...chain].reverse();
  for (const entry of descendants) {
    if (isMatchingPersistedMessage(entry, pending.event.message)) {
      return entry;
    }
  }
  return null;
}

/**
 * One full-session scan, only after the cheap parent walk failed.
 * Must never run on `message_update`.
 */
export function resolvePersistedMessageEntrySlow(
  tree: CanonicalSessionTree,
  pending: PendingCanonicalMessage,
): Extract<SessionEntry, { type: "message" }> | null {
  const entries = tree.getEntries?.();
  if (!entries || entries.length === 0) {
    return null;
  }

  const captured = pending.preAppendLeafId;
  const candidates = entries.flatMap((entry) => {
    if (!isMatchingPersistedMessage(entry, pending.event.message)) {
      return [];
    }
    if (captured === null) {
      return entry.parentId === null ? [entry] : [];
    }
    return entry.parentId === captured ? [entry] : [];
  });

  return candidates.length === 1 ? (candidates[0] ?? null) : null;
}

export function sessionTreeFromUnknown(value: unknown): CanonicalSessionTree | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  const candidate = value as Partial<CanonicalSessionTree>;
  if (
    typeof candidate.getLeafId !== "function" ||
    typeof candidate.getLeafEntry !== "function" ||
    typeof candidate.getEntry !== "function"
  ) {
    return undefined;
  }
  return candidate as CanonicalSessionTree;
}
