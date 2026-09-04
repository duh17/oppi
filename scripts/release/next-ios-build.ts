#!/usr/bin/env bun

import { spawnSync } from "node:child_process";

export function parseIosProjectBuild(yaml: string): number | null {
  const match = yaml.match(/CURRENT_PROJECT_VERSION:\s*(\d+)/);
  if (!match) return null;
  const build = Number(match[1]);
  return Number.isInteger(build) && build > 0 ? build : null;
}

export function nextIosReleaseBuild(
  current: number,
  lastShipped: number | null,
): number {
  if (!Number.isInteger(current) || current < 1) {
    throw new Error(`invalid current iOS build: ${current}`);
  }
  if (lastShipped == null) {
    return current + 1;
  }
  if (!Number.isInteger(lastShipped) || lastShipped < 1) {
    throw new Error(`invalid last shipped iOS build: ${lastShipped}`);
  }
  if (current > lastShipped) {
    return current;
  }
  return current + 1;
}

export function readLastShippedIosBuild(
  repoRoot: string,
  remoteRef = "origin/main",
): number | null {
  const result = spawnSync(
    "git",
    ["-C", repoRoot, "show", `${remoteRef}:clients/apple/project.yml`],
    { encoding: "utf8" },
  );
  if (result.status !== 0) return null;
  return parseIosProjectBuild(result.stdout);
}

function readFlag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1) return undefined;
  return args[index + 1];
}

function parseBuildFlag(args: string[], name: string): number | null {
  const raw = readFlag(args, name);
  if (raw == null) return null;
  if (!/^\d+$/.test(raw)) {
    throw new Error(`invalid ${name}: ${raw}`);
  }
  return Number(raw);
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const current = parseBuildFlag(args, "--current");
  if (current == null) {
    console.error("usage: next-ios-build.ts --current N [--last-shipped N]");
    process.exit(1);
  }
  const lastShipped = parseBuildFlag(args, "--last-shipped");
  process.stdout.write(`${nextIosReleaseBuild(current, lastShipped)}\n`);
}
