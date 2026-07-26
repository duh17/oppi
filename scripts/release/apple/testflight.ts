#!/usr/bin/env bun
//
// testflight.ts — Archive/upload and perform explicit TestFlight distribution steps.
//
// Usage:
//   bun testflight.ts --bump                          # bump build number, archive, upload
//   bun testflight.ts --build-number 25               # explicit build number
//   bun testflight.ts --build-only                    # archive + export IPA only (no upload)
//   bun testflight.ts list-builds                     # list recent builds from ASC
//   bun testflight.ts build-usage [build]             # exact build aggregate from ASC (not period-scoped)
//   bun testflight.ts build-usage-raw [build]         # raw JSON from /metrics/betaBuildUsages
//   bun testflight.ts sync-internal 28 [notes-file] [locale]      # sync What to Test + Internal Testers only
//   bun testflight.ts add-external-groups 28 "Group" [...]        # explicitly add named external groups
//   bun testflight.ts submit-beta-review 28                       # explicitly submit external beta review
//   bun testflight.ts show-what-to-test 28                           # show current What to Test text
//   bun testflight.ts set-what-to-test 28 [notes-file]               # update What to Test (default: .internal/release-notes/...)
//   bun testflight.ts usage [--save]                                 # exact app-level usage summary by period
//   bun testflight.ts usage-testers [period] [--no-top]              # exact app-level per-tester usage counts
//   bun testflight.ts usage-testers-raw [period] [limit]             # raw JSON from /metrics/betaTesterUsages
//   bun testflight.ts usage-history [limit]                          # show saved snapshot history
//
// Prerequisites:
//   - Xcode with automatic signing (team AZAQMY4SPZ)
//   - ASC API key: ~/.appstoreconnect/AuthKey_<KEY_ID>.p8
//   - ASC issuer ID: ~/.appstoreconnect/issuer_id
//   - XcodeGen installed (brew install xcodegen)

import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { $ } from "bun";

// ── Constants ──

const BUNDLE_ID = "dev.chenda.Oppi";
const TEAM_ID = "AZAQMY4SPZ";
const INTERNAL_GROUP = "Internal Testers";
const DEFAULT_WHAT_TO_TEST_LOCALE = "en-US";
export function defaultRepoRoot(moduleUrl = import.meta.url): string {
  return path.resolve(path.dirname(fileURLToPath(moduleUrl)), "../../..");
}
const REPO_ROOT = process.env.OPPI_ROOT || defaultRepoRoot();
const APPLE_DIR = path.join(REPO_ROOT, "clients", "apple");
const PROJECT_YML = path.join(APPLE_DIR, "project.yml");
const DEFAULT_INTERNAL_RELEASE_NOTES_DIR = path.join(
  REPO_ROOT,
  ".internal",
  "release-notes",
);
const USAGE_TRACKING_FILE = path.join(
  REPO_ROOT,
  ".pi",
  "testflight-usage.jsonl",
);

// ── ASC credentials ──

function loadCredentials(): {
  keyId: string;
  issuerId: string;
  privateKey: string;
  keyPath: string;
} {
  const home = process.env.HOME!;
  const keyId = (
    process.env.ASC_KEY_ID || readFileOr(`${home}/.appstoreconnect/key_id`)
  ).trim();
  const issuerId = (
    process.env.ASC_ISSUER_ID ||
    readFileOr(`${home}/.appstoreconnect/issuer_id`)
  ).trim();
  const keyPath =
    process.env.ASC_KEY_PATH || `${home}/.appstoreconnect/AuthKey_${keyId}.p8`;
  const privateKey = fs.readFileSync(keyPath, "utf-8");
  return { keyId, issuerId, privateKey, keyPath };
}

function readFileOr(filePath: string, fallback = ""): string {
  try {
    return fs.readFileSync(filePath, "utf-8");
  } catch {
    return fallback;
  }
}

// ── ASC API ──

let _creds: ReturnType<typeof loadCredentials> | null = null;
function creds() {
  if (!_creds) _creds = loadCredentials();
  return _creds;
}

function makeJWT(): string {
  const { keyId, issuerId, privateKey } = creds();
  const header = Buffer.from(
    JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }),
  ).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const payload = Buffer.from(
    JSON.stringify({
      iss: issuerId,
      iat: now,
      exp: now + 1200,
      aud: "appstoreconnect-v1",
    }),
  ).toString("base64url");
  const sig = crypto.sign("sha256", Buffer.from(`${header}.${payload}`), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${header}.${payload}.${sig.toString("base64url")}`;
}

async function ascApi(
  urlPath: string,
  method = "GET",
  body?: object,
): Promise<any> {
  const jwt = makeJWT();
  const opts: RequestInit = {
    method,
    headers: {
      Authorization: `Bearer ${jwt}`,
      "Content-Type": "application/json",
    },
  };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(
    `https://api.appstoreconnect.apple.com${urlPath}`,
    opts,
  );
  if (method === "DELETE" && res.status === 204) return null;
  const json = await res.json();
  if (!res.ok)
    throw new Error(`ASC API ${res.status}: ${JSON.stringify(json)}`);
  return json;
}

// ── ASC helpers ──

