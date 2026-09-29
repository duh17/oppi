#!/usr/bin/env bun
import { randomUUID } from "node:crypto";
import { closeSync, existsSync, openSync } from "node:fs";
import { join } from "node:path";
import {
  CommandSession,
  type CompletionResult,
} from "./sim-pool-supervise";
import {
  JOURNEYS,
  PARENT_SCHEMA,
  QAVerifyError,
  RECEIPT_SCHEMA,
  admitLane,
  appleDir,
  assertionViews,
  canStartNextLane,
  createRunDirectory,
  e2eWrapperScript,
  ensureDir,
  executedStepViews,
  fingerprintSource,
  isoNow,
  journeysForLane,
  loadReceiptFiles,
  ownedRunFromCommandLogs,
  publicErrorPayload,
  repoRoot,
  workflowScript,
  writeJson,
  type OwnedLaneRun,
  type QAStatus,
  type SourceFingerprint,
} from "./qa-verify-lib";

const USAGE = `Usage:
  bun clients/apple/scripts/qa-verify.ts journeys [--json]
  bun clients/apple/scripts/qa-verify.ts fingerprint [--json]
  bun clients/apple/scripts/qa-verify.ts run --lane e2e|negatives|all [--json] [--out DIR] [--native]

Parent-facing Oppi iOS deterministic QA core. Reuses sim-pool and the documented
paired E2E wrapper. Always sets OPPI_SIM_POOL_HANG_RETRIES=0. Does not compare
drivers or call hosted models.

Examples:
  bun clients/apple/scripts/qa-verify.ts journeys --json
  bun clients/apple/scripts/qa-verify.ts run --lane negatives --json
  bun clients/apple/scripts/qa-verify.ts run --lane e2e --native --json
`;

const XCODEGEN_DEADLINE_MS = 90_000;
const NEGATIVES_DEADLINE_MS = 12 * 60_000;
const E2E_DEADLINE_MS = 18 * 60_000;

function hasFlag(flag: string): boolean {
  return process.argv.includes(flag);
}

function argValue(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

function emitError(error: unknown, jsonMode: boolean): void {
  const payload = publicErrorPayload(error);
  console.error(payload.message);
  if (payload.hint) console.error(payload.hint);
  if (jsonMode) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  }
  process.exitCode = payload.exit_code;
}

function emit(jsonMode: boolean, humanTitle: string, payload: unknown, exitCode = 0): void {
  if (jsonMode) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
  } else {
    console.log(humanTitle);
    console.log(typeof payload === "string" ? payload : JSON.stringify(payload, null, 2));
  }
  // Natural exit lets a slow pipe consumer drain the complete JSON receipt.
  process.exitCode = exitCode;
}

function parentExit(status: QAStatus): number {
  if (status === "pass") return 0;
  if (status === "unknown") return 4;
  return 1;
}

function journeysPayload() {
  return {
    schema: PARENT_SCHEMA,
    summary: "Named deterministic QA journeys",
    fetched_at: isoNow(),
    journeys: JOURNEYS.map((journey) => ({
      id: journey.id,
      lane: journey.lane,
      subject: journey.subject,
      requestedStepIds: journey.requestedStepIds,
      requiredAssertionIds: journey.requiredAssertionIds,
      mockedBoundaries: journey.mockedBoundaries,
      terminalMirrorExercised: false,
      runtime: "oppi",
    })),
  };
}

async function runOwned(
  session: CommandSession,
  command: string,
  args: string[],
  options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
    stdoutPath: string;
    stderrPath: string;
    timeoutMs: number;
  },
): Promise<CompletionResult & { code: number }> {
  const stdoutFd = openSync(options.stdoutPath, "w");
  const stderrFd = openSync(options.stderrPath, "w");
  try {
    const completed = await session.run(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ["ignore", stdoutFd, stderrFd],
      timeoutMs: options.timeoutMs,
      firstSignal: "SIGTERM",
      termMs: 5_000,
      killMs: 2_000,
    });
    return completed;
  } finally {
    closeSync(stdoutFd);
    closeSync(stderrFd);
  }
}

function bindingEnv(params: {
  receiptDir: string;
  nonce: string;
  source: SourceFingerprint;
  lane: "e2e" | "negatives" | "all";
}): NodeJS.ProcessEnv {
  const expected = journeysForLane(params.lane).map((journey) => journey.id).join(",");
  return {
    ...process.env,
    OPPI_ROOT: repoRoot(),
    OPPI_SIM_POOL_HANG_RETRIES: "0",
    OPPI_QA_RECEIPT_DIR: params.receiptDir,
    TEST_RUNNER_OPPI_QA_RECEIPT_DIR: params.receiptDir,
    OPPI_QA_RUN_NONCE: params.nonce,
    TEST_RUNNER_OPPI_QA_RUN_NONCE: params.nonce,
    OPPI_QA_SOURCE_SHA: params.source.sha,
    TEST_RUNNER_OPPI_QA_SOURCE_SHA: params.source.sha,
    OPPI_QA_SOURCE_HASH: params.source.contentHash,
    TEST_RUNNER_OPPI_QA_SOURCE_HASH: params.source.contentHash,
    OPPI_QA_EXPECTED_JOURNEYS: expected,
    TEST_RUNNER_OPPI_QA_EXPECTED_JOURNEYS: expected,
  };
}

