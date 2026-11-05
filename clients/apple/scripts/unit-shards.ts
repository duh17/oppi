#!/usr/bin/env bun
// Run the whole OppiUnitTests suite as N parallel shards from one build.
//
//   bun clients/apple/scripts/unit-shards.ts [--shards N] [--strict] [--scheme OppiUnitTests|Oppi]
//   bun clients/apple/scripts/unit-shards.ts --record <sim-pool log of a full run>
//
// 1. Build once without a simulator slot (`sim-pool.sh run -- ... build-for-testing`). --scheme
//    (default OppiUnitTests) names the scheme to build: both build OppiTests with the same settings,
//    and the shards select only OppiTests. The pre-push gate passes the scheme its Apple lane just
//    built, so sim-pool skips this build and takes no xcode-build slot.
// 2. sim-pool clones the products (OPPI_SIM_POOL_PRODUCTS_DIR) under the build's checkout
//    lock, so a rebuild cannot change them.
// 3. Split the top-level test types of OppiTests into N shards by recorded suite seconds
//    (unit-shard-seconds.json; unknown types count TEST_SECONDS per @Test). Shards 1..N-1
//    run `-only-testing` lists; the last shard runs `-skip-testing` of everything the
//    others run, so a test type the scan misses still runs.
// 4. Run every shard in its own pool slot with `test-without-building -xctestrun` at once.
// Fails when any shard fails or runs zero tests; a shard that ran none is reported as an
// infrastructure failure, apart from test failures. Default N: OPPI_UNIT_SHARDS or 3.
// A failed shard reruns its failed tests once; every rerun outcome goes to the rerun ledger, a red
// run in a land-queue batch to the red-lane ledger, and the summary prints the hidden flakes and the
// longest shard against its budget (scripts/gate-report.ts).
// A shard whose pool slots are all busy waits for one: the gate (pre-push) sets OPPI_SIM_POOL_GATE=1,
// which gives sim-pool its gate wait (see GATE_POOL_WAIT_SECONDS in sim-pool-ops.ts).
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, readdirSync, writeFileSync, closeSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { budgetVerdict, headOf, hiddenFlakesLine, loadBudgets, recordRedLane, recordRerun, redLaneLine, zeroTestLine } from "../../../scripts/gate-report";
import { findXctestrun, runDirectory } from "./sim-pool-build";

/** Schemes whose build-for-testing builds OppiTests (project.yml). */
const SCHEMES = new Set(["OppiUnitTests", "Oppi"]);
const BUNDLE = "OppiTests";
const TEST_SECONDS = 0.05;
const scriptDir = dirname(fileURLToPath(import.meta.url));
const appleDir = dirname(scriptDir);
const weightsPath = join(scriptDir, "unit-shard-seconds.json");
const quarantinePath = join(appleDir, "..", "..", "dev", "testing", "quarantine.json");

export type TestType = { name: string; display: string; tests: number };

/** Top-level types declared in test files (files with `@Test`), with their `@Suite` display name. */
export function scanTestTypes(files: { path: string; text: string }[]): TestType[] {
  const types = new Map<string, TestType>();
  for (const { text } of files) {
    if (!/@Test\b/.test(text)) continue;
    const lines = text.split("\n");
    let pendingDisplay: string | undefined;
    let current: TestType | undefined;
    for (const line of lines) {
      const suite = /^@Suite\("([^"]*)"/.exec(line);
      if (suite) pendingDisplay = suite[1];
      const decl = /^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*(?:struct|class|enum|actor)\s+(\w+)/.exec(line);
      const ext = /^extension\s+(\w+)/.exec(line);
      if (decl) {
        const name = decl[1];
        current = types.get(name) ?? { name, display: pendingDisplay ?? name, tests: 0 };
        types.set(name, current);
        pendingDisplay = undefined;
      } else if (ext) {
        current = types.get(ext[1]);
      } else if (/^(?:func|let|var|private|fileprivate|@Test)\b/.test(line)) {
        current = undefined;
      }
      if (current && /^\s+@Test\b/.test(line)) current.tests += 1;
    }
  }
  return [...types.values()].filter((type) => type.tests > 0).sort((a, b) => a.name.localeCompare(b.name));
}

