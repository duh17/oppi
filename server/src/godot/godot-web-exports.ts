/**
 * Web builds `godot_export` made, under `<dataDir>/godot/<projectId>/web/<exportId>/`, served
 * at `GET /godot/<projectId>/web/<exportId>/` to the owner and paired devices. The export id is
 * the first 16 hex of a SHA-256 over the build's file names and bytes, so exporting the same
 * game twice gives the same address. The newest three builds per game are kept; deleting the
 * game's folder (`GodotStore.deleteProject`) deletes them with it.
 */
import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import * as fs from "node:fs/promises";
import { extname, join } from "node:path";

import { GODOT_PROJECT_ID } from "./godot-protocol.js";

export const GODOT_WEB_EXPORTS_KEPT = 3;
const EXPORT_ID = /^[0-9a-f]{16}$/;
/** A file a Web export writes: a plain name, no folders. */
const FILE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
};

export class GodotWebExports {
  constructor(private readonly root: string) {}

  private folder(id: string): string {
    return join(this.root, id, "web");
  }

  /**
   * Move a finished Web export folder (flat: `index.html` and its files) into the store and
   * return its id. The same bytes again keep their id and folder.
   */
  async adopt(id: string, source: string): Promise<string> {
    if (!GODOT_PROJECT_ID.test(id)) throw new Error(`Invalid game id ${id}`);
    const names = (await fs.readdir(source)).sort();
    if (!names.includes("index.html")) throw new Error("The Web export wrote no index.html");
    const digest = createHash("sha256");
    for (const name of names) {
      if (!FILE_NAME.test(name)) throw new Error(`Unexpected file in the Web export: ${name}`);
      const path = join(source, name);
      if (!(await fs.lstat(path)).isFile())
        throw new Error(`Unexpected entry in the Web export: ${name}`);
      digest.update(name).update("\0");
      for await (const chunk of createReadStream(path)) digest.update(chunk as Buffer);
    }
    const exportId = digest.digest("hex").slice(0, 16);
    const folder = this.folder(id);
    await fs.mkdir(folder, { recursive: true, mode: 0o700 });
    const target = join(folder, exportId);
    const staged = join(folder, `.${randomUUID()}`);
    await fs.cp(source, staged, { recursive: true });
    try {
      await fs.rename(staged, target);
    } catch {
      // Already stored: same bytes, same id. Mark it newest.
      await fs.rm(staged, { recursive: true, force: true });
    }
    const now = new Date();
    await fs.utimes(target, now, now);
    await this.collect(folder);
    return exportId;
  }

  /** One file of a stored build, or undefined. `name` is one plain file name. */
  async file(
    id: string,
    exportId: string,
    name: string,
  ): Promise<{ path: string; size: number; contentType: string } | undefined> {
    if (!GODOT_PROJECT_ID.test(id) || !EXPORT_ID.test(exportId) || !FILE_NAME.test(name))
      return undefined;
    const path = join(this.folder(id), exportId, name);
    try {
      const info = await fs.lstat(path);
      if (!info.isFile()) return undefined;
      return {
        path,
        size: info.size,
        contentType: CONTENT_TYPES[extname(name).toLowerCase()] ?? "application/octet-stream",
      };
    } catch {
      return undefined;
    }
  }

  private async collect(folder: string): Promise<void> {
    const builds: Array<{ path: string; mtimeMs: number }> = [];
    for (const name of await fs.readdir(folder)) {
      if (!EXPORT_ID.test(name)) continue;
      const path = join(folder, name);
      builds.push({ path, mtimeMs: (await fs.stat(path)).mtimeMs });
    }
    builds.sort((a, b) => b.mtimeMs - a.mtimeMs);
    for (const old of builds.slice(GODOT_WEB_EXPORTS_KEPT))
      await fs.rm(old.path, { recursive: true, force: true });
  }
}
