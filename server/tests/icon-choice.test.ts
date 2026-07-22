import { describe, expect, it } from "vitest";

import {
  DEFAULT_ICON_CHOICE,
  iconAssetId,
  migrateIconChoice,
  validateIconChoice,
} from "../src/icon-choice.js";

describe("IconChoice", () => {
  it.each([
    [{ kind: "default" }, { kind: "default" }],
    [{ kind: "emoji", value: "👨‍👩‍👧‍👦" }, { kind: "emoji", value: "👨‍👩‍👧‍👦" }],
    [{ kind: "symbol", name: "checkmark.shield" }, { kind: "symbol", name: "checkmark.shield" }],
    [
      { kind: "genmoji", assetId: `ia_${"a".repeat(43)}`, contentDescription: "Smiling cat" },
      { kind: "genmoji", assetId: `ia_${"a".repeat(43)}`, contentDescription: "Smiling cat" },
    ],
  ])("validates tagged icon %#", (input, expected) => {
    expect(validateIconChoice(input)).toEqual(expected);
  });

  it.each([
    [{ kind: "emoji", value: "😀😀" }, "one Unicode emoji"],
    [{ kind: "symbol", name: "not/a/symbol" }, "SF Symbol"],
    [{ kind: "genmoji", assetId: "../../etc/passwd", contentDescription: "Bad" }, "assetId"],
    [{ kind: "genmoji", assetId: `ia_${"a".repeat(43)}`, contentDescription: "  " }, "contentDescription"],
    [{ kind: "future", value: "x" }, "kind"],
    [{ kind: "default", extra: true }, "unexpected field"],
  ])("rejects malformed tagged icon %#", (input, message) => {
    expect(() => validateIconChoice(input)).toThrow(message);
  });

  it("can require a Genmoji asset to resolve at a server boundary", () => {
    const input = {
      kind: "genmoji",
      assetId: `ia_${"b".repeat(43)}`,
      contentDescription: "Blue dog",
    };
    expect(() => validateIconChoice(input, { assetExists: () => false })).toThrow(
      "icon asset not found",
    );
  });

  it.each([
    [undefined, DEFAULT_ICON_CHOICE],
    [null, DEFAULT_ICON_CHOICE],
    ["", DEFAULT_ICON_CHOICE],
    ["🧘", { kind: "emoji", value: "🧘" }],
    ["checkmark.shield", { kind: "symbol", name: "checkmark.shield" }],
    ["historical/icon", DEFAULT_ICON_CHOICE],
    [{ kind: "future" }, DEFAULT_ICON_CHOICE],
  ])("migrates persisted icon %# deterministically", (input, expected) => {
    expect(migrateIconChoice(input)).toEqual(expected);
    expect(migrateIconChoice(migrateIconChoice(input))).toEqual(expected);
  });

  it("extracts only Genmoji asset references", () => {
    expect(iconAssetId({ kind: "default" })).toBeUndefined();
    expect(
      iconAssetId({
        kind: "genmoji",
        assetId: `ia_${"c".repeat(43)}`,
        contentDescription: "Cat",
      }),
    ).toBe(`ia_${"c".repeat(43)}`);
  });
});