async function findApp(): Promise<string> {
  const resp = await ascApi(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
  const app = resp.data?.[0];
  if (!app) throw new Error(`App not found for bundle ID: ${BUNDLE_ID}`);
  return app.id;
}

async function listBuilds(appId: string, limit = 10): Promise<any[]> {
  const resp = await ascApi(
    `/v1/builds?filter[app]=${appId}&sort=-version&limit=${limit}&fields[builds]=version,processingState,uploadedDate,minOsVersion`,
  );
  return resp.data || [];
}

type BuildUsagePoint = {
  start?: string;
  end?: string;
  values?: {
    installCount?: number;
    inviteCount?: number;
    sessionCount?: number;
    crashCount?: number;
    feedbackCount?: number;
  };
};

async function findBuild(
  appId: string,
  buildNumber: string,
): Promise<any | null> {
  const resp = await ascApi(
    `/v1/builds?filter[app]=${appId}&filter[version]=${buildNumber}`,
  );
  return resp.data?.[0] || null;
}

function extractLatestBuildUsagePoint(
  metricData: any[],
): BuildUsagePoint | null {
  const points: BuildUsagePoint[] = [];
  for (const metric of metricData || []) {
    for (const point of metric.dataPoints || []) {
      points.push(point);
    }
  }
  if (points.length === 0) return null;
  points.sort((a, b) => {
    const aKey = a.end || a.start || "";
    const bKey = b.end || b.start || "";
    return aKey.localeCompare(bKey);
  });
  return points[points.length - 1];
}

async function getBuildUsageRaw(buildId: string): Promise<any> {
  return await ascApi(`/v1/builds/${buildId}/metrics/betaBuildUsages`);
}

async function getBuildUsagePoint(
  buildId: string,
): Promise<BuildUsagePoint | null> {
  const raw = await getBuildUsageRaw(buildId);
  return extractLatestBuildUsagePoint(raw.data || []);
}

async function waitForBuild(
  appId: string,
  buildNumber: string,
  maxWait = 900,
): Promise<any> {
  const start = Date.now();
  const interval = 30_000;
  console.log(
    `Waiting for build ${buildNumber} to finish processing (up to ${maxWait / 60} min)...`,
  );

  while (Date.now() - start < maxWait * 1000) {
    const build = await findBuild(appId, buildNumber);
    if (!build) {
      console.log(`  Build ${buildNumber} not yet visible in ASC, retrying...`);
      await sleep(interval);
      continue;
    }
    const state = build.attributes.processingState;
    console.log(`  Build ${buildNumber}: ${state}`);
    if (state === "VALID") return build;
    if (state === "FAILED" || state === "INVALID") {
      throw new Error(`Build ${buildNumber} processing failed: ${state}`);
    }
    await sleep(interval);
  }
  throw new Error(`Timed out waiting for build ${buildNumber} to process`);
}

async function findBetaGroup(
  appId: string,
  groupName: string,
): Promise<string> {
  const resp = await ascApi(`/v1/apps/${appId}/betaGroups`);
  const group = (resp.data || []).find(
    (g: any) => g.attributes.name === groupName,
  );
  if (!group) {
    const available = (resp.data || [])
      .map((g: any) => g.attributes.name)
      .join(", ");
    throw new Error(
      `Beta group "${groupName}" not found. Available: ${available}`,
    );
  }
  return group.id;
}

async function addBuildToGroup(
  groupId: string,
  buildId: string,
): Promise<void> {
  await ascApi(`/v1/betaGroups/${groupId}/relationships/builds`, "POST", {
    data: [{ type: "builds", id: buildId }],
  });
  console.log(`Build added to beta group.`);
}

async function betaGroupHasBuild(
  groupId: string,
  buildId: string,
): Promise<boolean> {
  const resp = await ascApi(
    `/v1/betaGroups/${groupId}/relationships/builds?limit=200`,
  );
  return (resp.data || []).some((build: any) => build.id === buildId);
}

async function buildBetaDetail(buildId: string): Promise<any | null> {
  const resp = await ascApi(`/v1/builds/${buildId}/buildBetaDetail`);
  return resp.data || null;
}

const BETA_REVIEW_ALREADY_SUBMITTED_STATES = new Set([
  "WAITING_FOR_BETA_REVIEW",
  "IN_BETA_REVIEW",
  "READY_FOR_BETA_TESTING",
  "IN_BETA_TESTING",
]);

export function isBetaReviewAlreadySubmittedState(state: string): boolean {
  return BETA_REVIEW_ALREADY_SUBMITTED_STATES.has(state);
}

async function submitForBetaReview(buildId: string): Promise<void> {
  try {
    await ascApi(`/v1/betaAppReviewSubmissions`, "POST", {
      data: {
        type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: buildId } } },
      },
    });
    console.log(`Build submitted for beta app review.`);
    return;
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("INVALID_QC_STATE")) throw error;

    let externalState: string;
    try {
      const detail = await buildBetaDetail(buildId);
      externalState = detail?.attributes?.externalBuildState || "UNKNOWN";
    } catch {
      throw error;
    }
    if (!isBetaReviewAlreadySubmittedState(externalState)) throw error;

    console.log(
      `Build is already in an external beta state (${externalState}); skipping beta review submission.`,
    );
  }
}

async function listBetaBuildLocalizations(buildId: string): Promise<any[]> {
  const resp = await ascApi(
    `/v1/builds/${buildId}/betaBuildLocalizations?limit=200`,
  );
  return resp.data || [];
}

async function upsertWhatToTest(
  buildId: string,
  whatsNew: string,
  locale: string,
): Promise<void> {
  const localizations = await listBetaBuildLocalizations(buildId);
  const existing = localizations.find(
    (loc: any) => loc.attributes?.locale === locale,
  );

  if (existing) {
    await ascApi(`/v1/betaBuildLocalizations/${existing.id}`, "PATCH", {
      data: {
        type: "betaBuildLocalizations",
        id: existing.id,
        attributes: { whatsNew },
      },
    });
    console.log(`Updated What to Test (${locale}).`);
    return;
  }

  await ascApi(`/v1/betaBuildLocalizations`, "POST", {
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale, whatsNew },
      relationships: {
        build: {
          data: { type: "builds", id: buildId },
        },
      },
    },
  });

  console.log(`Created What to Test (${locale}).`);
}

function defaultWhatToTestPath(buildNumber: string): string {
  return path.join(
    DEFAULT_INTERNAL_RELEASE_NOTES_DIR,
    `testflight-build-${buildNumber}-what-to-test.md`,
  );
}

function resolveWhatToTestPath(buildNumber: string, filePath?: string): string {
  if (filePath) return path.resolve(process.cwd(), filePath);
  return defaultWhatToTestPath(buildNumber);
}

function loadWhatToTestText(
  buildNumber: string,
  filePath?: string,
): { absPath: string; whatsNew: string } {
  const absPath = resolveWhatToTestPath(buildNumber, filePath);
  if (!fs.existsSync(absPath)) {
    die(
      `What to Test file not found: ${absPath}\nCreate it (default path: ${defaultWhatToTestPath(buildNumber)}) and re-run.`,
    );
  }

  const whatsNew = fs.readFileSync(absPath, "utf-8").trim();
  if (!whatsNew) {
    die(`What to Test content is empty: ${absPath}`);
  }

  return { absPath, whatsNew };
}

