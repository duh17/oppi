import { describe, expect, it } from "vitest";

import { parseByteRangeHeader } from "../src/http-range.js";

describe("HTTP byte range edge cases", () => {
  it("distinguishes absent and unsupported ranges from malformed byte ranges", () => {
    expect(parseByteRangeHeader(undefined, 10)).toEqual({ kind: "none" });
    expect(parseByteRangeHeader("items=0-1", 10)).toEqual({ kind: "none" });
    expect(parseByteRangeHeader(["bytes=0-1", "bytes=2-3"], 10)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("", 10)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("bytes=", 10)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("bytes=-", 10)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("bytes=0-1,4-5", 10)).toEqual({ kind: "invalid" });
  });

  it("normalizes case and whitespace and clamps valid bounds", () => {
    expect(parseByteRangeHeader("  BYTES=2-99  ", 10)).toEqual({
      kind: "valid",
      start: 2,
      end: 9,
    });
    expect(parseByteRangeHeader("bytes=4-", 10)).toEqual({ kind: "valid", start: 4, end: 9 });
    expect(parseByteRangeHeader("bytes=-99", 10)).toEqual({ kind: "valid", start: 0, end: 9 });
    expect(parseByteRangeHeader("bytes=9-9", 10)).toEqual({ kind: "valid", start: 9, end: 9 });
  });

  it("rejects unsafe integers, reversed bounds, and invalid file sizes", () => {
    expect(parseByteRangeHeader("bytes=4-3", 10)).toEqual({ kind: "unsatisfiable" });
    expect(parseByteRangeHeader("bytes=10-", 10)).toEqual({ kind: "unsatisfiable" });
    expect(parseByteRangeHeader("bytes=-0", 10)).toEqual({ kind: "unsatisfiable" });
    expect(parseByteRangeHeader("bytes=0-0", 0)).toEqual({ kind: "unsatisfiable" });
    expect(parseByteRangeHeader("bytes=9007199254740992-", 10)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("bytes=0-1", Number.NaN)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("bytes=0-1", -1)).toEqual({ kind: "invalid" });
  });
});
