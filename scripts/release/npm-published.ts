#!/usr/bin/env bun
// Post-publish npm checks for oppi-server and oppi-mirror. Read-only: it never publishes,
// tags, or installs outside a temporary prefix, which it deletes.
//
//   1. Poll the registry until `latest` names the version for both packages.
//   2. oppi-server ships its shrinkwrap (`_hasShrinkwrap`).
//   3. `npm pack` the published oppi-server tarball; its SHA-256 must equal the tarball the
//      pre-publish validation verified (newest `.pi/reports/npm-release/*/artifacts/` copy,
//      or --tarball).
//   4. server/scripts/check-pack-contents.mjs passes on the published tarball.
//   5. A clean `npm install -g --prefer-online` into a temporary prefix reports the version.
//
// Every registry read passes --prefer-online: npm's cache once served a stale version list
// right after a publish.
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SERVER = "oppi-server";
const MIRROR = "oppi-mirror";

type Options = {
  serverVersion: string;
  mirrorVersion: string;
  tarball: string;
  timeoutSeconds: number;
};

function usage(): string {
  return `Usage: bun scripts/release/npm-published.ts [options]

Options:
  --version X.Y.Z         oppi-server version (default: server/package.json)
  --mirror-version X.Y.Z  oppi-mirror version (default: pi-extensions/oppi-mirror/package.json)
  --tarball <path>        Verified oppi-server tarball (default: newest
                          .pi/reports/npm-release/*/artifacts/oppi-server-<version>.tgz)
  --timeout <seconds>     How long to wait for \`latest\` (default: 600)`;
}

function packageVersion(relativePath: string): string {
  return (JSON.parse(readFileSync(join(ROOT, relativePath), "utf8")) as { version: string }).version;
}

/** Newest release-npm report (timestamped directory names sort by time) holding this version's tarball. */
function findVerifiedTarball(reportsDir: string, version: string): string | null {
  if (!existsSync(reportsDir)) return null;
  const runs = readdirSync(reportsDir).sort().reverse();
  for (const run of runs) {
    const candidate = join(reportsDir, run, "artifacts", `${SERVER}-${version}.tgz`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function parseArgs(args: string[]): Options {
  let serverVersion = "";
  let mirrorVersion = "";
  let tarball = "";
  let timeoutSeconds = 600;
  for (let index = 0; index < args.length; index += 1) {
    const [flag, inline] = args[index].split(/=(.*)/s, 2);
    const value = () => inline ?? args[++index] ?? "";
    if (flag === "--version") serverVersion = value();
    else if (flag === "--mirror-version") mirrorVersion = value();
    else if (flag === "--tarball") tarball = value();
    else if (flag === "--timeout") timeoutSeconds = Number(value());
    else if (flag === "-h" || flag === "--help") {
      console.log(usage());
      process.exit(0);
    } else throw new Error(`Unknown argument: ${args[index]}\n${usage()}`);
  }
  serverVersion ||= packageVersion("server/package.json");
  mirrorVersion ||= packageVersion("pi-extensions/oppi-mirror/package.json");
  for (const version of [serverVersion, mirrorVersion]) {
    if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Not a version: ${version}`);
  }
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds < 0) throw new Error("Pass --timeout <seconds>");
  const reportsDir = join(process.env.OPPI_ROOT ?? ROOT, ".pi/reports/npm-release");
  tarball ||= findVerifiedTarball(reportsDir, serverVersion) ?? "";
  if (!tarball || !existsSync(tarball)) {
    throw new Error(
      `No verified ${SERVER}-${serverVersion}.tgz under ${reportsDir}; pass --tarball <path>`,
    );
  }
  return { serverVersion, mirrorVersion, tarball: resolve(tarball), timeoutSeconds };
}

// A user's npm config may hold back new releases (`before`, `min-release-age`); a
// post-publish check must see the version the registry serves now.
function npmEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined || /^npm_config_(before|min_release_age)$/i.test(key)) continue;
    env[key] = value;
  }
  return env;
}

function run(cmd: string[], cwd = ROOT): string {
  console.log(`+ ${cmd.join(" ")}`);
  const result = Bun.spawnSync(cmd, { cwd, env: npmEnv(), stdout: "pipe", stderr: "pipe" });
  const stdout = result.stdout.toString();
  if (result.exitCode !== 0) {
    throw new Error(`${cmd.join(" ")} exited ${result.exitCode}\n${stdout}${result.stderr.toString()}`);
  }
  return stdout;
}

function latest(name: string): string {
  return JSON.parse(run(["npm", "view", name, "dist-tags.latest", "--json", "--prefer-online"]) || '""');
}

async function waitForLatest(name: string, version: string, timeoutSeconds: number): Promise<void> {
  const deadline = Date.now() + timeoutSeconds * 1000;
  for (;;) {
    const current = latest(name);
    if (current === version) {
      console.log(`OK ${name} latest = ${version}`);
      return;
    }
    if (Date.now() >= deadline) {
      throw new Error(`${name} latest is ${current || "unset"}, not ${version}, after ${timeoutSeconds}s`);
    }
    console.log(`${name} latest is ${current || "unset"}; waiting for ${version}`);
    await Bun.sleep(15_000);
  }
}

function sha256(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

async function main(): Promise<void> {
  const options = parseArgs(Bun.argv.slice(2));
  const { serverVersion, mirrorVersion, tarball } = options;
  const spec = `${SERVER}@${serverVersion}`;
  console.log(`=== Post-publish npm checks: ${spec}, ${MIRROR}@${mirrorVersion} ===`);
  console.log(`Verified tarball: ${tarball}`);

  await waitForLatest(SERVER, serverVersion, options.timeoutSeconds);
  await waitForLatest(MIRROR, mirrorVersion, options.timeoutSeconds);

  const shrinkwrap = run(["npm", "view", spec, "_hasShrinkwrap", "--json", "--prefer-online"]).trim();
  if (shrinkwrap !== "true") throw new Error(`${spec} _hasShrinkwrap is ${shrinkwrap || "unset"}, not true`);
  console.log(`OK ${spec} _hasShrinkwrap = true`);

  const tmp = mkdtempSync(join(tmpdir(), "oppi-npm-published-"));
  try {
    run(["npm", "pack", spec, "--pack-destination", tmp, "--prefer-online"], tmp);
    const published = join(tmp, `${SERVER}-${serverVersion}.tgz`);
    const publishedSha = sha256(published);
    const verifiedSha = sha256(tarball);
    if (publishedSha !== verifiedSha) {
      throw new Error(`Published tarball sha256 ${publishedSha} differs from verified ${verifiedSha}`);
    }
    console.log(`OK published tarball sha256 = verified ${verifiedSha}`);

    process.stdout.write(
      run(["node", "scripts/check-pack-contents.mjs", "--tarball", published], join(ROOT, "server")),
    );
    console.log("OK check-pack-contents");

    const prefix = join(tmp, "prefix");
    // Install by name from the registry: only a registry install honors the shrinkwrap.
    run(["npm", "install", "-g", "--prefer-online", "--no-audit", "--no-fund", "--prefix", prefix, spec], tmp);
    const reported = run([join(prefix, "bin", "oppi"), "--version"], tmp).trim();
    if (!reported.includes(serverVersion)) {
      throw new Error(`Clean install reports "${reported}", not ${serverVersion}`);
    }
    console.log(`OK clean install reports: ${reported}`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  console.log(`=== ${spec} and ${MIRROR}@${mirrorVersion} verified ===`);
}

if (import.meta.main) {
  main().catch((error: unknown) => {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  });
}
