import type { SessionBackendEvent } from "./pi-events.js";
import type { SearchIndex } from "./search-index.js";

/**
 * Apply search-index side effects for a runtime event.
 *
 * Both Oppi-owned SDK sessions and pi-tui mirrored sessions ingest the same Pi
 * agent event stream. Keep indexing policy here so new runtimes do not need to
 * remember route-specific side effects.
 *
 * This runs for every streamed event, so only a finished turn touches the index.
 * Re-indexing reads the live session row and drops an incognito session's rows
 * instead of writing them.
 */
export function updateSearchIndexForSessionEvent(
  searchIndex: SearchIndex | null | undefined,
  sessionId: string,
  event: SessionBackendEvent,
): void {
  if (searchIndex && event.type === "agent_end") {
    searchIndex.reindexSession(sessionId);
  }
}
