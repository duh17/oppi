import { statSync } from "node:fs";

/** A store lock not refreshed for this long is stale: its holder died, and the next open takes it. */
export const DURABLE_STORE_LOCK_STALE_MS = 2_000;

/**
 * Milliseconds until the store lock at `lockPath` goes stale if nobody refreshes it, 0 without
 * one. Capped at the stale window, so a lock dated in the future cannot stall a caller.
 */
export function durableStoreLockStaleInMs(lockPath: string): number {
  let refreshedMs: number;
  try {
    refreshedMs = statSync(lockPath).mtimeMs;
  } catch {
    return 0;
  }
  return Math.min(
    DURABLE_STORE_LOCK_STALE_MS,
    Math.max(0, refreshedMs + DURABLE_STORE_LOCK_STALE_MS - Date.now()),
  );
}
