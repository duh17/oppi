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
    [
      { kind: "emoji", value: "👨‍👩‍👧‍👦" },
      { kind: "emoji", value: "👨‍👩‍👧‍👦" },
    ],
    [
      { kind: "symbol", name: "checkmark.shield" },
      { kind: "symbol", name: "checkmark.shield" },
    ],
    [
      { kind: "genmoji", assetId: `ia_${"a".repeat(43)}`, contentDescription: "Smiling cat" },
      { kind: "genmoji", assetId: `ia_${"a".repeat(43)}`, contentDescription: "Smiling cat" },
    ],
    [
      { kind: "image", assetId: ` ia_${"a".repeat(43)} ` },
      { kind: "image", assetId: `ia_${"a".repeat(43)}` },
    ],
  ])("validates tagged icon %#", (input, expected) => {
    expect(validateIconChoice(input)).toEqual(expected);
  });

  it.each([
    [{ kind: "emoji", value: "😀😀" }, "one Unicode emoji"],
    [{ kind: "symbol", name: "not/a/symbol" }, "SF Symbol"],
    [{ kind: "genmoji", assetId: "../../etc/passwd", contentDescription: "Bad" }, "assetId"],
    [
      { kind: "genmoji", assetId: `ia_${"a".repeat(43)}`, contentDescription: "  " },
      "contentDescription",
    ],
    [{ kind: "image", assetId: "../../etc/passwd" }, "assetId"],
    [
      { kind: "image", assetId: `ia_${"a".repeat(43)}`, contentDescription: "x" },
      "unexpected field",
    ],
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
    expect(() => validateIconChoice(input, { assetKind: () => undefined })).toThrow(
      "icon asset not found",
    );
  });

  it("requires an icon's asset to be of its own kind at a server boundary", () => {
    const assetId = `ia_${"d".repeat(43)}`;
    const image = { kind: "image", assetId };
    const genmoji = { kind: "genmoji", assetId, contentDescription: "Fox" };
    expect(validateIconChoice(image, { assetKind: () => "image" })).toEqual(image);
    expect(() => validateIconChoice(image, { assetKind: () => "genmoji" })).toThrow(
      "wrong kind for this image icon",
    );
    expect(() => validateIconChoice(genmoji, { assetKind: () => "image" })).toThrow(
      "wrong kind for this genmoji icon",
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

  it("extracts Genmoji and image asset references only", () => {
    expect(iconAssetId({ kind: "default" })).toBeUndefined();
    expect(iconAssetId({ kind: "symbol", name: "star" })).toBeUndefined();
    expect(iconAssetId({ kind: "image", assetId: `ia_${"e".repeat(43)}` })).toBe(
      `ia_${"e".repeat(43)}`,
    );
    expect(
      iconAssetId({
        kind: "genmoji",
        assetId: `ia_${"c".repeat(43)}`,
        contentDescription: "Cat",
      }),
    ).toBe(`ia_${"c".repeat(43)}`);
  });
});
