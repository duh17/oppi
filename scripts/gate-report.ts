#!/usr/bin/env bun
// What a gate lane reports besides its exit code, shared by scripts/batch-gate.ts, the pre-push hook,
// and clients/apple/scripts/{unit,ui}-shards.ts:
//
// - the rerun ledger `$(git rev-parse --git-common-dir)/oppi/test-flakes.jsonl`: one row per test a
//   lane reran, `{id, lane, profile, head, at, outcome}`, outcome `flaky` (passed on the rerun, so the
//   lane passed) or `failed` (failed again);
// - the red-lane ledger `$(git rev-parse --git-common-dir)/oppi/land-queue/red-lanes.jsonl`: one row per
//   lane that failed in a land-queue batch, with a cause guessed from the lane's output
//   (`cause_guess`), left for a person or the night triage to confirm (`cause_confirmed`);
// - lane time budgets (dev/testing/lane-budgets.json): over budget is a warning, never a failure.
//
//   bun scripts/gate-report.ts budget <lane> <wall seconds>
//   bun scripts/gate-report.ts red-lane --lane <lane> --exit <code> [--seconds N] [--log <file>]
//
// The CLI is for the pre-push hook's bash lanes; `red-lane` records nothing outside a land-queue
// batch (LAND_QUEUE_BATCH unset), so a developer's own push never writes the queue's ledger.
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
export const BUDGETS_PATH = join(repoRoot, "dev", "testing", "lane-budgets.json");
const BUDGETS_DOC = "dev/testing/lane-budgets.json";

function git(cwd: string, args: string[]): string | undefined {
  const run = spawnSync("git", args, { cwd, encoding: "utf8" });
  return run.status === 0 ? run.stdout.trim() : undefined;
}

/** `<git common dir>/oppi`: shared by every worktree, so a row outlives the batch worktree that wrote it. */
export function oppiDir(cwd: string): string {
  const common = git(cwd, ["rev-parse", "--git-common-dir"]);
  if (!common) throw new Error(`not a git checkout: ${cwd}`);
  return join(resolve(cwd, common), "oppi");
}

export const headOf = (cwd: string): string => git(cwd, ["rev-parse", "HEAD"]) ?? "unknown";

