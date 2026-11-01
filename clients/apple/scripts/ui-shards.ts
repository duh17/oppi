#!/usr/bin/env bun
// Run named OppiUITests filters as N parallel shards of one device profile, from one build.
//
//   bun clients/apple/scripts/ui-shards.ts [--profile iphone|ipad|duo] [--shards N] [--plan] -- OppiUITests/<Class>[/<test>]...
//   bun clients/apple/scripts/ui-shards.ts --record <sim-pool log>...
//
// What `scripts/batch-gate.ts` runs for each `ui-<profile>` lane, and what you run by hand to
// time or debug a multi-class UI selection. Same shape as unit-shards.ts:
// 1. Build once without a simulator slot (`sim-pool.sh run -- ... build-for-testing`); sim-pool
//    clones the products (OPPI_SIM_POOL_PRODUCTS_DIR) under the build's checkout lock.
// 2. Split the filters into shards balanced by recorded seconds (ui-shard-seconds.json, per
//    test; a test with no record counts the median of the recorded ones, so an unrecorded
//    selection balances by count). A class is one unit; a class heavier than half a shard's
//    share is split into its test methods, so one big class cannot be the whole critical path.
//    One shard of a split class runs the class minus the methods the others run, so a test the
//    source scan missed still runs (like unit-shards' last shard), and each shard's executed
//    test ids are checked against its plan.
// 3. Run every shard in its own pool slot of the profile with `test-without-building -xctestrun`
//    at once. Shard count: enough that each shard has MIN_SHARD_SECONDS of tests (a shard costs
//    about 30 s of install and runner start), at most OPPI_UI_SHARDS (default per profile:
//    iphone 3, ipad 3, duo 1) and never more than the profile's slots. sim-pool still enforces the
//    machine-wide limits: a shard waits for a slot (OPPI_SIM_POOL_WAIT, or the gate wait under
//    OPPI_SIM_POOL_GATE=1), for booted-simulator capacity, and for the first-boot slot.
//
// A shard whose finished run failed reruns its failed tests once (at most XCTEST_RERUN_LIMIT), on the
// same products and profile, like unit-shards: a test that passes on the rerun is FLAKY and does not
// block, every rerun outcome goes to the rerun ledger, and the summary names the flakes the rerun hid
// (scripts/gate-report.ts). Quarantined UI tests (dev/testing/quarantine.json) are taken out of the
// shards and run in one non-blocking shard; an expired or incomplete entry fails the run before it
// builds. Every shard prints its own output file, sim-pool summary, and xcresult. A shard that ran no
// tests is reported as an infrastructure failure (pool full, broken build or simulator), apart from
// test failures, with the selectors it was given. The summary prints the median test against the
// profile's budget (dev/testing/lane-budgets.json).
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { findXctestrun, runDirectory } from "./sim-pool-build";
import {
  budgetVerdict, failedXCTestCases, hiddenFlakesLine, loadBudgets, logOfSummary, median, passedXCTestCases, recordRerun, xctestCaseSeconds, xctestRerun, zeroTestLine,
} from "../../../scripts/gate-report";
import { DEVICE_PROFILES } from "./sim-pool-ops";
import { executedTests, infrastructureFailure, loadQuarantine, runShard, verdict, type ShardResult } from "./unit-shards";

const SCHEME = "Oppi";
const BUNDLE = "OppiUITests";
/** Source folders compiled into the UI test bundle (project.yml). */
const SOURCE_DIRS = ["OppiUITests", "QAVerificationSupport"];
/** A shard needs at least this many seconds of tests to pay for its own install and runner start. */
export const MIN_SHARD_SECONDS = 120;
const FALLBACK_TEST_SECONDS = 30;
// iPad was the critical lane in 8 of 11 measured UI gates and its 4 slots never queued, so it takes 3,
// leaving one for workers (.internal/reports/gate-speed-2026-11-01, recommendation 1).
const DEFAULT_SHARDS: Record<string, number> = { iphone: 3, ipad: 3, duo: 1 };
const scriptDir = dirname(fileURLToPath(import.meta.url));
const appleDir = dirname(scriptDir);
const weightsPath = join(scriptDir, "ui-shard-seconds.json");
const quarantinePath = join(appleDir, "..", "..", "dev", "testing", "quarantine.json");

