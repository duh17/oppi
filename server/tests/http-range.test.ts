import { describe, expect, it } from "vitest";

import { clampUtf8CodepointRange, parseByteRangeHeader } from "../src/http-range.js";

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
    // AVPlayer Int.max closed ranges are not JS-safe and must stay invalid.
    expect(parseByteRangeHeader("bytes=0-9223372036854775806", 21_123_557)).toEqual({
      kind: "invalid",
    });
    expect(parseByteRangeHeader("bytes=0-1", Number.NaN)).toEqual({ kind: "invalid" });
    expect(parseByteRangeHeader("bytes=0-1", -1)).toEqual({ kind: "invalid" });
  });
});

describe("UTF-8 codepoint range clamping", () => {
  // Tool-output Range responses never split a UTF-8 codepoint: start advances
  // off a continuation byte; end retracts to the last complete scalar.
  const sidecar = Buffer.from("abc😀def", "utf8"); // 10 bytes: 61 62 63 F0 9F 98 80 64 65 66
  const byteAt = (offset: number) => sidecar[offset] ?? 0;

  it.each([0xc0, 0xc1, 0xf5, 0xf6, 0xf7, 0x80, 0xbf])(
    "preserves a chunk boundary after invalid byte %i",
    (byte) => {
      const raw = Buffer.from([0x61, byte, 0x62]);
      expect(clampUtf8CodepointRange(0, 1, raw.length, (at) => raw[at]!)).toEqual({
        start: 0,
        end: 1,
      });
      expect(clampUtf8CodepointRange(1, 2, raw.length, (at) => raw[at]!)).toEqual({
        start: 1,
        end: 2,
      });
    },
  );

  it("serves trailing partial bytes at EOF, as the final drain does", () => {
    for (const raw of [Buffer.from([0x61, 0xe2]), Buffer.from([0x61, 0xf0, 0x9f])]) {
      expect(clampUtf8CodepointRange(0, raw.length - 1, raw.length, (at) => raw[at]!)).toEqual({
        start: 0,
        end: raw.length - 1,
      });
    }
  });

  it("keeps ASCII ranges unchanged", () => {
    expect(clampUtf8CodepointRange(0, 2, sidecar.length, byteAt)).toEqual({
      start: 0,
      end: 2,
    });
  });

  it("retracts an end that lands inside a multi-byte scalar", () => {
    expect(clampUtf8CodepointRange(0, 3, sidecar.length, byteAt)).toEqual({
      start: 0,
      end: 2,
    });
    expect(clampUtf8CodepointRange(0, 5, sidecar.length, byteAt)).toEqual({
      start: 0,
      end: 2,
    });
  });

  it("keeps a range that already ends on a complete scalar", () => {
    expect(clampUtf8CodepointRange(0, 6, sidecar.length, byteAt)).toEqual({
      start: 0,
      end: 6,
    });
  });

  it("advances a start that lands on a continuation byte", () => {
    expect(clampUtf8CodepointRange(4, 9, sidecar.length, byteAt)).toEqual({
      start: 7,
      end: 9,
    });
  });

  it("returns empty when the range contains no complete codepoint", () => {
    expect(clampUtf8CodepointRange(4, 5, sidecar.length, byteAt)).toEqual({ kind: "empty" });
  });
});
