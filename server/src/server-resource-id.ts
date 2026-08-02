import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

export type ServerResourceIdentityKind = "skill" | "extension";

export function canonicalServerResourcePath(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

export function serverResourceId(kind: ServerResourceIdentityKind, path: string): string {
  const canonicalPath = canonicalServerResourcePath(path);
  const digest = createHash("sha256").update(`${kind}\0${canonicalPath}`).digest("hex");
  return `${kind}_${digest}`;
}