/** A UI test class: the `test…()` methods it declares, in its body and extensions. */
export type UIClass = { name: string; superclass?: string; tests: Set<string>; complete: boolean };

/** Swift sources with comments blanked and string contents emptied, so a brace in either cannot unbalance a body. */
function stripNoise(text: string): string {
  return text.replace(/"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, (all) => (all.startsWith("/") ? " " : '""'));
}

/** Text of `{…}` starting at the `{` at `open`, without nested blocks; undefined when it never closes. */
function ownBody(text: string, open: number): string | undefined {
  let depth = 0;
  let own = "";
  for (let i = open; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return own;
    } else if (depth === 1) own += ch;
    // A nested block leaves a `{}` marker, so a `func test…() {…}` still reads as one declaration.
    if (depth === 2 && ch === "{") own += "{}";
  }
  return undefined;
}

/**
 * Classes with the test methods XCTest would run: non-private `func test…()` with no parameters,
 * declared directly in the class body or an extension. `complete` is false for a class whose
 * body the scan could not read to its closing brace; callers must not split such a class.
 */
export function scanUIClasses(sources: string[]): Map<string, UIClass> {
  const classes = new Map<string, UIClass>();
  for (const source of sources) {
    const text = stripNoise(source);
    for (const decl of text.matchAll(/\b(class|extension)\s+(\w+)\s*(?::\s*([\w.]+))?[^{;=]*\{/g)) {
      if (["func", "var", "let"].includes(decl[2])) continue;
      const entry = classes.get(decl[2]) ?? { name: decl[2], tests: new Set<string>(), complete: true };
      classes.set(decl[2], entry);
      if (decl[1] === "class" && decl[3]) entry.superclass = decl[3];
      const body = ownBody(text, decl.index! + decl[0].length - 1);
      if (body === undefined) {
        entry.complete = false;
        continue;
      }
      for (const method of body.matchAll(/((?:[@\w]+(?:\([^)]*\))?\s+)*)func\s+(test\w*)\s*\(\s*\)/g)) {
        if (!/\b(?:private|fileprivate|static|class)\b/.test(method[1])) entry.tests.add(method[2]);
      }
    }
  }
  return classes;
}

/**
 * Every test method of `name`, inherited ones included; undefined when the scan cannot vouch for the
 * list: a body it could not close, or a superclass that is neither XCTestCase nor a scanned class
 * (its helpers' tests would be invisible).
 */
export function testsOf(name: string, classes: Map<string, UIClass>, seen = new Set<string>()): string[] | undefined {
  const entry = classes.get(name);
  if (!entry || !entry.complete || seen.has(name)) return undefined;
  seen.add(name);
  const tests = new Set(entry.tests);
  // XCTestCase itself is not declared here; a declared superclass contributes its tests.
  if (entry.superclass !== "XCTestCase") {
    const inherited = entry.superclass && classes.has(entry.superclass) ? testsOf(entry.superclass, classes, seen) : undefined;
    if (!inherited) return undefined;
    for (const test of inherited) tests.add(test);
  }
  return [...tests].sort();
}

/** Seconds per `Class/test` from sim-pool logs: the median of every passed execution. */
export function recordUIWeights(logTexts: string[]): Record<string, number> {
  const runs = new Map<string, number[]>();
  for (const text of logTexts) {
    for (const match of text.matchAll(/^Test Case '-\[OppiUITests\.(\w+) (test\w*)\]' passed \(([0-9.]+) seconds\)/gm)) {
      const id = `${match[1]}/${match[2]}`;
      runs.set(id, [...(runs.get(id) ?? []), Number(match[3])]);
    }
  }
  const weights: Record<string, number> = {};
  for (const [id, seconds] of [...runs].sort(([a], [b]) => a.localeCompare(b))) {
    const sorted = seconds.sort((a, b) => a - b);
    weights[id] = Number(sorted[Math.floor((sorted.length - 1) / 2)].toFixed(1));
  }
  return weights;
}

/** Drop recorded tests the sources no longer declare (renamed, deleted, or in a deleted class); a class the scan cannot list keeps its tests. */
export function pruneStale(weights: Record<string, number>, classes: Map<string, UIClass>): Record<string, number> {
  return Object.fromEntries(Object.entries(weights).filter(([id]) => {
    const [cls, test] = id.split("/");
    if (!classes.has(cls)) return false;
    const tests = testsOf(cls, classes);
    return tests === undefined || tests.includes(test);
  }));
}

/** What one shard runs, with the classes and tests it was planned from. */
export type Unit = {
  label: string;
  flags: string[];
  seconds: number;
  /** Tests this unit runs, or undefined when the scan cannot say (a filter the scan does not know). */
  tests: number | undefined;
  /** `Class/test` ids this unit is planned to run; empty for a filter the scan cannot list. */
  ids: string[];
  /** Set on a method unit that came from splitting this class. */
  splitOf?: string;
  /** Runs the whole class except the methods of it that other shards run (see addCatchAlls). */
  catchAll?: boolean;
};
export type ShardPlan = { units: Unit[]; seconds: number; tests: number | undefined; ids: string[] };

function medianSeconds(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length > 0 ? sorted[Math.floor((sorted.length - 1) / 2)] : FALLBACK_TEST_SECONDS;
}

/**
 * Filters with duplicates and covered ones removed: `OppiUITests/C` covers `OppiUITests/C/testX`.
 * A trailing `()` (Swift Testing's spelling) is dropped first: XCTest names have none, so
 * `C/testX()` and `C/testX` are one test.
 */
export function normalizeFilters(filters: string[]): string[] {
  const unique = [...new Set(filters.map((filter) => filter.replace(/\(\)$/, "")))];
  const classes = new Set(unique.filter((filter) => filter.split("/").length === 2));
  return unique.filter((filter) => {
    const [target, cls, ...rest] = filter.split("/");
    return rest.length === 0 || !classes.has(`${target}/${cls}`);
  });
}

/** Shard count for `seconds` of tests: MIN_SHARD_SECONDS each, at most `cap`, and one test per shard at the least. */
export function shardCount(seconds: number, cap: number, tests: number): number {
  return Math.max(1, Math.min(cap, tests, Math.floor(seconds / MIN_SHARD_SECONDS)));
}

/** Run slots of a device profile. */
export function profileSlots(profile: string): number {
  const config = DEVICE_PROFILES[profile];
  if (!config) throw new Error(`unknown --profile '${profile}' (${Object.keys(DEVICE_PROFILES).join(", ")})`);
  return config.count;
}

/** Most shards a profile runs: OPPI_UI_SHARDS or the profile default, never more than its slots. */
export function shardCap(profile: string, env: NodeJS.ProcessEnv = process.env): number {
  const asked = env.OPPI_UI_SHARDS === undefined ? DEFAULT_SHARDS[profile] ?? 1 : Number(env.OPPI_UI_SHARDS);
  if (!Number.isInteger(asked) || asked < 1) throw new Error(`invalid OPPI_UI_SHARDS ${env.OPPI_UI_SHARDS}`);
  return Math.min(asked, profileSlots(profile));
}

/**
 * `filters` with the quarantined UI tests (`OppiUITests/<Class>[/<test>]`) taken out: a filter an
 * entry covers is dropped, and an entry inside a named class is returned in `skip` (as `Class/test`)
 * for planShards to skip. `watched`: the quarantined tests this selection names, for the non-blocking run.
 */
export function applyQuarantine(filters: string[], quarantined: string[]): { filters: string[]; skip: string[]; watched: string[] } {
  const ids = quarantined.map((id) => id.replace(/\(\)$/, ""));
  const kept: string[] = [];
  const skip = new Set<string>();
  const watched = new Set<string>();
  for (const filter of normalizeFilters(filters)) {
    if (ids.some((id) => filter === id || filter.startsWith(`${id}/`))) {
      watched.add(filter);
      continue;
    }
    kept.push(filter);
    for (const id of ids.filter((id) => id.startsWith(`${filter}/`))) {
      skip.add(id.slice(`${BUNDLE}/`.length));
      watched.add(id);
    }
  }
  return { filters: kept, skip: [...skip], watched: [...watched] };
}

/**
 * Split `filters` (`OppiUITests/<Class>[/<test>]`) into at most `cap` shards. Greedy longest-first:
 * each unit goes to the currently lightest shard. `shards` forces the count (clamped to the units).
 * `skip`: `Class/test` ids (quarantined) that no shard runs or expects.
 */
export function planShards(
  filters: string[],
  classes: Map<string, UIClass>,
  weights: Record<string, number>,
  cap: number,
  shards?: number,
  skip: string[] = [],
): ShardPlan[] {
  const fallback = medianSeconds(Object.values(weights));
  const secondsOf = (cls: string, test: string) => weights[`${cls}/${test}`] ?? fallback;
  const skipped = new Set(skip);
  const skipFlags = (cls: string) => skip.filter((id) => id.startsWith(`${cls}/`)).map((id) => `-skip-testing:${BUNDLE}/${id}`);
  const runnable = (cls: string) => testsOf(cls, classes)?.filter((test) => !skipped.has(`${cls}/${test}`));
  const classUnit = (target: string, cls: string, tests: string[]): Unit => ({
    label: cls,
    flags: [`-only-testing:${target}/${cls}`, ...skipFlags(cls)],
    seconds: tests.reduce((sum, test) => sum + secondsOf(cls, test), 0),
    tests: tests.length,
    ids: tests.map((test) => `${cls}/${test}`),
  });
  let units: Unit[] = normalizeFilters(filters).map((filter) => {
    const [target, cls, test, ...rest] = filter.split("/");
    if (!test) {
      const tests = runnable(cls);
      if (tests && tests.length > 0) return classUnit(target, cls, tests);
      // A class the scan cannot list: xcodebuild decides what it holds; weigh it by what was recorded.
      const recorded = Object.entries(weights).filter(([id]) => id.startsWith(`${cls}/`));
      return { label: cls, flags: [`-only-testing:${filter}`, ...skipFlags(cls)], seconds: recorded.length > 0 ? recorded.reduce((sum, [, s]) => sum + s, 0) : fallback, tests: undefined, ids: [] };
    }
    // A named test, or a nested type the scan does not model: one unit as named.
    return { label: filter.slice(target.length + 1), flags: [`-only-testing:${filter}`], seconds: rest.length === 0 ? secondsOf(cls, test) : fallback, tests: rest.length === 0 ? 1 : undefined, ids: rest.length === 0 ? [`${cls}/${test}`] : [] };
  });
  const total = units.reduce((sum, unit) => sum + unit.seconds, 0);
  const count = shards === undefined ? shardCount(total, cap, units.reduce((sum, unit) => sum + (unit.tests ?? 1), 0)) : Math.max(1, Math.min(shards, cap));
  if (count > 1) {
    // A class over half of a shard's share would be the critical path alone: run its methods apart.
    const share = total / count;
    units = units.flatMap((unit) => {
      // A listed class unit: its label is the class (a named test's label has a `/`).
      const cls = !unit.label.includes("/") && unit.tests !== undefined && unit.tests > 1 ? unit.label : undefined;
      const tests = cls ? runnable(cls) : undefined;
      if (!cls || !tests || unit.seconds <= share / 2) return [unit];
      return tests.map((test) => ({ label: `${cls}/${test}`, flags: [`-only-testing:${BUNDLE}/${cls}/${test}`], seconds: secondsOf(cls, test), tests: 1, ids: [`${cls}/${test}`], splitOf: cls }));
    });
  }
  const bins: ShardPlan[] = Array.from({ length: Math.min(count, units.length) }, () => ({ units: [], seconds: 0, tests: 0, ids: [] }));
  for (const unit of [...units].sort((a, b) => b.seconds - a.seconds || a.label.localeCompare(b.label))) {
    const bin = bins.reduce((lightest, next) => (next.seconds < lightest.seconds ? next : lightest));
    bin.units.push(unit);
    bin.seconds += unit.seconds;
    bin.tests = bin.tests === undefined || unit.tests === undefined ? undefined : bin.tests + unit.tests;
  }
  addCatchAlls(bins, skipFlags);
  for (const bin of bins) bin.ids = bin.units.flatMap((unit) => unit.ids);
  return bins;
}

/**
 * A split class must not lose a test the source scan missed (a macro-made or `#if`'d method, one
 * a helper type declares). Like unit-shards' last shard, one shard that already runs methods of the
 * class takes a catch-all: the whole class, skipping the methods other shards run. Every method the
 * scan did find still runs exactly once, and an unlisted one runs in the catch-all shard.
 */
function addCatchAlls(bins: ShardPlan[], skipFlags: (cls: string) => string[]): void {
  const classes = new Set(bins.flatMap((bin) => bin.units.flatMap((unit) => (unit.splitOf ? [unit.splitOf] : []))));
  for (const cls of classes) {
    const holders = bins.filter((bin) => bin.units.some((unit) => unit.splitOf === cls));
    const keeper = holders.reduce((lightest, next) => (next.seconds < lightest.seconds ? next : lightest));
    const mine = keeper.units.filter((unit) => unit.splitOf === cls);
    const elsewhere = holders.filter((bin) => bin !== keeper).flatMap((bin) => bin.units.filter((unit) => unit.splitOf === cls));
    keeper.units = [
      ...keeper.units.filter((unit) => unit.splitOf !== cls),
      {
        label: cls,
        flags: [`-only-testing:${BUNDLE}/${cls}`, ...elsewhere.flatMap((unit) => unit.ids.map((id) => `-skip-testing:${BUNDLE}/${id}`)), ...skipFlags(cls)],
        seconds: mine.reduce((sum, unit) => sum + unit.seconds, 0),
        tests: mine.length,
        ids: mine.flatMap((unit) => unit.ids),
        catchAll: true,
      },
    ];
  }
}

/** xcodebuild filter flags of one shard. */
export const shardFlags = (plan: ShardPlan): string[] => plan.units.flatMap((unit) => unit.flags);

/** Short description of a shard's units: `ChatRoutesUITests (3), RouterModalSitesUITests/testX`. */
export function describeShard(plan: ShardPlan): string {
  const byClass = new Map<string, number>();
  const single: string[] = [];
  for (const unit of plan.units) {
    const cls = unit.label.split("/")[0];
    if (unit.catchAll) single.push(`${cls} (${unit.tests} test${unit.tests === 1 ? "" : "s"} + any the scan missed)`);
    else if (unit.label.includes("/") && unit.tests === 1) byClass.set(cls, (byClass.get(cls) ?? 0) + 1);
    else single.push(unit.label);
  }
  return [...single, ...[...byClass].map(([cls, n]) => `${cls} (${n} test${n === 1 ? "" : "s"})`)].join(", ");
}

/** `Class/test` ids of the test cases a finished run executed, from the log its sim-pool summary names. */
export function ranTestIds(summary: string | undefined): Set<string> {
  const ran = new Set<string>();
  if (!summary || !existsSync(summary)) return ran;
  const log = JSON.parse(readFileSync(summary, "utf8")).log_path as string | undefined;
  if (!log || !existsSync(log)) return ran;
  for (const match of readFileSync(log, "utf8").matchAll(/^Test Case '-\[OppiUITests\.(\w+) (test\w*)\]' (?:passed|failed|skipped) \(/gm)) ran.add(`${match[1]}/${match[2]}`);
  return ran;
}

/**
 * Planned tests a shard did not run although xcodebuild passed: the shard's own list, compared
 * as ids, so one missing test cannot hide behind an extra one.
 */
export function missingTests(plan: ShardPlan, ran: Set<string>): string[] {
  return plan.ids.filter((id) => !ran.has(id));
}

/** Tests a shard ran that no shard planned, in a class the plan split: tests the source scan missed. */
export function unplannedTests(plans: ShardPlan[], index: number, ran: Set<string>): string[] {
  const planned = new Set(plans.flatMap((plan) => plan.ids));
  const caught = new Set(plans[index].units.filter((unit) => unit.catchAll).map((unit) => unit.label));
  return [...ran].filter((id) => caught.has(id.split("/")[0]) && !planned.has(id)).sort();
}

function swiftSources(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return swiftSources(path);
    return entry.name.endsWith(".swift") ? [readFileSync(path, "utf8")] : [];
  });
}

