import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  JOURNEYS,
  PARENT_SCHEMA,
  QAVerifyError,
  RECEIPT_SCHEMA,
  REQUIRED_SOURCE_DIRS,
  REQUIRED_SOURCE_FILES,
  SOURCE_EXTRA_FILES,
  SOURCE_TREES,
  admitLane,
  admitReceipt,
  canStartNextLane,
  fingerprintSource,
  journeyById,
  mergeStatus,
  parseXcodeTestExecution,
  uniqueArtifactPath,
  type JourneyCatalogEntry,
  type OwnedLaneRun,
  type SourceFingerprint,
} from "./qa-verify-lib";

const cli = join(import.meta.dir, "qa-verify.ts");

function runCli(args: string[], env?: NodeJS.ProcessEnv) {
  return spawnSync("bun", [cli, ...args], { encoding: "utf8", env: env ?? process.env });
}

function source(overrides: Partial<SourceFingerprint> = {}): SourceFingerprint {
  return {
    sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    branch: "feat/qa-deterministic-core",
    contentHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    fileCount: 0,
    files: [],
    wrappers: [],
    ...overrides,
  };
}

const TEST_BUNDLE = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

function ownedRun(lane: "negatives" | "e2e" = "e2e"): OwnedLaneRun {
  return {
    lane,
    summary: {
      path: `/tmp/${lane}.summary.json`,
      scope: "final",
      attemptCount: 1,
      attemptNumber: 1,
      hangDetected: false,
      incomplete: false,
      udid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      slot: 0,
      derivedDataPath: "/tmp/pool-0",
      logPath: "/tmp/pool.log",
      exitCode: 0,
      executedTests: 2,
      skippedTests: 0,
    },
    built: {
      appPath: "/tmp/Oppi.app/Oppi",
      appSha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      testBundlePath: "/tmp/tests.xctest/tests",
      testBundleSha256: TEST_BUNDLE,
    },
  };
}

function validReceipt(catalog: JourneyCatalogEntry, nonce: string, src: SourceFingerprint) {
  return {
    schema: RECEIPT_SCHEMA,
    status: "pass",
    journeyId: catalog.id,
    subject: catalog.subject,
    driver: "strict",
    runNonce: nonce,
    source: { sha: src.sha, contentHash: src.contentHash },
    built: { testBundlePath: "/tmp/tests.xctest/tests", testBundleSha256: TEST_BUNDLE },
    runtime: "oppi",
    terminalMirrorExercised: false,
    requestedStepIds: catalog.requestedStepIds,
    requiredAssertionIds: catalog.requiredAssertionIds,
    steps: {
      requested: catalog.requestedStepIds.length,
      executed: catalog.requestedStepIds.length,
      skipped: 0,
      cancelled: 0,
      records: catalog.requestedStepIds.map((id, index) => ({
        id,
        index,
        op: "step",
        status: "pass",
      })),
    },
    assertions: catalog.requiredAssertionIds.map((name) => ({
      name,
      required: true,
      status: "pass",
      expected: "ok",
      observed: "ok",
    })),
    failingStep: null,
    timing: { observeActionWaitMs: 1, modelMs: 0, recordingMs: 0, wallMs: 1 },
    collector: { health: "ok", recording: "off", artifacts: [] },
    mockedBoundaries: catalog.mockedBoundaries,
    ...(catalog.innerStatus
      ? {
          innerAttempt: {
            schema: RECEIPT_SCHEMA,
            status: catalog.innerStatus,
            journeyId: `${catalog.id}.inner`,
            subject: "inner",
            driver: "strict",
            runNonce: nonce,
            source: { sha: src.sha, contentHash: src.contentHash },
            runtime: "oppi",
            terminalMirrorExercised: false,
            requestedStepIds: ["tap"],
            requiredAssertionIds: [],
            steps: {
              requested: 1,
              executed: 1,
              skipped: 0,
              cancelled: 0,
              records: [{ id: "tap", index: 0, op: "tap", status: catalog.innerStatus }],
            },
            assertions: [],
            failingStep: { index: 0, op: "tap", reason: "inner" },
            timing: { observeActionWaitMs: 1, modelMs: 0, recordingMs: 0, wallMs: 1 },
            collector: { health: catalog.innerStatus === "unknown" ? "failed" : "ok", recording: "off", artifacts: [] },
            mockedBoundaries: catalog.mockedBoundaries,
          },
        }
      : {}),
  };
}

