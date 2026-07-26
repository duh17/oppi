#!/usr/bin/env bun
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type ReleaseIntent = {
  schemaVersion: number;
  components: {
    server: { release: boolean; version: string };
    mirror: { release: boolean; version: string };
    ios: {
      release: boolean;
      target: string;
      marketingVersion: string;
      build: number;
      whatsNewFromBuild: number;
    };
  };
  whatToTestPath: string;
  changelogPath: string;
};

export type ReleasePreflightInput = {
  targetBuild: number;
  whatsNewStartBuild: number;
  serverVersion: string;
  mirrorVersion: string;
  iosMarketingVersion: string;
  intent: ReleaseIntent;
  changelogRelativePath: string;
  whatToTestRelativePath: string;
  serverManifestVersion: string;
  lockfileVersion: string;
  lockfileRootVersion: string;
  mirrorManifestVersion: string;
  iosBuilds: Record<string, number | null>;
  whatsNewSource: string;
  changelog: string;
  whatToTest: string;
  trackedReleasePaths: string[];
};

const REQUIRED_IOS_TARGETS = [
  "Oppi",
  "OppiActivityExtension",
  "OppiShareExtension",
  "OppiControlWidget",
];

export function readTargetSetting(
  projectYml: string,
  target: string,
  key: string,
): string | null {
  const lines = projectYml.split("\n");
  let inTarget = false;
  for (const line of lines) {
    if (line === `  ${target}:`) {
      inTarget = true;
      continue;
    }
    if (inTarget && /^  [A-Za-z0-9_]+:/.test(line)) break;
    if (inTarget) {
      const match = line.match(new RegExp(`^\\s+${key}:\\s*["']?([^"'#]+)`));
      if (match) return match[1].trim();
    }
  }
  return null;
}

export function validateReleasePreflight(
  input: ReleasePreflightInput,
): string[] {
  const failures: string[] = [];
  if (input.intent.schemaVersion !== 1) {
    failures.push(
      `release intent schema ${input.intent.schemaVersion} is unsupported`,
    );
  }
  if (
    !input.intent.components.server.release ||
    input.intent.components.server.version !== input.serverVersion
  ) {
    failures.push(
      "release intent does not authorize the target server version",
    );
  }
  if (
    input.intent.components.mirror.release ||
    input.intent.components.mirror.version !== input.mirrorVersion
  ) {
    failures.push(
      "release intent must retain the declared non-released mirror version",
    );
  }
  const intentIos = input.intent.components.ios;
  if (
    !intentIos.release ||
    intentIos.target !== "Oppi" ||
    intentIos.marketingVersion !== input.iosMarketingVersion ||
    intentIos.build !== input.targetBuild ||
    intentIos.whatsNewFromBuild !== input.whatsNewStartBuild
  ) {
    failures.push("release intent iOS coordinates do not match the candidate");
  }
  if (
    input.intent.changelogPath !== input.changelogRelativePath ||
    input.intent.whatToTestPath !== input.whatToTestRelativePath
  ) {
    failures.push("release intent note paths do not match the candidate files");
  }
  if (input.serverManifestVersion !== input.serverVersion) {
    failures.push(
      `oppi-server version ${input.serverManifestVersion} does not match target ${input.serverVersion}`,
    );
  }
  if (
    input.lockfileVersion !== input.serverVersion ||
    input.lockfileRootVersion !== input.serverVersion
  ) {
    failures.push(
      `server package-lock versions must both equal ${input.serverVersion}`,
    );
  }
  if (input.mirrorManifestVersion !== input.mirrorVersion) {
    failures.push(
      `oppi-mirror version ${input.mirrorManifestVersion} does not match target ${input.mirrorVersion}`,
    );
  }
  for (const target of REQUIRED_IOS_TARGETS) {
    if (input.iosBuilds[target] !== input.targetBuild) {
      failures.push(
        `${target} build ${input.iosBuilds[target] ?? "missing"} does not match ${input.targetBuild}`,
      );
    }
  }
  const whatsNewPattern =
    input.whatsNewStartBuild === input.targetBuild
      ? new RegExp(`Build[^\\n]*\\b${input.targetBuild}\\b`, "i")
      : new RegExp(
          `Builds?\\s+${input.whatsNewStartBuild}\\s*[–-]\\s*${input.targetBuild}\\b`,
          "i",
        );
  if (!whatsNewPattern.test(input.whatsNewSource)) {
    const expected =
      input.whatsNewStartBuild === input.targetBuild
        ? `build ${input.targetBuild}`
        : `builds ${input.whatsNewStartBuild}–${input.targetBuild}`;
    failures.push(`What's New does not identify ${expected}`);
  }
  if (!input.changelog.trim())
    failures.push("internal changelog is missing or empty");
  if (!input.whatToTest.trim())
    failures.push("What to Test is missing or empty");
  if (/\bDraft:/i.test(input.changelog) || /\bDraft:/i.test(input.whatToTest)) {
    failures.push("release notes still contain Draft placeholders");
  }
  if (input.whatToTest.length > 600) {
    failures.push(
      `What to Test is ${input.whatToTest.length} characters; keep it at or below 600`,
    );
  }
  for (const path of input.trackedReleasePaths) {
    if (path.startsWith("missing:")) {
      failures.push(
        `required release path is not tracked: ${path.slice("missing:".length)}`,
      );
    }
  }
  return failures;
}