const loadClasses = () => scanUIClasses(SOURCE_DIRS.flatMap((dir) => swiftSources(join(appleDir, dir))));
const loadWeights = (): Record<string, number> => (existsSync(weightsPath) ? JSON.parse(readFileSync(weightsPath, "utf8")) : {});

/** The xcresult of a finished run, from the derived data path its sim-pool summary names. */
function xcresultOf(summary: string | undefined): string | undefined {
  if (!summary || !existsSync(summary)) return undefined;
  const derivedData = JSON.parse(readFileSync(summary, "utf8")).derived_data_path as string | undefined;
  const logs = derivedData ? join(derivedData, "Logs", "Test") : "";
  const bundle = existsSync(logs) ? readdirSync(logs).filter((name) => name.endsWith(".xcresult")).sort().at(-1) : undefined;
  return bundle ? join(logs, bundle) : undefined;
}

function option(argv: string[], flag: string): string | undefined {
  const at = argv.indexOf(flag);
  return at >= 0 ? argv[at + 1] : undefined;
}

async function main(argv: string[]): Promise<number> {
  const record = argv.indexOf("--record");
  if (record >= 0) {
    const logs = argv.slice(record + 1);
    if (logs.length === 0) throw new Error("--record needs at least one sim-pool log");
    // New medians replace old ones; tests the logs do not mention keep their record.
    const weights = pruneStale({ ...loadWeights(), ...recordUIWeights(logs.map((path) => readFileSync(path, "utf8"))) }, loadClasses());
    writeFileSync(weightsPath, `${JSON.stringify(Object.fromEntries(Object.entries(weights).sort(([a], [b]) => a.localeCompare(b))), null, 1)}\n`);
    console.log(`[ui-shards] recorded ${Object.keys(weights).length} test timings in ${weightsPath}`);
    return 0;
  }
  const separator = argv.indexOf("--");
  const flags = separator >= 0 ? argv.slice(0, separator) : argv;
  const filters = separator >= 0 ? argv.slice(separator + 1) : [];
  const profile = option(flags, "--profile") ?? "iphone";
  const forced = option(flags, "--shards");
  const bad = filters.filter((filter) => !/^OppiUITests(?:\/[\w.()-]+)+$/.test(filter));
  if (filters.length === 0 || bad.length > 0) {
    console.error(`[ui-shards] usage: ui-shards.ts [--profile p] [--shards N] [--plan] -- OppiUITests/<Class>[/<test>]...${bad.length > 0 ? ` (not a UI filter: ${bad.join(", ")})` : ""}`);
    return 2;
  }
  if (forced !== undefined && (!Number.isInteger(Number(forced)) || Number(forced) < 1)) throw new Error(`invalid shard count ${forced}`);
  // --shards N forces the count past OPPI_UI_SHARDS and the time rule; only the profile's slots and the test count limit it.
  const cap = forced === undefined ? shardCap(profile) : profileSlots(profile);
  const laneStarted = Date.now();
  const lane = `ui-${profile}`;
  const quarantine = loadQuarantine(quarantinePath, BUNDLE);
  if (quarantine.problems.length > 0) {
    for (const problem of quarantine.problems) console.error(`[ui-shards] ${problem}`);
    return 1;
  }
  const quarantined = applyQuarantine(filters, quarantine.active.map((entry) => entry.id));
  if (quarantined.watched.length > 0) {
    const owners = quarantine.active.filter((entry) => quarantined.watched.some((id) => id === entry.id.replace(/\(\)$/, "") || id.startsWith(`${entry.id}/`)));
    console.log(`[ui-shards] quarantined, run without blocking: ${quarantined.watched.join(", ")} (${owners.map((entry) => `${entry.id}: owner ${entry.owner}, expires ${entry.expires}, backlog ${entry.backlog}`).join("; ")})`);
  }
  const plans = quarantined.filters.length === 0 ? [] : planShards(quarantined.filters, loadClasses(), loadWeights(), cap, forced === undefined ? undefined : Number(forced), quarantined.skip);
  const estimate = Math.round(plans.reduce((sum, plan) => sum + plan.seconds, 0));
  console.log(`[ui-shards] ${profile}: ${plans.length} shard${plans.length === 1 ? "" : "s"} (cap ${cap}), ${estimate}s of recorded tests`);
  for (const [index, plan] of plans.entries()) {
    console.log(`[ui-shards] shard ${index + 1}/${plans.length}: ~${Math.round(plan.seconds)}s, ${plan.tests ?? "?"} tests: ${describeShard(plan)}`);
  }
  if (flags.includes("--plan")) return 0;

  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
  const runDir = runDirectory(join(appleDir, ".build"), `ui-shards-${stamp}`);
  // sim-pool clones the products into runDir under the same checkout lock as the build, so
  // another run in this checkout cannot swap them in between. The build is slotless and the same
  // for every profile.
  const build = spawnSync(join(scriptDir, "sim-pool.sh"), ["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", SCHEME, "build-for-testing"], {
    cwd: appleDir,
    stdio: "inherit",
    env: { ...process.env, OPPI_SIM_POOL_PRODUCTS_DIR: runDir },
  });
  if (build.status !== 0) {
    console.error(`[ui-shards] build failed (exit ${build.status ?? build.signal})`);
    return build.status || 1;
  }
  const xctestrun = findXctestrun(join(runDir, "Build", "Products"), SCHEME);
  const outDir = join(runDir, "shards");
  mkdirSync(outDir, { recursive: true });
  console.log(`[ui-shards] ${plans.length} shards from ${relative(appleDir, xctestrun)}; outputs in ${outDir}`);
  const started = Date.now();
  const env = { ...process.env, OPPI_SIM_DEVICE_PROFILE: profile };
  const results = await Promise.all(plans.map((plan, index) => runShard(index, xctestrun, shardFlags(plan), outDir, `shard-${index + 1}`, env, true)));
  const testFailures: string[] = [];
  const infraFailures: string[] = [];
  /** Tests still red after the rerun (or with no rerun), and the ones that passed only on it. */
  const failing: string[] = [];
  const flaky: string[] = [];
  const caseSeconds: number[] = [];
  for (const result of results) {
    const output = readFileSync(result.output, "utf8");
    const infra = infrastructureFailure(result, output);
    const ran = ranTestIds(result.summary);
    const missing = result.code === 0 && !infra ? missingTests(plans[result.index], ran) : [];
    const mismatch = missing.length > 0 ? `planned tests that did not run: ${missing.join(", ")}` : undefined;
    const unplanned = unplannedTests(plans, result.index, ran);
    let ok = result.code === 0 && !infra && !mismatch;
    const xcresult = xcresultOf(result.summary);
    caseSeconds.push(...xctestCaseSeconds(logOfSummary(result.summary)));
    console.log(`[ui-shards] shard ${result.index + 1}/${plans.length}: ${ok ? "PASS" : infra ? "INFRASTRUCTURE FAIL" : "FAIL"} exit=${result.code} tests=${result.tests} ${result.seconds}s output=${result.output}${result.summary ? ` summary=${result.summary}` : ""}${xcresult ? ` xcresult=${xcresult}` : ""}`);
    if (result.tests === 0) console.log(`[ui-shards] ${result.label}: ${zeroTestLine(selectorsOf(shardFlags(plans[result.index])), result.code === 0)}`);
    if (unplanned.length > 0) console.log(`[ui-shards] ${result.label}: ran ${unplanned.length} test(s) the source scan did not list (the class's catch-all): ${unplanned.join(", ")}`);
    if (!ok) {
      // sim-pool's own summary (failures, log path) ends the shard output.
      process.stdout.write(`${output.trimEnd().split("\n").slice(-40).join("\n")}\n`);
      if (infra) console.log(`[ui-shards] ${result.label}: ${infra}; no test failed, so there is nothing to rerun`);
      if (mismatch) {
        console.log(`[ui-shards] ${result.label}: ${mismatch}`);
        failing.push(...missing.map((id) => `${BUNDLE}/${id}`));
      }
      if (!infra && !mismatch) {
        const rerun = await rerunShard(result, xctestrun, outDir, env, lane, profile);
        ok = rerun.ok;
        failing.push(...rerun.failing);
        flaky.push(...rerun.flaky);
      }
      if (!ok) (infra ? infraFailures : testFailures).push(result.label);
    }
  }
  if (quarantined.watched.length > 0) {
    // Quarantined tests still run, on the same products and profile, but never block.
    const watch = await runShard(plans.length, xctestrun, quarantined.watched.map((id) => `-only-testing:${id}`), outDir, "quarantined", env, true);
    console.log(`[ui-shards] quarantined (non-blocking): ${watch.code === 0 ? "passed" : "failed"} ${quarantined.watched.join(", ")} output=${watch.output}`);
  }
  for (const id of failing) console.log(`[ui-shards] FAILED ${id}`);
  // sim-pool stops xcodebuild once the test run completes, which can leave an xcresult unreadable.
  console.log("[ui-shards] xcresult paths are best effort: sim-pool stops xcodebuild when the tests finish, so a bundle may be unreadable; the shard output and the sim-pool log are the record");
  const total = results.reduce((sum, result) => sum + result.tests, 0);
  const wall = Math.round((Date.now() - started) / 1000);
  console.log(`[ui-shards] ${verdict(testFailures, infraFailures)}: ${total} tests in ${plans.length} shards, longest ${Math.max(0, ...results.map((r) => r.seconds))}s, ${wall}s wall after the build`);
  const { budgets, warnings } = loadBudgets();
  const budget = budgetVerdict(lane, { wall: Math.round((Date.now() - laneStarted) / 1000), medianTest: median(caseSeconds), tests: caseSeconds.length }, budgets);
  for (const warning of warnings) console.log(`[ui-shards] ${warning}`);
  console.log(`[ui-shards] ${budget.line}`);
  if (budget.warning) console.log(`[ui-shards] ${budget.warning}`);
  // No plans: every named test is quarantined, so nothing blocking had to run.
  if (total === 0 && plans.length > 0) {
    console.log(`[ui-shards] ${zeroTestLine(quarantined.filters, results.every((result) => result.code === 0))}`);
    return 1;
  }
  if (testFailures.length + infraFailures.length > 0) return 1;
  // A red run hides nothing: its failures are printed above.
  console.log(`[ui-shards] ${hiddenFlakesLine(flaky.map((id) => ({ id, lane })))}`);
  return 0;
}

