import { describe, expect, it } from "vitest";

import { resolveUniqueSessionId } from "../src/cli/session-id-target.js";

const UUID_A = "019e1fff-5555-7555-8555-555555555555";
const UUID_B = "019e1fff-6666-7666-8666-666666666666";
const UUID_C = "019e2000-7777-7777-8777-777777777777";
const WRAPPER_ID = "RleHDYBu";

describe("resolveUniqueSessionId", () => {
  it("returns an exact Session.id before considering prefixes", () => {
    expect(resolveUniqueSessionId(UUID_A, [UUID_A, UUID_B])).toBe(UUID_A);
    expect(resolveUniqueSessionId(WRAPPER_ID, [WRAPPER_ID, UUID_A])).toBe(WRAPPER_ID);
  });

  it("prefers an exact short wrapper over a longer id that starts with it", () => {
    expect(resolveUniqueSessionId("abc", ["abc", "abcdef"])).toBe("abc");
  });

  it("resolves a unique Session.id prefix", () => {
    expect(resolveUniqueSessionId("019e1fff-5555", [UUID_A, UUID_B, UUID_C])).toBe(UUID_A);
    expect(resolveUniqueSessionId("019e2000", [UUID_A, UUID_C])).toBe(UUID_C);
  });

  it("fails and lists full ids when a prefix is ambiguous", () => {
    expect(() => resolveUniqueSessionId("019e1fff", [UUID_A, UUID_B, UUID_C])).toThrow(
      /Ambiguous session prefix '019e1fff'[\s\S]*019e1fff-5555-7555-8555-555555555555[\s\S]*019e1fff-6666-7666-8666-666666666666/,
    );
    try {
      resolveUniqueSessionId("019e1fff", [UUID_A, UUID_B, UUID_C]);
    } catch (error) {
      expect(error).toMatchObject({
        status: 409,
        code: "session_prefix_ambiguous",
        hint: "Pass more of the UUID until exactly one session matches.",
        exitCode: 1,
      });
    }
  });

  it("caps a long ambiguous id list", () => {
    const many = Array.from(
      { length: 12 },
      (_, index) => `019e1fff-${String(index).padStart(4, "0")}-7000-8000-000000000000`,
    );
    expect(() => resolveUniqueSessionId("019e1fff", many)).toThrow(/and 2 more/);
  });

  it("fails when no Session.id matches the prefix", () => {
    expect(() => resolveUniqueSessionId("019e1fff", [UUID_C])).toThrow(
      "Session not found: 019e1fff",
    );
    expect(() => resolveUniqueSessionId(WRAPPER_ID, [UUID_A])).toThrow(
      `Session not found: ${WRAPPER_ID}`,
    );
  });

  it("does not treat a leftover wrapper id as an alias for a UUID Session.id", () => {
    expect(() => resolveUniqueSessionId(WRAPPER_ID, [UUID_A])).toThrow(
      `Session not found: ${WRAPPER_ID}`,
    );
    expect(resolveUniqueSessionId(WRAPPER_ID, [WRAPPER_ID])).toBe(WRAPPER_ID);
  });
});
