#!/usr/bin/env bun
/**
 * Stage the Mac app's embedded server into Oppi.app/Contents/Helpers, Apple's place for
 * helper executables, and list what to sign:
 *
 *   Contents/Helpers/bun       the Bun that server/.bun-version pins, arm64 only
 *   Contents/Helpers/server/   the `oppi-server` npm package with production dependencies
 *
 * Apple silicon only: the Bun is the darwin-aarch64 build, and every Mach-O in the server
 * tree is thinned to arm64 or removed, as are native addons built for other platforms.
 * `sign-list` prints every Mach-O inside-out (deepest first, `bun` last), native `.node`
 * addons included; `codesign-args` prints one codesign command per file in that order.
 * Only `bun` gets the worker identifier (`dev.chenda.Oppi.server`) and the JIT entitlements;
 * signing never copies Oppi's designated requirement onto it.
 *
 * No build phase calls this yet. Supply chain: the Bun zip must match the SHA-256 pinned
 * below before it is extracted, the download must stay on GitHub's release hosts, and the
 * extracted binary must report the pinned version. Dependencies come from the package's
 * npm-shrinkwrap.json through `npm ci` with install scripts off. Any failure aborts.
 */
import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";

export const SERVER_WORKER_IDENTIFIER = "dev.chenda.Oppi.server";
export const HELPERS_RELATIVE_PATH = "Contents/Helpers";
export const BUNDLED_BUN_RELATIVE_PATH = `${HELPERS_RELATIVE_PATH}/bun`;
export const BUNDLED_SERVER_RELATIVE_PATH = `${HELPERS_RELATIVE_PATH}/server`;

/**
 * Must equal server/.bun-version, the Bun the server suite runs on. SHA-256 of
 * bun-darwin-aarch64.zip from the release's SHASUMS256.txt (two identical HTTPS fetches).
 * Update all three together.
 */
export const PINNED_BUN_VERSION = "1.4.4";
export const PINNED_BUN_SHA256 = "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510";
/** Hosts a release download may end on after GitHub's redirect. */
export const BUN_DOWNLOAD_ORIGINS = [
  "https://github.com/",
  "https://release-assets.githubusercontent.com/",
  "https://objects.githubusercontent.com/",
] as const;

const REPO_ROOT = resolve(import.meta.dir, "../../..");
export const SERVER_DIR = join(REPO_ROOT, "server");

export function bundledBunPath(appPath: string): string {
  return join(appPath, BUNDLED_BUN_RELATIVE_PATH);
}

export function bundledServerPath(appPath: string): string {
  return join(appPath, BUNDLED_SERVER_RELATIVE_PATH);
}

export function bunReleaseZipUrl(version: string): string {
  return `https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-darwin-aarch64.zip`;
}

export const BUN_BINARY_PATH_INSIDE_ZIP = "bun-darwin-aarch64/bun";

/** Fail unless server/.bun-version names the Bun this script pins. */
export function assertPinnedBunMatchesServer(serverDir: string = SERVER_DIR): void {
  const pinned = readFileSync(join(serverDir, ".bun-version"), "utf8").trim();
  if (pinned !== PINNED_BUN_VERSION) {
    throw new Error(
      `server/.bun-version pins Bun ${pinned}, but this script bundles ${PINNED_BUN_VERSION}. Update PINNED_BUN_VERSION and PINNED_BUN_SHA256 from that release's SHASUMS256.txt.`,
    );
  }
}

// allow-jit + allow-unsigned-executable-memory: JavaScriptCore generates and runs machine
// code at runtime (JIT, WebAssembly), which hardened runtime blocks without them.
// disable-library-validation: sessions load native addons from Pi packages the owner
// installs, which are unsigned or signed by another team.
export function serverBunEntitlementsPlist(): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
`;
}

/** codesign for one Mach-O. Only the Bun worker carries the identifier and entitlements. */
export function codesignArgs(opts: {
  identity: string;
  path: string;
  /** Present only for the Bun worker. */
  entitlementsPath?: string;
}): string[] {
  const worker = opts.entitlementsPath
    ? ["--identifier", SERVER_WORKER_IDENTIFIER, "--entitlements", opts.entitlementsPath]
    : [];
  return [
    "codesign",
    "--force",
    "--options",
    "runtime",
    "--timestamp",
    ...worker,
    "--sign",
    opts.identity,
    opts.path,
  ];
}

export function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/**
 * Download the release zip and return its bytes only when the final URL is on a GitHub
 * release host and the SHA-256 matches `expectedSha256`. Nothing is written before that.
 */
export async function downloadVerifiedZip(opts: {
  url: string;
  expectedSha256: string;
  fetchImpl?: typeof fetch;
}): Promise<Uint8Array> {
  const response = await (opts.fetchImpl ?? fetch)(opts.url);
  if (!response.ok) {
    throw new Error(`Failed to download pinned Bun from ${opts.url}: ${response.status}`);
  }
  if (!BUN_DOWNLOAD_ORIGINS.some((origin) => response.url.startsWith(origin))) {
    throw new Error(
      `Refusing Bun download that left GitHub's release hosts: ${opts.url} -> ${response.url || "(unknown)"}`,
    );
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  const actual = sha256Hex(bytes);
  if (actual !== opts.expectedSha256) {
    throw new Error(
      `SHA-256 mismatch for ${opts.url}: expected ${opts.expectedSha256}, got ${actual}`,
    );
  }
  return bytes;
}