/** The `-only-testing` values of a shard's flags: the selectors it was given. */
const selectorsOf = (flags: string[]) => flags.filter((flag) => flag.startsWith("-only-testing:")).map((flag) => flag.slice("-only-testing:".length));

/**
 * Rerun a finished shard's failed tests once, on the same products and profile. A test that passes
 * is FLAKY: it does not block, and the rerun ledger counts the gates it flaked in. A run that did not
 * finish (some tests may never have started), a failure outside any test, or more than
 * XCTEST_RERUN_LIMIT failures stays red without a rerun. Ids are full `OppiUITests/<Class>/<test>`.
 */
async function rerunShard(
  result: ShardResult,
  xctestrun: string,
  outDir: string,
  env: NodeJS.ProcessEnv,
  lane: string,
  profile: string,
): Promise<{ ok: boolean; failing: string[]; flaky: string[] }> {
  const log = logOfSummary(result.summary);
  const candidates = xctestRerun(log);
  if ("reason" in candidates) {
    console.log(`[ui-shards] ${result.label}: no rerun (${candidates.reason})`);
    return { ok: false, failing: failedXCTestCases(log), flaky: [] };
  }
  const ids = candidates.ids;
  const rerun = await runShard(result.index, xctestrun, ids.map((id) => `-only-testing:${id}`), outDir, `${result.label}-rerun`, env, true);
  const passed = passedXCTestCases(logOfSummary(rerun.summary));
  const ok = rerun.code === 0 && ids.every((id) => passed.has(id));
  console.log(`[ui-shards] ${result.label} rerun of ${ids.length} failed test${ids.length === 1 ? "" : "s"}: ${ok ? "PASS" : "FAIL"} output=${rerun.output}`);
  // A red rerun in which every test passed failed outside them: none of them is cleared.
  const stillRed = ok ? [] : ids.filter((id) => !passed.has(id));
  const red = new Set(!ok && stillRed.length === 0 ? ids : stillRed);
  const failing: string[] = [];
  const flaky: string[] = [];
  for (const id of ids) {
    const outcome = red.has(id) ? "failed" : "flaky";
    const gates = recordRerun(appleDir, { id, lane, profile, outcome });
    if (outcome === "failed") {
      failing.push(id);
      continue;
    }
    flaky.push(id);
    console.log(`[ui-shards] FLAKY ${id}: failed, then passed on rerun (flaked in ${gates} gate${gates === 1 ? "" : "s"})${gates >= 2 ? "; quarantine it in dev/testing/quarantine.json with an owner, an expiry, and a backlog key" : ""}`);
  }
  return { ok, failing, flaky };
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
