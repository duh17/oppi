#!/usr/bin/env bun
/**
 * Stage and describe the version-pinned Node Mach-O that becomes the Mac
 * server worker (`dev.chenda.OppiMac.server`).
 *
 * The binary is copied into Oppi.app/Contents/Resources/Helpers after archive.
 * It is never Homebrew Node, and signing must not copy Oppi's designated
 * requirement onto the worker.
 *
 * Supply chain: the release signs whatever this script stages, so every tarball
 * is checked against a SHA-256 pinned below before it is extracted, the download
 * must stay on https://nodejs.org, and the extracted binary must report the
 * pinned version. Any failure aborts the release.
 */
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

export const SERVER_WORKER_IDENTIFIER = "dev.chenda.OppiMac.server";
export const PINNED_NODE_VERSION = "24.11.1";
/**
 * SHA-256 of the official tarballs, copied from
 * https://nodejs.org/dist/v24.11.1/SHASUMS256.txt (two identical HTTPS fetches).
 * Update these together with PINNED_NODE_VERSION, from the new release's SHASUMS256.txt.
 */
export const PINNED_NODE_SHA256 = {
  arm64: "b05aa3a66efe680023f930bd5af3fdbbd542794da5644ca2ad711d68cbd4dc35",
  x64: "096081b6d6fcdd3f5ba0f5f1d44a47e83037ad2e78eada26671c252fe64dd111",
} as const;
export const NODE_DOWNLOAD_ORIGIN = "https://nodejs.org/";
export type DarwinArch = "arm64" | "x64";
/**
 * The Release app is universal (xcodebuild ARCHS = arm64 x86_64, ONLY_ACTIVE_ARCH = NO
 * for `generic/platform=macOS`), so the helper must carry both slices.
 */
export const APP_DARWIN_ARCHS: readonly DarwinArch[] = ["arm64", "x64"];
export const BUNDLED_NODE_RELATIVE_PATH = "Contents/Resources/Helpers/node";

export function bundledNodePath(appPath: string): string {
  return join(appPath, BUNDLED_NODE_RELATIVE_PATH);
}

export function darwinArch(arch: string = process.arch): DarwinArch {
  if (arch === "arm64") return "arm64";
  if (arch === "x64") return "x64";
  throw new Error(`Unsupported architecture for bundled Node: ${arch}`);
}

export function officialNodeTarballUrl(version: string, arch: DarwinArch): string {
  return `https://nodejs.org/dist/v${version}/node-v${version}-darwin-${arch}.tar.gz`;
}

export function nodeBinaryPathInsideTarball(version: string, arch: DarwinArch): string {
  return `node-v${version}-darwin-${arch}/bin/node`;
}

// allow-jit + allow-unsigned-executable-memory: V8 generates and runs machine code at runtime
// (JIT, WebAssembly), which hardened runtime blocks without them.
// disable-library-validation: the server's dependencies load N-API addons (for example the
// Pi clipboard binding) that are unsigned or signed by another team, which hardened-runtime
// library validation would reject.
export function serverNodeEntitlementsPlist(): string {
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

export function serverNodeCodesignArgs(opts: {
  identity: string;
  nodePath: string;
  entitlementsPath: string;
}): string[] {
  return [
    "codesign",
    "--force",
    "--options",
    "runtime",
    "--timestamp",
    "--identifier",
    SERVER_WORKER_IDENTIFIER,
    "--entitlements",
    opts.entitlementsPath,
    "--sign",
    opts.identity,
    opts.nodePath,
  ];
}

function flagValue(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1 || index + 1 >= args.length) return undefined;
  return args[index + 1];
}