// ── Build number helpers ──

function readCurrentBuild(): number {
  const content = fs.readFileSync(PROJECT_YML, "utf-8");
  const match = content.match(/CURRENT_PROJECT_VERSION:\s*(\d+)/);
  if (!match)
    throw new Error("CURRENT_PROJECT_VERSION not found in project.yml");
  return parseInt(match[1], 10);
}

function updateBuildNumber(oldBuild: number, newBuild: number): void {
  let content = fs.readFileSync(PROJECT_YML, "utf-8");
  content = content.replaceAll(
    `CURRENT_PROJECT_VERSION: ${oldBuild}`,
    `CURRENT_PROJECT_VERSION: ${newBuild}`,
  );
  fs.writeFileSync(PROJECT_YML, content, "utf-8");
}

// ── Utilities ──

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function timestamp(): string {
  const now = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
}

function die(msg: string): never {
  console.error(`Error: ${msg}`);
  process.exit(1);
}

export async function runXcodebuild(
  args: string[],
  logPath: string,
  tailLineCount: number,
  executable = "xcodebuild",
): Promise<void> {
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const log = fs.createWriteStream(logPath, { flags: "w" });
  const tail: string[] = [];

  const append = (chunk: Buffer | string) => {
    const text = chunk.toString();
    log.write(text);
    for (const line of text.split(/\r?\n/)) {
      if (!line) continue;
      tail.push(line);
      if (tail.length > tailLineCount) tail.shift();
    }
  };

  const child = spawn(executable, args, {
    cwd: APPLE_DIR,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", append);
  child.stderr.on("data", append);

  const exitCode = await new Promise<number>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => resolve(code ?? 1));
  });
  await new Promise<void>((resolve) => log.end(resolve));

  if (tail.length > 0) console.log(tail.join("\n"));
  console.log(`xcodebuild log: ${logPath}`);
  if (exitCode !== 0) {
    throw new Error(`xcodebuild failed with exit code ${exitCode}`);
  }
}

// ── Commands ──

async function cmdListBuilds(): Promise<void> {
  const appId = await findApp();
  const builds = await listBuilds(appId);

  if (builds.length === 0) {
    console.log("No builds found.");
    return;
  }

  console.log("Recent builds:");
  console.log("  BUILD    STATE              UPLOADED");
  console.log("  -----    -----              --------");
  for (const b of builds) {
    const ver = b.attributes.version.padEnd(8);
    const state = b.attributes.processingState.padEnd(18);
    const date = b.attributes.uploadedDate?.slice(0, 19) || "—";
    console.log(`  ${ver} ${state} ${date}`);
  }
}

async function resolveBuildOrLatest(
  appId: string,
  buildNumber?: string,
): Promise<any> {
  if (buildNumber) {
    const build = await findBuild(appId, buildNumber);
    if (!build) die(`Build ${buildNumber} not found in App Store Connect.`);
    return build;
  }

  const builds = await listBuilds(appId, 1);
  if (builds.length === 0) die("No builds found in App Store Connect.");
  return builds[0];
}

async function cmdBuildUsage(buildNumber?: string): Promise<void> {
  const appId = await findApp();
  const build = await resolveBuildOrLatest(appId, buildNumber);
  const point = await getBuildUsagePoint(build.id);

  console.log(`Build ${build.attributes.version} usage`);
  console.log(`  Source:   /v1/builds/${build.id}/metrics/betaBuildUsages`);
  console.log(`  State:    ${build.attributes.processingState || "—"}`);
  console.log(
    `  Uploaded: ${build.attributes.uploadedDate?.slice(0, 19) || "—"}`,
  );
  console.log(
    `  ASC range:${point?.start ? ` ${point.start} → ${point.end || point.start}` : " —"}`,
  );
  console.log(
    "  Note:     exact build aggregate from Apple; this endpoint has no period filter and no per-tester breakdown.",
  );
  console.log(`  Installs: ${point?.values?.installCount ?? 0}`);
  console.log(`  Invites:  ${point?.values?.inviteCount ?? 0}`);
  console.log(`  Sessions: ${point?.values?.sessionCount ?? 0}`);
  console.log(`  Crashes:  ${point?.values?.crashCount ?? 0}`);
  console.log(`  Feedback: ${point?.values?.feedbackCount ?? 0}`);
}

async function cmdBuildUsageRaw(buildNumber?: string): Promise<void> {
  const appId = await findApp();
  const build = await resolveBuildOrLatest(appId, buildNumber);
  const raw = await getBuildUsageRaw(build.id);

  console.log(
    JSON.stringify(
      {
        appId,
        buildId: build.id,
        buildVersion: build.attributes.version,
        processingState: build.attributes.processingState,
        uploadedDate: build.attributes.uploadedDate,
        endpoint: `/v1/builds/${build.id}/metrics/betaBuildUsages`,
        raw,
      },
      null,
      2,
    ),
  );
}

async function cmdShowWhatToTest(
  buildNumber?: string,
  locale = DEFAULT_WHAT_TO_TEST_LOCALE,
): Promise<void> {
  const appId = await findApp();

  let build: any;
  if (buildNumber) {
    build = await findBuild(appId, buildNumber);
    if (!build) die(`Build ${buildNumber} not found in App Store Connect.`);
  } else {
    const builds = await listBuilds(appId, 1);
    if (builds.length === 0) die("No builds found in App Store Connect.");
    build = builds[0];
  }

  const localizations = await listBetaBuildLocalizations(build.id);
  if (localizations.length === 0) {
    console.log(
      `Build ${build.attributes.version} has no What to Test localizations yet.`,
    );
    return;
  }

  const match =
    localizations.find((loc: any) => loc.attributes?.locale === locale) ||
    localizations[0];
  const whatsNew = match.attributes?.whatsNew || "";

  console.log(
    `Build ${build.attributes.version} What to Test (${match.attributes?.locale || "unknown-locale"})`,
  );
  console.log("---");
  console.log(whatsNew || "(empty)");
}

