import type { PushEvent } from "../types.js";

/** Every alert `event` this server sends (protocol/push/spec.md §2.4). */
const PUSH_EVENTS: ReadonlySet<string> = new Set<PushEvent>([
  "blocked",
  "error",
  "notify",
  "pairing_approval",
  "device_enrolled",
]);

/**
 * The events a phone listed that this server sends, deduplicated; undefined unless `value` is
 * an array of strings. Names this server does not know are dropped: a newer app may list
 * events an older server never sends.
 */
export function parsePushEvents(value: unknown): PushEvent[] | undefined {
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) {
    return undefined;
  }
  return [...new Set(value)].filter((entry): entry is PushEvent => PUSH_EVENTS.has(entry));
}