function compactSource(source: SourceFingerprint) {
  return {
    sha: source.sha,
    branch: source.branch,
    contentHash: source.contentHash,
    fileCount: source.fileCount,
    wrappers: source.wrappers,
  };
}

function bindOwnedLane(input: {
  lane: "negatives" | "e2e";
  stdoutPath: string;
  stderrPath: string;
  ownedRuns: OwnedLaneRun[];
  bindErrors: string[];
}): void {
  try {
    input.ownedRuns.push(
      ownedRunFromCommandLogs({
        lane: input.lane,
        stdoutPath: input.stdoutPath,
        stderrPath: input.stderrPath,
        appleDir: appleDir(),
      }),
    );
  } catch (error) {
    input.bindErrors.push(error instanceof Error ? error.message : String(error));
  }
}

async function runLane(
  lane: "e2e" | "negatives" | "all",
  native: boolean,
  jsonMode: boolean,
  out?: string,
): Promise<void> {
  if (lane === "e2e" || lane === "all") {
    const workflow = workflowScript();
    if (!existsSync(workflow) || !existsSync(e2eWrapperScript())) {
      throw new QAVerifyError(
        `Missing ${workflow} or ${e2eWrapperScript()}`,
        "Shared apple/e2e.sh is not in this worktree; reuse the skill wrapper with OPPI_ROOT. Do not invent a second server lifecycle.",
        8,
      );
    }
  }
  const source = fingerprintSource();
  const nonce = randomUUID();
  const outDir = createRunDirectory(out, nonce);
  const receiptDir = ensureDir(join(outDir, "receipts"));
  const logDir = ensureDir(join(outDir, "logs"));
  writeJson(join(outDir, "fingerprint.json"), source);
  writeJson(join(outDir, "predeclared-inputs.json"), {
    lane,
    native,
    runNonce: nonce,
    journeys: journeysForLane(lane),
    hangRetries: 0,
    terminalMirrorExercised: false,
    runtime: "oppi",
  });

  const session = new CommandSession();
  session.installHandlers();
  const commands: string[][] = [];
  const exitCodes: number[] = [];
  const ownedRuns: OwnedLaneRun[] = [];
  const bindErrors: string[] = [];
  let timedOut = false;
  let stopOwned = true;
  const startedAtMs = Date.now();
  try {
    console.error(`qa-verify run ${lane} nonce=${nonce}`);
    const env = bindingEnv({ receiptDir, nonce, source, lane });
    const xcodegen = await runOwned(session, "xcodegen", ["generate"], {
      cwd: appleDir(),
      env,
      stdoutPath: join(logDir, "xcodegen.stdout.log"),
      stderrPath: join(logDir, "xcodegen.stderr.log"),
      timeoutMs: XCODEGEN_DEADLINE_MS,
    });
    commands.push(["xcodegen", "generate"]);
    exitCodes.push(xcodegen.code);
    if (xcodegen.timedOut) timedOut = true;
    stopOwned = stopOwned && xcodegen.stop.quiescent;
    let continueLanes = canStartNextLane({
      timedOut: xcodegen.timedOut,
      canceled: session.canceled,
      code: xcodegen.code,
      stop: xcodegen.stop,
    });
    if (xcodegen.code !== 0 || !continueLanes) {
      console.error("xcodegen generate failed or did not stop cleanly");
    }

    if (continueLanes && (lane === "negatives" || lane === "all")) {
      const args = [
        join(appleDir(), "scripts/sim-pool.sh"),
        "run",
        "--",
        "xcodebuild",
        "-project",
        "Oppi.xcodeproj",
        "-scheme",
        "Oppi",
        "test",
        "-only-testing:OppiUITests/QAVerificationNegativeUITests",
      ];
      commands.push(["bash", ...args]);
      const negativesStdout = join(logDir, "negatives.stdout.log");
      const negativesStderr = join(logDir, "negatives.stderr.log");
      const result = await runOwned(session, "bash", args, {
        cwd: appleDir(),
        env,
        stdoutPath: negativesStdout,
        stderrPath: negativesStderr,
        timeoutMs: NEGATIVES_DEADLINE_MS,
      });
      exitCodes.push(result.code);
      if (result.timedOut) timedOut = true;
      stopOwned = stopOwned && result.stop.quiescent;
      bindOwnedLane({
        lane: "negatives",
        stdoutPath: negativesStdout,
        stderrPath: negativesStderr,
        ownedRuns,
        bindErrors,
      });
      continueLanes = canStartNextLane({
        timedOut: result.timedOut,
        canceled: session.canceled,
        stop: result.stop,
      });
    }

    if (continueLanes && (lane === "e2e" || lane === "all")) {
      const workflow = workflowScript();
      const args = ["sim-test"];
      if (native) args.push("--native");
      args.push(
        "--only-testing",
        "OppiE2ETests/QAVerificationJourneysE2ETests",
        "--record-video=off",
      );
      commands.push([workflow, ...args]);
      const e2eStdout = join(logDir, "e2e.stdout.log");
      const e2eStderr = join(logDir, "e2e.stderr.log");
      const result = await runOwned(session, workflow, args, {
        cwd: repoRoot(),
        env: {
          ...env,
          E2E_ARTIFACT_DIR: join(outDir, "e2e"),
        },
        stdoutPath: e2eStdout,
        stderrPath: e2eStderr,
        timeoutMs: E2E_DEADLINE_MS,
      });
      exitCodes.push(result.code);
      if (result.timedOut) timedOut = true;
      stopOwned = stopOwned && result.stop.quiescent;
      bindOwnedLane({
        lane: "e2e",
        stdoutPath: e2eStdout,
        stderrPath: e2eStderr,
        ownedRuns,
        bindErrors,
      });
    }
  } finally {
    const disposed = await session.dispose();
    stopOwned = stopOwned && disposed.quiescent;
  }

  const after = fingerprintSource();
  const sourceUnchanged = after.contentHash === source.contentHash && after.sha === source.sha;
  const receipts = loadReceiptFiles(receiptDir);
  const admitted = admitLane({
    lane,
    receipts,
    runNonce: nonce,
    source,
    sourceUnchanged,
    ownedRuns,
    wrappers: source.wrappers,
  });
  let status: QAStatus = admitted.status;
  if (bindErrors.length > 0 && status === "pass") status = "fail";
  if (timedOut) status = status === "pass" ? "unknown" : status;
  if (!stopOwned) status = status === "pass" ? "unknown" : status;
  if (exitCodes.some((code) => code !== 0) && status === "pass") status = "fail";

  const parent = {
    schema: PARENT_SCHEMA,
    status,
    subject: `qa-verify ${lane}`,
    source: compactSource(source),
    sourceUnchanged,
    runNonce: nonce,
    receiptSchema: RECEIPT_SCHEMA,
    journeys: journeysForLane(lane).map((journey) => journey.id),
    admissions: admitted.admissions,
    reasons: [
      ...admitted.reasons,
      ...bindErrors.map((message) => ({ code: "owned-artifact", message })),
    ],
    steps: {
      requested: journeysForLane(lane).reduce((sum, journey) => sum + journey.requestedStepIds.length, 0),
      catalogDeclared: true,
      executed: executedStepViews(receipts),
    },
    assertions: assertionViews(receipts),
    timing: {
      wallMs: Date.now() - startedAtMs,
    },
    collector: {
      health: timedOut || !stopOwned ? "failed" : "ok",
      recording: "off",
      artifacts: [outDir, ...admitted.admissions.map((item) => item.file).filter(Boolean)],
      ownedRuns,
      timedOut,
      ownedProcessStopped: stopOwned,
    },
    mockedBoundaries: [
      ...new Set(journeysForLane(lane).flatMap((journey) => journey.mockedBoundaries)),
    ],
    runtime: "oppi",
    terminalMirrorExercised: false,
    commands,
    exitCodes,
    fetched_at: isoNow(),
    summary:
      status === "pass"
        ? "Declared journeys admitted"
        : status === "unknown"
          ? "Verification unknown"
          : "Verification failed",
  };
  writeJson(join(outDir, "parent.receipt.json"), parent);
  emit(jsonMode, `QA verification ${lane}`, parent, parentExit(status));
}

async function main(): Promise<void> {
  const command = process.argv[2];
  const jsonMode = hasFlag("--json");
  try {
    if (!command || command === "help" || command === "-h" || command === "--help") {
      process.stdout.write(USAGE);
      return;
    }
    switch (command) {
      case "journeys":
        emit(jsonMode, "Journeys", journeysPayload());
        break;
      case "fingerprint":
        emit(jsonMode, "Source fingerprint", fingerprintSource());
        break;
      case "run": {
        const lane = argValue("--lane");
        if (lane !== "e2e" && lane !== "negatives" && lane !== "all") {
          throw new QAVerifyError(
            "run requires --lane e2e|negatives|all",
            "This reduced slice has no compare or jev lane",
            2,
          );
        }
        await runLane(lane, hasFlag("--native"), jsonMode, argValue("--out"));
        break;
      }
      default:
        throw new QAVerifyError(`Unknown command ${command}`, USAGE.trim(), 2);
    }
  } catch (error) {
    emitError(error, jsonMode);
  }
}

void main();
