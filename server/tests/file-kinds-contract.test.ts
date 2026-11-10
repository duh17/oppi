import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

import { fileKindOfContentType, getContentType } from "../src/file-serving-policy.js";

/**
 * The server half of `protocol/file-kinds.json`: every extension the phone opens as
 * something other than text must be served here as the same kind, or the phone would
 * fetch it with the wrong cap or as the wrong content type. Apple `FileKindTableTests`
 * holds the client table to the same file.
 */
const fixture = JSON.parse(
  readFileSync(new URL("../../protocol/file-kinds.json", import.meta.url), "utf8"),
) as Record<string, string[]>;

describe("file kinds contract", () => {
  const rows = Object.entries(fixture).flatMap(([kind, extensions]) =>
    extensions.map((extension) => [kind, extension] as const),
  );

  test("the fixture lists the kinds the phone opens", () => {
    expect(Object.keys(fixture).sort()).toEqual(
      ["audio", "book", "image", "pdf", "usdz", "video"].sort(),
    );
  });

  test.each(rows)("serves %s files with .%s as that kind", (kind, extension) => {
    expect(fileKindOfContentType(getContentType(`.${extension}`, `file.${extension}`))).toBe(kind);
  });
});
