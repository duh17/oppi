import type { ExtensionUIState } from "./extension-ui-state.js";
import type { SdkUiBridge } from "./sdk-ui-bridge.js";
import type { ServerMessage, Session } from "./types.js";

/**
 * A session's `starting` phase: the start promise every concurrent caller shares, the stop race
 * (`stopRequested` is how a stop wins before a runtime registers), the dialogs an extension
 * opened before the runtime existed, and the focused sockets relaying them. A socket subscribes
 * before it opens the session, so an entry can outlive a start or exist without one.
 */
export interface StartingSession {
  /** The start in flight, from `start_begun` to `start_registered`/`start_failed`. */
  start?: {
    promise: Promise<Session>;
    /** The row's on-disk status when this start began, read by `fenceStopped`. */
    priorStatus: Session["status"];
    stopRequested: boolean;
  };
  dialogs?: { bridge: SdkUiBridge; state: ExtensionUIState };
  subscribers: Set<(message: ServerMessage) => void>;
}

/** One `StartingSession` per key; `SessionManager` is the only owner. */
export class StartingRegistry {
  private readonly entries = new Map<string, StartingSession>();

  get(key: string): StartingSession | undefined {
    return this.entries.get(key);
  }

  claim(key: string): StartingSession {
    let entry = this.entries.get(key);
    if (!entry) {
      entry = { subscribers: new Set() };
      this.entries.set(key, entry);
    }
    return entry;
  }

  /** Drops `entry` once neither a start nor a subscriber holds it. */
  release(key: string, entry: StartingSession): void {
    if (!entry.start && !entry.subscribers.size && this.entries.get(key) === entry)
      this.entries.delete(key);
  }
}
