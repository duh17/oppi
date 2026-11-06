/**
 * Narrowing for untrusted JSON-shaped input (parsed files, wire payloads, SDK events).
 * A record is any non-null object that is not an array, so a content-block array is never
 * read as a keyed object. Null-prototype objects and class instances count as records.
 */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function asRecord(value: unknown): Record<string, unknown> | undefined {
  return isRecord(value) ? value : undefined;
}