async function cmdSetWhatToTest(
  buildNumber: string,
  filePath?: string,
  locale = DEFAULT_WHAT_TO_TEST_LOCALE,
): Promise<void> {
  if (!buildNumber)
    die(
      "set-what-to-test requires a build number, e.g. set-what-to-test 28 [file]",
    );

  const { absPath, whatsNew } = loadWhatToTestText(buildNumber, filePath);
  const appId = await findApp();
  const build = await findBuild(appId, buildNumber);
  if (!build) {
    die(`Build ${buildNumber} not found in App Store Connect.`);
  }

  console.log(
    `Updating build ${build.attributes.version} What to Test (${locale}) from ${absPath}...`,
  );
  await upsertWhatToTest(build.id, whatsNew, locale);
  console.log("Done.");
}

async function resolveValidBuild(
  appId: string,
  buildNumber: string,
): Promise<any> {
  if (!buildNumber) die("A build number is required.");
  let build = await findBuild(appId, buildNumber);
  if (!build) {
    console.log(
      `Build ${buildNumber} is not visible in App Store Connect yet, waiting...`,
    );
    return await waitForBuild(appId, buildNumber);
  }
  if (build.attributes.processingState !== "VALID") {
    console.log(
      `Build ${buildNumber} is ${build.attributes.processingState}, waiting...`,
    );
    build = await waitForBuild(appId, buildNumber);
  }
  return build;
}

async function cmdSyncInternal(
  buildNumber: string,
  whatToTestFile?: string,
  locale = DEFAULT_WHAT_TO_TEST_LOCALE,
): Promise<void> {
  if (!buildNumber)
    die(
      "sync-internal requires a build number, e.g. sync-internal 44 [file] [locale]",
    );

  const appId = await findApp();
  const build = await resolveValidBuild(appId, buildNumber);
  const { absPath, whatsNew } = loadWhatToTestText(buildNumber, whatToTestFile);
  console.log(
    `Syncing build ${buildNumber} What to Test (${locale}) from ${absPath}...`,
  );
  await upsertWhatToTest(build.id, whatsNew, locale);

  const groupId = await findBetaGroup(appId, INTERNAL_GROUP);
  if (await betaGroupHasBuild(groupId, build.id)) {
    console.log(`Build ${buildNumber} is already in "${INTERNAL_GROUP}".`);
  } else {
    console.log(`Adding build ${buildNumber} to "${INTERNAL_GROUP}"...`);
    await addBuildToGroup(groupId, build.id);
  }
  console.log(
    `Build ${buildNumber} internal sync complete. No external groups or beta review were changed.`,
  );
}

async function cmdAddExternalGroups(
  buildNumber: string,
  groups: string[],
): Promise<void> {
  if (!buildNumber)
    die(
      "add-external-groups requires a build number and at least one explicit group.",
    );
  if (groups.length === 0)
    die("add-external-groups requires at least one explicit group name.");
  if (groups.includes(INTERNAL_GROUP))
    die(`Use sync-internal for "${INTERNAL_GROUP}".`);

  const appId = await findApp();
  const build = await resolveValidBuild(appId, buildNumber);
  for (const group of groups) {
    const groupId = await findBetaGroup(appId, group);
    if (await betaGroupHasBuild(groupId, build.id)) {
      console.log(`Build ${buildNumber} is already in "${group}".`);
      continue;
    }
    console.log(`Adding build ${buildNumber} to external group "${group}"...`);
    await addBuildToGroup(groupId, build.id);
  }
  console.log(
    `External group assignment complete. Beta review was not submitted.`,
  );
}

async function cmdSubmitBetaReview(buildNumber: string): Promise<void> {
  if (!buildNumber) die("submit-beta-review requires a build number.");
  const appId = await findApp();
  const build = await resolveValidBuild(appId, buildNumber);
  await submitForBetaReview(build.id);
}