const ANSI = /\x1b\[[0-9;]*m/g;

// ── Rerun ledger ──

/** `flaky`: failed, then passed on the lane's one rerun; `failed`: failed the rerun too. */
export type RerunOutcome = "flaky" | "failed";
export type FlakeRow = { id: string; lane: string; profile: string | null; head: string; at: string; outcome: RerunOutcome };

function flakesPath(cwd: string): string {
  return join(oppiDir(cwd), "test-flakes.jsonl");
}

/** Rows written before lanes and outcomes were recorded came from the unit shards' pass-on-rerun. */
export function parseFlakes(text: string): FlakeRow[] {
  return text.split("\n").filter(Boolean).flatMap((line) => {
    try {
      return [{ lane: "unit-full", profile: "iphone", outcome: "flaky" as const, ...(JSON.parse(line) as Partial<FlakeRow>) } as FlakeRow];
    } catch {
      return [];
    }
  });
}

function readFlakes(cwd: string): FlakeRow[] {
  const path = flakesPath(cwd);
  return existsSync(path) ? parseFlakes(readFileSync(path, "utf8")) : [];
}

const isCheckout = (cwd: string) => git(cwd, ["rev-parse", "--git-common-dir"]) !== undefined;

/** Gates (distinct heads) in which the test passed only on its rerun. */
export function flakedGates(rows: FlakeRow[], id: string): number {
  return new Set(rows.filter((row) => row.id === id && row.outcome === "flaky").map((row) => row.head)).size;
}

/** Append one rerun outcome at the checkout's HEAD; returns the gates this test has flaked in. */
export function recordRerun(cwd: string, row: Pick<FlakeRow, "id" | "lane" | "profile" | "outcome">, now = new Date()): number {
  const dir = oppiDir(cwd);
  mkdirSync(dir, { recursive: true });
  const full: FlakeRow = { id: row.id, lane: row.lane, profile: row.profile, head: headOf(cwd), at: now.toISOString(), outcome: row.outcome };
  appendFileSync(join(dir, "test-flakes.jsonl"), `${JSON.stringify(full)}\n`);
  return flakedGates(readFlakes(cwd), row.id);
}

/** Tests that passed only on a rerun at `head`, one per test and lane: every lane of one gate writes the same head. */
export function flakesAt(rows: FlakeRow[], head: string): FlakeRow[] {
  const seen = new Map<string, FlakeRow>();
  for (const row of rows) {
    if (row.head === head && row.outcome === "flaky") seen.set(`${row.lane}\0${row.id}`, row);
  }
  return [...seen.values()];
}

/** A directory outside any git checkout has no ledger, so no flakes. */
export const flakesAtHead = (cwd: string): FlakeRow[] => (isCheckout(cwd) ? flakesAt(readFlakes(cwd), headOf(cwd)) : []);

/** The summary line that keeps a rerun's pass from hiding the flake. */
export function hiddenFlakesLine(rows: Pick<FlakeRow, "id" | "lane">[]): string {
  if (rows.length === 0) return "no flakes hidden by rerun";
  return `${rows.length} flake${rows.length === 1 ? "" : "s"} hidden by rerun: ${rows.map((row) => `${row.id} (${row.lane})`).join(", ")}`;
}

// ── XCTest results in a sim-pool log ──

/** `<Bundle>/<Class>/<test>` of every XCTest case the log reports failed, in log order. */
export function failedXCTestCases(logText: string): string[] {
  const ids = [...logText.matchAll(/^Test Case '-\[(\w+)\.(\w+) (\w+)\]' failed \(/gm)].map((match) => `${match[1]}/${match[2]}/${match[3]}`);
  return [...new Set(ids)];
}

/** `<Bundle>/<Class>/<test>` of every XCTest case the log reports passed or skipped. */
export function passedXCTestCases(logText: string): Set<string> {
  return new Set([...logText.matchAll(/^Test Case '-\[(\w+)\.(\w+) (\w+)\]' (?:passed|skipped) \(/gm)].map((match) => `${match[1]}/${match[2]}/${match[3]}`));
}

/** Seconds of each XCTest case that finished, passed or failed. */
export function xctestCaseSeconds(logText: string): number[] {
  return [...logText.matchAll(/^Test Case '-\[\w+\.\w+ \w+\]' (?:passed|failed) \(([0-9.]+) seconds\)/gm)].map((match) => Number(match[1]));
}

/** The run reached XCTest's top-level result, so every selected test ran (a crashed runner never prints it). */
export function xctestRunFinished(logText: string): boolean {
  return /^Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at .+\r?\n[ \t]+Executed [0-9]+ tests?/m.test(logText);
}

/** UI and E2E tests cost 30-250 s each: a run with more failures than this is broken, not flaky. */
export const XCTEST_RERUN_LIMIT = 5;

/** The failed tests of a finished XCTest run to rerun once, or why there is no rerun. */
export function xctestRerun(logText: string, limit = XCTEST_RERUN_LIMIT): { ids: string[] } | { reason: string } {
  if (!xctestRunFinished(logText)) return { reason: "the run did not reach its test summary, so some tests may not have run" };
  const ids = failedXCTestCases(logText);
  if (ids.length === 0) return { reason: "no test case failed (the run failed outside a test)" };
  if (ids.length > limit) return { reason: `${ids.length} failed tests, more than the rerun limit of ${limit}` };
  return { ids };
}

/** The log a sim-pool summary artifact names, or "" when it cannot be read. */
export function logOfSummary(summary: string | undefined): string {
  if (!summary || !existsSync(summary)) return "";
  try {
    const log = JSON.parse(readFileSync(summary, "utf8")).log_path as string | undefined;
    return log && existsSync(log) ? readFileSync(log, "utf8") : "";
  } catch {
    return "";
  }
}

/** The last `Artifact: <summary>` a sim-pool run printed in `output`. */
export const lastArtifact = (output: string): string | undefined => [...output.matchAll(/^(?:\[sim-pool\] )?Artifact: (.+)$/gm)].at(-1)?.[1];

// ── Zero-test runs ──

/** Named selectors, at most `cap` of them. */
export function listSelectors(selectors: string[], cap = 5): string {
  const shown = selectors.slice(0, cap).join(", ");
  return selectors.length > cap ? `${shown} (+${selectors.length - cap} more)` : shown;
}

/**
 * The line a lane prints when it ran zero tests for the selectors it was given. `matchedNothing`:
 * the run finished (exit 0, or a test summary that counted zero), so the selector itself matched
 * no test; otherwise the run stopped before any test, and the lane's other output says why.
 */
export function zeroTestLine(selectors: string[], matchedNothing: boolean): string {
  return `zero tests ran for ${listSelectors(selectors)}${matchedNothing ? ": no test matches the selector (see dev/testing/apple.md#gotchas)" : ""}`;
}

// ── Failing tests and the cause of a red lane ──

/**
 * Test ids a lane's output names as failing: the shard runners' `FAILED <id>` lines (the tests that
 * stayed red after their rerun) and Vitest `FAIL <file> > <test>` lines. XCTest case lines are not
 * read here: a shard's output tail repeats first-run failures that its rerun may have cleared, so
 * XCTest failures come from a run's own sim-pool log (failedXCTestCases).
 */
export function failedTestsInOutput(output: string): string[] {
  const text = output.replace(ANSI, "");
  const ids = [
    ...[...text.matchAll(/^\[(?:unit|ui)-shards\] FAILED (\S+)$/gm)].map((match) => match[1]),
    ...[...text.matchAll(/^ FAIL +(\S+\.test\.ts(?: > .+?)?)\s*$/gm)].map((match) => `server/${match[1]}`),
  ];
  return [...new Set(ids)];
}

export type Cause = "selector" | "compile" | "test-failure" | "infra" | "quarantine" | "unknown";

/** First match wins: a selector or compile problem means the tests themselves never ran. */
const CAUSE_SIGNALS: [Cause, RegExp][] = [
  ["selector", /no test matches the selector|unknown --test|unknown profile|declares no (?:type|test)|ambiguous --test|No test files? found/],
  ["compile", /\.swift:[0-9]+:[0-9]+: error:|Compiler\/linker errors|\*\* (?:TEST )?BUILD FAILED \*\*|error TS[0-9]+:|\] build failed \(exit/],
  ["quarantine", /quarantine (?:expired|entry)/],
  ["infra", /busy or quarantined|slots? \(slots [^)]*\) busy|hang detected|stalled before opening|INFRASTRUCTURE|[Uu]nable to boot|failed to boot|could not start|Test runner never began|Lost connection to the test|EADDRINUSE|server (?:failed|did not start)|no tests ran/],
  ["test-failure", /^Test Case '.+' failed|^✘ Test |^ FAIL |test failures in|Issue recorded/m],
];

/** A guess at why a lane failed, from its output: the cause class and the line that suggested it. */
export function guessCause(output: string, failedTests: string[]): { cause: Cause; evidence: string | null } {
  const lines = output.replace(ANSI, "").split("\n");
  for (const [cause, signal] of CAUSE_SIGNALS) {
    // A named failing test outranks infrastructure noise (a retried hang, one busy shard).
    if (cause === "infra" && failedTests.length > 0) return { cause: "test-failure", evidence: failedTests[0] };
    const line = lines.find((text) => signal.test(text));
    if (line !== undefined) return { cause, evidence: line.trim().slice(0, 240) };
  }
  return failedTests.length > 0 ? { cause: "test-failure", evidence: failedTests[0] } : { cause: "unknown", evidence: null };
}

export type RedLane = {
  at: string;
  batch: string;
  branches: string[];
  head: string;
  lane: string;
  profile: string | null;
  exit: number;
  seconds: number | null;
  tests: string[];
  /** Guessed from the lane's output; see cause_evidence. Not a finding. */
  cause_guess: Cause;
  cause_evidence: string | null;
  /** Set by a person or the night triage once the cause is known: one of the Cause classes, or a short note. */
  cause_confirmed: null;
};

export const redLanesPath = (cwd: string): string => join(oppiDir(cwd), "land-queue", "red-lanes.jsonl");

/**
 * Append one red lane of the current land-queue batch (LAND_QUEUE_BATCH, LAND_QUEUE_BRANCHES), with a
 * cause guessed from `output`. Returns the ledger path, or undefined outside a batch.
 */
export function recordRedLane(
  cwd: string,
  lane: { lane: string; profile: string | null; exit: number; seconds: number | null; tests: string[]; output: string },
  env: NodeJS.ProcessEnv = process.env,
  now = new Date(),
): { path: string | undefined; cause: Cause; evidence: string | null } {
  const { cause, evidence } = guessCause(lane.output, lane.tests);
  const batch = env.LAND_QUEUE_BATCH;
  if (!batch) return { path: undefined, cause, evidence };
  const record: RedLane = {
    at: now.toISOString(),
    batch,
    branches: (env.LAND_QUEUE_BRANCHES ?? "").split(",").filter(Boolean),
    head: headOf(cwd),
    lane: lane.lane,
    profile: lane.profile,
    exit: lane.exit,
    seconds: lane.seconds,
    tests: lane.tests,
    cause_guess: cause,
    cause_evidence: evidence,
    cause_confirmed: null,
  };
  const path = redLanesPath(cwd);
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, `${JSON.stringify(record)}\n`);
  return { path, cause, evidence };
}

/** The summary line for a recorded (or, outside a batch, unrecorded) red lane. */
export function redLaneLine(lane: string, result: { path: string | undefined; cause: Cause; evidence: string | null }): string {
  const guess = `cause guess ${result.cause}${result.evidence ? ` (${result.evidence})` : ""}`;
  return `red lane ${lane}: ${guess}; ${result.path ? `recorded in ${result.path}` : "not recorded (no LAND_QUEUE_BATCH)"}`;
}

// ── Lane budgets ──

/** `longest-shard`: the slowest shard's seconds; `median-test`: the median seconds of one test; `wall`: the lane's wall time. */
export type Budget = { measure: "longest-shard" | "median-test" | "wall"; seconds: number };
export type Measured = { wall: number; longestShard?: number; medianTest?: number; tests?: number };

/**
 * The budgets in `path`, and a WARNING line for each entry (or the whole file) that cannot be read.
 * Budgets only ever warn: a broken file must not fail the lane that reads it after its tests ran.
 */
export function loadBudgets(path = BUDGETS_PATH): { budgets: Record<string, Budget>; warnings: string[] } {
  if (!existsSync(path)) return { budgets: {}, warnings: [] };
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    return { budgets: {}, warnings: [`WARNING lane budgets unreadable, no lane has a budget: ${path}: ${error instanceof Error ? error.message : String(error)}`] };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { budgets: {}, warnings: [`WARNING lane budgets unreadable, no lane has a budget: ${path} must be an object of lanes`] };
  }
  const budgets: Record<string, Budget> = {};
  const warnings: string[] = [];
  for (const [lane, value] of Object.entries(parsed)) {
    const budget = (value ?? {}) as Partial<Budget>;
    if (!["longest-shard", "median-test", "wall"].includes(budget.measure ?? "") || typeof budget.seconds !== "number" || budget.seconds <= 0) {
      warnings.push(`WARNING lane budget '${lane}' ignored: ${path} needs {"measure": "longest-shard"|"median-test"|"wall", "seconds": <positive number>}`);
      continue;
    }
    budgets[lane] = budget as Budget;
  }
  return { budgets, warnings };
}