describe("qa-verify catalog", () => {
  test("declares requested steps independently of a receipt", () => {
    const composer = journeyById("composer-ready");
    expect(composer?.requestedStepIds).toEqual(["wait-input", "type-marker", "wait-send"]);
    expect(composer?.requiredAssertionIds.length).toBeGreaterThan(0);
    expect(journeyById("queue-move-steering-to-followup")?.requiredAssertionIds).toContain(
      "queue-update-error-banner",
    );
    expect(journeyById("negative-unrelated-wait")?.innerStatus).toBe("unknown");
  });
});

describe("qa-verify admission", () => {
  const catalog = journeyById("composer-ready")!;
  const nonce = "run-nonce-1";
  const src = source();

  test("foreign schema cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    receipt.schema = "oppi.qa-verification.receipt/v1";
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "foreign-schema")).toBe(true);
  });

  test("stale run nonce cannot pass", () => {
    const receipt = validReceipt(catalog, "old-nonce", src);
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).not.toBe("pass");
    expect(result.reasons.some((reason) => reason.code === "stale-run")).toBe(true);
  });

  test("source byte mismatch cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    receipt.source.contentHash = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).not.toBe("pass");
    expect(result.reasons.some((reason) => reason.code === "stale-source")).toBe(true);
  });

  test("omitted records cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src) as Record<string, unknown> & {
      steps: Record<string, unknown>;
    };
    delete receipt.steps.records;
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "missing-records")).toBe(true);
  });

  test("wrong-id failed records cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    receipt.steps.records = receipt.steps.records.map(() => ({
      id: "unrelated",
      index: 0,
      op: "step",
      status: "fail",
    }));
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "record-id")).toBe(true);
    expect(result.reasons.some((reason) => reason.code === "record-status")).toBe(true);
  });

  test("omitted skip/cancel counts are malformed", () => {
    const receipt = validReceipt(catalog, nonce, src) as Record<string, unknown> & {
      steps: Record<string, unknown>;
    };
    delete receipt.steps.skipped;
    delete receipt.steps.cancelled;
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "malformed-counts")).toBe(true);
  });

  test("negative skipped count is malformed not a silent default", () => {
    const receipt = validReceipt(catalog, nonce, src);
    receipt.steps.skipped = -1;
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "malformed-counts")).toBe(true);
  });

  test("stale compiled test bundle cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    const result = admitReceipt(receipt, {
      catalog,
      runNonce: nonce,
      source: src,
      testBundleSha256: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    });
    expect(result.status).not.toBe("pass");
    expect(result.reasons.some((reason) => reason.code === "stale-compiled")).toBe(true);
  });

  test("rewriting requested count from executed records cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    receipt.requestedStepIds = ["only-executed"];
    receipt.steps.requested = 1;
    receipt.steps.executed = 1;
    receipt.steps.records = [{ id: "only-executed", index: 0, op: "step", status: "pass" }];
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "requested-steps")).toBe(true);
  });

  test("zero, skipped, cancelled, and collector failure cannot pass", () => {
    const zero = validReceipt(catalog, nonce, src);
    zero.steps.requested = 0;
    zero.steps.executed = 0;
    expect(admitReceipt(zero, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE }).status).toBe("fail");

    const skipped = validReceipt(catalog, nonce, src);
    skipped.steps.skipped = 1;
    expect(admitReceipt(skipped, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE }).status).toBe("fail");

    const cancelled = validReceipt(catalog, nonce, src);
    cancelled.steps.cancelled = 1;
    expect(admitReceipt(cancelled, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE }).status).toBe("fail");

    const collector = validReceipt(catalog, nonce, src);
    collector.collector.health = "failed";
    expect(admitReceipt(collector, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE }).status).toBe("unknown");
  });

  test("malformed JSON and missing journey fail the lane", () => {
    const dir = mkdtempSync(join(tmpdir(), "qa-verify-receipts-"));
    writeFileSync(join(dir, "broken.json"), "{not json");
    const admitted = admitLane({
      lane: "e2e",
      receipts: [{ file: join(dir, "broken.json"), parsed: null, malformed: true }],
      runNonce: nonce,
      source: src,
      sourceUnchanged: true,
      ownedRuns: [ownedRun("e2e")],
    });
    expect(admitted.status).toBe("fail");
    expect(admitted.reasons.some((reason) => reason.code === "malformed" || reason.code === "missing")).toBe(true);
  });

  test("missing sim-pool summary cannot pass", () => {
    const admitted = admitLane({
      lane: "e2e",
      receipts: [
        { file: "composer.json", parsed: validReceipt(catalog, nonce, src), malformed: false },
        {
          file: "queue.json",
          parsed: validReceipt(journeyById("queue-move-steering-to-followup")!, nonce, src),
          malformed: false,
        },
      ],
      runNonce: nonce,
      source: src,
      sourceUnchanged: true,
    });
    expect(admitted.status).toBe("fail");
    expect(admitted.reasons.some((reason) => reason.code === "missing-summary")).toBe(true);
  });

  test("hang summary is bound and cannot pass", () => {
    const hung = ownedRun("e2e");
    hung.summary.hangDetected = true;
    const admitted = admitLane({
      lane: "e2e",
      receipts: [
        { file: "composer.json", parsed: validReceipt(catalog, nonce, src), malformed: false },
        {
          file: "queue.json",
          parsed: validReceipt(journeyById("queue-move-steering-to-followup")!, nonce, src),
          malformed: false,
        },
      ],
      runNonce: nonce,
      source: src,
      sourceUnchanged: true,
      ownedRuns: [hung],
    });
    expect(admitted.status).not.toBe("pass");
    expect(admitted.reasons.some((reason) => reason.code === "hang")).toBe(true);
    expect(admitted.reasons.some((reason) => reason.code === "missing-summary")).toBe(false);
  });

  test("incomplete or zero-execution summaries cannot pass", () => {
    const incomplete = ownedRun("e2e");
    incomplete.summary.incomplete = true;
    const zero = ownedRun("e2e");
    zero.summary.executedTests = 0;
    expect(
      admitLane({
        lane: "e2e",
        receipts: [
          { file: "composer.json", parsed: validReceipt(catalog, nonce, src), malformed: false },
          {
            file: "queue.json",
            parsed: validReceipt(journeyById("queue-move-steering-to-followup")!, nonce, src),
            malformed: false,
          },
        ],
        runNonce: nonce,
        source: src,
        sourceUnchanged: true,
        ownedRuns: [incomplete],
      }).reasons.some((reason) => reason.code === "incomplete-summary"),
    ).toBe(true);
    expect(
      admitLane({
        lane: "e2e",
        receipts: [
          { file: "composer.json", parsed: validReceipt(catalog, nonce, src), malformed: false },
          {
            file: "queue.json",
            parsed: validReceipt(journeyById("queue-move-steering-to-followup")!, nonce, src),
            malformed: false,
          },
        ],
        runNonce: nonce,
        source: src,
        sourceUnchanged: true,
        ownedRuns: [zero],
      }).reasons.some((reason) => reason.code === "zero-execution"),
    ).toBe(true);
  });

  test("duplicate journey receipts cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    const admitted = admitLane({
      lane: "e2e",
      receipts: [
        { file: "a.json", parsed: receipt, malformed: false },
        { file: "b.json", parsed: receipt, malformed: false },
        {
          file: "queue.json",
          parsed: validReceipt(journeyById("queue-move-steering-to-followup")!, nonce, src),
          malformed: false,
        },
      ],
      runNonce: nonce,
      source: src,
      sourceUnchanged: true,
      ownedRuns: [ownedRun("e2e")],
    });
    expect(admitted.status).toBe("fail");
    expect(admitted.reasons.some((reason) => reason.code === "duplicate")).toBe(true);
  });

  test("non-pass required assertion cannot pass", () => {
    for (const status of ["fail", "unknown", "passed"]) {
      const receipt = validReceipt(catalog, nonce, src);
      receipt.assertions[0]!.status = status;
      const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
      expect(result.status).not.toBe("pass");
      expect(result.reasons.some((reason) => reason.code.startsWith("assertion-"))).toBe(true);
    }
  });

  test("dispatched-unconfirmed record needs a later confirming record", () => {
    const unconfirmed = (receipt: ReturnType<typeof validReceipt>, index: number) => {
      (receipt.steps.records[index] as Record<string, unknown>).detail = "dispatched-unconfirmed";
    };
    const dangling = validReceipt(catalog, nonce, src);
    unconfirmed(dangling, dangling.steps.records.length - 1);
    const rejected = admitReceipt(dangling, {
      catalog,
      runNonce: nonce,
      source: src,
      testBundleSha256: TEST_BUNDLE,
    });
    expect(rejected.status).toBe("fail");
    expect(rejected.reasons.some((reason) => reason.code === "dispatch-unconfirmed")).toBe(true);

    expect(catalog.requestedStepIds.length).toBeGreaterThan(1);
    const confirmed = validReceipt(catalog, nonce, src);
    unconfirmed(confirmed, 0);
    expect(
      admitReceipt(confirmed, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE }).status,
    ).toBe("pass");
  });

  test("omitted required assertion cannot pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    receipt.assertions = [];
    const result = admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE });
    expect(result.status).toBe("fail");
    expect(result.reasons.some((reason) => reason.code === "assertion-missing")).toBe(true);
  });

  test("valid bound receipt can pass", () => {
    const receipt = validReceipt(catalog, nonce, src);
    expect(
      admitReceipt(receipt, { catalog, runNonce: nonce, source: src, testBundleSha256: TEST_BUNDLE }).status,
    ).toBe("pass");
  });

  test("merge prefers fail then unknown", () => {
    expect(mergeStatus([])).toBe("fail");
    expect(mergeStatus(["pass", "fail", "unknown"])).toBe("fail");
    expect(mergeStatus(["pass", "unknown"])).toBe("unknown");
    expect(mergeStatus(["pass", "pass"])).toBe("pass");
  });
});