/** Greedy longest-first: each type goes to the currently lightest shard. */
export function partition(types: TestType[], weights: Record<string, number>, shards: number): TestType[][] {
  const weight = (type: TestType) => weights[type.name] ?? type.tests * TEST_SECONDS;
  const bins = Array.from({ length: shards }, () => ({ total: 0, types: [] as TestType[] }));
  for (const type of [...types].sort((a, b) => weight(b) - weight(a) || a.name.localeCompare(b.name))) {
    const bin = bins.reduce((lightest, next) => (next.total < lightest.total ? next : lightest));
    bin.types.push(type);
    bin.total += weight(type);
  }
  return bins.map((bin) => bin.types);
}

/** xcodebuild filter flags for shard `index`; the last shard is the complement of the others. */
export function shardFlags(parts: TestType[][], index: number): string[] {
  if (index < parts.length - 1) return parts[index].map((type) => `-only-testing:${BUNDLE}/${type.name}`);
  // Naming the bundle keeps the run single-bundle, which sim-pool's completion parser needs.
  return [`-only-testing:${BUNDLE}`, ...parts.slice(0, -1).flat().map((type) => `-skip-testing:${BUNDLE}/${type.name}`)];
}

/** Seconds per top-level type from a full run's `Suite "<display>" passed|failed after N seconds` lines. */
export function recordWeights(logText: string, types: TestType[]): Record<string, number> {
  const byDisplay = new Map<string, TestType[]>();
  for (const type of types) byDisplay.set(type.display, [...(byDisplay.get(type.display) ?? []), type]);
  const weights: Record<string, number> = {};
  for (const match of logText.matchAll(/^[✔✘] Suite "?([^"]+?)"? (?:passed|failed) after ([0-9.]+) seconds/gm)) {
    const owners = byDisplay.get(match[1]);
    if (owners?.length === 1) weights[owners[0].name] = Number(Number(match[2]).toFixed(2));
  }
  return weights;
}

function swiftFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return swiftFiles(path);
    return entry.name.endsWith(".swift") ? [path] : [];
  });
}

function loadTypes(): TestType[] {
  return scanTestTypes(swiftFiles(join(appleDir, BUNDLE)).map((path) => ({ path, text: readFileSync(path, "utf8") })));
}

/**
 * A known-flaky test the gate runs without blocking until its owner decides by `expires`. `backlog`
 * is the factory backlog key of the work that fixes or deletes it.
 */
export type QuarantineEntry = { id: string; owner: string; reason: string; addedAt: string; expires: string; backlog: string };

const QUARANTINE_FIELDS = ["id", "owner", "reason", "addedAt", "expires", "backlog"] as const;
/** Quarantine buys time for a decision: an `expires` further ahead than this is refused, so an entry cannot park a test indefinitely. */
export const QUARANTINE_MAX_DAYS = 30;
const QUARANTINE_BUNDLES = ["OppiTests/", "OppiUITests/", "OppiE2ETests/"];

/**
 * Why entries of dev/testing/quarantine.json cannot stand: a missing field, an id outside the test
 * bundles, a date that is not YYYY-MM-DD, an `expires` before `today`, or one more than
 * QUARANTINE_MAX_DAYS after it. Any problem fails every lane that reads the file, so a quarantine
 * cannot outlive its decision date unnoticed.
 */
export function quarantineProblems(entries: unknown, today: string): string[] {
  if (!Array.isArray(entries)) return ["dev/testing/quarantine.json must be a JSON array of entries"];
  const latest = new Date(Date.parse(`${today}T00:00:00Z`) + QUARANTINE_MAX_DAYS * 86_400_000).toISOString().slice(0, 10);
  return entries.flatMap((raw, index) => {
    const entry = (raw ?? {}) as Record<string, unknown>;
    const name = typeof entry.id === "string" && entry.id !== "" ? entry.id : `#${index + 1}`;
    const missing = QUARANTINE_FIELDS.filter((key) => typeof entry[key] !== "string" || (entry[key] as string).trim() === "");
    if (missing.length > 0) return [`quarantine entry ${name} lacks ${missing.join(", ")} (dev/testing/quarantine.json)`];
    const problems: string[] = [];
    if (!QUARANTINE_BUNDLES.some((bundle) => name.startsWith(bundle))) problems.push(`quarantine entry ${name}: the id must start with ${QUARANTINE_BUNDLES.join(", ")}`);
    for (const key of ["addedAt", "expires"] as const) {
      if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(entry[key] as string)) problems.push(`quarantine entry ${name}: ${key} '${entry[key]}' is not YYYY-MM-DD`);
    }
    if (problems.length === 0 && (entry.expires as string) < today) {
      problems.push(`quarantine expired ${entry.expires}: ${name} (owner ${entry.owner}, backlog ${entry.backlog}); fix it, extend it, or delete it in dev/testing/quarantine.json`);
    }
    if (problems.length === 0 && (entry.expires as string) > latest) {
      problems.push(`quarantine entry ${name}: expires ${entry.expires}, more than ${QUARANTINE_MAX_DAYS} days after ${today}; set a decision date by ${latest}`);
    }
    return problems;
  });
}

