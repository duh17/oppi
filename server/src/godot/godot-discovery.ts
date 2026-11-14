/**
 * Godot projects in workspace checkouts, and the pack each one's export left.
 *
 * - A project is a folder holding `project.godot`. The walk starts at a checkout root, never
 *   follows a link (a `Dirent` for a link is not a directory), skips hidden folders (`.godot`,
 *   `.git`) and `node_modules`, stops at a project folder, and is bounded in depth and folders.
 * - Its pack is the newest regular `build/*.pck`, or the file `oppi-godot.json`'s `pack` names
 *   (relative to the project folder). Either must resolve inside the checkout, real path included.
 *
 * Nothing here runs Godot or writes a file.
 */
import { createHash } from "node:crypto";
import type { Dirent } from "node:fs";
import * as fs from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import { asRecord } from "../json-shape.js";
import { canonicalRealPath, isPathWithinRoot } from "../path-utils.js";
import type { GodotEngine, GodotProjectConfig, GodotProjectSource } from "../types.js";
import { isReloadTier, parseGodotEntry } from "./godot-messages.js";

export const GODOT_PROJECT_FILE = "project.godot";
export const GODOT_CONFIG_FILE = "oppi-godot.json";
const DEFAULT_PACK_DIR = "build";
const MAX_DEPTH = 6;
const MAX_FOLDERS_PER_CHECKOUT = 4_000;
const MAX_CONFIG_BYTES = 16 * 1024;
/**
 * Folders the walk never enters besides hidden ones: dependency and build output that holds no
 * Godot project and can hold a great many folders.
 */
const SKIPPED_FOLDERS: ReadonlySet<string> = new Set([
  "node_modules",
  "Library",
  "Pods",
  "DerivedData",
  "target",
  "dist",
  "build",
  "vendor",
  "venv",
  "__pycache__",
]);

/** A checkout discovery walks: a workspace's own folder or one of its worktrees. */
export interface GodotCheckout {
  workspaceId: string;
  worktreeId: string;
  /** Display name. */
  label: string;
  /** Host directory. */
  root: string;
}

/** A project found in a checkout. */
export interface DiscoveredGodotProject {
  id: string;
  name: string;
  engine: GodotEngine;
  source: GodotProjectSource;
  checkout: GodotCheckout;
  /** Real path of the project folder. */
  dir: string;
  /** Real path of the checkout root. */
  checkoutRoot: string;
  config: GodotProjectConfig;
  /** Why `oppi-godot.json` was ignored, when it was. */
  configProblem?: string;
}

/** The pack a project's export left, as found now. */
export interface FoundGodotPack {
  /** Real path. */
  path: string;
  /** Relative to the checkout, `/`-separated. */
  relative: string;
}

/**
 * `<folder-slug>-<8 hex>`: readable, and stable for the same folder of the same checkout. The
 * hash covers workspace, worktree, and folder, so a project in two worktrees has two ids.
 */
export function gameProjectId(checkout: GodotCheckout, root: string, folderName: string): string {
  const slug =
    folderName
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40) || "game";
  const hash = createHash("sha256")
    .update(`${checkout.workspaceId}\0${checkout.worktreeId}\0${root}`)
    .digest("hex")
    .slice(0, 8);
  return `${slug}-${hash}`;
}

/** Project folders under a checkout, as real paths, in walk order. */
export async function findGodotProjectDirs(checkoutRoot: string): Promise<string[]> {
  const root = canonicalRealPath(checkoutRoot);
  // A workspace on the home folder itself would walk everything the account owns.
  if (!root || root === canonicalRealPath(homedir())) return [];
  const found: string[] = [];
  let visited = 0;
  let level: string[] = [root];
  for (let depth = 0; depth <= MAX_DEPTH && level.length > 0; depth += 1) {
    const next: string[] = [];
    for (const dir of level) {
      if (visited >= MAX_FOLDERS_PER_CHECKOUT) return found;
      visited += 1;
      let entries: Dirent[];
      try {
        entries = await fs.readdir(dir, { withFileTypes: true });
      } catch {
        continue;
      }
      if (entries.some((entry) => entry.isFile() && entry.name === GODOT_PROJECT_FILE)) {
        found.push(dir);
        continue;
      }
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        if (entry.name.startsWith(".") || SKIPPED_FOLDERS.has(entry.name)) continue;
        next.push(join(dir, entry.name));
      }
    }
    level = next;
  }
  return found;
}

/** A project folder as discovery describes it; `dir` is a real path inside the checkout. */
export async function readGodotProject(
  checkout: GodotCheckout,
  checkoutRoot: string,
  dir: string,
): Promise<DiscoveredGodotProject> {
  const root = toPosix(relative(checkoutRoot, dir));
  const folderName = root === "" ? basename(checkoutRoot) : basename(dir);
  let text = "";
  try {
    text = await fs.readFile(join(dir, GODOT_PROJECT_FILE), "utf8");
  } catch {
    // Unreadable: keep the folder's name.
  }
  const { config, problem } = await readGodotConfig(dir, checkoutRoot);
  return {
    id: gameProjectId(checkout, root, folderName),
    name: config.name ?? godotProjectName(text) ?? folderName,
    engine: { name: "godot", ...versionOf(text) },
    source: {
      workspaceId: checkout.workspaceId,
      worktreeId: checkout.worktreeId,
      checkout: checkout.label,
      root,
    },
    checkout,
    dir,
    checkoutRoot,
    config,
    ...(problem ? { configProblem: problem } : {}),
  };
}

