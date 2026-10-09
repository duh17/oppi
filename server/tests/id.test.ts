import { describe, expect, it } from "vitest";
import { generateId } from "../src/id.js";

const ALPHABET = /^[A-Za-z0-9_-]+$/;

describe("generateId", () => {
  it("never starts with a dash, and keeps length and the base64url alphabet", () => {
    const sample = Array.from({ length: 20_000 }, () => generateId(8));
    expect(sample.every((id) => id.length === 8 && ALPHABET.test(id) && !id.startsWith("-"))).toBe(
      true,
    );
    // A leading "_" is still a positional, so it stays in the alphabet.
    expect(sample.some((id) => id.startsWith("_"))).toBe(true);
    for (const size of [1, 12, 16, 24]) {
      const id = generateId(size);
      expect(id).toHaveLength(size);
      expect(id.startsWith("-")).toBe(false);
      expect(id).toMatch(ALPHABET);
    }
  });
});