describe("qa-verify source bytes", () => {
  test("missing required app source fails closed", () => {
    const fixture = mkdtempSync(join(tmpdir(), "oppi-qa-fingerprint-missing-"));
    expect(() => fingerprintSource(fixture)).toThrow(QAVerifyError);
  });

  test("app and shared source mutations change the content hash", () => {
    const root = join(import.meta.dir, "..", "..", "..");
    const fixture = mkdtempSync(join(tmpdir(), "oppi-qa-fingerprint-app-"));
    symlinkSync(join(root, ".git"), join(fixture, ".git"));
    for (const path of REQUIRED_SOURCE_DIRS) {
      mkdirSync(join(fixture, path), { recursive: true });
      writeFileSync(join(fixture, path, ".keep"), `dir ${path}\n`);
    }
    for (const path of REQUIRED_SOURCE_FILES) {
      const full = join(fixture, path);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, `placeholder ${path}\n`);
    }
    for (const extra of [...SOURCE_EXTRA_FILES, "clients/apple/scripts/tsconfig.json"]) {
      const full = join(fixture, extra);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, `extra ${extra}\n`);
    }
    const sharedPath = "clients/apple/Shared/Auth/Trust.swift";
    mkdirSync(dirname(join(fixture, sharedPath)), { recursive: true });
    writeFileSync(join(fixture, sharedPath), "// shared source\n");
    for (const path of ["clients/apple/Oppi/App/OppiApp.swift", sharedPath]) {
      const before = fingerprintSource(fixture);
      expect(before.files.some((file) => file.path === path)).toBe(true);
      writeFileSync(join(fixture, path), `// changed ${path}\n`);
      const after = fingerprintSource(fixture);
      expect(after.contentHash).not.toBe(before.contentHash);
    }
  });

  test("embedded extension, xcconfig, server tsconfig, e2e and wrapper helper mutations change the hash", () => {
    const root = join(import.meta.dir, "..", "..", "..");
    const fixture = mkdtempSync(join(tmpdir(), "oppi-qa-fingerprint-build-inputs-"));
    symlinkSync(join(root, ".git"), join(fixture, ".git"));
    for (const path of REQUIRED_SOURCE_DIRS) {
      mkdirSync(join(fixture, path), { recursive: true });
    }
    for (const path of [...REQUIRED_SOURCE_FILES, ...SOURCE_EXTRA_FILES]) {
      const full = join(fixture, path);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, `placeholder ${path}\n`);
    }
    const treeProbes = [
      "clients/apple/OppiActivityExtension",
      "clients/apple/OppiControlWidget",
      "clients/apple/OppiShareExtension",
      "clients/apple/OppiAssetDownloader",
      "server/extensions",
      "server/e2e",
    ].map((tree) => {
      expect(SOURCE_TREES).toContain(tree as (typeof SOURCE_TREES)[number]);
      const path = `${tree}/Probe.txt`;
      writeFileSync(join(fixture, path), "probe\n");
      return path;
    });
    const fileProbes = [
      "clients/apple/Base.xcconfig",
      "server/tsconfig.json",
      "server/scripts/e2e-clean.mjs",
      "server/scripts/e2e-gen-invite.mjs",
      "server/scripts/e2e-precreate-pair.mjs",
    ];
    for (const path of [...treeProbes, ...fileProbes]) {
      const before = fingerprintSource(fixture);
      expect(before.files.some((file) => file.path === path)).toBe(true);
      writeFileSync(join(fixture, path), `changed ${path}\n`);
      expect(fingerprintSource(fixture).contentHash).not.toBe(before.contentHash);
    }
  });
});