/** The entries in force for one test bundle, and every problem in the file (a missing file is an empty quarantine). */
export function loadQuarantine(path: string, bundle: string, today = new Date().toISOString().slice(0, 10)): { active: QuarantineEntry[]; problems: string[] } {
  if (!existsSync(path)) return { active: [], problems: [] };
  let entries: unknown;
  try {
    entries = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    return { active: [], problems: [`quarantine entry file ${path} is not JSON: ${error instanceof Error ? error.message : String(error)}`] };
  }
  const problems = quarantineProblems(entries, today);
  if (problems.length > 0) return { active: [], problems };
  return { active: splitQuarantine(entries as QuarantineEntry[], today).active.filter((entry) => entry.id.startsWith(`${bundle}/`)), problems };
}

/** Entries still in force on `today` (YYYY-MM-DD), and the ones whose decision is overdue. */
export function splitQuarantine(entries: QuarantineEntry[], today: string): { active: QuarantineEntry[]; expired: QuarantineEntry[] } {
  return {
    active: entries.filter((entry) => entry.expires >= today),
    expired: entries.filter((entry) => entry.expires < today),
  };
}

/** Identifiers (`Suite/test()`) of the test cases in an xcresult whose result is one of `results` (any result when omitted), or undefined when it cannot be read. */
function testIdsWith(xcresultTestsJson: string, results?: Set<string>): string[] | undefined {
  try {
    const ids: string[] = [];
    const walk = (node: { nodeType?: string; result?: string; nodeIdentifier?: string; children?: unknown[] }) => {
      if (node.nodeType === "Test Case" && (!results || results.has(node.result ?? "")) && node.nodeIdentifier) ids.push(node.nodeIdentifier);
      for (const child of node.children ?? []) walk(child as typeof node);
    };
    for (const node of JSON.parse(xcresultTestsJson).testNodes ?? []) walk(node);
    return ids;
  } catch {
    return undefined;
  }
}

/** Failed test identifiers (`Suite/test()`) in an xcresult, or undefined when it cannot be read. */
export const failedTestIds = (xcresultTestsJson: string) => testIdsWith(xcresultTestsJson, new Set(["Failed"]));

/** Identifiers of every test an xcresult lists, whatever its result (skipped and disabled included), or undefined when unreadable. */
const listedTestIds = (xcresultTestsJson: string) => testIdsWith(xcresultTestsJson);

/** Identifiers of the tests that ran (passed or failed; not skipped or disabled), or undefined when unreadable. */
const executedTestIds = (xcresultTestsJson: string) => testIdsWith(xcresultTestsJson, new Set(["Passed", "Failed", "Expected Failure"]));

/**
 * Which `-only-testing` selectors (`Target[/Type[/method]]`) name none of the tests an xcresult lists.
 * Listed ids are `Type/method()` and carry no target, so a selector's target is dropped and the rest
 * must name a listed test or a type holding one. A test that was skipped (`.enabled(if:)`, XCTSkip)
 * is still listed: the selector found it, and what the test did is the run's verdict, not the
 * selector's. Swift Testing's trailing `()` is ignored on both sides. A bare `Target` matches any run
 * that listed something.
 */
export function unmatchedSelectors(selectors: string[], listed: string[]): string[] {
  const bare = (id: string) => id.replace(/\([^/]*\)$/, "");
  const ids = listed.map(bare);
  return selectors.filter((selector) => {
    const wanted = bare(selector.split("/").slice(1).join("/"));
    return wanted === "" ? ids.length === 0 : !ids.some((id) => id === wanted || id.startsWith(`${wanted}/`));
  });
}

/**
 * The record of the last full unit run in this checkout, under clients/apple/.build: its HEAD and
 * the sim-pool summaries of its shards (the quarantine watch run included). batch-gate reads it to
 * check that each named unit selector matched a test of that run.
 */
