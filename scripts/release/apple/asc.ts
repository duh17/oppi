#!/usr/bin/env bun
/**
 * asc.ts — Read-only App Store Connect CLI helpers for TestFlight analytics.
 *
 * Read-only guarantee: this script only performs GET requests.
 *
 * Usage examples:
 *   bun scripts/release/apple/asc.ts build-usage 27
 *   bun scripts/release/apple/asc.ts usage-builds 5
 *   bun scripts/release/apple/asc.ts build-access 25
 *   bun scripts/release/apple/asc.ts build-usage-raw 25
 *   bun scripts/release/apple/asc.ts app-tester-usage-raw P7D 20
 *
 * Auth sources (same as testflight.ts):
 *   ASC_KEY_ID / ~/.appstoreconnect/key_id
 *   ASC_ISSUER_ID / ~/.appstoreconnect/issuer_id
 *   ASC_KEY_PATH / ~/.appstoreconnect/AuthKey_<KEY_ID>.p8
 */

import * as crypto from "crypto";
import * as fs from "fs";

const ASC_BASE_URL = "https://api.appstoreconnect.apple.com";
const DEFAULT_BUNDLE_ID = process.env.ASC_BUNDLE_ID || "dev.chenda.Oppi";

type Dict<T = string | boolean> = Record<string, T>;

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

type BuildAccessGroup = {
  id: string;
  name: string;
  testerCount: number | null;
};

let _creds: {
  keyId: string;
  issuerId: string;
  privateKey: string;
  keyPath: string;
} | null = null;

let _jwtCache: { token: string; exp: number } | null = null;

function readFileOr(path: string, fallback = ""): string {
  try {
    return fs.readFileSync(path, "utf-8");
  } catch {
    return fallback;
  }
}

function die(message: string): never {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function parseArgs(args: string[]): { positionals: string[]; options: Dict } {
  const positionals: string[] = [];
  const options: Dict = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith("--")) {
      positionals.push(arg);
      continue;
    }

    const raw = arg.slice(2);
    const eq = raw.indexOf("=");

    if (eq !== -1) {
      const key = raw.slice(0, eq);
      const value = raw.slice(eq + 1);
      options[key] = value;
      continue;
    }

    const next = args[i + 1];
    if (next && !next.startsWith("--")) {
      options[raw] = next;
      i++;
    } else {
      options[raw] = true;
    }
  }

  return { positionals, options };
}

function optString(options: Dict, key: string, fallback = ""): string {
  const value = options[key];
  if (typeof value === "string") return value;
  return fallback;
}

function optBool(options: Dict, key: string): boolean {
  return options[key] === true;
}

function loadCredentials(): {
  keyId: string;
  issuerId: string;
  privateKey: string;
  keyPath: string;
} {
  if (_creds) return _creds;

  const home = process.env.HOME;
  if (!home) die("HOME environment variable is not set.");

  const keyId = (
    process.env.ASC_KEY_ID || readFileOr(`${home}/.appstoreconnect/key_id`)
  ).trim();
  const issuerId = (
    process.env.ASC_ISSUER_ID ||
    readFileOr(`${home}/.appstoreconnect/issuer_id`)
  ).trim();

  if (!keyId) {
    die("Missing ASC key ID (set ASC_KEY_ID or ~/.appstoreconnect/key_id).");
  }
  if (!issuerId) {
    die(
      "Missing ASC issuer ID (set ASC_ISSUER_ID or ~/.appstoreconnect/issuer_id).",
    );
  }

  const keyPath =
    process.env.ASC_KEY_PATH || `${home}/.appstoreconnect/AuthKey_${keyId}.p8`;
  if (!fs.existsSync(keyPath)) {
    die(`ASC private key not found: ${keyPath}`);
  }

  const privateKey = fs.readFileSync(keyPath, "utf-8");
  _creds = { keyId, issuerId, privateKey, keyPath };
  return _creds;
}

