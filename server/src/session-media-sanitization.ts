import { asRecord } from "./json-shape.js";

export function stripImageMediaFromDetails(details: unknown): unknown | undefined {
  const root = asRecord(details);
  if (!root) {
    return details === undefined ? undefined : details;
  }

  let changed = false;
  const next: Record<string, unknown> = { ...root };

  if (asRecord(root.image)?.kind === "image") {
    delete next.image;
    changed = true;
  }

  if (Array.isArray(root.media)) {
    const media = root.media.filter((item) => asRecord(item)?.kind !== "image");
    if (media.length !== root.media.length) {
      changed = true;
      if (media.length > 0) {
        next.media = media;
      } else {
        delete next.media;
      }
    }
  }

  return changed ? (Object.keys(next).length > 0 ? next : undefined) : details;
}
