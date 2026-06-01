import type { SessionBackendEvent } from "./pi-events.js";
import type { Storage } from "./storage.js";

export interface SessionSearchIndex {
  markForReindex(sessionId: string): void;
  flushForSession(sessionId: string): void;
  indexSession(sessionId: string): void;
  deleteSession(sessionId: string): void;
}

/**
 * Apply search-index side effects for a runtime event.
 *
 * Both Oppi-owned SDK sessions and pi-tui mirrored sessions ingest the same Pi
 * agent event stream. Keep indexing policy here so new runtimes do not need to
 * remember route-specific side effects.
 */
export function updateSearchIndexForSessionEvent(
  searchIndex: SessionSearchIndex | null | undefined,
  storage: Pick<Storage, "getSession">,
  sessionId: string,
  event: SessionBackendEvent,
): void {
  if (!searchIndex) {
    return;
  }

  const session = storage.getSession(sessionId);
  if (session?.ephemeral) {
    searchIndex.deleteSession(sessionId);
    return;
  }

  if (event.type === "agent_end") {
    searchIndex.markForReindex(sessionId);
    searchIndex.flushForSession(sessionId);
  }
}