/** `config/name="…"` in `project.godot`. */
export function godotProjectName(text: string): string | undefined {
  const match = /^config\/name="((?:[^"\\]|\\.)*)"/m.exec(text);
  const name = match?.[1]?.replace(/\\(.)/g, "$1").trim();
  return name ? name : undefined;
}

/** The first `major.minor` in `config/features`, Godot's target version. */
function versionOf(text: string): { version?: string } {
  const features = /^config\/features=PackedStringArray\(([^)]*)\)/m.exec(text)?.[1] ?? "";
  const version = /"(\d+\.\d+)"/.exec(features)?.[1];
  return version ? { version } : {};
}

/** `oppi-godot.json`, checked field by field; an unusable file is ignored with a reason. */
async function readGodotConfig(
  dir: string,
  checkoutRoot: string,
): Promise<{ config: GodotProjectConfig; problem?: string }> {
  let bytes: Buffer;
  try {
    // Never through a link: the file must be the project folder's own.
    const handle = await fs.open(
      join(dir, GODOT_CONFIG_FILE),
      fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW,
    );
    try {
      const info = await handle.stat();
      if (!info.isFile()) return { config: {}, problem: `${GODOT_CONFIG_FILE} is not a file` };
      if (info.size > MAX_CONFIG_BYTES)
        return { config: {}, problem: `${GODOT_CONFIG_FILE} is over 16 KiB` };
      bytes = await handle.readFile();
    } finally {
      await handle.close();
    }
  } catch {
    return { config: {} };
  }
  let raw: Record<string, unknown> | undefined;
  try {
    raw = asRecord(JSON.parse(bytes.toString("utf8")));
  } catch {
    raw = undefined;
  }
  if (!raw) return { config: {}, problem: `${GODOT_CONFIG_FILE} is not a JSON object` };
  return parseGodotConfig(raw, dir, checkoutRoot);
}

/**
 * `oppi-godot.json`, field by field. A `pack` that resolves outside the checkout is dropped here,
 * before anything watches or reads it.
 */
export function parseGodotConfig(
  raw: Record<string, unknown>,
  dir: string,
  checkoutRoot: string,
): {
  config: GodotProjectConfig;
  problem?: string;
} {
  const config: GodotProjectConfig = {};
  const problems: string[] = [];
  if (raw.name !== undefined) {
    if (typeof raw.name === "string" && raw.name.trim()) config.name = raw.name.trim().slice(0, 80);
    else problems.push("name must be a non-empty string");
  }
  if (raw.pack !== undefined) {
    const pack = typeof raw.pack === "string" ? raw.pack.trim() : "";
    if (!pack || pack.includes("\0") || isAbsolute(pack))
      problems.push("pack must be a path relative to the project folder");
    else if (!isPathWithinRoot(resolve(dir, pack), checkoutRoot))
      problems.push("pack must stay inside the checkout");
    else config.pack = pack;
  }
  if (raw.reload !== undefined) {
    if (isReloadTier(raw.reload)) config.reload = raw.reload;
    else problems.push("reload must be scripts, scene, or restart");
  }
  if (raw.entry !== undefined) {
    const entry = parseGodotEntry(raw.entry);
    if (entry) config.entry = entry;
    else problems.push("entry must be { scene?: string, args?: string[] }");
  }
  return problems.length > 0
    ? { config, problem: `${GODOT_CONFIG_FILE}: ${problems.join("; ")}` }
    : { config };
}

/**
 * The pack to watch: `oppi-godot.json`'s `pack`, else the newest regular `build/*.pck`. Undefined
 * when there is none, or it resolves outside the checkout.
 */
export async function findGodotPack(
  project: Pick<DiscoveredGodotProject, "dir" | "checkoutRoot" | "config">,
): Promise<FoundGodotPack | undefined> {
  const configured = project.config.pack;
  let candidate: string | undefined;
  if (configured) {
    candidate = resolve(project.dir, configured);
  } else {
    candidate = await newestPck(join(project.dir, DEFAULT_PACK_DIR));
  }
  if (!candidate || !isPathWithinRoot(candidate, project.checkoutRoot)) return undefined;
  const real = canonicalRealPath(candidate);
  if (!real || !isPathWithinRoot(real, project.checkoutRoot)) return undefined;
  try {
    if (!(await fs.stat(real)).isFile()) return undefined;
  } catch {
    return undefined;
  }
  return { path: real, relative: toPosix(relative(project.checkoutRoot, real)) };
}

/** The folder whose changes can change a project's pack: the pack's folder. */
export function packFolderOf(project: Pick<DiscoveredGodotProject, "dir" | "config">): string {
  return project.config.pack
    ? dirname(resolve(project.dir, project.config.pack))
    : join(project.dir, DEFAULT_PACK_DIR);
}

async function newestPck(folder: string): Promise<string | undefined> {
  let entries: Dirent[];
  try {
    entries = await fs.readdir(folder, { withFileTypes: true });
  } catch {
    return undefined;
  }
  let newest: { path: string; mtimeMs: number } | undefined;
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.toLowerCase().endsWith(".pck")) continue;
    const path = join(folder, entry.name);
    try {
      const { mtimeMs } = await fs.stat(path);
      if (!newest || mtimeMs > newest.mtimeMs) newest = { path, mtimeMs };
    } catch {
      // Removed while listing.
    }
  }
  return newest?.path;
}

function toPosix(path: string): string {
  return sep === "/" ? path : path.split(sep).join("/");
}
