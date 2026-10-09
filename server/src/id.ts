/**
 * Generate a URL-safe random ID. Replaces nanoid — zero deps.
 * Uses crypto.randomBytes with base64url encoding (A-Za-z0-9_-).
 * A leading "-" is an unknown CLI flag (`oppi agent update -abc`), so that draw is discarded.
 * A leading "_" is an ordinary positional and is left alone.
 */
import { randomBytes, randomUUID } from "node:crypto";

export function generateId(size: number): string {
  // base64url produces ceil(n * 4/3) chars from n bytes.
  // We need at least `size` chars, so request ceil(size * 3/4) bytes.
  let id: string;
  do {
    id = randomBytes(Math.ceil(size * 0.75))
      .toString("base64url")
      .slice(0, size);
  } while (id.startsWith("-"));
  return id;
}

/** Mint the canonical Oppi/Pi session identity before the first persist. */
export function mintSessionId(): string {
  return randomUUID();
}