async function cmdBuild(opts: {
  bump: boolean;
  buildOnly: boolean;
  explicitBuild: string;
}): Promise<void> {
  const { bump, buildOnly, explicitBuild } = opts;

  // Validate credentials for App Store Connect upload/export signing.
  const { issuerId: credentialIssuerId, keyPath: credentialKeyPath } = creds();
  if (!credentialIssuerId)
    die("ASC_ISSUER_ID not set and ~/.appstoreconnect/issuer_id not found");
  if (!fs.existsSync(credentialKeyPath))
    die(`API key not found at ${credentialKeyPath}`);

  // Step 1: Determine build number
  const currentBuild = readCurrentBuild();
  let newBuild: number;
  if (explicitBuild) {
    newBuild = parseInt(explicitBuild, 10);
    if (isNaN(newBuild)) die(`Invalid build number: ${explicitBuild}`);
  } else if (bump) {
    newBuild = currentBuild + 1;
  } else {
    die("Specify --bump or --build-number <N>");
    return; // unreachable but satisfies TS
  }

  const buildDir = path.join(APPLE_DIR, "build", `testflight-${timestamp()}`);
  const archivePath = path.join(buildDir, "Oppi.xcarchive");
  const exportPath = path.join(buildDir, "export");

  console.log("=== Oppi TestFlight Build ===");
  console.log(`Build number: ${currentBuild} -> ${newBuild}`);
  console.log(`Build dir:    ${buildDir}`);
  console.log();

  // Step 2: Update build number in project.yml
  if (newBuild !== currentBuild) {
    console.log(`--- Step 2: Bumping build number to ${newBuild} ---`);
    updateBuildNumber(currentBuild, newBuild);
    console.log("Done.");
  } else {
    console.log(`--- Step 2: Build number unchanged (${currentBuild}) ---`);
  }

  // Step 3: Generate Xcode project
  console.log("--- Step 3: Generating Xcode project ---");
  $.cwd(APPLE_DIR);
  await $`xcodegen generate`.quiet();
  console.log("Done.");

  // Step 4: Archive
  console.log("--- Step 4: Archiving Oppi (Release, iOS device) ---");
  fs.mkdirSync(buildDir, { recursive: true });

  await runXcodebuild(
    [
      "archive",
      "-project",
      "Oppi.xcodeproj",
      "-scheme",
      "Oppi",
      "-archivePath",
      archivePath,
      "-configuration",
      "Release",
      "-destination",
      "generic/platform=iOS",
      "-allowProvisioningUpdates",
      `CURRENT_PROJECT_VERSION=${newBuild}`,
    ],
    path.join(buildDir, "archive.log"),
    20,
  );

  if (!fs.existsSync(archivePath)) {
    die(`Archive failed — ${archivePath} not found.`);
  }
  console.log("Archive created.");

  // Step 5: Export / Upload
  if (buildOnly) {
    console.log("--- Step 5: Exporting IPA (build-only, no upload) ---");
    const localPlist = path.join(buildDir, "ExportOptions-local.plist");
    fs.writeFileSync(
      localPlist,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>`,
    );

    const { keyPath, keyId, issuerId } = creds();
    await runXcodebuild(
      [
        "-exportArchive",
        "-archivePath",
        archivePath,
        "-exportPath",
        exportPath,
        "-exportOptionsPlist",
        localPlist,
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        keyPath,
        "-authenticationKeyID",
        keyId,
        "-authenticationKeyIssuerID",
        issuerId,
      ],
      path.join(buildDir, "export.log"),
      10,
    );
    console.log(`IPA exported to: ${exportPath}/`);
  } else {
    console.log("--- Step 5: Exporting + uploading to App Store Connect ---");
    const { keyPath, keyId, issuerId } = creds();
    const exportPlist = path.join(APPLE_DIR, "ExportOptions-AppStore.plist");

    await runXcodebuild(
      [
        "-exportArchive",
        "-archivePath",
        archivePath,
        "-exportPath",
        exportPath,
        "-exportOptionsPlist",
        exportPlist,
        "-allowProvisioningUpdates",
        "-authenticationKeyPath",
        keyPath,
        "-authenticationKeyID",
        keyId,
        "-authenticationKeyIssuerID",
        issuerId,
      ],
      path.join(buildDir, "upload.log"),
      20,
    );
    console.log("Upload complete.");
  }

  // Summary
  console.log();
  console.log(`=== TestFlight build ${newBuild} complete ===`);
  console.log(`Archive:  ${archivePath}`);
  if (fs.existsSync(exportPath)) {
    console.log(`Export:   ${exportPath}/`);
  }
  if (!buildOnly) {
    console.log("Status:   Uploaded to App Store Connect");
    console.log();
    console.log(
      `Next: check TestFlight in App Store Connect for build ${newBuild}`,
    );
  }
}

// ── Usage tracking commands ──

type UsagePeriod = "P7D" | "P30D" | "P90D" | "P365D";

type UsagePeriodSummary = {
  sessions: number;
  active: number;
  totalTesters: number;
  crashes: number;
  feedback: number;
  sessionsFloor?: number;
  activeFloor?: number;
  note?: string;
};

type UsageEntry = {
  id: string;
  sessions: number;
  crashes: number;
  feedback: number;
  periodSessions?: Partial<Record<UsagePeriod, number>>;
};

type TesterDetails = {
  id: string;
  inviteType: string;
  email: string | null;
  firstName: string | null;
  lastName: string | null;
};

type UsageConcentration = {
  top1Sessions: number;
  top1Share: number;
  top2Sessions: number;
  top2Share: number;
  withoutTopSessions: number;
  withoutTopActive: number;
};

type UsageSnapshot = {
  date?: string;
  capturedAt?: string;
  scope?: "app";
  source?: string;
  note?: string;
  periods?: Partial<Record<UsagePeriod, UsagePeriodSummary>>;
  topTesters?: UsageEntry[];
  concentration?: Partial<Record<UsagePeriod, UsageConcentration>>;
};

const USAGE_PERIODS: UsagePeriod[] = ["P7D", "P30D", "P90D", "P365D"];

const testerDetailsCache = new Map<string, Promise<TesterDetails>>();

function usageNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function usageShare(part: number, total: number): number {
  return total > 0 ? (part / total) * 100 : 0;
}

function formatShare(value: number): string {
  return `${value.toFixed(1)}%`;
}

function concentrationFor(
  entries: UsageEntry[],
  totalSessions: number,
): UsageConcentration {
  const activeEntries = entries.filter((entry) => entry.sessions > 0);
  const top1Sessions = activeEntries[0]?.sessions ?? 0;
  const top2Sessions = activeEntries
    .slice(0, 2)
    .reduce((sum, entry) => sum + entry.sessions, 0);
  return {
    top1Sessions,
    top1Share: usageShare(top1Sessions, totalSessions),
    top2Sessions,
    top2Share: usageShare(top2Sessions, totalSessions),
    withoutTopSessions: Math.max(0, totalSessions - top1Sessions),
    withoutTopActive: activeEntries.length > 0 ? activeEntries.length - 1 : 0,
  };
}

function readUsageSnapshots(): UsageSnapshot[] {
  if (!fs.existsSync(USAGE_TRACKING_FILE)) return [];
  const raw = fs.readFileSync(USAGE_TRACKING_FILE, "utf-8").trim();
  if (!raw) return [];

  const snapshots: UsageSnapshot[] = [];
  for (const line of raw.split("\n")) {
    try {
      snapshots.push(JSON.parse(line));
    } catch {
      // Keep history best-effort; one bad manual edit should not hide all snapshots.
    }
  }
  return snapshots;
}

function snapshotLabel(snapshot: UsageSnapshot): string {
  if (snapshot.capturedAt) {
    return snapshot.capturedAt.slice(0, 16).replace("T", " ");
  }
  return snapshot.date || "unknown";
}

function snapshotConcentration(
  snapshot: UsageSnapshot,
  period: UsagePeriod,
): UsageConcentration {
  const stored = snapshot.concentration?.[period];
  if (stored) return stored;

  const summary = snapshot.periods?.[period];
  const topTesters = snapshot.topTesters ?? [];
  const top1Sessions = topTesters[0]?.sessions ?? 0;
  const top2Sessions = topTesters
    .slice(0, 2)
    .reduce((sum, entry) => sum + (entry.sessions ?? 0), 0);
  const totalSessions = summary?.sessions ?? 0;
  return {
    top1Sessions,
    top1Share: usageShare(top1Sessions, totalSessions),
    top2Sessions,
    top2Share: usageShare(top2Sessions, totalSessions),
    withoutTopSessions: Math.max(0, totalSessions - top1Sessions),
    withoutTopActive: Math.max(
      0,
      (summary?.active ?? 0) - (top1Sessions > 0 ? 1 : 0),
    ),
  };
}

async function getTesterDetails(testerId: string): Promise<TesterDetails> {
  let pending = testerDetailsCache.get(testerId);
  if (!pending) {
    pending = (async () => {
      const resp = await ascApi(`/v1/betaTesters/${testerId}`);
      const attr = resp.data?.attributes || {};
      return {
        id: testerId,
        inviteType: attr.inviteType || "UNKNOWN",
        email: attr.email || null,
        firstName: attr.firstName || null,
        lastName: attr.lastName || null,
      } as TesterDetails;
    })();
    testerDetailsCache.set(testerId, pending);
  }
  return pending;
}

async function getTesterDetailsSafe(testerId: string): Promise<TesterDetails> {
  try {
    return await getTesterDetails(testerId);
  } catch {
    return {
      id: testerId,
      inviteType: "UNKNOWN",
      email: null,
      firstName: null,
      lastName: null,
    };
  }
}

function formatTesterLabel(details: TesterDetails): string {
  const fullName = [details.firstName, details.lastName]
    .filter(Boolean)
    .join(" ")
    .trim();
  if (details.email) {
    return fullName ? `${fullName} <${details.email}>` : details.email;
  }
  return `${details.id.substring(0, 16)}...`;
}

async function getAppTesterUsageRaw(
  appId: string,
  period: UsagePeriod,
  limit = 200,
): Promise<any> {
  return await ascApi(
    `/v1/apps/${appId}/metrics/betaTesterUsages?groupBy=betaTesters&period=${period}&limit=${limit}`,
  );
}

function usageEntryFromMetric(entry: any): UsageEntry {
  let sessions = 0,
    crashes = 0,
    feedback = 0;
  for (const point of entry.dataPoints || []) {
    const values = point.values || {};
    sessions += usageNumber(values.sessionCount);
    crashes += usageNumber(values.crashCount);
    feedback += usageNumber(values.feedbackCount);
  }

  return {
    id: entry.dimensions?.betaTesters?.data?.id || "",
    sessions,
    crashes,
    feedback,
  };
}

function markP30DLowerBound(
  periods: Record<UsagePeriod, UsagePeriodSummary>,
): void {
  const p7 = periods.P7D;
  const p30 = periods.P30D;
  if (!p7 || !p30) return;

  if (p30.sessions === 0 && p7.sessions > 0) {
    p30.sessionsFloor = p7.sessions;
    p30.activeFloor = p7.active;
    p30.note = `Apple returned zero P30D sessions while P7D has ${p7.sessions}; showing P7D as the lower bound.`;
  }
}

async function fetchUsageEntries(
  appId: string,
  period: UsagePeriod,
): Promise<UsageEntry[]> {
  const resp = await getAppTesterUsageRaw(appId, period, 200);
  const entries = (resp.data || []).map(usageEntryFromMetric);
  entries.sort((a: UsageEntry, b: UsageEntry) => b.sessions - a.sessions);
  return entries;
}

async function fetchUsageSummary(appId: string): Promise<{
  periods: Record<UsagePeriod, UsagePeriodSummary>;
  entriesByPeriod: Record<UsagePeriod, UsageEntry[]>;
  concentration: Record<UsagePeriod, UsageConcentration>;
  topTesters: UsageEntry[];
}> {
  const periods = {} as Record<UsagePeriod, UsagePeriodSummary>;
  const entriesByPeriod = {} as Record<UsagePeriod, UsageEntry[]>;
  const concentration = {} as Record<UsagePeriod, UsageConcentration>;

  for (const period of USAGE_PERIODS) {
    const entries = await fetchUsageEntries(appId, period);
    const sessions = entries.reduce((sum, entry) => sum + entry.sessions, 0);
    const crashes = entries.reduce((sum, entry) => sum + entry.crashes, 0);
    const feedback = entries.reduce((sum, entry) => sum + entry.feedback, 0);
    const active = entries.filter((entry) => entry.sessions > 0).length;

    periods[period] = {
      sessions,
      active,
      totalTesters: entries.length,
      crashes,
      feedback,
    };
    entriesByPeriod[period] = entries;
    concentration[period] = concentrationFor(entries, sessions);
  }
  markP30DLowerBound(periods);

  const p30TopTesters = entriesByPeriod.P30D.filter(
    (entry) => entry.sessions > 0,
  );
  const fallbackTopTesters =
    p30TopTesters.length > 0
      ? p30TopTesters
      : entriesByPeriod.P7D.filter((entry) => entry.sessions > 0);

  return {
    periods,
    entriesByPeriod,
    concentration,
    topTesters: fallbackTopTesters.slice(0, 15),
  };
}

function formatPeriodRow(label: UsagePeriod, data: UsagePeriodSummary): string {
  const sessions =
    data.sessionsFloor !== undefined
      ? `>=${data.sessionsFloor}`
      : String(data.sessions);
  const active =
    data.activeFloor !== undefined
      ? `>=${data.activeFloor}/${data.totalTesters}`
      : `${data.active}/${data.totalTesters}`;
  const parts = [label.padEnd(6), sessions.padStart(8), active.padStart(10)];
  if (data.crashes) parts.push(String(data.crashes).padStart(4) + " crash");
  if (data.feedback) parts.push(String(data.feedback).padStart(4) + " fb");
  if (data.note) parts.push("*");
  return parts.join("  ");
}

async function cmdUsage(save: boolean): Promise<void> {
  const appId = await findApp();
  const now = new Date();
  const today = now.toISOString().slice(0, 10);
  const { periods, entriesByPeriod, concentration, topTesters } =
    await fetchUsageSummary(appId);

  console.log(`TestFlight App Usage — ${today}`);
  console.log(
    "Source: /v1/apps/{appId}/metrics/betaTesterUsages grouped by beta tester.",
  );
  console.log(
    "Scope: exact app-level TestFlight activity by period; not build-specific; excludes local dev/Xcode installs.",
  );
  console.log();
  console.log("Period  Sessions  Active     Extras");
  console.log("------  --------  --------   ------");
  for (const p of USAGE_PERIODS) {
    console.log(formatPeriodRow(p, periods[p]));
  }

  const notedPeriods = USAGE_PERIODS.filter((period) => periods[period].note);
  if (notedPeriods.length > 0) {
    console.log();
    for (const period of notedPeriods) {
      console.log(`* ${period}: ${periods[period].note}`);
    }
  }

  console.log();
  console.log(
    "Next: run `bun scripts/release/apple/testflight.ts usage-testers P7D` for exact per-tester counts.",
  );

  if (save) {
    const existingSnapshots = readUsageSnapshots();
    const sameDayCount = existingSnapshots.filter(
      (snapshot) => snapshot.date === today,
    ).length;
    const snapshot: UsageSnapshot = {
      date: today,
      capturedAt: now.toISOString(),
      scope: "app",
      source:
        "/v1/apps/{appId}/metrics/betaTesterUsages?groupBy=betaTesters&period=...",
      note: "App-level TestFlight usage. Not build-specific. Excludes local dev/Xcode installs.",
      periods,
      concentration,
      topTesters: topTesters.slice(0, 5),
    };
    const dir = path.dirname(USAGE_TRACKING_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(
      USAGE_TRACKING_FILE,
      JSON.stringify(snapshot) + "\n",
      "utf-8",
    );
    console.log(`\nSaved snapshot to ${USAGE_TRACKING_FILE}`);
    if (sameDayCount > 0) {
      console.log(
        `Note: ${sameDayCount + 1} snapshots now recorded for ${today}.`,
      );
    }
  }
}

async function cmdUsageTesters(
  period: UsagePeriod,
  excludeTop: boolean,
): Promise<void> {
  const appId = await findApp();
  let entries = await fetchUsageEntries(appId, period);
  let displayPeriod = period;
  let lowerBoundNote = "";

  if (period === "P30D" && entries.every((entry) => entry.sessions === 0)) {
    const p7Entries = await fetchUsageEntries(appId, "P7D");
    const p7Total = p7Entries.reduce((sum, entry) => sum + entry.sessions, 0);
    if (p7Total > 0) {
      entries = p7Entries;
      displayPeriod = "P7D";
      lowerBoundNote = `Apple returned zero P30D sessions; showing P7D as a lower bound for the requested P30D window.`;
    }
  }

  let display = entries;
  if (excludeTop && entries.length > 0) {
    display = entries.slice(1);
  }

  const total = display.reduce((s, e) => s + e.sessions, 0);
  const active = display.filter((e) => e.sessions > 0).length;
  const activeWithDetails = await Promise.all(
    display
      .filter((e) => e.sessions > 0)
      .map(async (entry) => {
        const details = await getTesterDetailsSafe(entry.id);
        return {
          ...entry,
          inviteType: details.inviteType,
          email: details.email,
          firstName: details.firstName,
          lastName: details.lastName,
          anonymous: !details.email,
          displayName: formatTesterLabel(details),
        };
      }),
  );

  console.log(`TestFlight app testers — ${period}`);
  console.log(
    "Source: /v1/apps/{appId}/metrics/betaTesterUsages grouped by beta tester.",
  );
  console.log(
    "Scope: exact app-level per-tester counts for this period; not build-specific.",
  );
  if (lowerBoundNote) {
    console.log(`Note: ${lowerBoundNote}`);
  }
  const totalLabel = lowerBoundNote ? `>=${total}` : String(total);
  const activeLabel = lowerBoundNote
    ? `>=${active}/${display.length}`
    : `${active}/${display.length}`;
  console.log(
    `Total: ${totalLabel} sessions, ${activeLabel} active${displayPeriod !== period ? ` (${displayPeriod} data)` : ""}`,
  );
  if (excludeTop && entries.length > 0) {
    console.log(`(excluding top tester: ${entries[0].sessions} sessions)`);
  } else if (excludeTop) {
    console.log("(no testers to exclude)");
  }
  console.log();
  for (const e of activeWithDetails) {
    let extra = "";
    if (e.crashes) extra += `  crash:${e.crashes}`;
    if (e.feedback) extra += `  fb:${e.feedback}`;
    const invite = String(e.inviteType || "UNKNOWN").padEnd(12);
    console.log(
      `  ${String(e.sessions).padStart(5)}  ${invite} ${e.displayName}${extra}`,
    );
  }
  const inactive = display.filter((e) => e.sessions === 0).length;
  if (inactive > 0) {
    console.log(`  ... and ${inactive} testers with 0 sessions`);
  }
}

async function cmdUsageTestersRaw(
  periodArg?: string,
  limitArg?: string,
): Promise<void> {
  const requestedPeriod = periodArg as UsagePeriod | undefined;
  const period =
    requestedPeriod && USAGE_PERIODS.includes(requestedPeriod)
      ? requestedPeriod
      : "P7D";
  const limit = limitArg ? parseInt(limitArg, 10) : 20;
  if (isNaN(limit) || limit < 1 || limit > 200) {
    die("usage-testers-raw limit must be between 1 and 200");
  }

  const appId = await findApp();
  const raw = await getAppTesterUsageRaw(appId, period, limit);
  console.log(
    JSON.stringify(
      {
        appId,
        period,
        endpoint: `/v1/apps/${appId}/metrics/betaTesterUsages?period=${period}&groupBy=betaTesters&limit=${limit}`,
        raw,
      },
      null,
      2,
    ),
  );
}

async function cmdUsageHistory(limit: number): Promise<void> {
  const snapshots = readUsageSnapshots();
  if (snapshots.length === 0) {
    console.log(
      `No tracking data yet. Run \`bun testflight.ts usage --save\` to start.`,
    );
    return;
  }

  if (limit > 0) {
    snapshots.splice(0, Math.max(0, snapshots.length - limit));
  }

  console.log(
    "Captured          P7D       P30D      P90D      P365D     Active30   Top1",
  );
  console.log(
    "----------------  --------  --------  --------  --------  --------   ------",
  );

  let prev: UsageSnapshot | null = null;
  for (const s of snapshots) {
    const p7 = s.periods?.P7D;
    const p30 = s.periods?.P30D;
    const p90 = s.periods?.P90D;
    const p365 = s.periods?.P365D;
    const c30 = snapshotConcentration(s, "P30D");

    let line = [
      snapshotLabel(s).padEnd(16),
      String(p7?.sessions || 0).padStart(8),
      String(p30?.sessions || 0).padStart(8),
      String(p90?.sessions || 0).padStart(8),
      String(p365?.sessions || 0).padStart(8),
      `${p30?.active ?? 0}/${p30?.totalTesters ?? 0}`.padStart(8),
      formatShare(c30.top1Share).padStart(6),
    ].join("  ");

    if (prev) {
      const prevP30 = prev.periods?.P30D?.sessions || 0;
      const delta30 = (p30?.sessions || 0) - prevP30;
      line += `  (P30D Δ ${delta30 >= 0 ? "+" : ""}${delta30})`;
    }
    console.log(line);
    prev = s;
  }
}

