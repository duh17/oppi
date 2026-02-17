/**
 * Generate a URL-safe random ID. Replaces nanoid — zero deps.
 * Uses crypto.randomBytes with base64url encoding (A-Za-z0-9_-).
 */
import { randomBytes } from "node:crypto";

export function generateId(size: number): string {
  // base64url produces ceil(n * 4/3) chars from n bytes.
  // We need at least `size` chars, so request ceil(size * 3/4) bytes.
  return randomBytes(Math.ceil(size * 0.75))
    .toString("base64url")
    .slice(0, size);
}