function run(command: string, args: string[], options: { cwd?: string } = {}): string {
  const result = spawnSync(command, args, { encoding: "utf-8", cwd: options.cwd });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(
      result.stderr || result.stdout || `${command} ${args.join(" ")} failed (${result.status})`,
    );
  }
  return result.stdout;
}

/** Fail unless `binary --version` prints exactly the pinned version. */
export function assertBunVersion(binary: string, version: string = PINNED_BUN_VERSION): void {
  const reported = run(binary, ["--version"]).trim();
  if (reported !== version) {
    throw new Error(`${binary} reports ${reported}, expected ${version}`);
  }
}

// ─── Mach-O inspection ───

const CPU_TYPE_ARM64 = 0x0100000c;
const MH_MAGIC = 0xfeedface;
const MH_MAGIC_64 = 0xfeedfacf;
const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
/** Java class files share FAT_MAGIC; their next word (the class version) is far above this. */
const MAX_FAT_ARCHS = 32;

export type MachO = { fat: boolean; cpuTypes: number[] };

/** The Mach-O layout of a file, or null when it is not a Mach-O binary. */
export function readMachO(path: string): MachO | null {
  const fd = openSync(path, "r");
  try {
    const header = Buffer.alloc(8);
    if (readSync(fd, header, 0, 8, 0) < 8) return null;
    const littleEndianMagic = header.readUInt32LE(0);
    if (littleEndianMagic === MH_MAGIC || littleEndianMagic === MH_MAGIC_64) {
      return { fat: false, cpuTypes: [header.readUInt32LE(4)] };
    }
    const fatMagic = header.readUInt32BE(0);
    if (fatMagic !== FAT_MAGIC && fatMagic !== FAT_MAGIC_64) return null;
    const count = header.readUInt32BE(4);
    if (count === 0 || count > MAX_FAT_ARCHS) return null;
    const entrySize = fatMagic === FAT_MAGIC_64 ? 32 : 20;
    const table = Buffer.alloc(count * entrySize);
    if (readSync(fd, table, 0, table.length, 8) < table.length) return null;
    const cpuTypes: number[] = [];
    for (let i = 0; i < count; i += 1) cpuTypes.push(table.readUInt32BE(i * entrySize));
    return { fat: true, cpuTypes };
  } finally {
    closeSync(fd);
  }
}

function regularFiles(root: string): string[] {
  const files: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) files.push(...regularFiles(path));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}

/**
 * Make `root` arm64-only: thin universal Mach-Os to arm64, delete Mach-Os without an arm64
 * slice, and delete `.node` addons that are not Mach-O at all (Linux and Windows prebuilds).
 * Returns the deleted paths.
 */
export function pruneToArm64(root: string): string[] {
  const removed: string[] = [];
  for (const path of regularFiles(root)) {
    const machO = readMachO(path);
    if (!machO) {
      if (path.endsWith(".node")) {
        rmSync(path);
        removed.push(path);
      }
      continue;
    }
    if (!machO.cpuTypes.includes(CPU_TYPE_ARM64)) {
      rmSync(path);
      removed.push(path);
    } else if (machO.fat && machO.cpuTypes.length > 1) {
      run("lipo", [path, "-thin", "arm64", "-output", path]);
    }
  }
  return removed;
}

/** Every Mach-O under Contents/Helpers in signing order: deepest first, `bun` last. */
export function machOSigningOrder(appPath: string): string[] {
  const helpers = join(appPath, HELPERS_RELATIVE_PATH);
  const depth = (path: string): number => relative(helpers, path).split(sep).length;
  return regularFiles(helpers)
    .filter((path) => readMachO(path) !== null)
    .sort((a, b) => depth(b) - depth(a) || a.localeCompare(b));
}

// ─── Staging ───