// ── Help ──

function printHelp(): void {
  console.log(`testflight.ts — Archive and upload Oppi builds with explicit TestFlight distribution steps.

Build commands:
  bun testflight.ts --bump                            Bump build number, archive, upload
  bun testflight.ts --build-number 44                 Explicit build number, archive, upload
  bun testflight.ts --build-number 44 --build-only    Archive + export IPA only (no upload)

Distribution commands:
  bun testflight.ts sync-internal <build> [file] [locale]        Sync brief What to Test + Internal Testers only
  bun testflight.ts add-external-groups <build> "Group" [...]    Add explicit external groups; does not submit review
  bun testflight.ts submit-beta-review <build>                   Submit external beta review explicitly

Read/update commands:
  bun testflight.ts list-builds                                             List recent builds from ASC
  bun testflight.ts build-usage [build]                                     Exact build aggregate from ASC (latest if omitted)
  bun testflight.ts build-usage-raw [build]                                 Raw JSON from /v1/builds/{id}/metrics/betaBuildUsages
  bun testflight.ts show-what-to-test [build] [locale]                      Show current What to Test text
  bun testflight.ts set-what-to-test <build> [file] [locale]                Update What to Test from a file

Usage tracking:
  bun testflight.ts usage [--save]                    Exact app-level TestFlight usage summary across all periods
  bun testflight.ts usage-testers [period] [--no-top] Exact app-level per-tester counts (default P7D, --no-top excludes top)
  bun testflight.ts usage-testers-raw [period] [limit] Raw JSON from /v1/apps/{id}/metrics/betaTesterUsages
  bun testflight.ts usage-history [limit]             Show saved app-wide snapshots with session deltas

Options:
  --help, -h                                                    Show this help`);
}

