#!/usr/bin/env bun

import { readFileSync } from "node:fs";

export type ServerGateMode = "none" | "changed" | "full";
export type AppleGateMode = "none" | "unit" | "all";

export type PrePushPlan = {
  server: ServerGateMode;
  apple: AppleGateMode;
  mac: boolean;
  harness: boolean;
  changedPaths: string[];
};

const gatePolicyPaths = new Set([
  ".gitignore",
  ".githooks/pre-push",
  "scripts/pre-push-plan.ts",
  "scripts/pre-push-plan.test.ts",
  "scripts/detect-ci-relevant-paths.sh",
  "scripts/detect-ci-relevant-paths.test.ts",
  "server/testing-policy.json",
  "server/scripts/testing-gates.ts",
  "server/tests/testing-policy-gate.test.ts",
  "dev/testing/README.md",
]);

function strongerServer(lhs: ServerGateMode, rhs: ServerGateMode): ServerGateMode {
  const rank: Record<ServerGateMode, number> = { none: 0, changed: 1, full: 2 };
  return rank[rhs] > rank[lhs] ? rhs : lhs;
}

function strongerApple(lhs: AppleGateMode, rhs: AppleGateMode): AppleGateMode {
  const rank: Record<AppleGateMode, number> = { none: 0, unit: 1, all: 2 };
  return rank[rhs] > rank[lhs] ? rhs : lhs;
}

function isDocumentation(path: string): boolean {
  return path === "LICENSE"
    || path === "SECURITY.md"
    || path === "CHANGELOG.md"
    || path === "README.md"
    || path.startsWith("docs/")
    || path.startsWith("dev/")
    || path.endsWith(".md");
}

function serverMode(path: string): ServerGateMode {
  if (!path.startsWith("server/")) return "none";
  if (
    path === "server/package.json"
    || path === "server/package-lock.json"
    || path === "server/testing-policy.json"
    || path.startsWith("server/scripts/")
    || path.startsWith("server/e2e/")
    || /^server\/(vitest|tsconfig|eslint|prettier|knip)/.test(path)
  ) {
    return "full";
  }
  return "changed";
}

function affectsMacBuild(path: string): boolean {
  return path === "clients/apple/project.yml"
    || path.endsWith(".xcconfig")
    || path.endsWith("Package.resolved")
    || path.endsWith("project.pbxproj")
    || path.endsWith("OppiMac.xcscheme")
    || path.startsWith("clients/apple/OppiCore/")
    || path.startsWith("clients/apple/Shared/");
}

function appleMode(path: string): AppleGateMode {
  if (!path.startsWith("clients/apple/")) return "none";
  if (path.startsWith("clients/apple/OppiMac")) return "none";
  if (
    path.startsWith("clients/apple/OppiUITests/")
    || path.startsWith("clients/apple/OppiE2ETests/")
    || path.startsWith("clients/apple/OppiPerfTests/")
    || path.startsWith("clients/apple/scripts/")
    || path.includes(".xcodeproj/")
    || path.endsWith("/project.yml")
    || path.endsWith("Package.resolved")
    || path.includes("Extension/")
  ) {
    return "all";
  }
  return "unit";
}

export function planForPaths(inputPaths: Iterable<string>): PrePushPlan {
  const changedPaths = [...new Set([...inputPaths].filter(Boolean))].sort();
  let server: ServerGateMode = "none";
  let apple: AppleGateMode = "none";
  let mac = false;
  let harness = false;

  for (const path of changedPaths) {
    if (gatePolicyPaths.has(path) || path.startsWith(".github/workflows/")) {
      harness = true;
      if (!path.startsWith("server/")) continue;
    }

    const protocolBoundary = path.startsWith("protocol/")
      || path === "server/src/types/protocol.ts"
      || path === "server/src/types/session.ts"
      || path === "server/src/types/icon.ts"
      || path === "server/src/types/git.ts"
      || path === "server/src/types/shared.ts"
      || path === "server/src/thinking-levels.ts"
      || path.startsWith("clients/apple/OppiCore/Models/");
    if (protocolBoundary) {
      server = "full";
      apple = strongerApple(apple, "unit");
      mac = true;
      continue;
    }

    const crossPlatformGuard = path === "server/scripts/check-architecture-boundaries.ts"
      || path === "server/scripts/architecture-layer-rules.mjs"
      || path === "scripts/theme-surface-guard.ts";
    if (crossPlatformGuard) {
      server = strongerServer(server, "full");
      apple = strongerApple(apple, "unit");
      mac = true;
      continue;
    }

    const pathServerMode = serverMode(path);
    if (pathServerMode !== "none") {
      server = strongerServer(server, pathServerMode);
      continue;
    }

    if (path.startsWith("clients/apple/OppiMac")) {
      mac = true;
      continue;
    }

    const pathAppleMode = appleMode(path);
    if (pathAppleMode !== "none") {
      apple = strongerApple(apple, pathAppleMode);
      if (affectsMacBuild(path)) mac = true;
      continue;
    }

    if (isDocumentation(path)) continue;

    // Unknown executable/configuration surfaces fail closed.
    server = "full";
    apple = strongerApple(apple, "unit");
    mac = true;
  }

  return { server, apple, mac, harness, changedPaths };
}

function usage(): never {
  console.error(
    "Usage: scripts/pre-push-plan.ts (--paths-file <path> | --paths0-file <path>) [--format shell|json]",
  );
  process.exit(2);
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const textFileIndex = args.indexOf("--paths-file");
  const zeroFileIndex = args.indexOf("--paths0-file");
  const fileIndex = textFileIndex >= 0 ? textFileIndex : zeroFileIndex;
  if (fileIndex < 0 || !args[fileIndex + 1]) usage();
  const formatIndex = args.indexOf("--format");
  const format = formatIndex >= 0 ? args[formatIndex + 1] : "json";
  if (format !== "json" && format !== "shell") usage();

  const separator = zeroFileIndex >= 0 ? "\0" : "\n";
  const paths = readFileSync(args[fileIndex + 1]!, "utf8").split(separator).filter(Boolean);
  const plan = planForPaths(paths);
  if (format === "json") {
    console.log(JSON.stringify(plan, null, 2));
  } else {
    console.log(`SERVER_MODE=${plan.server}`);
    console.log(`APPLE_MODE=${plan.apple}`);
    console.log(`MAC_CHANGED=${plan.mac ? 1 : 0}`);
    console.log(`HARNESS_CHANGED=${plan.harness ? 1 : 0}`);
    console.log(`CHANGED_COUNT=${plan.changedPaths.length}`);
  }
}
