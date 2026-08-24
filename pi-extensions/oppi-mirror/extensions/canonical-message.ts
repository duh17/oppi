export interface MirrorSessionEntry {
  type: string;
  id: string;
  parentId: string | null;
  message?: {
    role?: string;
    content?: unknown;
  };
}

export interface MirrorSessionTree {
  getLeafId(): string | null;
  getLeafEntry(): MirrorSessionEntry | undefined;
  getEntry(id: string): MirrorSessionEntry | undefined;
}

export interface PendingMirrorMessage {
  preAppendLeafId: string | null;
  event: unknown;
  expectedRole?: string;
}

const MAX_PARENT_WALK = 8;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function messageFromMirrorEvent(event: unknown): {
  role?: string;
  content?: unknown;
} {
  if (!isRecord(event)) {
    return {};
  }
  const message = event.message;
  if (!isRecord(message)) {
    return {};
  }
  return {
    ...(typeof message.role === "string" ? { role: message.role } : {}),
    ...("content" in message ? { content: message.content } : {}),
  };
}

function toolCallIds(content: unknown): string[] {
  if (!Array.isArray(content)) {
    return [];
  }
  return content.flatMap((part) => {
    if (!isRecord(part) || part.type !== "toolCall") {
      return [];
    }
    return typeof part.id === "string" && part.id.length > 0 ? [part.id] : [];
  });
}

function isMatchingMessage(
  entry: MirrorSessionEntry | undefined,
  expected: { role?: string; content?: unknown },
): boolean {
  if (!entry || entry.type !== "message" || !entry.message) {
    return false;
  }
  if (entry.message.role !== expected.role) {
    return false;
  }
  const expectedTools = toolCallIds(expected.content);
  const persistedTools = toolCallIds(entry.message.content);
  if (expectedTools.length !== persistedTools.length) {
    return false;
  }
  return expectedTools.every((id, index) => id === persistedTools[index]);
}

function walkAncestors(
  tree: MirrorSessionTree,
  start: MirrorSessionEntry | undefined,
  stopId: string | null,
): MirrorSessionEntry[] | null {
  const chain: MirrorSessionEntry[] = [];
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

export function resolveMirrorPersistedMessage(
  tree: MirrorSessionTree,
  pending: PendingMirrorMessage,
): MirrorSessionEntry | null {
  const expected = messageFromMirrorEvent(pending.event);
  if (pending.expectedRole && expected.role && pending.expectedRole !== expected.role) {
    return null;
  }
  const leaf = tree.getLeafEntry();
  const callbackMessage = isRecord(pending.event) ? pending.event.message : undefined;
  if (leaf?.type === "message" && leaf.message === callbackMessage) {
    return leaf;
  }
  if (pending.preAppendLeafId !== null && leaf?.id === pending.preAppendLeafId) {
    return null;
  }

  const chain = walkAncestors(tree, leaf, pending.preAppendLeafId);
  if (!chain) {
    return null;
  }
  for (const entry of [...chain].reverse()) {
    if (isMatchingMessage(entry, expected)) {
      return entry;
    }
  }
  return null;
}

export function withMirrorEntryId(event: unknown, entryId: string): Record<string, unknown> {
  const record = isRecord(event) ? event : {};
  return {
    ...record,
    type: typeof record.type === "string" ? record.type : "message_end",
    entryId,
    ...(isRecord(record.message) ? { message: record.message } : {}),
  };
}
