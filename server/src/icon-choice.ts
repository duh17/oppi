import type { IconChoice, IconSymbolEffect } from "./types/icon.js";
import { isRecord } from "./json-shape.js";

export const DEFAULT_ICON_CHOICE: IconChoice = Object.freeze({ kind: "default" });
export const ICON_ASSET_ID_PATTERN = /^ia_[A-Za-z0-9_-]{43}$/;
export const ICON_CONTENT_DESCRIPTION_MAX_SCALARS = 256;
export const ICON_SYMBOL_EFFECTS: readonly IconSymbolEffect[] = [
  "bounce",
  "pulse",
  "breathe",
  "wiggle",
  "rotate",
];

const SF_SYMBOL_NAME_PATTERN = /^[A-Za-z0-9.-]+$/;
const ICON_TEXT_MAX_SCALARS = 128;
const EMOJI_PATTERN = /^\p{Emoji}$/u;
const EMOJI_PRESENTATION_PATTERN = /^\p{Emoji_Presentation}$/u;
const EMOJI_MODIFIER_BASE_PATTERN = /^\p{Emoji_Modifier_Base}$/u;

/** The icon kinds a stored icon asset backs: a Genmoji (HEIC) or an imported image. */
export type IconAssetKind = Extract<IconChoice["kind"], "genmoji" | "image">;

export interface IconChoiceValidationOptions {
  /** The kind a stored asset can back, or undefined when there is no such asset. */
  assetKind?: (assetId: string) => IconAssetKind | undefined;
}

export function validateIconChoice(
  value: unknown,
  options: IconChoiceValidationOptions = {},
): IconChoice {
  if (!isRecord(value) || typeof value.kind !== "string") {
    throw new Error("icon must be a tagged object with a kind");
  }

  switch (value.kind) {
    case "default":
      assertAllowedKeys(value, new Set(["kind"]), "icon");
      return DEFAULT_ICON_CHOICE;

    case "emoji": {
      assertAllowedKeys(value, new Set(["kind", "value"]), "icon");
      const emoji = requireBoundedString(value.value, "icon.value", ICON_TEXT_MAX_SCALARS);
      if (!isSingleEmojiSequence(Array.from(emoji))) {
        throw new Error("icon.value must be one Unicode emoji sequence");
      }
      return { kind: "emoji", value: emoji };
    }

    case "symbol": {
      assertAllowedKeys(value, new Set(["kind", "name", "effect"]), "icon");
      const name = requireBoundedString(value.name, "icon.name", ICON_TEXT_MAX_SCALARS);
      if (!SF_SYMBOL_NAME_PATTERN.test(name)) {
        throw new Error("icon.name must be an SF Symbol name");
      }
      if (value.effect === undefined) return { kind: "symbol", name };
      const effect = ICON_SYMBOL_EFFECTS.find((candidate) => candidate === value.effect);
      if (!effect) {
        throw new Error(`icon.effect must be one of ${ICON_SYMBOL_EFFECTS.join(", ")}`);
      }
      return { kind: "symbol", name, effect };
    }

    case "genmoji": {
      assertAllowedKeys(value, new Set(["kind", "assetId", "contentDescription"]), "icon");
      const assetId = requireAssetId(value.assetId, "genmoji", options);
      const contentDescription = requireBoundedString(
        value.contentDescription,
        "icon.contentDescription",
        ICON_CONTENT_DESCRIPTION_MAX_SCALARS,
      );
      return { kind: "genmoji", assetId, contentDescription };
    }

    case "image": {
      assertAllowedKeys(value, new Set(["kind", "assetId"]), "icon");
      return { kind: "image", assetId: requireAssetId(value.assetId, "image", options) };
    }

    default:
      throw new Error("icon.kind is invalid");
  }
}

/** Convert historical persisted values without extending the public wire contract. */
export function migrateIconChoice(value: unknown): IconChoice {
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return DEFAULT_ICON_CHOICE;
    const scalars = Array.from(trimmed);
    if (scalars.length <= ICON_TEXT_MAX_SCALARS && isSingleEmojiSequence(scalars)) {
      return { kind: "emoji", value: trimmed };
    }
    if (scalars.length <= ICON_TEXT_MAX_SCALARS && SF_SYMBOL_NAME_PATTERN.test(trimmed)) {
      return { kind: "symbol", name: trimmed };
    }
    return DEFAULT_ICON_CHOICE;
  }

  try {
    return validateIconChoice(value);
  } catch {
    return DEFAULT_ICON_CHOICE;
  }
}