export const UNIT_RUN_RECORD = "unit-shards-last.json";

const RERUN_LIMIT = 20;

export type ShardResult = { index: number; label: string; code: number; tests: number; seconds: number; output: string; summary?: string };

export async function runShard(
  index: number,
  xctestrun: string,
  flags: string[],
  outDir: string,
  label = `shard-${index + 1}`,
  env: NodeJS.ProcessEnv = process.env,
  /** UI shards keep xcodebuild's default diagnostics: their xcresult is read by people, not by a rerun. */
  diagnostics = false,
): Promise<ShardResult> {
  const output = join(outDir, `${label}.out`);
  const fd = openSync(output, "w");
  const started = Date.now();
  // Unit shards collect no failure diagnostics (simctl diagnose runs minutes and, cut short by
  // sim-pool's completion stop, leaves an unreadable xcresult, so failed tests could not be rerun).
  const child = spawn(join(scriptDir, "sim-pool.sh"), [
    "run", "--", "xcodebuild", "test-without-building", "-xctestrun", xctestrun, ...(diagnostics ? [] : ["-collect-test-diagnostics", "never"]), ...flags,
  ], {
    cwd: appleDir,
    stdio: ["ignore", fd, fd],
    env,
  });
  closeSync(fd);
  const code = await new Promise<number>((resolve) => child.on("exit", (status, signal) => resolve(status ?? (signal ? 128 : 1))));
  const summary = /^Artifact: (.+)$/m.exec(readFileSync(output, "utf8"))?.[1];
  return { index, label, code, tests: executedTests(summary), seconds: Math.round((Date.now() - started) / 1000), output, summary };
}

/**
 * Why a shard failed without testing anything (the pool had no slot, the build or simulator
 * broke, xcodebuild died before the first test), or undefined when it ran tests. A shard that
 * ran nothing has no failed test to rerun or fix; the failure is the machine's, and the gate
 * summary must say so instead of reporting a red test suite.
 */
export function infrastructureFailure(result: Pick<ShardResult, "code" | "tests">, output: string): string | undefined {
  if (result.tests > 0) return undefined;
  // sim-pool's own failure line (`error: all 6 simulator slots ... (waited 60s)`) says what stopped it.
  const cause = [...output.matchAll(/^error: (.+)$/gm)].at(-1)?.[1];
  const ran = result.code === 0 ? "the shard exited 0 but ran no tests" : `the shard ran no tests (exit ${result.code})`;
  return cause ? `${ran}: ${cause}` : ran;
}

/** The outcome line of a gate run: test failures and infrastructure failures are never conflated. */
export function verdict(testFailures: string[], infraFailures: string[]): string {
  const parts = [
    testFailures.length > 0 ? `test failures in ${testFailures.join(", ")}` : "",
    infraFailures.length > 0 ? `INFRASTRUCTURE failure, no tests ran in ${infraFailures.join(", ")}` : "",
  ].filter(Boolean);
  return parts.length > 0 ? `FAILED (${parts.join("; ")})` : "PASSED";
}

/** Failed test ids, or why they cannot be read. */
export type Failures = { ids: string[] } | { reason: string };

// `xcresulttool get test-results tests` prints ~0.7 KB of JSON per test: a shard of a few thousand
// tests is several MB. Bun's default 1 MiB maxBuffer fails that spawn with ENOBUFS, so no failure
// was ever readable and no gate reran anything.
const XCRESULT_MAX_BYTES = 256 * 1024 * 1024;

/** Run an xcresulttool-style command that prints the tests JSON and extract its failed test ids. */
export function readFailures(command: string, args: string[]): Failures {
  return readTestIds(command, args, failedTestIds);
}

/** Run an xcresulttool-style command that prints the tests JSON and pick test ids out of it with `pick`. */
function readTestIds(command: string, args: string[], pick: (json: string) => string[] | undefined): Failures {
  const tool = spawnSync(command, args, { encoding: "utf8", timeout: 60_000, maxBuffer: XCRESULT_MAX_BYTES, killSignal: "SIGKILL" });
  if (tool.error) return { reason: `xcresulttool did not finish: ${tool.error.message}` };
  if (tool.status !== 0) {
    const stderr = tool.stderr.trim().split("\n").slice(-3).join(" | ");
    return { reason: `xcresulttool ${tool.signal ? `killed by ${tool.signal}` : `exit ${tool.status}`}${stderr ? `: ${stderr}` : ""}` };
  }
  const ids = pick(tool.stdout);
  return ids ? { ids } : { reason: `xcresulttool output (${tool.stdout.length} chars) is not test-results JSON` };
}