export function sha256Hex(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/**
 * Download one official tarball and return its bytes only when the final URL is
 * on nodejs.org and the SHA-256 matches `expectedSha256`. Nothing is written
 * before verification.
 */
export async function downloadVerifiedTarball(opts: {
  url: string;
  expectedSha256: string;
  fetchImpl?: typeof fetch;
}): Promise<Uint8Array> {
  const response = await (opts.fetchImpl ?? fetch)(opts.url);
  if (!response.ok) {
    throw new Error(`Failed to download pinned Node from ${opts.url}: ${response.status}`);
  }
  if (!response.url.startsWith(NODE_DOWNLOAD_ORIGIN)) {
    throw new Error(
      `Refusing Node download that left ${NODE_DOWNLOAD_ORIGIN}: ${opts.url} -> ${response.url || "(unknown)"}`,
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

function run(command: string, args: string[]): string {
  const result = spawnSync(command, args, { encoding: "utf-8" });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(result.stderr || `${command} ${args.join(" ")} failed (${result.status})`);
  }
  return result.stdout;
}

/** Fail unless `binary --version` prints exactly the pinned version. */
export function assertNodeVersion(binary: string, version: string = PINNED_NODE_VERSION): void {
  const reported = run(binary, ["--version"]).trim();
  if (reported !== `v${version}`) {
    throw new Error(`${binary} reports ${reported}, expected v${version}`);
  }
}

function extractNode(tarball: string, arch: DarwinArch, dir: string): string {
  const member = nodeBinaryPathInsideTarball(PINNED_NODE_VERSION, arch);
  mkdirSync(dir, { recursive: true });
  run("tar", ["-xzf", tarball, "-C", dir, member]);
  const extracted = join(dir, member);
  if (!existsSync(extracted)) {
    throw new Error(`Extracted Node missing at ${extracted}`);
  }
  return extracted;
}

export async function stageBundledNode(
  appPath: string,
  options: {
    fetchImpl?: typeof fetch;
    sha256?: Record<DarwinArch, string>;
  } = {},
): Promise<string> {
  const dest = bundledNodePath(appPath);

  const work = mkdtempSync(join(tmpdir(), `oppi-node-${PINNED_NODE_VERSION}-`));
  try {
    const slices: string[] = [];
    for (const arch of APP_DARWIN_ARCHS) {
      const url = officialNodeTarballUrl(PINNED_NODE_VERSION, arch);
      const bytes = await downloadVerifiedTarball({
        url,
        expectedSha256: (options.sha256 ?? PINNED_NODE_SHA256)[arch],
        fetchImpl: options.fetchImpl,
      });
      const tarball = join(work, `node-${arch}.tar.gz`);
      writeFileSync(tarball, bytes);
      const extracted = extractNode(tarball, arch, join(work, arch));
      // The host can only execute its own slice; the other one is covered by its digest.
      if (arch === darwinArch()) assertNodeVersion(extracted);
      slices.push(extracted);
    }

    const staged = join(work, "node");
    run("lipo", ["-create", ...slices, "-output", staged]);
    chmodSync(staged, 0o755);
    assertNodeVersion(staged);

    mkdirSync(dirname(dest), { recursive: true });
    run("cp", [staged, dest]);
    chmodSync(dest, 0o755);
    return dest;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function printUsage(): never {
  console.error(
    "Usage: bundle-mac-server-node.ts <stage|path|identifier|write-entitlements|codesign-args> [--app <app>] [--identity <id>] [--output <plist>]",
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
    case "path": {
      const app = flagValue(rest, "--app");
      if (!app) printUsage();
      console.log(bundledNodePath(app));
      break;
    }
    case "write-entitlements": {
      const output = flagValue(rest, "--output");
      if (!output) printUsage();
      writeFileSync(output, serverNodeEntitlementsPlist());
      console.log(output);
      break;
    }
    case "codesign-args": {
      const app = flagValue(rest, "--app");
      const identity = flagValue(rest, "--identity");
      const entitlements = flagValue(rest, "--entitlements");
      if (!app || !identity || !entitlements) printUsage();
      console.log(
        serverNodeCodesignArgs({
          identity,
          nodePath: bundledNodePath(app),
          entitlementsPath: entitlements,
        }).join("\n"),
      );
      break;
    }
    case "stage": {
      const app = flagValue(rest, "--app");
      if (!app) printUsage();
      const dest = await stageBundledNode(app);
      console.log(dest);
      break;
    }
    default:
      printUsage();
  }
}