function parseArgs(args: string[]): {
  targetBuild: number;
  whatsNewStartBuild: number;
  serverVersion: string;
  mirrorVersion: string;
} {
  let targetBuild = 0;
  let whatsNewStartBuild = 0;
  let serverVersion = "";
  let mirrorVersion = "";
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "--build-number") targetBuild = Number(args[++index]);
    else if (args[index]?.startsWith("--build-number="))
      targetBuild = Number(args[index].split("=")[1]);
    else if (args[index] === "--whats-new-from-build")
      whatsNewStartBuild = Number(args[++index]);
    else if (args[index]?.startsWith("--whats-new-from-build="))
      whatsNewStartBuild = Number(args[index].split("=")[1]);
    else if (args[index] === "--server-version")
      serverVersion = args[++index] || "";
    else if (args[index]?.startsWith("--server-version="))
      serverVersion = args[index].split("=")[1] || "";
    else if (args[index] === "--mirror-version")
      mirrorVersion = args[++index] || "";
    else if (args[index]?.startsWith("--mirror-version="))
      mirrorVersion = args[index].split("=")[1] || "";
    else throw new Error(`Unknown argument: ${args[index]}`);
  }
  if (!Number.isInteger(targetBuild) || targetBuild < 1)
    throw new Error("Pass --build-number N");
  if (
    !Number.isInteger(whatsNewStartBuild) ||
    whatsNewStartBuild < 1 ||
    whatsNewStartBuild > targetBuild
  ) {
    throw new Error(
      "Pass --whats-new-from-build N at or before the target build",
    );
  }
  if (!/^\d+\.\d+\.\d+$/.test(serverVersion))
    throw new Error("Pass --server-version X.Y.Z");
  if (!/^\d+\.\d+\.\d+$/.test(mirrorVersion))
    throw new Error("Pass --mirror-version X.Y.Z");
  return { targetBuild, whatsNewStartBuild, serverVersion, mirrorVersion };
}

type PackageManifest = { version?: string };
type PackageLock = {
  version?: string;
  packages?: Record<string, { version?: string }>;
};

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

async function main(): Promise<void> {
  const { targetBuild, whatsNewStartBuild, serverVersion, mirrorVersion } =
    parseArgs(Bun.argv.slice(2));
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const root = resolve(scriptDir, "../..");
  const serverManifest = readJson<PackageManifest>(
    resolve(root, "server/package.json"),
  );
  const serverLock = readJson<PackageLock>(
    resolve(root, "server/package-lock.json"),
  );
  const mirrorManifest = readJson<PackageManifest>(
    resolve(root, "pi-extensions/oppi-mirror/package.json"),
  );
  const intent = readJson<ReleaseIntent>(resolve(root, "release/intent.json"));
  const projectYml = readFileSync(
    resolve(root, "clients/apple/project.yml"),
    "utf8",
  );
  const changelogRelativePath = `.internal/release-notes/testflight-build-${targetBuild}-changelog.md`;
  const whatToTestRelativePath = `.internal/release-notes/testflight-build-${targetBuild}-what-to-test.md`;
  const changelogPath = resolve(root, changelogRelativePath);
  const whatToTestPath = resolve(root, whatToTestRelativePath);
  const whatsNewPath = resolve(
    root,
    "clients/apple/Oppi/Features/Onboarding/WhatsNewView.swift",
  );
  const requiredTrackedPaths = [
    "release/intent.json",
    "scripts/release/preflight.ts",
    "scripts/release/release-notes.ts",
    "scripts/release/apple/testflight.ts",
    "scripts/release/apple/asc.ts",
  ];

  const trackedReleasePaths = await Promise.all(
    requiredTrackedPaths.map(async (relativePath) => {
      const file = Bun.file(resolve(root, relativePath));
      if (!(await file.exists())) return `missing:${relativePath}`;
      const proc = Bun.spawn(
        ["git", "-C", root, "ls-files", "--error-unmatch", "--", relativePath],
        { stdout: "ignore", stderr: "ignore" },
      );
      return (await proc.exited) === 0
        ? relativePath
        : `missing:${relativePath}`;
    }),
  );

  const input: ReleasePreflightInput = {
    targetBuild,
    whatsNewStartBuild,
    serverVersion,
    mirrorVersion,
    iosMarketingVersion:
      readTargetSetting(projectYml, "Oppi", "MARKETING_VERSION") ?? "",
    intent,
    changelogRelativePath,
    whatToTestRelativePath,
    serverManifestVersion: serverManifest.version ?? "",
    lockfileVersion: serverLock.version ?? "",
    lockfileRootVersion: serverLock.packages?.[""]?.version ?? "",
    mirrorManifestVersion: mirrorManifest.version ?? "",
    iosBuilds: Object.fromEntries(
      REQUIRED_IOS_TARGETS.map((target) => {
        const raw = readTargetSetting(
          projectYml,
          target,
          "CURRENT_PROJECT_VERSION",
        );
        return [target, raw ? Number(raw) : null];
      }),
    ),
    whatsNewSource: readFileSync(whatsNewPath, "utf8"),
    changelog: existsSync(changelogPath)
      ? readFileSync(changelogPath, "utf8")
      : "",
    whatToTest: existsSync(whatToTestPath)
      ? readFileSync(whatToTestPath, "utf8")
      : "",
    trackedReleasePaths,
  };

  const failures = validateReleasePreflight(input);
  if (failures.length > 0) {
    console.error("Release preflight failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }

  console.log(
    `Release preflight passed: iOS build ${targetBuild}, oppi-server ${serverVersion}, oppi-mirror ${mirrorVersion}.`,
  );
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