/** The xcresult in a finished run's directory, or why there is none. */
function xcresultOf(summary: string | undefined): { path: string } | { reason: string } {
  if (!summary || !existsSync(summary)) return { reason: "no sim-pool summary" };
  const derivedData = JSON.parse(readFileSync(summary, "utf8")).derived_data_path as string | undefined;
  const testLogs = derivedData ? join(derivedData, "Logs", "Test") : "";
  if (!testLogs || !existsSync(testLogs)) return { reason: `no test logs directory (${testLogs || "no derived data path"})` };
  const bundle = readdirSync(testLogs).filter((name) => name.endsWith(".xcresult")).sort().at(-1);
  return bundle ? { path: join(testLogs, bundle) } : { reason: `no .xcresult in ${testLogs}` };
}

/** Failed tests of a finished run, read from the xcresult in its run directory. */
export function runFailures(summary: string | undefined): Failures {
  const xcresult = xcresultOf(summary);
  if ("reason" in xcresult) return xcresult;
  return readFailures("xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", xcresult.path]);
}

/** Every test the xcresult at `path` lists, whatever its result, or why it cannot be read. */
export function xcresultTestIds(path: string): Failures {
  return readTestIds("xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", path], listedTestIds);
}

/**
 * Tests a finished run executed (a skipped or disabled test is not one), read from the xcresult in its
 * run directory. A gate's named tests are evidence that they ran, which a skipped test is not.
 */
export function runExecutedTestIds(summary: string | undefined): Failures {
  const xcresult = xcresultOf(summary);
  if ("reason" in xcresult) return xcresult;
  return readTestIds("xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", xcresult.path], executedTestIds);
}

/** The gate lane the full unit run is, in the rerun and red-lane ledgers and dev/testing/lane-budgets.json. */
const LANE = "unit-full";
const profile = () => process.env.OPPI_SIM_DEVICE_PROFILE ?? "iphone";

/** The `-only-testing` values of a shard's flags: the selectors it was given. */
const selectorsOf = (flags: string[]) => flags.filter((flag) => flag.startsWith("-only-testing:")).map((flag) => flag.slice("-only-testing:".length));

/**
 * Tests the shard's xcodebuild ran, from its log: the Swift Testing result line (unit tests), or
 * XCTest's `Executed N tests` line or, when the run died before printing it, the count of finished
 * test cases (UI tests). A run that finished some cases is a failure, not an infrastructure failure.
 */
