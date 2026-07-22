#!/usr/bin/env node

import { readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const PI_RELEASE_PACKAGES = [
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
];

const EXACT_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

export function checkPiReleaseVersions(dependencies, latestVersions) {
  const failures = [];

  for (const packageName of PI_RELEASE_PACKAGES) {
    const pinned = dependencies[packageName];
    const latest = latestVersions[packageName];

    if (typeof pinned !== "string") {
      failures.push(`${packageName}: missing from package.json dependencies`);
      continue;
    }
    if (!EXACT_VERSION.test(pinned)) {
      failures.push(
        `${packageName}: package.json must use exact version ${latest}, found ${pinned}`,
      );
      continue;
    }
    if (pinned !== latest) {
      failures.push(`${packageName}: package.json pins ${pinned}, npm latest is ${latest}`);
    }
  }

  return failures;
}

async function fetchLatestVersion(packageName) {
  const response = await fetch(
    `https://registry.npmjs.org/${encodeURIComponent(packageName)}/latest`,
    { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(10_000) },
  );
  if (!response.ok) {
    throw new Error(`${packageName}: npm registry returned HTTP ${response.status}`);
  }
  const body = await response.json();
  if (typeof body.version !== "string" || body.version.length === 0) {
    throw new Error(`${packageName}: npm registry response did not include a version`);
  }
  return body.version;
}

async function runCli() {
  const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const manifest = JSON.parse(readFileSync(path.join(serverDir, "package.json"), "utf8"));
  const entries = await Promise.all(
    PI_RELEASE_PACKAGES.map(async (packageName) => [
      packageName,
      await fetchLatestVersion(packageName),
    ]),
  );
  const latestVersions = Object.fromEntries(entries);
  const failures = checkPiReleaseVersions(manifest.dependencies ?? {}, latestVersions);

  if (failures.length > 0) {
    console.error("Pi release dependency guard failed:");
    for (const failure of failures) console.error(`  - ${failure}`);
    console.error("Update and validate the Pi runtime dependencies before publishing oppi-server.");
    process.exitCode = 1;
    return;
  }

  console.log(
    `Pi release dependencies match npm latest (${PI_RELEASE_PACKAGES.map((name) => `${name}@${latestVersions[name]}`).join(", ")}).`,
  );
}

const cliPath = process.argv[1];
if (
  cliPath &&
  realpathSync(fileURLToPath(import.meta.url)) === realpathSync(path.resolve(cliPath))
) {
  runCli().catch((error) => {
    console.error(
      `Pi release dependency guard failed: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  });
}
