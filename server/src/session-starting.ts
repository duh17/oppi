import type { ExtensionUIState } from "./extension-ui-state.js";
import type { SdkUiBridge } from "./sdk-ui-bridge.js";
import type { ServerMessage, Session } from "./types.js";

/**
 * A session's `starting` phase: the start promise every concurrent caller shares, the stop race
 * (`stopRequested` is how a stop wins before a runtime registers), the dialogs an extension
 * opened before the runtime existed, and the focused sockets relaying them. One entry per key,
 * from `start_begun` to `start_registered`/`start_failed`.
 */
export interface StartingSession {
  /** Set once the start begins; a subscriber can claim an entry before that. */
  promise?: Promise<Session>;
  /** The row's on-disk status right when this start began, read by `fenceStopped`. */
  priorStatus: Session["status"];
  stopRequested: boolean;
  dialogs?: { bridge: SdkUiBridge; state: ExtensionUIState };
  subscribers: Set<(message: ServerMessage) => void>;
}

/** One `StartingSession` per key; `SessionManager` is the only owner. */
export class StartingRegistry {
  private readonly entries = new Map<string, StartingSession>();

  get(key: string): StartingSession | undefined {
    return this.entries.get(key);
  }

  /**
   * The entry a start or a startup-dialog subscriber claims, creating a placeholder if none is
   * live. `priorStatus` refreshes on every claim, so a start reads it right when it begins.
   */
  claim(key: string, priorStatus: () => Session["status"]): StartingSession {
    let entry = this.entries.get(key);
    if (!entry) {
      entry = { priorStatus: priorStatus(), stopRequested: false, subscribers: new Set() };
      this.entries.set(key, entry);
    } else entry.priorStatus = priorStatus();
    return entry;
  }

  /** Clears `key` only while `entry` is still the live one. */
  release(key: string, entry: StartingSession): void {
    if (this.entries.get(key) === entry) this.entries.delete(key);
  }
}
