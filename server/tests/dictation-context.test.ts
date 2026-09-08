/**
 * Per-take dictation vocabulary bounds and start-message parsing.
 *
 * Shared wire contract: optional contextualStrings on dictation_start.
 * Errors must be predictable and must not echo raw phrases.
 */
import { describe, expect, it } from "vitest";
import {
  DICTATION_CONTEXT_MAX_PHRASE_BYTES,
  DICTATION_CONTEXT_MAX_PHRASES,
  DICTATION_CONTEXT_MAX_TOTAL_BYTES,
  parseDictationClientMessage,
  parseDictationContextualStrings,
  trimDictationContextBlanks,
} from "../src/dictation-types.js";

function utf8Repeat(ch: string, bytes: number): string {
  const unit = Buffer.byteLength(ch, "utf8");
  if (bytes % unit !== 0) {
    throw new Error(`utf8Repeat: ${bytes} is not a multiple of ${unit}`);
  }
  return ch.repeat(bytes / unit);
}

describe("parseDictationContextualStrings", () => {
  it("omits the field when it is absent", () => {
    expect(parseDictationContextualStrings(undefined)).toEqual({ ok: true });
  });

  it("omits an empty array", () => {
    expect(parseDictationContextualStrings([])).toEqual({ ok: true });
  });

  it("accepts ordinary phrases including internal spaces", () => {
    expect(parseDictationContextualStrings(["Yuwp", "Hint Extractor"])).toEqual({
      ok: true,
      contextualStrings: ["Yuwp", "Hint Extractor"],
    });
  });

  it("preserves surrounding spaces in otherwise valid phrases", () => {
    expect(parseDictationContextualStrings(["  Foo Bar  "])).toEqual({
      ok: true,
      contextualStrings: ["  Foo Bar  "],
    });
  });

  it("accepts the maximum phrase count", () => {
    const phrases = Array.from({ length: DICTATION_CONTEXT_MAX_PHRASES }, (_, i) => `p${i}`);
    const result = parseDictationContextualStrings(phrases);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.contextualStrings).toHaveLength(DICTATION_CONTEXT_MAX_PHRASES);
    }
  });

  it("rejects more than 100 phrases", () => {
    const phrases = Array.from({ length: DICTATION_CONTEXT_MAX_PHRASES + 1 }, (_, i) => `p${i}`);
    const result = parseDictationContextualStrings(phrases);
    expect(result).toEqual({
      ok: false,
      error: "dictation contextualStrings allows at most 100 phrases",
    });
  });

  it("accepts a 256-byte phrase", () => {
    const phrase = utf8Repeat("é", DICTATION_CONTEXT_MAX_PHRASE_BYTES);
    expect(Buffer.byteLength(phrase, "utf8")).toBe(DICTATION_CONTEXT_MAX_PHRASE_BYTES);
    expect(parseDictationContextualStrings([phrase])).toEqual({
      ok: true,
      contextualStrings: [phrase],
    });
  });

  it("rejects a phrase over 256 UTF-8 bytes", () => {
    const phrase = utf8Repeat("é", DICTATION_CONTEXT_MAX_PHRASE_BYTES + 2);
    const result = parseDictationContextualStrings([phrase]);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe("dictation contextualStrings phrase exceeds 256 UTF-8 bytes");
      expect(result.error).not.toContain(phrase);
    }
  });

  it("accepts a total of 8192 UTF-8 bytes", () => {
    const phrase = utf8Repeat("a", DICTATION_CONTEXT_MAX_PHRASE_BYTES);
    const phrases = Array.from(
      { length: DICTATION_CONTEXT_MAX_TOTAL_BYTES / DICTATION_CONTEXT_MAX_PHRASE_BYTES },
      () => phrase,
    );
    expect(phrases.reduce((sum, item) => sum + Buffer.byteLength(item, "utf8"), 0)).toBe(
      DICTATION_CONTEXT_MAX_TOTAL_BYTES,
    );
    const result = parseDictationContextualStrings(phrases);
    expect(result.ok).toBe(true);
  });

  it("rejects a total over 8192 UTF-8 bytes", () => {
    const phrase = utf8Repeat("a", DICTATION_CONTEXT_MAX_PHRASE_BYTES);
    const phrases = [
      ...Array.from(
        { length: DICTATION_CONTEXT_MAX_TOTAL_BYTES / DICTATION_CONTEXT_MAX_PHRASE_BYTES },
        () => phrase,
      ),
      "x",
    ];
    const result = parseDictationContextualStrings(phrases);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe("dictation contextualStrings total exceeds 8192 UTF-8 bytes");
      expect(result.error).not.toContain(phrase);
    }
  });

  it("rejects empty and whitespace-only phrases", () => {
    expect(parseDictationContextualStrings([""])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include empty phrases",
    });
    expect(parseDictationContextualStrings(["   "])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include empty phrases",
    });
  });

  it("rejects FEFF, ZWSP, and Unicode spaces as blank-only vocabulary", () => {
    expect(parseDictationContextualStrings(["\uFEFF"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include empty phrases",
    });
    expect(parseDictationContextualStrings(["\u200B"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include empty phrases",
    });
    expect(parseDictationContextualStrings(["\u00A0\u2000\u3000"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include empty phrases",
    });
    expect(parseDictationContextualStrings([" \u200B\uFEFF "])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include empty phrases",
    });
  });

  it("preserves mixed non-blank phrases that include Unicode spaces", () => {
    expect(parseDictationContextualStrings(["Foo\u00A0Bar"])).toEqual({
      ok: true,
      contextualStrings: ["Foo\u00A0Bar"],
    });
    expect(parseDictationContextualStrings(["Foo\uFEFF"])).toEqual({
      ok: true,
      contextualStrings: ["Foo\uFEFF"],
    });
  });

  it("client trim uses the same blank policy including FEFF and ZWSP", () => {
    expect(trimDictationContextBlanks("\uFEFFFoo\uFEFF")).toBe("Foo");
    expect(trimDictationContextBlanks("\u200BFoo\u200B")).toBe("Foo");
    expect(trimDictationContextBlanks("\u00A0")).toBe("");
  });

  it("rejects control characters on the raw string before trimming", () => {
    expect(parseDictationContextualStrings(["foo\nbar"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include control characters",
    });
    expect(parseDictationContextualStrings(["Alpha\n"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include control characters",
    });
    expect(parseDictationContextualStrings(["\tAlpha"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include control characters",
    });
    expect(parseDictationContextualStrings(["ok\u0000"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include control characters",
    });
    expect(parseDictationContextualStrings(["ok\u007f"])).toEqual({
      ok: false,
      error: "dictation contextualStrings cannot include control characters",
    });
  });

  it("rejects raw UTF-8 over 256 bytes even when trim would fit", () => {
    const padded = ` ${utf8Repeat("a", DICTATION_CONTEXT_MAX_PHRASE_BYTES)}`;
    expect(Buffer.byteLength(padded, "utf8")).toBe(DICTATION_CONTEXT_MAX_PHRASE_BYTES + 1);
    expect(Buffer.byteLength(padded.trim(), "utf8")).toBe(DICTATION_CONTEXT_MAX_PHRASE_BYTES);
    const result = parseDictationContextualStrings([padded]);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe("dictation contextualStrings phrase exceeds 256 UTF-8 bytes");
      expect(result.error).not.toContain(padded);
    }
  });

  it("counts Unicode on the supplied UTF-8 bytes, not JS string length", () => {
    const nfc = "é"; // U+00E9, 2 UTF-8 bytes
    const nfd = "e\u0301"; // e + combining acute, 3 UTF-8 bytes
    expect(nfc.length).toBe(1);
    expect(nfd.length).toBe(2);
    expect(Buffer.byteLength(nfc, "utf8")).toBe(2);
    expect(Buffer.byteLength(nfd, "utf8")).toBe(3);
    expect(parseDictationContextualStrings([nfc, nfd])).toEqual({
      ok: true,
      contextualStrings: [nfc, nfd],
    });

    const over = utf8Repeat(nfd, 258);
    expect(over.length).toBeLessThan(Buffer.byteLength(over, "utf8"));
    expect(Buffer.byteLength(over, "utf8")).toBeGreaterThan(DICTATION_CONTEXT_MAX_PHRASE_BYTES);
    const result = parseDictationContextualStrings([over]);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe("dictation contextualStrings phrase exceeds 256 UTF-8 bytes");
      expect(result.error).not.toContain(over);
    }
  });

  it("rejects non-array, null, and non-string values as malformed supplied context", () => {
    expect(parseDictationContextualStrings(null)).toEqual({
      ok: false,
      error: "dictation contextualStrings must be an array of strings",
    });
    expect(parseDictationContextualStrings("Yuwp")).toEqual({
      ok: false,
      error: "dictation contextualStrings must be an array of strings",
    });
    expect(parseDictationContextualStrings([1])).toEqual({
      ok: false,
      error: "dictation contextualStrings must be an array of strings",
    });
  });
});

describe("parseDictationClientMessage", () => {
  it("parses a fieldless dictation_start", () => {
    expect(parseDictationClientMessage({ type: "dictation_start" })).toEqual({
      ok: true,
      message: { type: "dictation_start" },
    });
  });

  it("attaches valid contextualStrings to dictation_start", () => {
    expect(
      parseDictationClientMessage({
        type: "dictation_start",
        contextualStrings: ["Foo Bar", "Yuwp"],
      }),
    ).toEqual({
      ok: true,
      message: { type: "dictation_start", contextualStrings: ["Foo Bar", "Yuwp"] },
    });
  });

  it("omits empty contextualStrings from dictation_start", () => {
    expect(
      parseDictationClientMessage({
        type: "dictation_start",
        contextualStrings: [],
      }),
    ).toEqual({
      ok: true,
      message: { type: "dictation_start" },
    });
  });

  it("rejects null contextualStrings as malformed supplied context", () => {
    expect(
      parseDictationClientMessage({
        type: "dictation_start",
        contextualStrings: null,
      }),
    ).toEqual({
      ok: false,
      error: "dictation contextualStrings must be an array of strings",
    });
  });

  it("rejects malformed contextualStrings without starting semantics", () => {
    const result = parseDictationClientMessage({
      type: "dictation_start",
      contextualStrings: ["bad\nphrase"],
    });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toBe("dictation contextualStrings cannot include control characters");
      expect(result.error).not.toContain("bad");
    }
  });

  it("parses stop and cancel without extra fields", () => {
    expect(parseDictationClientMessage({ type: "dictation_stop" })).toEqual({
      ok: true,
      message: { type: "dictation_stop" },
    });
    expect(parseDictationClientMessage({ type: "dictation_cancel" })).toEqual({
      ok: true,
      message: { type: "dictation_cancel" },
    });
  });

  it("rejects missing or empty type", () => {
    expect(parseDictationClientMessage({})).toEqual({
      ok: false,
      error: "Message type is required",
    });
    expect(parseDictationClientMessage({ type: "  " })).toEqual({
      ok: false,
      error: "Message type is required",
    });
  });
});