export function iconAssetId(value: IconChoice | undefined): string | undefined {
  return value?.kind === "genmoji" || value?.kind === "image" ? value.assetId : undefined;
}

export function formatIconChoice(value: IconChoice | undefined): string {
  switch (value?.kind) {
    case "emoji":
      return `emoji ${value.value}`;
    case "symbol":
      return value.effect ? `symbol ${value.name} (${value.effect})` : `symbol ${value.name}`;
    case "genmoji":
      return `Genmoji ${value.contentDescription}`;
    case "image":
      return `image ${value.assetId}`;
    case "default":
    case undefined:
      return "default";
  }
}

/** A well-formed asset ID that, at a server boundary, names an asset of `kind`. */
function requireAssetId(
  value: unknown,
  kind: IconAssetKind,
  options: IconChoiceValidationOptions,
): string {
  const assetId = requireBoundedString(value, "icon.assetId", 46);
  if (!ICON_ASSET_ID_PATTERN.test(assetId)) {
    throw new Error("icon.assetId is invalid");
  }
  if (options.assetKind) {
    const stored = options.assetKind(assetId);
    if (!stored) throw new Error("icon asset not found");
    if (stored !== kind) throw new Error(`icon asset is the wrong kind for this ${kind} icon`);
  }
  return assetId;
}

function requireBoundedString(value: unknown, label: string, maxScalars: number): string {
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  const trimmed = value.trim();
  if (!trimmed) throw new Error(`${label} must not be empty`);
  if (Array.from(trimmed).length > maxScalars) {
    throw new Error(`${label} must not exceed ${maxScalars} Unicode scalars`);
  }
  return trimmed;
}

export function isSingleEmojiSequence(scalars: string[]): boolean {
  const codePoint = (scalar: string): number => scalar.codePointAt(0) ?? 0;
  const keycapBase = (scalar: string): boolean => {
    const point = codePoint(scalar);
    return point === 0x23 || point === 0x2a || (point >= 0x30 && point <= 0x39);
  };

  if (
    scalars.length === 2 &&
    keycapBase(scalars[0] ?? "") &&
    codePoint(scalars[1] ?? "") === 0x20e3
  ) {
    return true;
  }
  if (
    scalars.length === 3 &&
    keycapBase(scalars[0] ?? "") &&
    codePoint(scalars[1] ?? "") === 0xfe0f &&
    codePoint(scalars[2] ?? "") === 0x20e3
  ) {
    return true;
  }

  const isRegionalIndicator = (scalar: string): boolean => {
    const point = codePoint(scalar);
    return point >= 0x1f1e6 && point <= 0x1f1ff;
  };
  if (scalars.some(isRegionalIndicator)) {
    return scalars.length === 2 && scalars.every(isRegionalIndicator);
  }

  if (
    codePoint(scalars[0] ?? "") === 0x1f3f4 &&
    scalars.length >= 3 &&
    codePoint(scalars[scalars.length - 1] ?? "") === 0xe007f
  ) {
    return scalars.slice(1, -1).every((scalar) => {
      const point = codePoint(scalar);
      return point >= 0xe0061 && point <= 0xe007a;
    });
  }

  const consumeComponent = (start: number): number | undefined => {
    const base = scalars[start];
    if (!base || !EMOJI_PATTERN.test(base)) return undefined;

    let index = start + 1;
    let hasEmojiVariation = false;
    if (codePoint(scalars[index] ?? "") === 0xfe0f) {
      hasEmojiVariation = true;
      index += 1;
    }
    if (!EMOJI_PRESENTATION_PATTERN.test(base) && !hasEmojiVariation) return undefined;

    const modifier = codePoint(scalars[index] ?? "");
    if (modifier >= 0x1f3fb && modifier <= 0x1f3ff) {
      if (!EMOJI_MODIFIER_BASE_PATTERN.test(base)) return undefined;
      index += 1;
    }
    return index;
  };

  let index = consumeComponent(0);
  if (index === undefined) return false;
  while (index < scalars.length) {
    if (codePoint(scalars[index] ?? "") !== 0x200d) return false;
    index = consumeComponent(index + 1);
    if (index === undefined) return false;
  }
  return true;
}

function assertAllowedKeys(
  value: Record<string, unknown>,
  allowed: ReadonlySet<string>,
  label: string,
): void {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`${label} has unexpected field: ${key}`);
  }
}
