import { describe, expect, test } from "bun:test";
import { bump, parseProjectYmlPackages } from "./deps-check";

describe("bump", () => {
  test("classifies by the first differing component", () => {
    expect(bump("2.9.5", "2.9.6")).toBe("patch");
    expect(bump("2.9.5", "2.10.0")).toBe("minor");
    expect(bump("2.9.5", "3.0.0")).toBe("major");
    expect(bump("2.9.5", "v2.9.5")).toBe("current");
    expect(bump("2.9.5", "2.9.4")).toBe("ahead");
    expect(bump("2.9.5", "nightly")).toBe("unknown");
  });
});

describe("parseProjectYmlPackages", () => {
  test("keeps each pin with the nearest comment block above it", () => {
    const yml = [
      "packages:",
      "  A:",
      "    url: https://github.com/o/a.git",
      '    from: "1.0.0"',
      "  # scanner.c is hardcoded;",
      "  # pin exact.",
      "  B:",
      "    url: https://github.com/o/b",
      '    exactVersion: "0.23.1"',
      "  C:",
      "    url: https://github.com/o/c",
      "    revision: abc123",
      "options:",
      '  x: "1"',
    ].join("\n");
    const [a, b, c] = parseProjectYmlPackages(yml);
    expect([a.rule, a.value, a.comment]).toEqual(["from", "1.0.0", ""]);
    expect([b.rule, b.value, b.comment]).toEqual(["exactVersion", "0.23.1", "scanner.c is hardcoded; pin exact."]);
    expect([c.rule, c.comment]).toEqual(["revision", "scanner.c is hardcoded; pin exact."]);
  });
});
