/**
 * The layout validator against the shared vectors in `protocol/layouts/` (the app's Swift
 * validator reads the same file), plus the byte-level rules only a file reader meets.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  LAYOUT_MAX_BYTES,
  validateLayoutBytes,
  validateLayoutText,
  validateLayoutValue,
} from "../src/layout-validation.js";

interface Vector {
  name: string;
  input?: unknown;
  inputText?: string;
  expect: "valid" | "invalid" | "newer";
  layout?: unknown;
  warnings?: { code: string; path: string }[];
  problems?: { code: string; path: string }[];
  v?: number;
  title?: string;
}

const VECTORS = JSON.parse(
  readFileSync(resolve(import.meta.dirname, "../../protocol/layouts/vectors.json"), "utf8"),
) as { vectors: Vector[] };

const codeAndPath = (issues: { code: string; path: string }[]): { code: string; path: string }[] =>
  issues.map(({ code, path }) => ({ code, path }));

describe("layout vectors", () => {
  it.each(VECTORS.vectors.map((vector) => [vector.name, vector] as const))("%s", (_, vector) => {
    const result =
      vector.inputText !== undefined
        ? validateLayoutText(vector.inputText)
        : validateLayoutValue(vector.input);
    switch (vector.expect) {
      case "valid":
        expect(result.kind).toBe("valid");
        if (result.kind !== "valid") return;
        expect(result.layout).toEqual(vector.layout);
        expect(codeAndPath(result.warnings)).toEqual(vector.warnings);
        return;
      case "invalid":
        expect(result.kind).toBe("invalid");
        if (result.kind !== "invalid") return;
        expect(codeAndPath(result.problems)).toEqual(vector.problems);
        expect(codeAndPath(result.warnings)).toEqual(vector.warnings);
        return;
      case "newer":
        expect(result).toEqual({
          kind: "newer",
          v: vector.v,
          ...(vector.title ? { title: vector.title } : {}),
        });
    }
  });
});

describe("layout bytes", () => {
  const document = '{"v":1,"title":"Review","root":{"pane":"chat","chat":"self"},"focus":"chat"}';

  it("accepts a UTF-8 byte order mark", () => {
    const bytes = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(document)]);
    expect(validateLayoutBytes(bytes).kind).toBe("valid");
  });

  it("refuses bytes that are not UTF-8", () => {
    const bytes = Buffer.from(document.replace("Review", "Revi\u00e9w"), "latin1");
    const result = validateLayoutBytes(bytes);
    expect(result.kind === "invalid" && result.problems.map((p) => p.code)).toEqual(["notUtf8"]);
  });

  it("refuses one byte past 16 KiB without parsing it, and takes 16 KiB exactly", () => {
    const padded = (size: number): Buffer => {
      const text = document.replace('"focus"', `"pad":"${" ".repeat(size)}","focus"`);
      return Buffer.from(
        text.replace(" ".repeat(size), " ".repeat(size - (text.length - LAYOUT_MAX_BYTES))),
      );
    };
    expect(padded(LAYOUT_MAX_BYTES).length).toBe(LAYOUT_MAX_BYTES);
    expect(validateLayoutBytes(padded(LAYOUT_MAX_BYTES)).kind).toBe("valid");
    const over = Buffer.concat([padded(LAYOUT_MAX_BYTES), Buffer.from(" ")]);
    const result = validateLayoutBytes(over);
    expect(result.kind === "invalid" && result.problems.map((p) => p.code)).toEqual(["tooLarge"]);
  });
});