describe("qa-verify owned sim-pool binding", () => {
  test("unique Artifact path is required", () => {
    expect(uniqueArtifactPath("Artifact: /tmp/a.summary.json\n")).toBe("/tmp/a.summary.json");
    expect(
      uniqueArtifactPath("Artifact: /tmp/a.summary.json\n[sim-pool] Artifact: /tmp/a.summary.json\n"),
    ).toBe("/tmp/a.summary.json");
    expect(
      uniqueArtifactPath("Artifact: /tmp/a.summary.json\nArtifact: /tmp/b.summary.json\n"),
    ).toBeUndefined();
    expect(uniqueArtifactPath("no artifact")).toBeUndefined();
  });

  test("zero executed tests parse as zero", () => {
    expect(parseXcodeTestExecution("Executed 0 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds")).toEqual(
      { executed: 0, skipped: 0 },
    );
    expect(
      parseXcodeTestExecution("\t Executed 2 tests, with 0 failures (0 unexpected) in 44.221 (44.224) seconds"),
    ).toEqual({ executed: 2, skipped: 0 });
    expect(
      parseXcodeTestExecution("\t Executed 2 tests, with 1 failure (0 unexpected) in 45.238 (45.240) seconds"),
    ).toEqual({ executed: 2, skipped: 0 });
    for (const line of [
      "Executed 8 tests, with 0 failures (1 skipped)",
      "Executed 8 tests, with 1 test skipped and 0 failures (0 unexpected)",
      "Executed 8 tests, with 0 failures (0 unexpected), 1 test skipped",
    ]) {
      expect(parseXcodeTestExecution(line)).toEqual({ executed: 8, skipped: 1 });
    }
    expect(parseXcodeTestExecution("Executed 8 tests, with 0 failures (skipped unknown)")).toBeNull();
  });

  test("timeout/cancel/non-quiescent stop cannot start the next lane", () => {
    expect(canStartNextLane({ timedOut: true, stop: { quiescent: true } })).toBe(false);
    expect(canStartNextLane({ canceled: true, stop: { quiescent: true } })).toBe(false);
    expect(canStartNextLane({ stop: { quiescent: false } })).toBe(false);
    expect(canStartNextLane({ timedOut: false, canceled: false, stop: { quiescent: true } })).toBe(true);
  });

  test("non-zero xcodegen exit cannot start a lane", () => {
    expect(canStartNextLane({ code: 1, stop: { quiescent: true } })).toBe(false);
    expect(canStartNextLane({ code: null, stop: { quiescent: true } })).toBe(false);
    expect(canStartNextLane({ code: 0, stop: { quiescent: true } })).toBe(true);
  });
});

