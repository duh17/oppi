/**
 * What the server keeps of each game, under `<dataDir>/godot/<projectId>/`:
 *
 * - `project.json`: the project's name, engine and source, its newest five releases, and the
 *   stat of the pack its last discovery release came from (so a restart does not hash it again).
 * - `packs/<sha256>`: content-addressed packs, verified by hash, size, and format magic. A pack
 *   no kept release names is deleted once it is an hour old (an upload waiting for its
 *   `POST .../releases` survives).
 * - `captures/<id>.png|.jpg`: the newest 20 player captures.
 *
 * One writer: `GodotService` serializes changes per project.
 */
import { createHash, randomUUID } from "node:crypto";
import {
  createReadStream,
  createWriteStream,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import * as fs from "node:fs/promises";
import { join } from "node:path";
import type { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

import { HttpStatusError } from "../http-status-error.js";
import { asRecord } from "../json-shape.js";
import { writeFileAtomic } from "../storage/atomic-file.js";
import type {
  GodotCapture,
  GodotEngine,
  GodotPack,
  GodotPackFormat,
  GodotProjectSource,
  GodotRelease,
} from "../types.js";
import {
  GODOT_CAPTURE_ID,
  GODOT_CAPTURES_KEPT,
  GODOT_PACK_MAX_BYTES,
  GODOT_PACK_SHA256,
  GODOT_PROJECT_ID,
  GODOT_RELEASES_KEPT,
} from "./godot-protocol.js";

const UNREFERENCED_PACK_GRACE_MS = 60 * 60 * 1000;

export interface StoredGodotProject {
  v: 1;
  id: string;
  name: string;
  engine: GodotEngine;
  /** Present for a discovered project. */
  source?: GodotProjectSource;
  /** Real path of the source checkout; a project whose checkout is gone is deleted. */
  checkoutRoot?: string;
  nextSeq: number;
  /** Newest first. */
  releases: GodotRelease[];
  /** `size:mtimeMs:ino` of the pack the last discovery release came from. */
  packStat?: string;
  /** SHA-256 of `project.godot` when the last discovery release was made. */
  projectFileSha?: string;
}

/** What a discovery release remembers of the files it came from. */
export interface DiscoveryStamp {
  packStat: string;
  projectFileSha?: string;
}

export type GodotProjectMeta = Pick<
  StoredGodotProject,
  "name" | "engine" | "source" | "checkoutRoot"
>;

/** A refusal of bytes that are not what they claim: 400 at the HTTP edge. */
export class GodotPackRejected extends HttpStatusError {
  constructor(message: string) {
    super(400, message);
  }
}

/** The format the first bytes name, or undefined. */
export function packFormatOf(head: Uint8Array): GodotPackFormat | undefined {
  if (head[0] === 0x47 && head[1] === 0x44 && head[2] === 0x50 && head[3] === 0x43) return "pck";
  if (head[0] === 0x50 && head[1] === 0x4b && head[2] === 0x03 && head[3] === 0x04) return "zip";
  return undefined;
}

function captureTypeOf(
  head: Uint8Array,
): { mimeType: GodotCapture["mimeType"]; ext: string } | undefined {
  if (head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47)
    return { mimeType: "image/png", ext: "png" };
  if (head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff)
    return { mimeType: "image/jpeg", ext: "jpg" };
  return undefined;
}

/** `size:mtimeMs:ino`: a pack file looks unchanged while this does. */
export function statKeyOf(info: { size: number; mtimeMs: number; ino: number }): string {
  return `${info.size}:${info.mtimeMs}:${info.ino}`;
}

export class GodotStore {
  private readonly projects = new Map<string, StoredGodotProject | null>();
  private listed = false;

  constructor(
    private readonly root: string,
    private readonly now: () => number = Date.now,
  ) {}

  /** Every stored project; the folder is listed once, on first use. */
  stored(): StoredGodotProject[] {
    if (!this.listed) {
      this.listed = true;
      let names: string[] = [];
      try {
        names = readdirSync(this.root);
      } catch {
        // No games yet.
      }
      for (const name of names) if (GODOT_PROJECT_ID.test(name)) this.get(name);
    }
    return [...this.projects.values()].filter((p): p is StoredGodotProject => p !== null);
  }

  get(id: string): StoredGodotProject | undefined {
    if (!GODOT_PROJECT_ID.test(id)) return undefined;
    const cached = this.projects.get(id);
    if (cached !== undefined) return cached ?? undefined;
    const loaded = readProjectFile(join(this.root, id, "project.json"), id);
    this.projects.set(id, loaded ?? null);
    return loaded;
  }

  /** Copy a pack file in while hashing it; throws when it changed during the copy. */
  async storePackFile(id: string, path: string): Promise<GodotPack & { statKey: string }> {
    const before = await fs.stat(path);
    const pack = await this.ingest(id, createReadStream(path), GODOT_PACK_MAX_BYTES);
    const after = await fs.stat(path);
    if (statKeyOf(before) !== statKeyOf(after) || after.size !== pack.size)
      throw new Error("The pack changed while it was read");
    return { ...pack, statKey: statKeyOf(after) };
  }

  /** Store an uploaded pack named by its hash; a pack already stored is not read again. */
  async storePackUpload(
    id: string,
    sha256: string,
    body: Readable,
    maxBytes: number,
  ): Promise<{ pack: GodotPack; existed: boolean }> {
    const existing = await this.packInfo(id, sha256);
    if (existing) {
      body.resume();
      return { pack: existing.pack, existed: true };
    }
    const pack = await this.ingest(id, body, maxBytes, sha256);
    return { pack, existed: false };
  }

  async packInfo(
    id: string,
    sha256: string,
  ): Promise<{ path: string; pack: GodotPack } | undefined> {
    if (!GODOT_PROJECT_ID.test(id) || !GODOT_PACK_SHA256.test(sha256)) return undefined;
    const path = join(this.root, id, "packs", sha256);
    try {
      const info = await fs.stat(path);
      if (!info.isFile()) return undefined;
      const handle = await fs.open(path, "r");
      const head = Buffer.alloc(4);
      try {
        await handle.read(head, 0, 4, 0);
      } finally {
        await handle.close();
      }
      const format = packFormatOf(head);
      return format ? { path, pack: { sha256, size: info.size, format } } : undefined;
    } catch {
      return undefined;
    }
  }

  /** Append a release, keep the newest five, and delete packs nothing names. */
  async addRelease(
    id: string,
    meta: GodotProjectMeta,
    release: Omit<GodotRelease, "v" | "seq" | "createdAt">,
    stamp?: DiscoveryStamp,
  ): Promise<GodotRelease> {
    const current = this.get(id);
    const created: GodotRelease = {
      v: 1,
      seq: current?.nextSeq ?? 1,
      createdAt: this.now(),
      ...release,
    };
    const next: StoredGodotProject = {
      v: 1,
      id,
      ...meta,
      nextSeq: created.seq + 1,
      releases: [created, ...(current?.releases ?? [])].slice(0, GODOT_RELEASES_KEPT),
      ...(current?.packStat ? { packStat: current.packStat } : {}),
      ...(current?.projectFileSha ? { projectFileSha: current.projectFileSha } : {}),
      ...stamp,
    };
    this.write(next);
    await this.collectPacks(next);
    return created;
  }

  /** Remember the pack stat a discovery saw, so the same file is not hashed again. */
  rememberPackStat(id: string, packStat: string): void {
    const current = this.get(id);
    if (!current || current.packStat === packStat) return;
    this.write({ ...current, packStat });
  }

  async deleteProject(id: string): Promise<void> {
    if (!GODOT_PROJECT_ID.test(id)) return;
    this.projects.set(id, null);
    await fs.rm(join(this.root, id), { recursive: true, force: true });
  }

  async storeCapture(
    id: string,
    captureId: string,
    body: Readable,
    maxBytes: number,
  ): Promise<GodotCapture> {
    if (!GODOT_PROJECT_ID.test(id) || !GODOT_CAPTURE_ID.test(captureId))
      throw new HttpStatusError(400, "Invalid capture id");
    const folder = join(this.root, id, "captures");
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    const temp = join(folder, `.${randomUUID()}.tmp`);
    const { size, head } = await writeCapped(body, temp, maxBytes);
    const type = captureTypeOf(head);
    if (!type) {
      await fs.rm(temp, { force: true });
      throw new HttpStatusError(415, "A capture must be a PNG or JPEG image");
    }
    for (const ext of ["png", "jpg"])
      await fs.rm(join(folder, `${captureId}.${ext}`), { force: true });
    await fs.rename(temp, join(folder, `${captureId}.${type.ext}`));
    await this.collectCaptures(folder);
    return { id: captureId, mimeType: type.mimeType, size, createdAt: this.now() };
  }

  async capture(
    id: string,
    captureId: string,
  ): Promise<{ path: string; mimeType: GodotCapture["mimeType"]; size: number } | undefined> {
    if (!GODOT_PROJECT_ID.test(id) || !GODOT_CAPTURE_ID.test(captureId)) return undefined;
    for (const [ext, mimeType] of [
      ["png", "image/png"],
      ["jpg", "image/jpeg"],
    ] as const) {
      const path = join(this.root, id, "captures", `${captureId}.${ext}`);
      try {
        const info = await fs.stat(path);
        if (info.isFile()) return { path, mimeType, size: info.size };
      } catch {
        // Try the next type.
      }
    }
    return undefined;
  }

  private write(project: StoredGodotProject): void {
    const folder = join(this.root, project.id);
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    writeFileAtomic(join(folder, "project.json"), JSON.stringify(project, null, 2) + "\n", {
      durable: false,
    });
    this.projects.set(project.id, project);
  }

  /** Hash `body` into `packs/`, checking its claimed hash and its format. */
  private async ingest(
    id: string,
    body: Readable,
    maxBytes: number,
    claimed?: string,
  ): Promise<GodotPack> {
    if (!GODOT_PROJECT_ID.test(id)) throw new HttpStatusError(400, "Invalid project id");
    const folder = join(this.root, id, "packs");
    mkdirSync(folder, { recursive: true, mode: 0o700 });
    const temp = join(folder, `.${randomUUID()}.tmp`);
    try {
      const { size, head, sha256 = "" } = await writeCapped(body, temp, maxBytes, true);
      if (claimed && sha256 !== claimed)
        throw new GodotPackRejected(`The bytes hash to ${sha256}, not ${claimed}`);
      const format = packFormatOf(head);
      if (!format)
        throw new GodotPackRejected("Not a pack: it starts with neither GDPC nor a ZIP header");
      const target = join(folder, sha256);
      if (!existsSync(target)) await fs.rename(temp, target);
      return { sha256, size, format };
    } finally {
      await fs.rm(temp, { force: true });
    }
  }

  /**
   * Uploads to an id that never got a release: their packs go once they are an hour old, and the
   * id's folder with them once it is empty. `live` ids (discovered projects, which may have
   * captures and a first pack being copied in) are left alone.
   */
  async collectUnreleased(live: ReadonlySet<string>): Promise<void> {
    let names: string[];
    try {
      names = await fs.readdir(this.root);
    } catch {
      return;
    }
    for (const id of names) {
      if (!GODOT_PROJECT_ID.test(id) || live.has(id) || this.get(id)) continue;
      if ((await this.collectPackFolder(id, new Set())) > 0) continue;
      // Only empty folders: an upload that started meanwhile keeps its folder.
      for (const folder of [join(this.root, id, "packs"), join(this.root, id)]) {
        try {
          await fs.rmdir(folder);
        } catch {
          break;
        }
      }
    }
  }

  private async collectPacks(project: StoredGodotProject): Promise<void> {
    const keep = new Set(project.releases.flatMap((r) => r.packs.map((p) => p.sha256)));
    await this.collectPackFolder(project.id, keep);
  }

  /** Delete the id's packs `keep` does not name once they are an hour old; how many are left. */
  private async collectPackFolder(id: string, keep: ReadonlySet<string>): Promise<number> {
    const folder = join(this.root, id, "packs");
    let names: string[];
    try {
      names = await fs.readdir(folder);
    } catch {
      return 0;
    }
    let left = 0;
    for (const name of names) {
      const path = join(folder, name);
      try {
        const { mtimeMs } = await fs.stat(path);
        const stale = this.now() - mtimeMs > UNREFERENCED_PACK_GRACE_MS;
        if (stale && (!GODOT_PACK_SHA256.test(name) || !keep.has(name)))
          await fs.rm(path, { force: true });
        else left += 1;
      } catch {
        // Gone already.
      }
    }
    return left;
  }

  private async collectCaptures(folder: string): Promise<void> {
    const entries: Array<{ path: string; mtimeMs: number }> = [];
    for (const name of await fs.readdir(folder)) {
      if (name.startsWith(".")) continue;
      const path = join(folder, name);
      try {
        entries.push({ path, mtimeMs: (await fs.stat(path)).mtimeMs });
      } catch {
        // Gone already.
      }
    }
    entries.sort((a, b) => b.mtimeMs - a.mtimeMs);
    for (const old of entries.slice(GODOT_CAPTURES_KEPT)) await fs.rm(old.path, { force: true });
  }
}

/**
 * Stream `body` to `path`, refusing past `maxBytes` (413). Returns the size, the first four
 * bytes, and the SHA-256 when asked.
 */
async function writeCapped(
  body: Readable,
  path: string,
  maxBytes: number,
  hash = false,
): Promise<{ size: number; head: Buffer; sha256?: string }> {
  const digest = hash ? createHash("sha256") : undefined;
  let size = 0;
  const head: Buffer[] = [];
  let headBytes = 0;
  await pipeline(
    body,
    async function* (source: AsyncIterable<Buffer>) {
      for await (const chunk of source) {
        size += chunk.length;
        if (size > maxBytes) throw new HttpStatusError(413, `Over the ${maxBytes}-byte limit`);
        if (headBytes < 4) {
          head.push(chunk.subarray(0, 4 - headBytes));
          headBytes += Math.min(chunk.length, 4 - headBytes);
        }
        digest?.update(chunk);
        yield chunk;
      }
    },
    createWriteStream(path, { mode: 0o600 }),
  );
  return { size, head: Buffer.concat(head), ...(digest ? { sha256: digest.digest("hex") } : {}) };
}

function readProjectFile(path: string, id: string): StoredGodotProject | undefined {
  let raw: Record<string, unknown> | undefined;
  try {
    // Small, and read once per project per process.
    raw = asRecord(JSON.parse(readFileSync(path, "utf8")));
  } catch {
    return undefined;
  }
  if (!raw || raw.v !== 1 || raw.id !== id || !Array.isArray(raw.releases)) return undefined;
  return raw as unknown as StoredGodotProject;
}
