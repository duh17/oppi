import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

import { migrateIconChoice } from "../icon-choice.js";
import { iconAssetKind, type IconAssetRecord } from "../storage/icon-asset-store.js";
import { ICON_IMAGE_MAX_BYTES } from "../storage/icon-image-formats.js";
import type { IconChoice } from "../types/icon.js";
import type { LocalApiRequestOptions } from "./local-api-client.js";

export function iconChoiceFromFlag(value: string): Record<string, string> {
  const trimmed = value.trim();
  if (trimmed.toLowerCase() === "default") return { kind: "default" };
  const icon = migrateIconChoice(trimmed);
  if (icon.kind === "default") {
    throw new Error("--icon must be default, one Unicode emoji, or an SF Symbol name");
  }
  return icon;
}

/**
 * `--icon-image <file>`: send a host image file to `POST /icon-assets`, the route the app
 * uploads through, so the server's icon store alone decides what is a valid image, and answer
 * the image icon that names it. `--icon` and `--icon-image` cannot be used together.
 */
export async function iconChoiceFromImageFile(
  call: <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>,
  value: string,
): Promise<IconChoice> {
  const given = value.trim();
  if (!given) throw new Error("--icon-image must be a non-empty file path");
  // Expanded here too: a control tool's argument never passes through a shell.
  const file = resolve(
    given === "~" || given.startsWith("~/") ? homedir() + given.slice(1) : given,
  );

  let bytes: Buffer;
  try {
    // Checked before reading: a large file is refused without loading it.
    if (statSync(file).size > ICON_IMAGE_MAX_BYTES) {
      throw new Error(`Icon image exceeds the 1 MiB maximum`);
    }
    bytes = readFileSync(file);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`--icon-image ${file}: ${message}`, { cause: error });
  }

  let asset: IconAssetRecord;
  try {
    ({ asset } = await call<{ asset: IconAssetRecord }>("/icon-assets", {
      method: "POST",
      upload: { file, bytes },
    }));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = (error as { status?: unknown }).status;
    throw Object.assign(new Error(`--icon-image ${file}: ${message}`, { cause: error }), {
      ...(typeof status === "number" ? { status } : {}),
    });
  }
  if (iconAssetKind(asset.contentType) !== "image") {
    throw new Error(`--icon-image ${file}: a Genmoji HEIC is not an image icon; use PNG or WebP`);
  }
  return { kind: "image", assetId: asset.assetId };
}
