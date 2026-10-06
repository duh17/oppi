#!/usr/bin/env bun
import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

export const RECEIPT_SCHEMA = "oppi.qa-deterministic.receipt/v1";
export const PARENT_SCHEMA = "oppi.qa-deterministic.parent/v1";

export type QAStatus = "pass" | "fail" | "unknown";

export class QAVerifyError extends Error {
  readonly hint: string;
  readonly exitCode: number;

  constructor(message: string, hint = "See qa-verify.ts help", exitCode = 2) {
    super(message);
    this.name = "QAVerifyError";
    this.hint = hint;
    this.exitCode = exitCode;
  }
}

export type JourneyCatalogEntry = {
  id: string;
  lane: "e2e" | "negatives";
  subject: string;
  requestedStepIds: string[];
  requiredAssertionIds: string[];
  mockedBoundaries: string[];
  innerStatus?: QAStatus;
};

export const JOURNEYS: JourneyCatalogEntry[] = [
  {
    id: "composer-ready",
    lane: "e2e",
    subject: "Unique chat.input accepts synthetic text and unique chat.send becomes enabled",
    requestedStepIds: ["wait-input", "type-marker", "wait-send"],
    requiredAssertionIds: ["composer-accepts-text-and-send-enabled"],
    mockedBoundaries: [],
  },
  {
    id: "queue-move-steering-to-followup",
    lane: "e2e",
    subject:
      "One synthetic steering item moves to follow-up; UI plus one correlated get_queue command_result",
    requestedStepIds: [
      "wait-queue-pill",
      "tap-queue-pill",
      "wait-steering-message",
      "wait-move-followup",
      "tap-move-followup",
      "wait-followup-control",
      "wait-steering-move-gone",
      "wait-message-still-present",
    ],
    requiredAssertionIds: [
      "authoritative-get-queue",
      "queue-id-once",
      "item-absent-steering",
      "item-present-followup",
      "item-content-unchanged",
      "queue-version-advanced",
      "ui-followup-visible",
      "queue-update-error-banner",
    ],
    mockedBoundaries: [],
  },
  {
    id: "negative-ambiguous-target",
    lane: "negatives",
    subject: "Three duplicate move controls fail closed; queue unchanged",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["rejected-ambiguous-3-matches", "queue-unchanged"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "fail",
  },
  {
    id: "negative-missing-target",
    lane: "negatives",
    subject: "Missing move identifier fails closed; queue unchanged",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["rejected-missing-target", "queue-unchanged"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "fail",
  },
  {
    id: "negative-missing-scope",
    lane: "negatives",
    subject: "Missing scope does not fall back to the app",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["rejected-missing-scope"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "fail",
  },
  {
    id: "negative-ambiguous-scope",
    lane: "negatives",
    subject: "Ambiguous scope does not fall back to the app",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["rejected-ambiguous-scope"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "fail",
  },
  {
    id: "negative-absent-postcondition",
    lane: "negatives",
    subject: "Absent postcondition does not pass",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["rejected-absent-postcondition"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "fail",
  },
  {
    id: "negative-uncertain-dispatch",
    lane: "negatives",
    subject: "Unconfirmed dispatch refuses another mutation",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["refused-second-mutation"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "unknown",
  },
  {
    id: "negative-unrelated-wait",
    lane: "negatives",
    subject: "Unrelated or already-present wait does not confirm another mutation",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["refused-after-unrelated-wait"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "unknown",
  },
  {
    id: "negative-evidence-unknown",
    lane: "negatives",
    subject: "Evidence collection failure is unknown, never pass",
    requestedStepIds: ["inner-attempt"],
    requiredAssertionIds: ["evidence-unknown"],
    mockedBoundaries: ["hang-harness-in-memory-queue"],
    innerStatus: "unknown",
  },
];

const DISPATCHED_UNCONFIRMED = "dispatched-unconfirmed";

export const SOURCE_TREES = [
  "clients/apple/Oppi",
  "clients/apple/Shared",
  "clients/apple/OppiCore",
  "clients/apple/OppiE2ETests",
  "clients/apple/OppiUITests",
  "clients/apple/QAVerificationSupport",
  "clients/apple/OppiActivityExtension",
  "clients/apple/OppiControlWidget",
  "clients/apple/OppiShareExtension",
  "clients/apple/OppiAssetDownloader",
  "clients/apple/scripts",
  "server/src",
  "server/extensions",
  "server/e2e",
] as const;

export const SOURCE_EXTRA_FILES = [
  "clients/apple/project.yml",
  "clients/apple/Base.xcconfig",
  "clients/apple/Oppi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  "dev/testing/qa-verification.md",
  "dev/testing/README.md",
  "dev/testing/apple.md",
  ".gitignore",
  "server/package.json",
  "server/package-lock.json",
  "server/tsconfig.json",
  // The only server/scripts the paired E2E wrapper (apple/e2e.sh) invokes.
  "server/scripts/e2e-clean.mjs",
  "server/scripts/e2e-gen-invite.mjs",
  "server/scripts/e2e-precreate-pair.mjs",
] as const;

export const REQUIRED_SOURCE_FILES = [
  "clients/apple/Oppi/App/OppiApp.swift",
  "clients/apple/QAVerificationSupport/QAVerificationExecutor.swift",
  "clients/apple/QAVerificationSupport/QAVerificationReceipt.swift",
  "clients/apple/scripts/qa-verify.ts",
  "clients/apple/scripts/qa-verify-lib.ts",
  "clients/apple/project.yml",
  "clients/apple/Base.xcconfig",
  "server/tsconfig.json",
  "server/scripts/e2e-clean.mjs",
  "server/scripts/e2e-gen-invite.mjs",
  "server/scripts/e2e-precreate-pair.mjs",
] as const;

export const REQUIRED_SOURCE_DIRS = [
  "clients/apple/Shared",
  "clients/apple/OppiCore",
  "clients/apple/OppiE2ETests",
  "clients/apple/OppiUITests",
  "clients/apple/OppiActivityExtension",
  "clients/apple/OppiControlWidget",
  "clients/apple/OppiShareExtension",
  "clients/apple/OppiAssetDownloader",
  "server/src",
  "server/extensions",
  "server/e2e",
] as const;

const SKIP_DIR_NAMES = new Set([
  ".git",
  "node_modules",
  ".build",
  "DerivedData",
  "xcuserdata",
  "build",
  "dist",
  ".internal",
  ".pi",
  "__pycache__",
]);

const SKIP_FILE_NAMES = new Set([".DS_Store", ".env", ".env.local", ".env.rc"]);

export type WrapperIdentity = {
  path: string;
  sha256: string;
  bytes: number;
  missing: boolean;
};

export type SourceFingerprint = {
  sha: string;
  branch: string;
  contentHash: string;
  fileCount: number;
  files: Array<{ path: string; sha256: string; bytes: number }>;
  wrappers: WrapperIdentity[];
};

export type AdmitReason = {
  code: string;
  message: string;
};

export type AdmitResult = {
  status: QAStatus;
  reasons: AdmitReason[];
};

export type BuiltIdentity = {
  appPath: string;
  appSha256: string;
  testBundlePath: string;
  testBundleSha256: string;
};

export type StrictSimPoolSummary = {
  path: string;
  scope: "final";
  attemptCount: number;
  attemptNumber: number;
  hangDetected: boolean;
  incomplete: boolean;
  udid: string;
  slot: number;
  derivedDataPath: string;
  logPath: string;
  exitCode: number;
  executedTests: number;
  skippedTests: number;
};

export type OwnedLaneRun = {
  lane: "negatives" | "e2e";
  summary: StrictSimPoolSummary;
  built: BuiltIdentity;
};

export function scriptDir(): string {
  return dirname(fileURLToPath(import.meta.url));
}

export function appleDir(): string {
  return resolve(scriptDir(), "..");
}

export function repoRoot(): string {
  return resolve(appleDir(), "..", "..");
}

export function isoNow(): string {
  return new Date().toISOString();
}

export function workflowScript(): string {
  return join(homedir(), ".pi/agent/skills/oppi-dev/scripts/oppi-workflow.sh");
}

export function e2eWrapperScript(): string {
  return join(homedir(), ".pi/agent/skills/oppi-dev/scripts/apple/e2e.sh");
}

export function ensureDir(path: string): string {
  mkdirSync(path, { recursive: true });
  return path;
}

export function writeJson(path: string, value: unknown): void {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

export function journeysForLane(lane: "e2e" | "negatives" | "all"): JourneyCatalogEntry[] {
  if (lane === "all") return JOURNEYS.slice();
  return JOURNEYS.filter((journey) => journey.lane === lane);
}

export function journeyById(id: string): JourneyCatalogEntry | undefined {
  return JOURNEYS.find((journey) => journey.id === id);
}

export function hashFileBytes(contents: Buffer): string {
  return createHash("sha256").update(contents).digest("hex");
}

export function publicErrorPayload(error: unknown): {
  error: "qa_verify_error";
  message: string;
  hint: string;
  exit_code: number;
} {
  if (error instanceof QAVerifyError) {
    return {
      error: "qa_verify_error",
      message: error.message,
      hint: error.hint,
      exit_code: error.exitCode,
    };
  }
  const message = error instanceof Error ? error.message : String(error);
  return {
    error: "qa_verify_error",
    message,
    hint: "Unexpected qa-verify failure. Child logs stay off stdout.",
    exit_code: 2,
  };
}

export function canStartNextLane(input: {
  timedOut?: boolean;
  canceled?: boolean;
  /** When given (xcodegen), a non-zero exit blocks the lane: never run against a stale project. */
  code?: number | null;
  stop: { quiescent: boolean };
}): boolean {
  return (
    input.timedOut !== true &&
    input.canceled !== true &&
    (input.code === undefined || input.code === 0) &&
    input.stop.quiescent === true
  );
}

function skipDir(name: string): boolean {
  return SKIP_DIR_NAMES.has(name);
}

function skipFile(name: string): boolean {
  if (SKIP_FILE_NAMES.has(name)) return true;
  if (name.startsWith(".env.")) return true;
  return /\.(o|a|dylib|dSYM|xcuserstate|pem|p12|key)$/i.test(name);
}

function collectFilesUnder(root: string, relativeDir: string, into: string[]): void {
  const full = join(root, relativeDir);
  if (!existsSync(full)) return;
  const stack = [full];
  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;
    let entries: string[];
    try {
      entries = readdirSync(current);
    } catch {
      throw new QAVerifyError(
        `Cannot read source directory ${relative(root, current)}`,
        "Required app/server/harness source must be readable",
        2,
      );
    }
    entries.sort();
    for (const name of entries) {
      const path = join(current, name);
      let stat;
      try {
        stat = lstatSync(path);
      } catch {
        continue;
      }
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) {
        if (skipDir(name)) continue;
        stack.push(path);
        continue;
      }
      if (!stat.isFile()) continue;
      if (skipFile(name)) continue;
      into.push(relative(root, path).split(sep).join("/"));
    }
  }
}

export function collectSourcePaths(root = repoRoot()): string[] {
  const paths = new Set<string>();
  for (const tree of SOURCE_TREES) {
    const bucket: string[] = [];
    collectFilesUnder(root, tree, bucket);
    for (const path of bucket) paths.add(path);
  }
  for (const extra of SOURCE_EXTRA_FILES) {
    const full = join(root, extra);
    if (existsSync(full) && lstatSync(full).isFile()) paths.add(extra);
  }
  return [...paths].sort();
}

function requireSource(root: string): void {
  const missing: string[] = [];
  for (const relativePath of REQUIRED_SOURCE_FILES) {
    const full = join(root, relativePath);
    if (!existsSync(full) || !lstatSync(full).isFile()) missing.push(relativePath);
  }
  for (const relativePath of REQUIRED_SOURCE_DIRS) {
    const full = join(root, relativePath);
    if (!existsSync(full) || !lstatSync(full).isDirectory()) missing.push(relativePath);
  }
  if (missing.length > 0) {
    throw new QAVerifyError(
      `Missing required source: ${missing.join(", ")}`,
      "Fingerprint refuses to hash a partial checkout as the tested app/server/harness",
      2,
    );
  }
}

function hashWrapper(path: string): WrapperIdentity {
  if (!existsSync(path) || !lstatSync(path).isFile()) {
    return { path, sha256: "", bytes: 0, missing: true };
  }
  const contents = readFileSync(path);
  return {
    path,
    sha256: hashFileBytes(contents),
    bytes: contents.byteLength,
    missing: false,
  };
}

export function fingerprintSource(root = repoRoot()): SourceFingerprint {
  requireSource(root);
  const paths = collectSourcePaths(root);
  const files = paths.map((relativePath) => {
    const full = join(root, relativePath);
    const contents = readFileSync(full);
    return {
      path: relativePath,
      sha256: hashFileBytes(contents),
      bytes: contents.byteLength,
    };
  });
  const hasher = createHash("sha256");
  for (const file of files) {
    hasher.update(file.path);
    hasher.update("\0");
    hasher.update(file.sha256);
    hasher.update("\n");
  }
  return {
    sha: git(root, ["rev-parse", "HEAD"]),
    branch: git(root, ["branch", "--show-current"]) || "detached",
    contentHash: hasher.digest("hex"),
    fileCount: files.length,
    files,
    wrappers: [hashWrapper(workflowScript()), hashWrapper(e2eWrapperScript())],
  };
}

function git(root: string, args: string[]): string {
  const result = spawnSync("git", args, { cwd: root, encoding: "utf8" });
  if (result.status !== 0) {
    throw new QAVerifyError(
      (result.stderr || `git ${args.join(" ")} failed`).trim(),
      "Source fingerprint requires a readable git checkout",
      2,
    );
  }
  return (result.stdout || "").trim();
}

export function createRunDirectory(out?: string, nonce = randomUUID()): string {
  const stamp = isoNow().replace(/[:.]/g, "-");
  const base = out
    ? resolve(out)
    : join(repoRoot(), ".internal/reports/qa-deterministic-core/runs");
  const path = join(base, `${stamp}-${nonce}`);
  if (existsSync(path)) {
    throw new QAVerifyError(`Refusing to reuse existing run directory ${path}`);
  }
  return ensureDir(path);
}

export function sameIdList(actual: unknown, expected: string[]): boolean {
  if (!Array.isArray(actual) || actual.length !== expected.length) return false;
  return actual.every((value, index) => value === expected[index]);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) ? value : undefined;
}

function asNonNegativeInteger(value: unknown): number | undefined {
  const n = asInteger(value);
  return n != null && n >= 0 ? n : undefined;
}

function asStatus(value: unknown): QAStatus | undefined {
  return value === "pass" || value === "fail" || value === "unknown" ? value : undefined;
}

function push(reasons: AdmitReason[], code: string, message: string): void {
  reasons.push({ code, message });
}

export function parseXcodeTestExecution(
  logText: string,
): { executed: number; skipped: number } | null {
  let last: { executed: number; skipped: number } | null = null;
  // XCTest can place skips before the failure count or in a trailing suffix.
  // Read the complete summary line, not only the prefix through "failures".
  const lineRe = /^\s*Executed (\d+) tests?, with ([^\r\n]+)$/gm;
  for (const match of logText.matchAll(lineRe)) {
    const executed = Number(match[1]);
    const detail = match[2];
    if (!Number.isSafeInteger(executed) || !/\b\d+ failures?\b/.test(detail)) return null;
    const skippedMatch = detail.match(/\b(\d+)\s+(?:tests?\s+)?skipped\b/);
    if (/\bskipped\b/.test(detail) && !skippedMatch) return null;
    const skipped = skippedMatch ? Number(skippedMatch[1]) : 0;
    if (!Number.isSafeInteger(skipped) || skipped > executed) return null;
    last = { executed, skipped };
  }
  return last;
}

export function uniqueArtifactPath(logText: string): string | undefined {
  const matches = [
    ...logText.matchAll(/^(?:\[sim-pool\] )?Artifact: (.+\.summary\.json)\s*$/gm),
  ].map((match) => match[1]);
  const unique = [...new Set(matches)];
  return unique.length === 1 ? unique[0] : undefined;
}

export function parseStrictSimPoolSummary(
  summaryPath: string,
  expected: { appleDir: string; lane: "negatives" | "e2e" },
): StrictSimPoolSummary {
  if (!existsSync(summaryPath)) {
    throw new QAVerifyError(`Missing sim-pool summary ${summaryPath}`, "Owned lane artifact is required", 1);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(summaryPath, "utf8"));
  } catch {
    throw new QAVerifyError(`Malformed sim-pool summary ${summaryPath}`, "Summary must be JSON", 1);
  }
  if (!isObject(parsed)) {
    throw new QAVerifyError(`Malformed sim-pool summary ${summaryPath}`, "Summary must be an object", 1);
  }
  const scope = asString(parsed.scope);
  const attemptCount = asNonNegativeInteger(parsed.attempt_count);
  const attemptNumber = asNonNegativeInteger(parsed.attempt_number);
  if (typeof parsed.hang_detected !== "boolean") {
    throw new QAVerifyError("sim-pool hang_detected is missing", "Hang field must be a boolean", 1);
  }
  const hangDetected = parsed.hang_detected;
  const incomplete = parsed.incomplete === true;
  const udid = asString(parsed.simulator_udid);
  const slot = asInteger(parsed.simulator_slot);
  const derivedDataPath = asString(parsed.derived_data_path);
  const logPath = asString(parsed.log_path);
  const exitCode = asInteger(parsed.exit_code);
  if (scope !== "final") {
    throw new QAVerifyError(`sim-pool summary scope is ${scope ?? "<missing>"}`, "Need the owned final summary", 1);
  }
  if (attemptCount == null || attemptNumber == null) {
    throw new QAVerifyError(
      "sim-pool attempt_count/attempt_number missing",
      "Owned attempt counts are required",
      1,
    );
  }
  if (!udid || !/^[0-9A-F-]{36}$/i.test(udid)) {
    throw new QAVerifyError("sim-pool simulator_udid is missing or malformed", "Wrong-lane/UDID evidence cannot pass", 1);
  }
  if (slot == null || slot < 0) {
    throw new QAVerifyError("sim-pool simulator_slot is missing", "Owned slot is required", 1);
  }
  if (!derivedDataPath || !logPath) {
    throw new QAVerifyError("sim-pool derived_data_path/log_path missing", "Owned build paths are required", 1);
  }
  if (exitCode == null) {
    throw new QAVerifyError("sim-pool exit_code missing", "Owned exit code is required", 1);
  }
  const expectedPrefix = join(expected.appleDir, ".build", `pool-`);
  if (!derivedDataPath.startsWith(expectedPrefix)) {
    throw new QAVerifyError(
      `sim-pool derived_data_path is not this worktree pool: ${derivedDataPath}`,
      "Wrong-lane DerivedData cannot pass",
      1,
    );
  }
  if (!existsSync(logPath)) {
    throw new QAVerifyError(`sim-pool log_path does not exist: ${logPath}`, "Owned xcodebuild log is required", 1);
  }
  const execution = parseXcodeTestExecution(readFileSync(logPath, "utf8"));
  return {
    path: summaryPath,
    scope: "final",
    attemptCount,
    attemptNumber,
    hangDetected,
    incomplete,
    udid,
    slot,
    derivedDataPath,
    logPath,
    exitCode,
    executedTests: execution?.executed ?? 0,
    skippedTests: execution?.skipped ?? 0,
  };
}

export function builtIdentityFromDerivedData(
  derivedDataPath: string,
  lane: "negatives" | "e2e",
): BuiltIdentity {
  const products = join(derivedDataPath, "Build", "Products", "Debug-iphonesimulator");
  const appPath = join(products, "Oppi.app", "Oppi");
  const testName = lane === "negatives" ? "OppiUITests" : "OppiE2ETests";
  const testBundlePath = join(
    products,
    `${testName}-Runner.app`,
    "PlugIns",
    `${testName}.xctest`,
    testName,
  );
  if (!existsSync(appPath)) {
    throw new QAVerifyError(`Missing built app ${appPath}`, "Built app identity is required", 1);
  }
  if (!existsSync(testBundlePath)) {
    throw new QAVerifyError(
      `Missing built test bundle ${testBundlePath}`,
      "Built test-bundle identity is required",
      1,
    );
  }
  const appBytes = readFileSync(appPath);
  const testBytes = readFileSync(testBundlePath);
  if (appBytes.byteLength === 0 || testBytes.byteLength === 0) {
    throw new QAVerifyError("Built app or test bundle is empty", "Empty compiled binding cannot pass", 1);
  }
  return {
    appPath,
    appSha256: hashFileBytes(appBytes),
    testBundlePath,
    testBundleSha256: hashFileBytes(testBytes),
  };
}

export function ownedRunFromCommandLogs(input: {
  lane: "negatives" | "e2e";
  stdoutPath: string;
  stderrPath: string;
  appleDir: string;
}): OwnedLaneRun {
  const text = [input.stdoutPath, input.stderrPath]
    .filter((path) => existsSync(path))
    .map((path) => readFileSync(path, "utf8"))
    .join("\n");
  const artifact = uniqueArtifactPath(text);
  if (!artifact) {
    throw new QAVerifyError(
      `No unique sim-pool Artifact summary in ${input.lane} logs`,
      "Bind the owned command artifact, not latest-by-time",
      1,
    );
  }
  const summary = parseStrictSimPoolSummary(artifact, {
    appleDir: input.appleDir,
    lane: input.lane,
  });
  const built = builtIdentityFromDerivedData(summary.derivedDataPath, input.lane);
  return { lane: input.lane, summary, built };
}

export function admitReceipt(
  raw: unknown,
  expected: {
    catalog: JourneyCatalogEntry;
    runNonce: string;
    source: SourceFingerprint;
    testBundleSha256?: string;
  },
): AdmitResult {
  const reasons: AdmitReason[] = [];
  if (!isObject(raw)) {
    return { status: "fail", reasons: [{ code: "malformed", message: "Receipt is not a JSON object" }] };
  }
  const schema = asString(raw.schema);
  if (schema !== RECEIPT_SCHEMA) {
    push(reasons, "foreign-schema", `schema ${schema ?? "<missing>"} is not ${RECEIPT_SCHEMA}`);
  }
  const journeyId = asString(raw.journeyId);
  if (journeyId !== expected.catalog.id) {
    push(reasons, "unexpected-journey", `journeyId ${journeyId ?? "<missing>"} != ${expected.catalog.id}`);
  }
  const runNonce = asString(raw.runNonce);
  if (runNonce !== expected.runNonce) {
    push(reasons, "stale-run", `runNonce ${runNonce ?? "<missing>"} != ${expected.runNonce}`);
  }
  const source = isObject(raw.source) ? raw.source : undefined;
  const sourceSha = source ? asString(source.sha) : undefined;
  const contentHash = source ? asString(source.contentHash) : undefined;
  if (sourceSha !== expected.source.sha || contentHash !== expected.source.contentHash) {
    push(
      reasons,
      "stale-source",
      "Receipt source sha/contentHash does not match the bound checkout bytes",
    );
  }
  const built = isObject(raw.built) ? raw.built : undefined;
  const testBundleSha256 = built ? asString(built.testBundleSha256) : undefined;
  if (!testBundleSha256) {
    push(reasons, "stale-compiled", "Receipt is missing built test-bundle sha256");
  } else if (expected.testBundleSha256 && testBundleSha256 !== expected.testBundleSha256) {
    push(reasons, "stale-compiled", "Receipt test-bundle sha256 does not match this run's built bundle");
  }
  if (raw.runtime !== "oppi") {
    push(reasons, "runtime", "runtime must be oppi");
  }
  if (raw.terminalMirrorExercised !== false) {
    push(reasons, "terminal-mirror", "this slice does not exercise a terminal mirror");
  }
  if (!sameIdList(raw.requestedStepIds, expected.catalog.requestedStepIds)) {
    push(reasons, "requested-steps", "requestedStepIds do not match the declared catalog");
  }
  if (!sameIdList(raw.requiredAssertionIds, expected.catalog.requiredAssertionIds)) {
    push(reasons, "required-assertions", "requiredAssertionIds do not match the declared catalog");
  }
  const steps = isObject(raw.steps) ? raw.steps : undefined;
  const requested = steps ? asNonNegativeInteger(steps.requested) : undefined;
  const executed = steps ? asNonNegativeInteger(steps.executed) : undefined;
  const skipped = steps ? asNonNegativeInteger(steps.skipped) : undefined;
  const cancelled = steps ? asNonNegativeInteger(steps.cancelled) : undefined;
  if (requested == null) {
    push(reasons, "malformed-counts", "steps.requested must be a finite nonnegative integer");
  }
  if (executed == null) {
    push(reasons, "malformed-counts", "steps.executed must be a finite nonnegative integer");
  }
  if (skipped == null) {
    push(reasons, "malformed-counts", "steps.skipped must be a finite nonnegative integer");
  }
  if (cancelled == null) {
    push(reasons, "malformed-counts", "steps.cancelled must be a finite nonnegative integer");
  }
  if (requested !== expected.catalog.requestedStepIds.length) {
    push(reasons, "requested-count", "steps.requested is not the catalog step count");
  }
  if (requested == null || requested <= 0 || executed == null || executed <= 0) {
    push(reasons, "zero-steps", "zero requested or executed steps cannot pass");
  }
  if (skipped != null && skipped > 0) {
    push(reasons, "skipped", "skipped steps cannot pass");
  }
  if (cancelled != null && cancelled > 0) {
    push(reasons, "cancelled", "cancelled steps cannot pass");
  }
  if (!steps || !Array.isArray(steps.records)) {
    push(reasons, "missing-records", "steps.records must be present");
  } else {
    const records = steps.records;
    if (executed !== records.length) {
      push(reasons, "executed-count", "steps.executed does not match records length");
    }
    if (records.length !== expected.catalog.requestedStepIds.length) {
      push(reasons, "record-count", "steps.records length does not match the catalog");
    }
    for (const [index, expectedId] of expected.catalog.requestedStepIds.entries()) {
      const record = records[index];
      if (!isObject(record)) {
        push(reasons, "record-missing", `steps.records[${index}] is missing`);
        continue;
      }
      if (asString(record.id) !== expectedId) {
        push(
          reasons,
          "record-id",
          `steps.records[${index}].id ${asString(record.id) ?? "<missing>"} != ${expectedId}`,
        );
      }
      if (asInteger(record.index) !== index) {
        push(reasons, "record-index", `steps.records[${index}].index is not ${index}`);
      }
      const recordStatus = asStatus(record.status);
      if (recordStatus !== "pass") {
        push(
          reasons,
          "record-status",
          `steps.records[${index}] (${expectedId}) is ${recordStatus ?? "invalid"}`,
        );
      }
    }
    // An unconfirmed dispatch (tap sent, effect not yet observed) is only
    // evidence once a later record confirms it; the executor clears the flag
    // on confirmation, so the confirming record carries no such detail.
    const lastIndex = records.length - 1;
    const isUnconfirmed = (record: unknown) =>
      isObject(record) && record.detail === DISPATCHED_UNCONFIRMED;
    if (records.some(isUnconfirmed) && isUnconfirmed(records[lastIndex])) {
      push(
        reasons,
        "dispatch-unconfirmed",
        "a dispatched-unconfirmed step record is not followed by a confirming record",
      );
    }
  }
  if (executed !== requested) {
    push(reasons, "incomplete", "executed step count does not match requested catalog steps");
  }
  const assertions = Array.isArray(raw.assertions) ? raw.assertions : [];
  const required = expected.catalog.requiredAssertionIds.map((id) => {
    const match = assertions.filter((item) => isObject(item) && item.name === id);
    return { id, match };
  });
  for (const item of required) {
    if (item.match.length !== 1) {
      push(reasons, "assertion-missing", `required assertion ${item.id} missing or duplicated`);
      continue;
    }
    const assertion = item.match[0] as Record<string, unknown>;
    if (assertion.required !== true) {
      push(reasons, "assertion-optional", `required assertion ${item.id} is not marked required`);
    }
    const status = asStatus(assertion.status);
    if (status !== "pass") {
      push(
        reasons,
        status === "unknown" ? "assertion-unknown" : "assertion-failed",
        `required assertion ${item.id} is ${status ?? "invalid"}`,
      );
    }
    if (asString(assertion.expected) == null || asString(assertion.observed) == null) {
      push(reasons, "assertion-evidence", `required assertion ${item.id} missing expected/observed`);
    }
  }
  const collector = isObject(raw.collector) ? raw.collector : undefined;
  const health = collector ? asString(collector.health) : undefined;
  if (health === "failed") {
    push(reasons, "collector-failure", "collector health is failed");
  }
  if (health !== "ok" && health !== "failed") {
    push(reasons, "collector-health", "collector health is missing");
  }
  if (expected.catalog.innerStatus) {
    const inner = raw.innerAttempt;
    if (!isObject(inner)) {
      push(reasons, "inner-missing", "negative proof requires an immutable innerAttempt");
    } else {
      const innerStatus = asStatus(inner.status);
      if (innerStatus !== expected.catalog.innerStatus) {
        push(
          reasons,
          "inner-status",
          `innerAttempt.status ${innerStatus ?? "<missing>"} != ${expected.catalog.innerStatus}`,
        );
      }
      if (asStatus(inner.status) === "pass") {
        push(reasons, "inner-pass", "inner attempt must remain fail/unknown");
      }
    }
  }
  const declared = asStatus(raw.status);
  if (!declared) {
    push(reasons, "malformed-status", "status is not pass|fail|unknown");
  }
  const blockingUnknown = reasons.some((reason) =>
    ["collector-failure", "assertion-unknown", "stale-run", "stale-source", "stale-compiled"].includes(
      reason.code,
    ),
  );
  const canPass =
    reasons.length === 0 &&
    declared === "pass" &&
    health === "ok" &&
    executed === requested &&
    skipped === 0 &&
    cancelled === 0;
  if (canPass) {
    return { status: "pass", reasons };
  }
  if (declared === "unknown" || blockingUnknown) {
    return { status: reasons.some((reason) => reason.code === "foreign-schema") ? "fail" : "unknown", reasons };
  }
  return { status: "fail", reasons };
}

export function mergeStatus(statuses: QAStatus[]): QAStatus {
  if (statuses.length === 0) return "fail";
  if (statuses.includes("fail")) return "fail";
  if (statuses.includes("unknown")) return "unknown";
  return "pass";
}

export type LoadedReceipt = {
  file: string;
  parsed: unknown;
  malformed: boolean;
};

export function loadReceiptFiles(dir: string): LoadedReceipt[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json") && !name.startsWith("parent."))
    .sort()
    .map((name) => {
      const file = join(dir, name);
      try {
        return { file, parsed: JSON.parse(readFileSync(file, "utf8")), malformed: false };
      } catch {
        return { file, parsed: null, malformed: true };
      }
    });
}

export function simLanesFor(lane: "e2e" | "negatives" | "all"): Array<"negatives" | "e2e"> {
  if (lane === "all") return ["negatives", "e2e"];
  return [lane];
}

export function admitLane(params: {
  lane: "e2e" | "negatives" | "all";
  receipts: LoadedReceipt[];
  runNonce: string;
  source: SourceFingerprint;
  sourceUnchanged: boolean;
  ownedRuns?: OwnedLaneRun[];
  wrappers?: WrapperIdentity[];
}): {
  status: QAStatus;
  admissions: Array<{ journeyId: string; file?: string; result: AdmitResult }>;
  reasons: AdmitReason[];
} {
  const reasons: AdmitReason[] = [];
  const expected = journeysForLane(params.lane);
  if (!params.sourceUnchanged) {
    reasons.push({ code: "source-changed", message: "Source bytes changed during the run" });
  }
  const owned = params.ownedRuns ?? [];
  const needed = simLanesFor(params.lane);
  for (const lane of needed) {
    const matches = owned.filter((run) => run.lane === lane);
    if (matches.length === 0) {
      reasons.push({
        code: "missing-summary",
        message: `Missing owned sim-pool result for ${lane}`,
      });
      continue;
    }
    if (matches.length > 1) {
      reasons.push({
        code: "duplicate-summary",
        message: `Multiple owned sim-pool results for ${lane}`,
      });
      continue;
    }
    const run = matches[0];
    if (run.summary.hangDetected) {
      reasons.push({ code: "hang", message: `${lane}: simulator hang detected; retries are forbidden` });
    }
    if (run.summary.attemptCount !== 1) {
      reasons.push({
        code: "retry",
        message: `${lane}: sim-pool attempt_count ${run.summary.attemptCount} is not exactly 1`,
      });
    }
    if (run.summary.incomplete) {
      reasons.push({ code: "incomplete-summary", message: `${lane}: sim-pool summary is incomplete` });
    }
    if (run.summary.executedTests <= 0) {
      reasons.push({ code: "zero-execution", message: `${lane}: executed 0 tests` });
    }
    if (run.summary.skippedTests > 0) {
      reasons.push({ code: "skipped-execution", message: `${lane}: skipped tests cannot pass` });
    }
    if (!run.built.appSha256 || !run.built.testBundleSha256) {
      reasons.push({ code: "stale-compiled", message: `${lane}: missing built app/test-bundle identity` });
    }
  }
  if (needed.includes("e2e")) {
    const wrappers = params.wrappers ?? params.source.wrappers;
    for (const wrapper of wrappers) {
      if (wrapper.missing || !wrapper.sha256) {
        reasons.push({
          code: "missing-wrapper",
          message: `External wrapper missing: ${wrapper.path}`,
        });
      }
    }
  }
  const ownedByLane = new Map(owned.map((run) => [run.lane, run]));
  const admissions: Array<{ journeyId: string; file?: string; result: AdmitResult }> = [];
  const used = new Set<number>();
  for (const catalog of expected) {
    const matches = params.receipts
      .map((receipt, index) => ({ receipt, index }))
      .filter(({ receipt }) => {
        if (receipt.malformed || !isObject(receipt.parsed)) return false;
        return receipt.parsed.journeyId === catalog.id;
      });
    if (matches.length === 0) {
      const malformed = params.receipts.filter((receipt) => receipt.malformed);
      const result: AdmitResult = {
        status: "fail",
        reasons: [
          {
            code: malformed.length > 0 ? "malformed" : "missing",
            message: `No valid receipt for ${catalog.id}`,
          },
        ],
      };
      admissions.push({ journeyId: catalog.id, result });
      reasons.push(...result.reasons);
      continue;
    }
    if (matches.length > 1) {
      const result: AdmitResult = {
        status: "fail",
        reasons: [{ code: "duplicate", message: `Duplicate receipts for ${catalog.id}` }],
      };
      admissions.push({ journeyId: catalog.id, result });
      reasons.push(...result.reasons);
      continue;
    }
    const match = matches[0];
    used.add(match.index);
    if (match.receipt.malformed) {
      const result: AdmitResult = {
        status: "fail",
        reasons: [{ code: "malformed", message: `Malformed JSON in ${match.receipt.file}` }],
      };
      admissions.push({ journeyId: catalog.id, file: match.receipt.file, result });
      reasons.push(...result.reasons);
      continue;
    }
    const result = admitReceipt(match.receipt.parsed, {
      catalog,
      runNonce: params.runNonce,
      source: params.source,
      testBundleSha256: ownedByLane.get(catalog.lane)?.built.testBundleSha256,
    });
    admissions.push({ journeyId: catalog.id, file: match.receipt.file, result });
    reasons.push(...result.reasons.map((reason) => ({ ...reason, message: `${catalog.id}: ${reason.message}` })));
  }
  for (const [index, receipt] of params.receipts.entries()) {
    if (used.has(index)) continue;
    reasons.push({
      code: receipt.malformed ? "malformed" : "unexpected-receipt",
      message: `Unexpected receipt file ${receipt.file}`,
    });
  }
  const extraUnknown = reasons.some((reason) => reason.code === "hang");
  const extraFail =
    params.receipts.length === 0 ||
    reasons.some((reason) =>
      [
        "source-changed",
        "retry",
        "duplicate",
        "missing",
        "malformed",
        "unexpected-receipt",
        "missing-summary",
        "duplicate-summary",
        "incomplete-summary",
        "zero-execution",
        "skipped-execution",
        "stale-compiled",
        "missing-wrapper",
      ].includes(reason.code),
    );
  const status = mergeStatus([
    ...admissions.map((item) => item.result.status),
    extraFail ? "fail" : extraUnknown ? "unknown" : "pass",
  ]);
  return { status, admissions, reasons };
}

export function assertionViews(
  receipts: LoadedReceipt[],
): Array<{
  journeyId: string;
  name: string;
  required: boolean;
  status: string;
  expected: string;
  observed: string;
}> {
  const views: Array<{
    journeyId: string;
    name: string;
    required: boolean;
    status: string;
    expected: string;
    observed: string;
  }> = [];
  for (const receipt of receipts) {
    if (receipt.malformed || !isObject(receipt.parsed)) continue;
    const journeyId = asString(receipt.parsed.journeyId) ?? "<unknown>";
    const assertions = Array.isArray(receipt.parsed.assertions) ? receipt.parsed.assertions : [];
    for (const item of assertions) {
      if (!isObject(item)) continue;
      views.push({
        journeyId,
        name: asString(item.name) ?? "<missing>",
        required: item.required === true,
        status: asString(item.status) ?? "invalid",
        expected: asString(item.expected) ?? "",
        observed: asString(item.observed) ?? "",
      });
    }
  }
  return views;
}

export function executedStepViews(
  receipts: LoadedReceipt[],
): Array<{ journeyId: string; id: string; index: number; op: string; status: string }> {
  const views: Array<{ journeyId: string; id: string; index: number; op: string; status: string }> = [];
  for (const receipt of receipts) {
    if (receipt.malformed || !isObject(receipt.parsed)) continue;
    const journeyId = asString(receipt.parsed.journeyId) ?? "<unknown>";
    const steps = isObject(receipt.parsed.steps) ? receipt.parsed.steps : undefined;
    const records = steps && Array.isArray(steps.records) ? steps.records : [];
    for (const record of records) {
      if (!isObject(record)) continue;
      views.push({
        journeyId,
        id: asString(record.id) ?? "<missing>",
        index: asInteger(record.index) ?? -1,
        op: asString(record.op) ?? "",
        status: asString(record.status) ?? "invalid",
      });
    }
  }
  return views;
}