export function median(values: number[]): number | undefined {
  if (values.length === 0) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

const seconds = (value: number) => `${Number(value.toFixed(1))}s`;

/** `budget <lane>: ...` against the lane's budget, and a warning line when over it. Never a failure. */
export function budgetVerdict(lane: string, measured: Measured, budgets: Record<string, Budget>): { line: string; warning?: string } {
  const budget = budgets[lane];
  const wall = `wall ${seconds(measured.wall)}`;
  if (!budget) return { line: `budget ${lane}: ${wall}, no budget` };
  const value = budget.measure === "wall" ? measured.wall : budget.measure === "longest-shard" ? measured.longestShard : measured.medianTest;
  const what = budget.measure === "wall" ? "wall" : budget.measure === "longest-shard" ? "longest shard" : "median test";
  const count = budget.measure === "median-test" && measured.tests !== undefined ? ` over ${measured.tests} test${measured.tests === 1 ? "" : "s"}` : "";
  if (value === undefined) return { line: `budget ${lane}: ${wall}; ${what} not measured (budget ${seconds(budget.seconds)})` };
  const against = budget.measure === "wall" ? "" : `, ${wall}`;
  const line = `budget ${lane}: ${what} ${seconds(value)} of ${seconds(budget.seconds)}${count}${against}`;
  if (value <= budget.seconds) return { line };
  return { line, warning: `WARNING ${lane} over budget: ${what} ${seconds(value)} > ${seconds(budget.seconds)}${count}; budgets live in ${BUDGETS_DOC}` };
}

// ── CLI for the pre-push hook ──

function option(argv: string[], flag: string): string | undefined {
  const at = argv.indexOf(flag);
  return at >= 0 ? argv[at + 1] : undefined;
}

function main(argv: string[]): number {
  const [command, ...rest] = argv;
  if (command === "budget" && rest.length === 2 && Number.isFinite(Number(rest[1]))) {
    const { budgets, warnings } = loadBudgets();
    for (const warning of warnings) console.log(`[${rest[0]}] ${warning}`);
    const verdict = budgetVerdict(rest[0], { wall: Number(rest[1]) }, budgets);
    console.log(`[${rest[0]}] ${verdict.line}`);
    if (verdict.warning) console.log(`[${rest[0]}] ${verdict.warning}`);
    return 0;
  }
  if (command === "red-lane" && option(rest, "--lane") && Number.isInteger(Number(option(rest, "--exit")))) {
    const lane = option(rest, "--lane")!;
    const log = option(rest, "--log");
    const output = log && existsSync(log) ? readFileSync(log, "utf8") : "";
    const secondsArg = option(rest, "--seconds");
    const result = recordRedLane(process.cwd(), {
      lane,
      profile: null,
      exit: Number(option(rest, "--exit")),
      seconds: secondsArg === undefined ? null : Number(secondsArg),
      tests: failedTestsInOutput(output),
      output,
    });
    console.log(`[${lane}] ${redLaneLine(lane, result)}`);
    return 0;
  }
  console.error("usage: gate-report.ts budget <lane> <wall seconds> | red-lane --lane <lane> --exit <code> [--seconds N] [--log <file>]");
  return 2;
}

if (import.meta.main) {
  process.exit(main(process.argv.slice(2)));
}