export async function stageBundledBun(
  appPath: string,
  options: { fetchImpl?: typeof fetch; sha256?: string; serverDir?: string } = {},
): Promise<string> {
  assertPinnedBunMatchesServer(options.serverDir);
  const dest = bundledBunPath(appPath);
  const work = mkdtempSync(join(tmpdir(), `oppi-bun-${PINNED_BUN_VERSION}-`));
  try {
    const bytes = await downloadVerifiedZip({
      url: bunReleaseZipUrl(PINNED_BUN_VERSION),
      expectedSha256: options.sha256 ?? PINNED_BUN_SHA256,
      fetchImpl: options.fetchImpl,
    });
    const zip = join(work, "bun.zip");
    writeFileSync(zip, bytes);
    run("unzip", ["-q", zip, BUN_BINARY_PATH_INSIDE_ZIP, "-d", work]);
    const extracted = join(work, BUN_BINARY_PATH_INSIDE_ZIP);
    if (!existsSync(extracted)) throw new Error(`Extracted Bun missing at ${extracted}`);
    const machO = readMachO(extracted);
    if (!machO || machO.fat || machO.cpuTypes[0] !== CPU_TYPE_ARM64) {
      throw new Error(`${extracted} is not a thin arm64 Mach-O`);
    }
    chmodSync(extracted, 0o755);
    assertBunVersion(extracted);

    mkdirSync(dirname(dest), { recursive: true });
    run("cp", [extracted, dest]);
    chmodSync(dest, 0o755);
    return dest;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

/**
 * `npm pack` of the server. Its `prepack` builds the package, checks its contents, and adds
 * npm-shrinkwrap.json, so lifecycle scripts are forced on even where npm config turns them off.
 * Returns the tarball.
 */
export function packServer(serverDir: string, destination: string): string {
  const output = run("npm", ["pack", "--ignore-scripts=false", "--pack-destination", destination], {
    cwd: serverDir,
  });
  const name = output.trim().split("\n").at(-1)?.trim();
  if (!name?.endsWith(".tgz")) throw new Error(`npm pack printed no tarball name:\n${output}`);
  return join(destination, name);
}

/**
 * Unpack the server package into Contents/Helpers/server, install its production
 * dependencies from the shrinkwrap with install scripts off, and prune to arm64.
 */
export function stageServerTree(appPath: string, packageTarball: string): string {
  const dest = bundledServerPath(appPath);
  const work = mkdtempSync(join(tmpdir(), "oppi-server-tree-"));
  try {
    run("tar", ["-xzf", packageTarball, "-C", work]);
    const unpacked = join(work, "package");
    if (!existsSync(join(unpacked, "package.json"))) {
      throw new Error(`${packageTarball} is not an npm package tarball`);
    }
    if (!existsSync(join(unpacked, "npm-shrinkwrap.json"))) {
      throw new Error(`${packageTarball} has no npm-shrinkwrap.json to install from`);
    }
    rmSync(dest, { recursive: true, force: true });
    mkdirSync(dirname(dest), { recursive: true });
    run("cp", ["-R", unpacked, dest]);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
  run(
    "npm",
    ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", "--os=darwin", "--cpu=arm64"],
    { cwd: dest },
  );
  pruneToArm64(dest);
  return dest;
}

export async function stageHelpers(
  appPath: string,
  options: { packageTarball?: string; serverDir?: string } = {},
): Promise<string[]> {
  const serverDir = options.serverDir ?? SERVER_DIR;
  await stageBundledBun(appPath, { serverDir });
  const work = mkdtempSync(join(tmpdir(), "oppi-server-pack-"));
  try {
    stageServerTree(appPath, options.packageTarball ?? packServer(serverDir, work));
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
  return machOSigningOrder(appPath);
}

function flagValue(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1 || index + 1 >= args.length) return undefined;
  return args[index + 1];
}

function printUsage(): never {
  console.error(
    "Usage: bundle-mac-server-bun.ts <stage|sign-list|codesign-args|write-entitlements|identifier> [--app <app>] [--package <tgz>] [--identity <id>] [--entitlements <plist>] [--output <plist>]",
  );
  process.exit(2);
}

if (import.meta.main) {
  const [command, ...rest] = process.argv.slice(2);
  if (!command) printUsage();

  switch (command) {
    case "identifier":
      console.log(SERVER_WORKER_IDENTIFIER);
      break;
    case "write-entitlements": {
      const output = flagValue(rest, "--output");
      if (!output) printUsage();
      writeFileSync(output, serverBunEntitlementsPlist());
      console.log(output);
      break;
    }
    case "stage": {
      const app = flagValue(rest, "--app");
      if (!app) printUsage();
      const packageTarball = flagValue(rest, "--package");
      for (const path of await stageHelpers(app, packageTarball ? { packageTarball } : {})) {
        console.log(path);
      }
      break;
    }
    case "sign-list": {
      const app = flagValue(rest, "--app");
      if (!app) printUsage();
      for (const path of machOSigningOrder(app)) console.log(path);
      break;
    }
    case "codesign-args": {
      const app = flagValue(rest, "--app");
      const identity = flagValue(rest, "--identity");
      const entitlements = flagValue(rest, "--entitlements");
      if (!app || !identity || !entitlements) printUsage();
      const bun = bundledBunPath(app);
      for (const path of machOSigningOrder(app)) {
        const args = codesignArgs({
          identity,
          path,
          ...(path === bun ? { entitlementsPath: entitlements } : {}),
        });
        console.log(args.map((arg) => JSON.stringify(arg)).join(" "));
      }
      break;
    }
    default:
      printUsage();
  }
}
