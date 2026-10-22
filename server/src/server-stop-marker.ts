import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * A stop the person asked for, as opposed to a restart. `oppi server restart`, the in-app
 * update, launchd's KeepAlive and a Docker restart all reach the serving process as the same
 * SIGTERM that `oppi server stop` sends, so the process cannot tell them apart. The CLI writes
 * this marker before it stops the service; the serving process ends away phones' Live Activity
 * cards only when it finds the marker at shutdown. A stop without one is a restart, which
 * keeps the cards.
 */
export function stopRequestedPath(dataDir: string): string {
  return join(dataDir, "server-stop-requested");
}

/** Best effort: a missing marker only means the cards stay up, as after a restart. */
export function requestServerStop(dataDir: string): void {
  try {
    writeFileSync(stopRequestedPath(dataDir), `${Date.now()}\n`, { mode: 0o600 });
  } catch {
    // The stop goes ahead without it.
  }
}

/** Withdraw a request the stop did not act on (the stop failed, or nothing was running). */
export function clearServerStopRequest(dataDir: string): void {
  try {
    if (existsSync(stopRequestedPath(dataDir))) unlinkSync(stopRequestedPath(dataDir));
  } catch {
    // A stale marker is removed at the next start.
  }
}

/** Whether a stop was requested; removes the marker either way. */
export function consumeServerStopRequest(dataDir: string): boolean {
  const requested = existsSync(stopRequestedPath(dataDir));
  clearServerStopRequest(dataDir);
  return requested;
}
