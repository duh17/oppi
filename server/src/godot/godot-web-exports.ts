/**
 * Web builds `godot_export` made, under `<dataDir>/godot/<projectId>/web/<exportId>/`.
 *
 * - The export id is the first 16 hex of a SHA-256 over the build's file names and bytes, so
 *   exporting the same game twice gives the same id. A build never changes once stored.
 * - Two addresses serve a build: `/godot/<projectId>/web/<exportId>/` to the owner and paired
 *   devices (the server's own auth), and a signed link `/godot/<projectId>/play/<grant>/` to
 *   anyone holding it until it expires. The grant is `<exportId>.<expires>.<mac>`: an HMAC-SHA256
 *   over the game, the build and the expiry (Unix seconds) with a key only this server holds
 *   (`web-links.key`, made on first use). It opens that one build's files and nothing else. It is
 *   carried in the path, not the query, so the page's relative asset URLs keep it.
 * - Each build stores brotli and gzip copies of its larger files (`.br/`, `.gz/`; a dot name is
 *   never a servable file), made once when the build is stored.
 * - The newest three builds per game are kept; deleting the game's folder deletes them with it.
 */
import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createReadStream, readFileSync, writeFileSync } from "node:fs";
import * as fs from "node:fs/promises";
import { extname, join } from "node:path";
import { promisify } from "node:util";
import { brotliCompress, constants as zlib, gzip } from "node:zlib";

import { GODOT_PROJECT_ID } from "./godot-protocol.js";

export const GODOT_WEB_EXPORTS_KEPT = 3;
/** How long a signed link opens its build. */
export const GODOT_WEB_LINK_TTL_MS = 24 * 60 * 60 * 1000;
const EXPORT_ID = /^[0-9a-f]{16}$/;
const GRANT = /^([0-9a-f]{16})\.([0-9]{1,12})\.([A-Za-z0-9_-]{43})$/;
/** A file a Web export writes: a plain name, no folders. */
const FILE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
/** Smaller files go out as they are. */
const COMPRESS_MIN_BYTES = 1024;

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

/** Content encodings stored per build, the server's preferred first. */
const ENCODINGS = [
  {
    name: "br",
    folder: ".br",
    // Quality 6: the 39.5 MB engine wasm goes to 8.2 MB in about a second; 11 takes a minute.
    encode: (bytes: Buffer) =>
      promisify(brotliCompress)(bytes, {
        params: {
          [zlib.BROTLI_PARAM_QUALITY]: 6,
          [zlib.BROTLI_PARAM_SIZE_HINT]: bytes.length,
        },
      }),
  },
  { name: "gzip", folder: ".gz", encode: (bytes: Buffer) => promisify(gzip)(bytes, { level: 6 }) },
] as const;

export interface GodotWebFile {
  path: string;
  size: number;
  contentType: string;
  /** Set when `path` holds the encoded bytes. */
  encoding?: string;
}

export class GodotWebExports {
  private linkKey?: Buffer;

  constructor(
    private readonly root: string,
    private readonly now: () => number = Date.now,
  ) {}

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
    await encodeAll(staged, names);
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

  /**
   * One file of a stored build, or undefined. `name` is one plain file name. With
   * `acceptEncoding`, the stored encoding the client takes, when there is one.
   */
  async file(
    id: string,
    exportId: string,
    name: string,
    acceptEncoding?: string,
  ): Promise<GodotWebFile | undefined> {
    if (!GODOT_PROJECT_ID.test(id) || !EXPORT_ID.test(exportId) || !FILE_NAME.test(name))
      return undefined;
    const build = join(this.folder(id), exportId);
    const plain = await fileSize(join(build, name));
    if (plain === undefined) return undefined;
    const contentType = CONTENT_TYPES[extname(name).toLowerCase()] ?? "application/octet-stream";
    const accepted = acceptedEncodings(acceptEncoding);
    for (const encoding of ENCODINGS) {
      if (!accepted.has(encoding.name)) continue;
      const path = join(build, encoding.folder, name);
      const size = await fileSize(path);
      if (size !== undefined) return { path, size, contentType, encoding: encoding.name };
    }
    return { path: join(build, name), size: plain, contentType };
  }

  /** The signed path that opens one build until `expiresAt` (ms), ending in `/`. */
  signedPath(id: string, exportId: string, expiresAt: number): string {
    const expires = Math.floor(expiresAt / 1000);
    return `/godot/${id}/play/${exportId}.${expires}.${this.mac(id, exportId, expires)}/`;
  }

  /** The build a signed grant opens for game `id` now; undefined when it opens nothing. */
  grantedExport(id: string, grant: string): string | undefined {
    const match = GRANT.exec(grant);
    if (!match || !GODOT_PROJECT_ID.test(id)) return undefined;
    const [, exportId = "", expiresText = "", mac = ""] = match;
    const expires = Number(expiresText);
    if (expires * 1000 <= this.now()) return undefined;
    const expected = Buffer.from(this.mac(id, exportId, expires), "base64url");
    const given = Buffer.from(mac, "base64url");
    return given.length === expected.length && timingSafeEqual(given, expected)
      ? exportId
      : undefined;
  }

  private mac(id: string, exportId: string, expires: number): string {
    return createHmac("sha256", this.key())
      .update(`oppi-godot-web-link\n${id}\n${exportId}\n${expires}`)
      .digest("base64url");
  }

  /** The signing key: made once, kept beside the builds, readable by the server user only. */
  private key(): Buffer {
    if (this.linkKey) return this.linkKey;
    const path = join(this.root, "web-links.key");
    try {
      this.linkKey = readFileSync(path);
    } catch {
      const fresh = randomBytes(32);
      try {
        writeFileSync(path, fresh, { mode: 0o600, flag: "wx" });
        this.linkKey = fresh;
      } catch {
        // Made by another writer between the read and the write.
        this.linkKey = readFileSync(path);
      }
    }
    return this.linkKey;
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

/** Store the brotli and gzip copies of each file worth compressing. */
async function encodeAll(build: string, names: string[]): Promise<void> {
  for (const encoding of ENCODINGS) await fs.mkdir(join(build, encoding.folder));
  for (const name of names) {
    const bytes = await fs.readFile(join(build, name));
    if (bytes.length < COMPRESS_MIN_BYTES) continue;
    for (const encoding of ENCODINGS) {
      const encoded = await encoding.encode(bytes);
      if (encoded.length < bytes.length * 0.9)
        await fs.writeFile(join(build, encoding.folder, name), encoded);
    }
  }
}

async function fileSize(path: string): Promise<number | undefined> {
  try {
    const info = await fs.lstat(path);
    return info.isFile() ? info.size : undefined;
  } catch {
    return undefined;
  }
}

/** The codings an `Accept-Encoding` header takes (a `q=0` refuses one). */
function acceptedEncodings(header: string | undefined): Set<string> {
  const accepted = new Set<string>();
  for (const part of (header ?? "").split(",")) {
    const [coding = "", ...params] = part.trim().toLowerCase().split(";");
    const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
    if (coding && (!q || Number(q.slice(2)) > 0)) accepted.add(coding);
  }
  return accepted;
}