function makeJWT(): { token: string; exp: number } {
  const { keyId, issuerId, privateKey } = loadCredentials();

  const now = Math.floor(Date.now() / 1000);
  const exp = now + 1200;

  const header = Buffer.from(
    JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }),
  ).toString("base64url");

  const payload = Buffer.from(
    JSON.stringify({ iss: issuerId, iat: now, exp, aud: "appstoreconnect-v1" }),
  ).toString("base64url");

  const sig = crypto.sign("sha256", Buffer.from(`${header}.${payload}`), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });

  return { token: `${header}.${payload}.${sig.toString("base64url")}`, exp };
}

function getJWT(): string {
  const now = Math.floor(Date.now() / 1000);
  if (_jwtCache && _jwtCache.exp - 60 > now) {
    return _jwtCache.token;
  }

  _jwtCache = makeJWT();
  return _jwtCache.token;
}

async function ascGet(pathOrUrl: string): Promise<any> {
  const url =
    pathOrUrl.startsWith("http://") || pathOrUrl.startsWith("https://")
      ? pathOrUrl
      : `${ASC_BASE_URL}${pathOrUrl}`;

  const res = await fetch(url, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${getJWT()}`,
      "Content-Type": "application/json",
    },
  });

  const json = await res.json();
  if (!res.ok) {
    throw new Error(`ASC API ${res.status}: ${JSON.stringify(json)}`);
  }

  return json;
}

async function ascGetAll(path: string): Promise<any[]> {
  const out: any[] = [];
  let next: string | null = path;

  while (next) {
    const json = await ascGet(next);
    if (Array.isArray(json.data)) {
      out.push(...json.data);
    }
    next = json.links?.next || null;
  }

  return out;
}

async function findApp(bundleId: string): Promise<any> {
  const json = await ascGet(
    `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}`,
  );
  const app = json.data?.[0];
  if (!app) {
    die(`App not found for bundle ID: ${bundleId}`);
  }
  return app;
}

async function listBuilds(appId: string, limit = 10): Promise<any[]> {
  const safe = Math.max(1, Math.min(limit, 200));
  const json = await ascGet(
    `/v1/builds?filter[app]=${appId}&sort=-uploadedDate&limit=${safe}` +
      `&fields[builds]=version,processingState,uploadedDate,expirationDate,minOsVersion,buildAudienceType`,
  );
  return json.data || [];
}

async function findBuildByVersion(
  appId: string,
  buildVersion: string,
): Promise<any | null> {
  const json = await ascGet(
    `/v1/builds?filter[app]=${appId}&filter[version]=${encodeURIComponent(buildVersion)}`,
  );
  return json.data?.[0] || null;
}

function extractLatestBuildUsagePoint(
  metricData: any[],
): BuildUsagePoint | null {
  const points: BuildUsagePoint[] = [];
  for (const metric of metricData || []) {
    for (const p of metric.dataPoints || []) points.push(p);
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
  return await ascGet(`/v1/builds/${buildId}/metrics/betaBuildUsages`);
}

async function getBuildUsagePoint(
  buildId: string,
): Promise<BuildUsagePoint | null> {
  const json = await getBuildUsageRaw(buildId);
  const metricData = json.data || [];
  return extractLatestBuildUsagePoint(metricData);
}

async function getAppTesterUsageRaw(
  appId: string,
  period: string,
  limit = 200,
): Promise<any> {
  const safePeriod = ["P7D", "P30D", "P90D", "P365D"].includes(period)
    ? period
    : "P365D";
  const safeLimit = Math.max(1, Math.min(limit, 200));
  return await ascGet(
    `/v1/apps/${appId}/metrics/betaTesterUsages?period=${safePeriod}&groupBy=betaTesters&limit=${safeLimit}`,
  );
}

async function listAppGroups(appId: string): Promise<any[]> {
  return await ascGetAll(`/v1/apps/${appId}/betaGroups?limit=200`);
}

async function groupContainsBuild(
  groupId: string,
  buildId: string,
): Promise<boolean> {
  const builds = await ascGetAll(
    `/v1/betaGroups/${groupId}/builds?limit=200&fields[builds]=version`,
  );
  return builds.some((b: any) => b.id === buildId);
}

async function listGroupTesterIds(groupId: string): Promise<Set<string>> {
  const testers = await ascGetAll(
    `/v1/betaGroups/${groupId}/betaTesters?limit=200`,
  );
  return new Set(testers.map((t: any) => t.id).filter(Boolean));
}

async function listBuildIndividualTesterIds(
  buildId: string,
): Promise<Set<string>> {
  const testers = await ascGetAll(
    `/v1/builds/${buildId}/individualTesters?limit=200`,
  );
  return new Set(testers.map((t: any) => t.id).filter(Boolean));
}

function fmtDate(s?: string): string {
  return (s || "—").slice(0, 10);
}

function fmtDateTime(s?: string): string {
  return s ? s.slice(0, 19) : "—";
}

function printHelp(): void {
  console.log(`asc.ts — Read-only App Store Connect client for TestFlight analytics.

Usage:
  bun scripts/release/apple/asc.ts <command> [args] [--bundle-id <id>] [--json]

Commands:
  builds [limit]
      List recent builds for the app.

  build-usage [build]
  usage-build [build]
      Show concrete beta build usage metrics for one build (latest if omitted).

  usage-builds [limit]
  build-usage-recent [limit]
      Show concrete beta build usage metrics for recent builds.

  build-access <build>
      Show concrete build facts: build usage counts plus the exact tester access pool
      from group assignment and individual tester assignment.

  build-usage-raw [build]
      Print the raw ASC JSON from /v1/builds/{id}/metrics/betaBuildUsages.

  app-tester-usage-raw [period] [limit]
      Print the raw ASC JSON from /v1/apps/{id}/metrics/betaTesterUsages.
      This is app-level tester usage, not build-specific.

Options:
  --bundle-id <id>   App bundle id (default: ${DEFAULT_BUNDLE_ID})
  --json             Print JSON output
  --help, -h         Show this help
`);
}

async function cmdBuilds(
  bundleId: string,
  limitArg: string,
  jsonOut: boolean,
): Promise<void> {
  const limit = limitArg ? parseInt(limitArg, 10) : 10;
  if (isNaN(limit) || limit < 1 || limit > 200) {
    die("builds limit must be between 1 and 200");
  }

  const app = await findApp(bundleId);
  const builds = await listBuilds(app.id, limit);

  if (jsonOut) {
    console.log(JSON.stringify({ appId: app.id, bundleId, builds }, null, 2));
    return;
  }

  if (builds.length === 0) {
    console.log("No builds found.");
    return;
  }

  console.log(`Recent builds for ${bundleId}:`);
  console.log("  BUILD    STATE              UPLOADED             EXPIRES");
  console.log("  -----    -----              --------             -------");
  for (const b of builds) {
    const version = String(b.attributes?.version || "—").padEnd(8);
    const state = String(b.attributes?.processingState || "—").padEnd(18);
    const uploaded = fmtDateTime(b.attributes?.uploadedDate).padEnd(19);
    const expires = fmtDateTime(b.attributes?.expirationDate);
    console.log(`  ${version} ${state} ${uploaded} ${expires}`);
  }
}

async function resolveBuild(appId: string, buildArg?: string): Promise<any> {
  if (buildArg) {
    const build = await findBuildByVersion(appId, buildArg);
    if (!build) die(`Build ${buildArg} not found.`);
    return build;
  }

  const builds = await listBuilds(appId, 1);
  if (builds.length === 0) die("No builds found.");
  return builds[0];
}

async function cmdBuildUsage(
  bundleId: string,
  buildArg: string,
  jsonOut: boolean,
): Promise<void> {
  const app = await findApp(bundleId);
  const build = await resolveBuild(app.id, buildArg || undefined);
  const point = await getBuildUsagePoint(build.id);

  const result = {
    bundleId,
    appId: app.id,
    buildId: build.id,
    buildVersion: build.attributes?.version,
    processingState: build.attributes?.processingState,
    uploadedDate: build.attributes?.uploadedDate,
    usage: {
      start: point?.start,
      end: point?.end,
      installCount: point?.values?.installCount ?? 0,
      inviteCount: point?.values?.inviteCount ?? 0,
      sessionCount: point?.values?.sessionCount ?? 0,
      crashCount: point?.values?.crashCount ?? 0,
      feedbackCount: point?.values?.feedbackCount ?? 0,
    },
  };

  if (jsonOut) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  console.log(`Build ${result.buildVersion}`);
  console.log(`  State:      ${result.processingState || "—"}`);
  console.log(`  Uploaded:   ${fmtDateTime(result.uploadedDate)}`);
  console.log(
    `  ASC range:  ${fmtDate(result.usage.start)} → ${fmtDate(result.usage.end)}`,
  );
  console.log(
    "  Note:       exact build aggregate from Apple; this endpoint has no period filter and no per-tester breakdown.",
  );
  console.log(`  Installs:   ${result.usage.installCount}`);
  console.log(`  Invites:    ${result.usage.inviteCount}`);
  console.log(`  Sessions:   ${result.usage.sessionCount}`);
  console.log(`  Crashes:    ${result.usage.crashCount}`);
  console.log(`  Feedback:   ${result.usage.feedbackCount}`);
}

async function cmdBuildUsageRecent(
  bundleId: string,
  limitArg: string,
  jsonOut: boolean,
): Promise<void> {
  const limit = limitArg ? parseInt(limitArg, 10) : 10;
  if (isNaN(limit) || limit < 1 || limit > 50) {
    die("usage-builds limit must be between 1 and 50");
  }

  const app = await findApp(bundleId);
  const builds = await listBuilds(app.id, limit);

  const rows: Array<{
    buildVersion: string;
    processingState: string;
    uploadedDate: string;
    start: string;
    end: string;
    installCount: number;
    inviteCount: number;
    sessionCount: number;
    crashCount: number;
    feedbackCount: number;
  }> = [];

  for (const build of builds) {
    const point = await getBuildUsagePoint(build.id);
    rows.push({
      buildVersion: build.attributes?.version || "—",
      processingState: build.attributes?.processingState || "—",
      uploadedDate: build.attributes?.uploadedDate || "",
      start: point?.start || "",
      end: point?.end || "",
      installCount: point?.values?.installCount ?? 0,
      inviteCount: point?.values?.inviteCount ?? 0,
      sessionCount: point?.values?.sessionCount ?? 0,
      crashCount: point?.values?.crashCount ?? 0,
      feedbackCount: point?.values?.feedbackCount ?? 0,
    });
  }

  if (jsonOut) {
    console.log(JSON.stringify({ bundleId, appId: app.id, rows }, null, 2));
    return;
  }

  if (rows.length === 0) {
    console.log("No builds found.");
    return;
  }

  console.log(`Recent builds with usage metrics (latest ${rows.length}):`);
  console.log(
    "  Note: exact build aggregates from Apple; RANGE is Apple-reported and this endpoint has no period filter.",
  );
  console.log(
    "  BUILD    STATE              INST  INV   SESS  CRASH FEEDB  RANGE ",
  );
  console.log(
    "  -----    -----              ----  ---   ----  ----- -----  ------",
  );

  for (const row of rows) {
    const build = String(row.buildVersion).padEnd(8);
    const state = String(row.processingState).padEnd(18);
    const installs = String(row.installCount).padStart(4);
    const invites = String(row.inviteCount).padStart(3);
    const sessions = String(row.sessionCount).padStart(5);
    const crashes = String(row.crashCount).padStart(5);
    const feedback = String(row.feedbackCount).padStart(5);
    const window =
      row.start || row.end
        ? `${fmtDate(row.start).slice(5, 10)}→${fmtDate(row.end).slice(5, 10)}`
        : "—";

    console.log(
      `  ${build} ${state} ${installs}  ${invites}  ${sessions}  ${crashes} ${feedback}  ${window}`,
    );
  }
}

async function collectBuildAccess(
  appId: string,
  buildId: string,
): Promise<{
  groupsContainingBuild: BuildAccessGroup[];
  testerIds: string[];
  individualTesterIds: string[];
  testerPoolSize: number;
}> {
  const appGroups = await listAppGroups(appId);
  const groupsContainingBuild: BuildAccessGroup[] = [];
  const testerIds = new Set<string>();

  for (const group of appGroups) {
    try {
      const hasBuild = await groupContainsBuild(group.id, buildId);
      if (!hasBuild) continue;

      let testerCount: number | null = null;
      try {
        const ids = await listGroupTesterIds(group.id);
        testerCount = ids.size;
        for (const id of ids) testerIds.add(id);
      } catch (err: any) {
        console.warn(
          `Warning: could not list testers for group ${group.id}: ${err?.message || err}`,
        );
      }

      groupsContainingBuild.push({
        id: group.id,
        name: group.attributes?.name || group.id,
        testerCount,
      });
    } catch (err: any) {
      console.warn(
        `Warning: could not inspect group ${group.id}: ${err?.message || err}`,
      );
    }
  }

  const individualIds = await listBuildIndividualTesterIds(buildId);
  for (const id of individualIds) testerIds.add(id);

  return {
    groupsContainingBuild,
    testerIds: Array.from(testerIds).sort(),
    individualTesterIds: Array.from(individualIds).sort(),
    testerPoolSize: testerIds.size,
  };
}

async function cmdBuildAccess(
  bundleId: string,
  buildVersion: string,
  jsonOut: boolean,
): Promise<void> {
  if (!buildVersion)
    die("build-access requires a build number, e.g. build-access 25");

  const app = await findApp(bundleId);
  const build = await resolveBuild(app.id, buildVersion);
  const buildUsage = await getBuildUsagePoint(build.id);
  const access = await collectBuildAccess(app.id, build.id);

  const payload = {
    bundleId,
    appId: app.id,
    buildId: build.id,
    buildVersion: build.attributes?.version,
    processingState: build.attributes?.processingState,
    uploadedDate: build.attributes?.uploadedDate,
    source: {
      buildUsage: `/v1/builds/${build.id}/metrics/betaBuildUsages`,
      buildGroups: `/v1/apps/${app.id}/betaGroups`,
      groupTesters: "/v1/betaGroups/{id}/betaTesters",
      individualTesters: `/v1/builds/${build.id}/individualTesters`,
    },
    buildUsage: {
      start: buildUsage?.start || null,
      end: buildUsage?.end || null,
      installCount: buildUsage?.values?.installCount ?? 0,
      inviteCount: buildUsage?.values?.inviteCount ?? 0,
      sessionCount: buildUsage?.values?.sessionCount ?? 0,
      crashCount: buildUsage?.values?.crashCount ?? 0,
      feedbackCount: buildUsage?.values?.feedbackCount ?? 0,
    },
    groupsContainingBuild: access.groupsContainingBuild,
    individualTesterCount: access.individualTesterIds.length,
    testerPoolSize: access.testerPoolSize,
    individualTesterIds: access.individualTesterIds,
    testerIds: access.testerIds,
  };

  if (jsonOut) {
    console.log(JSON.stringify(payload, null, 2));
    return;
  }

  console.log(`Build ${payload.buildVersion} access`);
  console.log(`  State:      ${payload.processingState || "—"}`);
  console.log(`  Uploaded:   ${fmtDateTime(payload.uploadedDate)}`);
  console.log(
    `  ASC range:  ${fmtDate(payload.buildUsage.start || undefined)} → ${fmtDate(payload.buildUsage.end || undefined)}`,
  );
  console.log(
    "  Note:       build usage is exact aggregate data from Apple; tester access is exact access pool, not who actually generated those sessions.",
  );
  console.log(`  Installs:   ${payload.buildUsage.installCount}`);
  console.log(`  Invites:    ${payload.buildUsage.inviteCount}`);
  console.log(`  Sessions:   ${payload.buildUsage.sessionCount}`);
  console.log(`  Crashes:    ${payload.buildUsage.crashCount}`);
  console.log(`  Feedback:   ${payload.buildUsage.feedbackCount}`);
  console.log(`  Groups:     ${payload.groupsContainingBuild.length}`);
  for (const group of payload.groupsContainingBuild) {
    const count = group.testerCount === null ? "?" : String(group.testerCount);
    console.log(`    - ${group.name} (${count} testers)`);
  }
  console.log(
    `  Tester pool: ${payload.testerPoolSize} unique testers with access`,
  );
  console.log(
    `  Individual:  ${payload.individualTesterCount} testers assigned directly`,
  );
}

async function cmdBuildUsageRaw(
  bundleId: string,
  buildArg: string,
): Promise<void> {
  const app = await findApp(bundleId);
  const build = await resolveBuild(app.id, buildArg || undefined);
  const raw = await getBuildUsageRaw(build.id);
  console.log(
    JSON.stringify(
      {
        bundleId,
        appId: app.id,
        buildId: build.id,
        buildVersion: build.attributes?.version,
        processingState: build.attributes?.processingState,
        uploadedDate: build.attributes?.uploadedDate,
        endpoint: `/v1/builds/${build.id}/metrics/betaBuildUsages`,
        raw,
      },
      null,
      2,
    ),
  );
}

async function cmdAppTesterUsageRaw(
  bundleId: string,
  periodArg: string,
  limitArg: string,
): Promise<void> {
  const period = ["P7D", "P30D", "P90D", "P365D"].includes(periodArg)
    ? periodArg
    : "P7D";
  const limit = limitArg ? parseInt(limitArg, 10) : 20;
  if (isNaN(limit) || limit < 1 || limit > 200) {
    die("app-tester-usage-raw limit must be between 1 and 200");
  }

  const app = await findApp(bundleId);
  const raw = await getAppTesterUsageRaw(app.id, period, limit);
  console.log(
    JSON.stringify(
      {
        bundleId,
        appId: app.id,
        period,
        endpoint: `/v1/apps/${app.id}/metrics/betaTesterUsages?period=${period}&groupBy=betaTesters&limit=${limit}`,
        raw,
      },
      null,
      2,
    ),
  );
}

async function main(): Promise<void> {
  const raw = process.argv.slice(2);
  const { positionals, options } = parseArgs(raw);

  if (optBool(options, "help") || positionals[0] === "-h") {
    printHelp();
    process.exit(0);
  }

  if (positionals.length === 0) {
    printHelp();
    process.exit(1);
  }

  const cmd = positionals[0];
  const args = positionals.slice(1);
  const bundleId = optString(options, "bundle-id", DEFAULT_BUNDLE_ID);
  const jsonOut = optBool(options, "json");

  switch (cmd) {
    case "builds":
      await cmdBuilds(bundleId, args[0] || "", jsonOut);
      return;

    case "build-usage":
    case "usage-build":
      await cmdBuildUsage(bundleId, args[0] || "", jsonOut);
      return;

    case "usage-builds":
    case "build-usage-recent":
      await cmdBuildUsageRecent(bundleId, args[0] || "", jsonOut);
      return;

    case "build-access":
      await cmdBuildAccess(bundleId, args[0] || "", jsonOut);
      return;

    case "build-usage-raw":
      await cmdBuildUsageRaw(bundleId, args[0] || "");
      return;

    case "app-tester-usage-raw":
      await cmdAppTesterUsageRaw(bundleId, args[0] || "P7D", args[1] || "20");
      return;

    default:
      die(`Unknown command: ${cmd}. Run with --help for usage.`);
  }
}

main().catch((err) => {
  console.error(err?.message || err);
  process.exit(1);
});