// ── Main ──

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    printHelp();
    process.exit(args.length === 0 ? 1 : 0);
  }

  // Standalone commands
  if (args[0] === "list-builds") {
    await cmdListBuilds();
    return;
  }

  if (args[0] === "build-usage") {
    await cmdBuildUsage(args[1]);
    return;
  }

  if (args[0] === "build-usage-raw") {
    await cmdBuildUsageRaw(args[1]);
    return;
  }

  if (args[0] === "sync-internal") {
    await cmdSyncInternal(
      args[1],
      args[2],
      args[3] || DEFAULT_WHAT_TO_TEST_LOCALE,
    );
    return;
  }

  if (args[0] === "add-external-groups") {
    await cmdAddExternalGroups(args[1], args.slice(2));
    return;
  }

  if (args[0] === "submit-beta-review") {
    await cmdSubmitBetaReview(args[1]);
    return;
  }

  if (["sync-followup", "submit-external"].includes(args[0])) {
    die(
      `${args[0]} was removed. Use sync-internal, add-external-groups, and submit-beta-review as separate actions.`,
    );
  }

  if (args[0] === "show-what-to-test") {
    await cmdShowWhatToTest(args[1], args[2] || DEFAULT_WHAT_TO_TEST_LOCALE);
    return;
  }

  if (args[0] === "set-what-to-test") {
    await cmdSetWhatToTest(
      args[1],
      args[2],
      args[3] || DEFAULT_WHAT_TO_TEST_LOCALE,
    );
    return;
  }

  if (args[0] === "usage") {
    const save = args.includes("--save");
    await cmdUsage(save);
    return;
  }

  if (args[0] === "usage-testers") {
    const requestedPeriod = args[1] as UsagePeriod | undefined;
    const period =
      requestedPeriod && USAGE_PERIODS.includes(requestedPeriod)
        ? requestedPeriod
        : "P7D";
    const excludeTop = args.includes("--no-top");
    await cmdUsageTesters(period, excludeTop);
    return;
  }

  if (args[0] === "usage-testers-raw") {
    await cmdUsageTestersRaw(args[1], args[2]);
    return;
  }

  if (args[0] === "usage-history") {
    const limit = parseInt(args[1], 10) || 0;
    await cmdUsageHistory(limit);
    return;
  }

  // Build flow: parse flags
  let bump = false;
  let buildOnly = false;
  let explicitBuild = "";

  let i = 0;
  while (i < args.length) {
    switch (args[i]) {
      case "--bump":
        bump = true;
        i++;
        break;
      case "--build-only":
        buildOnly = true;
        i++;
        break;
      case "--build-number":
        explicitBuild = args[i + 1] || die("--build-number requires a value");
        i += 2;
        break;
      case "--submit-external":
        die(
          "--submit-external was removed. Upload first, then use explicit distribution commands.",
        );
        break;
      default:
        die(`Unknown option: ${args[i]}`);
    }
  }

  if (!bump && !explicitBuild) {
    die("Specify --bump or --build-number <N>");
  }

  await cmdBuild({
    bump,
    buildOnly,
    explicitBuild,
  });
}

if (import.meta.main) {
  main().catch((err) => {
    console.error(err.message || err);
    process.exit(1);
  });
}