describe("qa-verify CLI", () => {
  test("help and journeys json is one object", () => {
    const help = runCli(["help"]);
    expect(help.status).toBe(0);
    expect(help.stdout).toContain("qa-verify.ts run");
    const listed = runCli(["journeys", "--json"]);
    expect(listed.status).toBe(0);
    expect(listed.stdout.trim().startsWith("{")).toBe(true);
    expect(listed.stdout.trim().endsWith("}")).toBe(true);
    const payload = JSON.parse(listed.stdout);
    expect(payload.schema).toBe(PARENT_SCHEMA);
    expect(payload.journeys).toHaveLength(JOURNEYS.length);
    expect(JSON.parse(listed.stdout)).toEqual(payload);
  });

  test("fingerprint json binds sha, content hash, and app source", () => {
    const result = runCli(["fingerprint", "--json"]);
    expect(result.status).toBe(0);
    const payload = JSON.parse(result.stdout);
    expect(payload.sha).toMatch(/^[0-9a-f]{40}$/);
    expect(payload.contentHash).toMatch(/^[0-9a-f]{64}$/);
    expect(Array.isArray(payload.files)).toBe(true);
    expect(payload.files.some((file: { path: string }) => file.path.endsWith("OppiApp.swift"))).toBe(true);
    expect(payload.fileCount).toBeGreaterThan(10);
  });

  test("piped fingerprint drains the entire JSON object", () => {
    const result = spawnSync("bash", ["-o", "pipefail", "-c",
      `"$QA_BUN" "$QA_CLI" fingerprint --json | "$QA_BUN" -e 'const text = await Bun.stdin.text(); const value = JSON.parse(text); console.log(JSON.stringify({bytes: text.length, files: value.fileCount}));'`,
    ], {
      encoding: "utf8",
      timeout: 10_000,
      env: { ...process.env, QA_BUN: process.execPath, QA_CLI: cli },
    });
    expect(result.status, result.stderr).toBe(0);
    const payload = JSON.parse(result.stdout);
    expect(payload.bytes).toBeGreaterThan(65_536);
    expect(payload.files).toBeGreaterThan(10);
  });

  test("json error for unknown command is one object", () => {
    const result = runCli(["nope", "--json"]);
    expect(result.status).toBe(2);
    const payload = JSON.parse(result.stdout);
    expect(payload.error).toBe("qa_verify_error");
    expect(payload.exit_code).toBe(2);
    expect(result.stdout.trim().startsWith("{")).toBe(true);
  });

  test("run without lane is a json usage error", () => {
    const result = runCli(["run", "--json"]);
    expect(result.status).toBe(2);
    const payload = JSON.parse(result.stdout);
    expect(payload.message).toContain("--lane");
  });

  test("fingerprint git failure is one json error", () => {
    const result = runCli(["fingerprint", "--json"], {
      ...process.env,
      GIT_DIR: join(tmpdir(), "qa-verify-not-a-git-dir"),
    });
    expect(result.status).toBe(2);
    const payload = JSON.parse(result.stdout);
    expect(payload.error).toBe("qa_verify_error");
    expect(payload.message.length).toBeGreaterThan(0);
    expect(result.stdout.trim().startsWith("{")).toBe(true);
  });

  test("missing workflow is a json error and does not start e2e", () => {
    const home = mkdtempSync(join(tmpdir(), "qa-verify-home-"));
    const result = runCli(["run", "--lane", "e2e", "--json"], { ...process.env, HOME: home });
    expect(result.status).toBe(8);
    const payload = JSON.parse(result.stdout);
    expect(payload.error).toBe("qa_verify_error");
    expect(payload.message).toContain("oppi-workflow.sh");
    expect(result.stdout.trim().startsWith("{")).toBe(true);
  });
});