export function executedTests(summary: string | undefined): number {
  if (!summary || !existsSync(summary)) return 0;
  const log = JSON.parse(readFileSync(summary, "utf8")).log_path as string | undefined;
  if (!log || !existsSync(log)) return 0;
  const text = readFileSync(log, "utf8");
  const swift = [...text.matchAll(/^[✔✘] Test run with ([0-9]+) tests? in [0-9]+ suites? (?:passed|failed) after/gm)].at(-1);
  const xctest = [...text.matchAll(/^Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at .+\r?\n[ \t]+Executed ([0-9]+) tests?/gm)].at(-1);
  const cases = [...text.matchAll(/^Test Case '.+' (?:passed|failed) \(/gm)].length;
  return Math.max(swift ? Number(swift[1]) : 0, xctest ? Number(xctest[1]) : 0, cases);
}

async function main(argv: string[]): Promise<number> {
  const record = argv.indexOf("--record");
  if (record >= 0) {
    const weights = recordWeights(readFileSync(argv[record + 1], "utf8"), loadTypes());
    writeFileSync(weightsPath, `${JSON.stringify(Object.fromEntries(Object.entries(weights).sort()), null, 1)}\n`);
    console.log(`[unit-shards] recorded ${Object.keys(weights).length} suite timings in ${weightsPath}`);
    return 0;
  }
  const shardsArg = argv.indexOf("--shards");
  const shards = Number(shardsArg >= 0 ? argv[shardsArg + 1] : process.env.OPPI_UNIT_SHARDS ?? "3");
  if (!Number.isInteger(shards) || shards < 1) throw new Error(`invalid shard count ${shards}`);
  const schemeArg = argv.indexOf("--scheme");
  const scheme = schemeArg >= 0 ? argv[schemeArg + 1] : "OppiUnitTests";
  if (!SCHEMES.has(scheme)) throw new Error(`--scheme must be one of ${[...SCHEMES].join(", ")}, got ${scheme}`);
  const started = Date.now();
  const wall = () => Math.round((Date.now() - started) / 1000);
  /** A red run of a land-queue batch goes to the red-lane ledger with a cause guessed from `output`. */
  const red = (tests: string[], output: string) => {
    console.log(`[unit-shards] ${redLaneLine(LANE, recordRedLane(appleDir, { lane: LANE, profile: profile(), exit: 1, seconds: wall(), tests, output }))}`);
    return 1;
  };

  // --strict (release): every test blocks; no quarantine, no pass-on-rerun.
  const strict = argv.includes("--strict");
  const quarantine = strict ? { active: [], problems: [] } : loadQuarantine(quarantinePath, BUNDLE);
  if (quarantine.problems.length > 0) {
    for (const problem of quarantine.problems) console.error(`[unit-shards] ${problem}`);
    return red([], quarantine.problems.join("\n"));
  }
  const skipQuarantined = quarantine.active.map((entry) => `-skip-testing:${entry.id}`);

  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
  const runDir = runDirectory(join(appleDir, ".build"), `shards-${stamp}`);
  // sim-pool clones the products into runDir under the same checkout lock as the build, so
  // another run in this checkout cannot swap them in between.
  const build = spawnSync(join(scriptDir, "sim-pool.sh"), ["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", scheme, "build-for-testing"], {
    cwd: appleDir,
    stdio: "inherit",
    env: { ...process.env, OPPI_SIM_POOL_PRODUCTS_DIR: runDir },
  });
  if (build.status !== 0) {
    const line = `[unit-shards] build failed (exit ${build.status ?? build.signal})`;
    console.error(line);
    red([], line);
    return build.status || 1;
  }
  const xctestrun = findXctestrun(join(runDir, "Build", "Products"), scheme);

  const weights: Record<string, number> = existsSync(weightsPath) ? JSON.parse(readFileSync(weightsPath, "utf8")) : {};
  const parts = partition(loadTypes(), weights, shards);
  const outDir = join(runDir, "shards");
  mkdirSync(outDir, { recursive: true });
  console.log(`[unit-shards] ${shards} shards from ${relative(appleDir, xctestrun)}; outputs in ${outDir}`);
  const results = await Promise.all(parts.map((_, index) => runShard(index, xctestrun, [...shardFlags(parts, index), ...skipQuarantined], outDir)));
  const testFailures: string[] = [];
  const infraFailures: string[] = [];
  /** Tests still red after the rerun, and the ones that passed only on it. */
  const failing: string[] = [];
  const flaky: string[] = [];
  const redOutput: string[] = [];
  for (const result of results) {
    const output = readFileSync(result.output, "utf8");
    const infra = infrastructureFailure(result, output);
    let ok = result.code === 0 && !infra;
    console.log(`[unit-shards] shard ${result.index + 1}/${shards}: ${ok ? "PASS" : infra ? "INFRASTRUCTURE FAIL" : "FAIL"} exit=${result.code} tests=${result.tests} ${result.seconds}s output=${result.output}${result.summary ? ` summary=${result.summary}` : ""}`);
    if (result.tests === 0) console.log(`[unit-shards] ${result.label}: ${zeroTestLine(selectorsOf(shardFlags(parts, result.index)), result.code === 0)}`);
    if (!ok) {
      // sim-pool's own summary (failures, log path) ends the shard output.
      const tail = output.trimEnd().split("\n").slice(-40).join("\n");
      process.stdout.write(`${tail}\n`);
      redOutput.push(tail);
      if (infra) {
        console.log(`[unit-shards] ${result.label}: ${infra}; no test failed, so there is nothing to rerun`);
        redOutput.push(`INFRASTRUCTURE failure: ${infra}`);
      } else if (!strict) {
        const rerun = await rerunFailures(result, xctestrun, outDir);
        ok = rerun.ok;
        failing.push(...rerun.failing);
        flaky.push(...rerun.flaky);
      } else {
        const failures = runFailures(result.summary);
        if ("ids" in failures) failing.push(...failures.ids.map((id) => `${BUNDLE}/${id}`));
      }
    }
    if (!ok) (infra ? infraFailures : testFailures).push(result.label);
  }
  const summaries = results.map((result) => result.summary).filter((summary): summary is string => summary !== undefined);
  if (quarantine.active.length > 0) {
    // Quarantined tests still run, on the same products, but never block.
    const watch = await runShard(shards, xctestrun, quarantine.active.map((entry) => `-only-testing:${entry.id}`), outDir, "quarantined");
    console.log(`[unit-shards] quarantined (non-blocking): ${watch.code === 0 ? "passed" : "failed"} ${quarantine.active.map((entry) => entry.id).join(", ")} output=${watch.output}`);
    if (watch.summary) summaries.push(watch.summary);
  }
  // What this run ran, for batch-gate's check that a named unit selector matched a test (paths only: it reads the xcresults when it needs them).
  writeFileSync(join(appleDir, ".build", UNIT_RUN_RECORD), `${JSON.stringify({ head: headOf(appleDir), at: new Date().toISOString(), summaries }, null, 1)}\n`);
  for (const id of failing) console.log(`[unit-shards] FAILED ${id}`);
  const total = results.reduce((sum, result) => sum + result.tests, 0);
  const longest = Math.max(...results.map((r) => r.seconds));
  const outcome = `${verdict(testFailures, infraFailures)}: ${total} tests in ${shards} shards, longest ${longest}s`;
  console.log(`[unit-shards] ${outcome}`);
  const { budgets, warnings } = loadBudgets();
  const budget = budgetVerdict(LANE, { wall: wall(), longestShard: longest }, budgets);
  for (const warning of warnings) console.log(`[unit-shards] ${warning}`);
  console.log(`[unit-shards] ${budget.line}`);
  if (budget.warning) console.log(`[unit-shards] ${budget.warning}`);
  // A red run hides nothing: its failures are printed above.
  if (testFailures.length + infraFailures.length === 0) {
    console.log(`[unit-shards] ${hiddenFlakesLine(flaky.map((id) => ({ id, lane: LANE })))}`);
    return 0;
  }
  return red(failing, [...redOutput, outcome].join("\n"));
}

/**
 * Rerun a failed shard's failing tests once on the same products. A test that passes on the
 * rerun is a flake: it does not block, and the rerun ledger counts the gates it flaked in. Crashes,
 * unreadable results, or more than RERUN_LIMIT failures stay red. `failing` and `flaky` are full
 * `OppiTests/...` ids.
 */
async function rerunFailures(result: ShardResult, xctestrun: string, outDir: string): Promise<{ ok: boolean; failing: string[]; flaky: string[] }> {
  const failures = runFailures(result.summary);
  if ("reason" in failures) {
    console.log(`[unit-shards] ${result.label}: no rerun (failures unreadable: ${failures.reason})`);
    return { ok: false, failing: [], flaky: [] };
  }
  const ids = failures.ids;
  if (ids.length === 0 || ids.length > RERUN_LIMIT) {
    console.log(`[unit-shards] ${result.label}: no rerun (${ids.length} failed tests)`);
    return { ok: false, failing: ids.map((id) => `${BUNDLE}/${id}`), flaky: [] };
  }
  const rerun = await runShard(result.index, xctestrun, ids.map((id) => `-only-testing:${BUNDLE}/${id}`), outDir, `${result.label}-rerun`);
  const ok = rerun.code === 0 && rerun.tests >= ids.length;
  console.log(`[unit-shards] ${result.label} rerun of ${ids.length} failed tests: ${ok ? "PASS" : "FAIL"} output=${rerun.output}`);
  // A red rerun names what failed again; when it names nothing (unreadable, or it died), every rerun test failed.
  const again = ok ? undefined : runFailures(rerun.summary);
  const stillRed = new Set(again === undefined ? [] : "ids" in again && again.ids.length > 0 ? again.ids : ids);
  const failing: string[] = [];
  const flaky: string[] = [];
  for (const id of ids) {
    const full = `${BUNDLE}/${id}`;
    const outcome = stillRed.has(id) ? "failed" : "flaky";
    const gates = recordRerun(appleDir, { id: full, lane: LANE, profile: profile(), outcome });
    if (outcome === "failed") {
      failing.push(full);
      continue;
    }
    flaky.push(full);
    console.log(`[unit-shards] FLAKY ${full}: failed, then passed on rerun (flaked in ${gates} gate${gates === 1 ? "" : "s"})${gates >= 2 ? "; quarantine it in dev/testing/quarantine.json with an owner, an expiry, and a backlog key" : ""}`);
  }
  return { ok, failing, flaky };
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
