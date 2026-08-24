import {
  messageFromMirrorEvent,
  resolveMirrorPersistedMessage,
  withMirrorEntryId,
  type MirrorSessionTree,
  type PendingMirrorMessage,
} from "./canonical-message.ts";

export interface MirrorCanonicalFlush {
  captureMessageEnd(event: unknown, tree: MirrorSessionTree): void;
  flush(
    tree: MirrorSessionTree,
  ): { event: Record<string, unknown>; guessed: false } | { event: unknown; guessed: true } | null;
  discard(): void;
  hasPending(): boolean;
}

export function createMirrorCanonicalFlush(
  onUnresolved?: (details: {
    expectedRole?: string;
    capturedLeaf: string | null;
    observedLeaf: string | null;
  }) => void,
): MirrorCanonicalFlush {
  let pending: PendingMirrorMessage | null = null;

  return {
    captureMessageEnd(event, tree) {
      pending = {
        preAppendLeafId: tree.getLeafId(),
        event,
        expectedRole: messageFromMirrorEvent(event).role,
      };
    },
    flush(tree) {
      if (!pending) {
        return null;
      }
      const current = pending;
      const resolved = resolveMirrorPersistedMessage(tree, current);
      if (resolved) {
        pending = null;
        const persistedEvent = {
          ...(typeof current.event === "object" && current.event !== null
            ? (current.event as Record<string, unknown>)
            : {}),
          type: "message_end",
          message: resolved.message ?? messageFromMirrorEvent(current.event),
        };
        return { event: withMirrorEntryId(persistedEvent, resolved.id), guessed: false };
      }
      if (
        current.preAppendLeafId !== null &&
        tree.getLeafId() === current.preAppendLeafId
      ) {
        // Pi has not appended yet. Keep the pending frame for a later event.
        return null;
      }
      pending = null;
      onUnresolved?.({
        expectedRole: current.expectedRole,
        capturedLeaf: current.preAppendLeafId,
        observedLeaf: tree.getLeafId(),
      });
      return { event: current.event, guessed: true };
    },
    discard() {
      pending = null;
    },
    hasPending() {
      return pending !== null;
    },
  };
}
