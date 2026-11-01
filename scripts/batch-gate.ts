#!/usr/bin/env bun
// Repository gate for a batch of commits: a merge queue or CI runs it after `.githooks/pre-push`
// passes on the batch, with the named suites every commit in the batch asked for.
//
//   bun scripts/batch-gate.ts --worktree <path> [--target <branch>] [--test <s>[@<p>[,<p>]]]... [--profile <p>]...
//
// --worktree defaults to the current directory; the gate resolves symlinks in it, so lanes run
// at the checkout's canonical path (the one pre-push built in). --target is the branch the batch will
// land on: the gate replays the pre-push plan for `merge-base(HEAD, target)..HEAD`, and when that plan
// ran the Apple lane (every OppiUnitTests test, in clients/apple/scripts/unit-shards.ts) it checks the
// named OppiTests selectors against the tests that run executed (unmatchedUnitSelectors) but does
// not run them again. Without --target, or without a readable record of that run, the ios-unit lane runs.
//
// `bun scripts/batch-gate.ts --supports-profile-scope` prints PROFILE_SCOPE_CAPABILITY and exits 0
// without running anything: a queue probes it before passing @<profile> selectors, because a gate
// from before that suffix exists rejects it. An older gate exits 2 on the unknown flag.
//
// Exit codes: 0 every lane passed (or no suites were named); 1 a lane failed, or an entry of
// dev/testing/quarantine.json expired or lacks a field; 2 a bad argument, test selector, or not an
// Oppi checkout; 143 stopped by SIGTERM/SIGINT; the failing exit code of the server-deps sync, which
// runs before any lane.
//
// The summary prints each lane's wall time against its budget (dev/testing/lane-budgets.json; over
// budget is a warning), the flakes that a rerun hid at this HEAD (pre-push's unit shards included),
// and, for each red lane, a guessed cause. In a land-queue batch (LAND_QUEUE_BATCH) each red lane is
// appended to the red-lane ledger (scripts/gate-report.ts).
//
// --test values:
//   OppiTests/<Suite>[/<test>]      iOS unit filter; one OppiUnitTests run on the iPhone pool
//   OppiUITests/<Suite>[/<test>]    UI test filter; one lane per profile, profiles in parallel. A
//                                   profile's lane holds only the filters scoped to it (see
//                                   "@<profile>" below); an unscoped filter runs on every --profile
//                                   (iphone, ipad, duo; default iphone). A lane builds once and runs
//                                   its filters as parallel shards in that profile's pool slots
//                                   (clients/apple/scripts/ui-shards.ts)
//   OppiE2ETests/<Suite>[/<test>]   paired-server E2E filter (clients/apple/scripts/e2e.sh --native).
//                                   A suite that reads the two-server fixture (its file calls
//                                   TwoServerFixture.<member>) runs through server/scripts/e2e-two-server.ts
//                                   instead, which owns the second server that suite pairs with.
//   <Suite>Tests[/<test>]           a bare iOS selector (suite name ending in Tests): runs as
//                                   <Target>/<Suite>Tests[/<test>] for the one test target
//                                   (OppiTests, OppiUITests, OppiE2ETests) that declares it; the gate
//                                   logs the resolution. Declared in no target, or in several
//                                   (QAVerificationSupport is in both UI and E2E), is an error that
//                                   lists the prefixed forms to choose from. Other bare names are unknown.
//   e2e-group:<name>                an E2E group (clients/apple/scripts/e2e.sh --group <name>)
//   server/tests/<file>.test.ts     a server Vitest file (the `server/` prefix is optional)
// Any --test value may end in @<profile>[,<profile>]: the profiles its UI tests run on, so a batch of
// commits does not run one commit's iPhone-only suite on another's iPad lane. Only UI tests are
// profile-specific; the scope is ignored for every other kind. The same selector named twice, or
// with a different scope, collapses to one filter per profile.
// Anything else fails the gate: a typo must not pass as "nothing to run". So does a suite
// that the test target does not declare, and an iOS run that executed zero tests (the lane names
// the selector).
// A failed E2E step whose run finished reruns its failed tests once (at most XCTEST_RERUN_LIMIT),
// like the UI and unit shards: a pass on the rerun is a flake, recorded in the rerun ledger, and the
// step passes. Quarantined E2E tests are skipped and run in non-blocking steps.
// Every lane runs even when an earlier one failed, so one gate reports every red suite.
// Lane output is prefixed with the lane name; SIGTERM/SIGINT stop every lane's process group.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { loadQuarantine, runFailures, runTestIds, UNIT_RUN_RECORD, type QuarantineEntry } from "../clients/apple/scripts/unit-shards";
import {
  budgetVerdict, failedTestsInOutput, failedXCTestCases, flakesAtHead, hiddenFlakesLine, lastArtifact, loadBudgets, logOfSummary, passedXCTestCases,
  headOf, recordRedLane, recordRerun, redLaneLine, xctestRerun, zeroTestLine,
} from "./gate-report";
import { planForPaths } from "./pre-push-plan";

/**
 * `requireTests`: a sim-pool run whose log must show at least one executed test.
 * `selectors`: what the step runs, named when it runs zero tests.
 * `rerun`: how a failed E2E step reruns its failed tests once: through e2e.sh, or the two-server wrapper.
 * `blocking: false`: a quarantine watch run, whose result never fails the lane.
 */
type Step = {
  cwd: string;
  command: string;
  args: string[];
  env?: NodeJS.ProcessEnv;
  requireTests?: boolean;
  selectors?: string[];
  rerun?: "e2e" | "two-server";
  blocking?: false;
};
/** Lanes run in parallel; a lane's steps run in order and all run even after one fails. `profile`: the simulator profile, for the ledgers. */
type Lane = { name: string; profile: string | null; steps: Step[] };

/** The line `--supports-profile-scope` prints; the queue matches it exactly (land-queue.ts gateSupportsProfileScope). */
export const PROFILE_SCOPE_CAPABILITY = "batch-gate: profile-scope";

const PROFILES = new Set(["iphone", "ipad", "duo"]);

/**
 * `resolutions`: one line per bare iOS selector, naming the prefixed filter it became.
 * `notes`: what the plan left out or made non-blocking, and why (a covered ios-unit lane, quarantine).
 */
export type Plan = { lanes: Lane[]; errors: string[]; resolutions: string[]; notes: string[]; unit: string[] };

/**
 * `unitShardsRan`: the pre-push gate of this checkout ran every OppiUnitTests test (prePushRanUnitShards),
 * so named OppiTests selectors are checked but not run again.
 * `quarantined`: entries in force from dev/testing/quarantine.json; the E2E lane honours its own bundle's.
 */
export type PlanOptions = { unitShardsRan?: boolean; quarantined?: QuarantineEntry[] };

/**
 * `functionsOf`: functions declared in the files that declare or extend each type.
 * `twoServer`: types declared in a file that calls the two-server fixture (`TwoServerFixture.<member>`);
 * their tests need the second server that `server/scripts/e2e-two-server.ts` starts.
 */
export type Declarations = { types: Set<string>; functionsOf: Map<string, Set<string>>; twoServer: Set<string> };

/** Swift string literals (kept) and comments (dropped), so prose in a comment is not a declaration. */
const STRINGS_AND_COMMENTS = /"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|(\/\*[\s\S]*?\*\/|\/\/[^\n]*)/g;
const stripComments = (text: string) => text.replace(STRINGS_AND_COMMENTS, (all, comment) => (comment === undefined ? all : " "));

/** Type and function names declared in a test target's Swift sources, for checking filters. */
export function declarations(sources: string[]): Declarations {
  const types = new Set<string>();
  const functionsOf = new Map<string, Set<string>>();
  const twoServer = new Set<string>();
  for (const source of sources) {
    const text = stripComments(source);
    // A call such as `TwoServerFixture.load()`; the type's own declaration is not a use.
    const usesFixture = /\bTwoServerFixture\./.test(text);
    const functions = [...text.matchAll(/\bfunc\s+(\w+)/g)].map((match) => match[1]);
    for (const match of text.matchAll(/\b(struct|class|enum|actor|extension)\s+(\w+)/g)) {
      if (match[1] !== "extension") types.add(match[2]);
      if (usesFixture) twoServer.add(match[2]);
      const known = functionsOf.get(match[2]) ?? new Set<string>();
      for (const name of functions) known.add(name);
      functionsOf.set(match[2], known);
    }
  }
  return { types, functionsOf, twoServer };
}

/** Source folders compiled into each test target (project.yml). */
const TARGET_SOURCES: Record<string, string[]> = {
  OppiTests: ["OppiTests"],
  OppiUITests: ["OppiUITests", "QAVerificationSupport"],
  OppiE2ETests: ["OppiE2ETests", "QAVerificationSupport"],
};

/** A `<Suite>Tests[/<test>]` selector with no target prefix; the Tests suffix is the suite naming convention, so helper types never match. */
const BARE_IOS_SELECTOR = /^[A-Za-z_]\w*Tests(?:\/[\w.()-]+)*$/;
const NOT_BARE = new Set(Object.keys(TARGET_SOURCES));

/**
 * Why a `Target/Suite[/Nested...][/test]` filter names nothing the target declares, or null.
 * Middle segments are types; a last segment that is not a declared type is a test method
 * (`name()` for Swift Testing, `testName` for XCTest) declared with the suite before it.
 */
export function undeclaredFilter(filter: string, declared: Declarations): string | null {
  const [target, ...segments] = filter.split("/");
  for (const [index, segment] of segments.entries()) {
    const last = index === segments.length - 1 && index > 0;
    if (declared.types.has(segment) && !segment.endsWith(")")) continue;
    if (last && declared.functionsOf.get(segments[index - 1])?.has(segment.replace(/\(.*\)$/, ""))) continue;
    return last ? `${segments[index - 1]} declares no test ${segment}` : `${target} declares no type ${segment}`;
  }
  return null;
}

export function swiftSources(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return swiftSources(path);
    return entry.name.endsWith(".swift") ? [readFileSync(path, "utf8")] : [];
  });
}

/** A `--test` value split into its selector and the profiles it is scoped to (none when unscoped). */
function splitScope(test: string): { selector: string; scope: string[] } {
  const at = test.lastIndexOf("@");
  if (at < 0) return { selector: test, scope: [] };
  return { selector: test.slice(0, at), scope: test.slice(at + 1).split(",") };
}

export function planGate(
  worktree: string,
  tests: string[],
  profiles: string[],
  declaredIn: (target: string) => Declarations = (target) =>
    declarations((TARGET_SOURCES[target] ?? [target]).flatMap((dir) => swiftSources(join(worktree, "clients", "apple", dir)))),
  options: PlanOptions = {},
): Plan {
  const errors: string[] = [];
  const notes: string[] = [];
  const unit = new Set<string>();
  /** Profile -> UI filters scoped to it, in the order first named. */
  const uiByProfile = new Map<string, Set<string>>();
  const e2e = new Set<string>();
  const groups = new Set<string>();
  const server = new Set<string>();
  const resolved: { filter: string; line: string }[] = [];
  const known = new Map<string, Declarations>();
  const declared = (target: string) => {
    if (!known.has(target)) known.set(target, declaredIn(target));
    return known.get(target)!;
  };
  const defaultProfiles = profiles.length > 0 ? profiles : ["iphone"];
  const scopeUi = (filter: string, scope: string[]) => {
    for (const profile of scope.length > 0 ? scope : defaultProfiles) {
      if (!uiByProfile.has(profile)) uiByProfile.set(profile, new Set());
      uiByProfile.get(profile)!.add(filter);
    }
  };
  for (const named of tests) {
    const { selector: test, scope } = splitScope(named);
    for (const profile of scope) {
      if (!PROFILES.has(profile)) errors.push(`unknown profile '${profile}' in --test '${named}' (iphone, ipad, duo)`);
    }
    if (/^OppiTests(?:\/[\w.()-]+)+$/.test(test)) unit.add(test);
    else if (/^OppiUITests(?:\/[\w.()-]+)+$/.test(test)) scopeUi(test, scope);
    else if (/^OppiE2ETests(?:\/[\w.()-]+)+$/.test(test)) e2e.add(test);
    else if (/^e2e-group:[\w-]+$/.test(test)) groups.add(test.slice("e2e-group:".length));
    else if (/^(?:server\/)?tests\/[\w./-]+\.test\.ts$/.test(test) && !test.includes("..")) server.add(test.replace(/^server\//, ""));
    else if (BARE_IOS_SELECTOR.test(test) && !NOT_BARE.has(test.split("/")[0])) {
      // A bare `<Suite>[/<test>]` names the one test target that declares <Suite>.
      const suite = test.split("/")[0];
      const owners = Object.keys(TARGET_SOURCES).filter((target) => declared(target).types.has(suite));
      if (owners.length === 0) errors.push(`unknown --test '${test}': no test target declares ${suite}`);
      else if (owners.length > 1) errors.push(`ambiguous --test '${test}': declared in ${owners.length} test targets; use ${owners.map((target) => `'${target}/${test}'`).join(" or ")}`);
      else {
        const filter = `${owners[0]}/${test}`;
        resolved.push({ filter, line: `--test '${test}' resolved to ${filter}` });
        if (owners[0] === "OppiUITests") scopeUi(filter, scope);
        else (owners[0] === "OppiTests" ? unit : e2e).add(filter);
      }
    } else errors.push(`unknown --test '${named}'`);
  }
  for (const profile of profiles) {
    if (!PROFILES.has(profile)) errors.push(`unknown --profile '${profile}' (iphone, ipad, duo)`);
  }
  const failed = new Set<string>();
  const allUi = new Set([...uiByProfile.values()].flatMap((filters) => [...filters]));
  for (const filter of [...unit, ...allUi, ...e2e]) {
    const problem = undeclaredFilter(filter, declared(filter.split("/")[0]));
    if (problem) {
      errors.push(`--test '${filter}': ${problem}`);
      failed.add(filter);
    }
  }
  const resolutions = resolved.filter(({ filter }) => !failed.has(filter)).map(({ line }) => line);
  const apple = join(worktree, "clients", "apple");
  const simPool = join(apple, "scripts", "sim-pool.sh");
  const uiShards = join(apple, "scripts", "ui-shards.ts");
  const e2eScript = join(apple, "scripts", "e2e.sh");
  // sim-pool prefers an inherited OPPI_ROOT over the cwd; a caller's own checkout must not
  // win over the worktree under test, or the gate would build and test different code.
  const pinned = { OPPI_ROOT: worktree };
  const lanes: Lane[] = [];
  if (server.size > 0) {
    lanes.push({ name: "server", profile: null, steps: [{ cwd: join(worktree, "server"), command: "npm", args: ["exec", "--offline", "--", "vitest", "run", ...server] }] });
  }
  const unitHeld = holdQuarantined([...unit], options.quarantined ?? [], "OppiTests");
  // The pre-push unit shards run the whole OppiUnitTests scheme, whose only test target is OppiTests,
  // on this same HEAD: every named unit selector already ran there (a quarantined one without
  // blocking). The selectors above were still checked, and main() checks that each one matched a
  // test of that run.
  if (unit.size > 0 && options.unitShardsRan) {
    if (unitHeld.blocking.length > 0) notes.push(`ios-unit: not run; the pre-push gate already ran every OppiUnitTests test in its unit shards, including ${unitHeld.blocking.join(", ")}`);
    if (unitHeld.watched.length > 0) notes.push(`ios-unit: quarantined, run without blocking by the pre-push unit shards: ${unitHeld.watched.join(", ")} (${unitHeld.owners})`);
  } else if (unit.size > 0) {
    const unitRun = (filters: string[], skips: string[]) => ["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test", ...filters.map((f) => `-only-testing:${f}`), ...skips.map((id) => `-skip-testing:${id}`)];
    const steps: Step[] = [];
    if (unitHeld.blocking.length > 0) {
      const skips = unitHeld.blocking.flatMap(unitHeld.skipsIn);
      steps.push({ cwd: apple, command: simPool, args: unitRun(unitHeld.blocking, skips), env: pinned, requireTests: true, selectors: unitHeld.blocking });
    }
    if (unitHeld.watched.length > 0) {
      notes.push(`ios-unit: quarantined, run without blocking: ${unitHeld.watched.join(", ")} (${unitHeld.owners})`);
      steps.push({ cwd: apple, command: simPool, args: unitRun(unitHeld.watched, []), env: pinned, selectors: unitHeld.watched, blocking: false });
    }
    lanes.push({ name: "ios-unit", profile: "iphone", steps });
  }
  // One lane per profile; ui-shards.ts builds once and splits the profile's filters over its pool
  // slots (see its header). It fails a shard that ran no tests and a run that executed none, so the
  // lane does not need the zero-test check, which reads one sim-pool log.
  for (const [profile, filters] of uiByProfile) {
    lanes.push({
      name: `ui-${profile}`,
      profile,
      steps: [{ cwd: apple, command: "bun", args: [uiShards, "--profile", profile, "--", ...filters], env: pinned }],
    });
  }
  // E2E runs start a paired server each; keep them one after another in a single lane.
  // A two-server suite runs through its wrapper, which starts the second server and then
  // runs e2e.sh for that one suite; its `TWO_SERVER_TEST` is `<Suite>[/<test>]`.
  const twoServerScript = join(worktree, "server", "scripts", "e2e-two-server.ts");
  const needsTwoServer = (filter: string) => declared("OppiE2ETests").twoServer.has(filter.split("/")[1]);
  const twoServerStep = (filter: string, extra: Partial<Step>): Step => ({
    cwd: worktree,
    command: "bun",
    args: [twoServerScript],
    env: { ...pinned, TWO_SERVER_TEST: filter.slice("OppiE2ETests/".length) },
    selectors: [filter],
    ...extra,
  });
  const { held, blocking, skipsIn, watched, owners } = holdQuarantined([...e2e], options.quarantined ?? [], "OppiE2ETests");
  const e2eSteps: Step[] = [
    ...blocking.filter((filter) => !needsTwoServer(filter)).map((filter) => ({
      args: ["--native", "--only-testing", filter, ...skipsIn(filter).flatMap((id) => ["--skip-testing", id])],
      selectors: [filter],
    })),
    // A group's members are e2e.sh's to choose; every quarantined E2E test is skipped in it (a skip of a test it does not hold is a no-op).
    ...[...groups].map((group) => ({ args: ["--group", group, ...held.flatMap((id) => ["--skip-testing", id])], selectors: [`e2e-group:${group}`] })),
  ].map(({ args, selectors }) => ({ cwd: worktree, command: e2eScript, args, env: pinned, requireTests: true, selectors, rerun: "e2e" as const }));
  for (const filter of blocking.filter(needsTwoServer)) {
    if (skipsIn(filter).length > 0) notes.push(`e2e: ${filter} runs through the two-server wrapper, which cannot skip tests, so quarantined ${skipsIn(filter).join(", ")} still block`);
    e2eSteps.push(twoServerStep(filter, { requireTests: true, rerun: "two-server" }));
  }
  if (groups.size > 0 && held.length > 0) notes.push(`e2e: groups ${[...groups].join(", ")} skip quarantined ${held.join(", ")} and do not run them`);
  if (watched.length > 0) {
    notes.push(`e2e: quarantined, run without blocking: ${watched.join(", ")} (${owners})`);
    const plain = watched.filter((id) => !needsTwoServer(id));
    if (plain.length > 0) {
      e2eSteps.push({ cwd: worktree, command: e2eScript, args: ["--native", ...plain.flatMap((id) => ["--only-testing", id])], env: pinned, selectors: plain, blocking: false });
    }
    for (const id of watched.filter(needsTwoServer)) e2eSteps.push(twoServerStep(id, { blocking: false }));
  }
  // One filter or group per step, so a step that ran zero tests is caught exactly.
  if (e2eSteps.length > 0) lanes.push({ name: "e2e", profile: process.env.OPPI_SIM_DEVICE_PROFILE ?? "iphone", steps: e2eSteps });
  return { lanes, errors, resolutions, notes, unit: [...unit] };
}

/** A selector's last segment without its Swift Testing parentheses: `Suite/test()` and `Suite/test` name one test. */
const bare = (id: string) => id.replace(/\([^/]*\)$/, "");

/**
 * Quarantine, as the unit shards do it, for one bundle's `filters`: a filter an entry covers leaves
 * the blocking run, and an entry inside a named filter is skipped there (`skipsIn`). `watched`: both
 * kinds, for a run that never blocks. `held`: every entry of the bundle; `owners`: who decides them.
 */
function holdQuarantined(filters: string[], entries: QuarantineEntry[], bundle: string) {
  const mine = entries.filter((entry) => entry.id.startsWith(`${bundle}/`));
  // Skips and watch runs use an entry's id as written, as unit-shards does; matching ignores `()`.
  const held = mine.map((entry) => entry.id);
  const watched = new Set<string>();
  const blocking = filters.filter((filter) => {
    if (!held.some((id) => bare(filter) === bare(id) || filter.startsWith(`${bare(id)}/`))) return true;
    watched.add(filter);
    return false;
  });
  const skipsIn = (filter: string) => held.filter((id) => id.startsWith(`${bare(filter)}/`));
  for (const filter of blocking) for (const id of skipsIn(filter)) watched.add(id);
  const owners = mine.map((entry) => `${entry.id}: owner ${entry.owner}, expires ${entry.expires}, backlog ${entry.backlog}`).join("; ");
  return { held, blocking, skipsIn, watched: [...watched], owners };
}

/**
 * Which named unit selectors matched no test of the pre-push unit run, read from the xcresults of its
 * shards (clients/apple/.build/unit-shards-last.json, written by unit-shards.ts). A selector matches a
 * test it names or a test inside the type it names; Swift Testing's `()` are ignored on both sides, so
 * the check asks whether the named test ran, not how xcodebuild would have spelled the filter. Without
 * a readable record of a unit run at this HEAD the answer is a reason, and the gate runs the lane.
 */
export function unmatchedUnitSelectors(worktree: string, head: string, selectors: string[]): { unmatched: string[] } | { reason: string } {
  const path = join(worktree, "clients", "apple", ".build", UNIT_RUN_RECORD);
  if (!existsSync(path)) return { reason: `no ${UNIT_RUN_RECORD} from the pre-push unit shards` };
  let record: { head?: string; summaries?: string[] };
  try {
    record = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return { reason: `${UNIT_RUN_RECORD} is not JSON` };
  }
  if (record.head !== head) return { reason: `the last unit shards ran at ${String(record.head).slice(0, 9)}, not at HEAD ${head.slice(0, 9)}` };
  const ran = new Set<string>();
  for (const summary of record.summaries ?? []) {
    const tests = runTestIds(summary);
    if ("reason" in tests) return { reason: `unit shard results unreadable: ${tests.reason}` };
    for (const id of tests.ids) ran.add(bare(id));
  }
  if (ran.size === 0) return { reason: "the unit shards' results list no tests" };
  const unmatched = selectors.filter((selector) => {
    const wanted = bare(selector.slice("OppiTests/".length));
    return ![...ran].some((id) => id === wanted || id.startsWith(`${wanted}/`));
  });
  return { unmatched };
}

/**
 * Whether the pre-push gate on this checkout ran the full unit shards: its plan (scripts/pre-push-plan.ts,
 * the same classifier the hook runs) for the paths between `merge-base(HEAD, target)` and HEAD has an
 * Apple lane, and the Apple lane always runs every OppiUnitTests test. A gate runs after pre-push passed
 * on the same HEAD. If the target moved since, its merge base is still the batch's base; if anything
 * is unknown, the answer is no and the ios-unit lane runs.
 */
export function prePushRanUnitShards(worktree: string, target: string | undefined): { ran: boolean; why: string } {
  if (!target) return { ran: false, why: "no --target, so the pre-push plan is unknown" };
  const git = (args: string[]) => spawnSync("git", args, { cwd: worktree, encoding: "utf8" });
  const base = git(["merge-base", "HEAD", target]);
  if (base.status !== 0) return { ran: false, why: `no merge base of HEAD and ${target}` };
  const sha = base.stdout.trim();
  const diff = git(["diff", "--name-only", "--diff-filter=ACMRD", "-z", sha, "HEAD"]);
  if (diff.status !== 0) return { ran: false, why: `git diff ${sha.slice(0, 9)}..HEAD failed` };
  const plan = planForPaths(diff.stdout.split("\0"));
  return { ran: plan.apple !== "none", why: `the pre-push plan for ${sha.slice(0, 9)}..HEAD has apple=${plan.apple}` };
}

/** Tests a finished sim-pool run executed, from the log its summary artifact names. */
export function executedTests(output: string): number {
  const summary = [...output.matchAll(/^Artifact: (.+)$/gm)].at(-1)?.[1];
  if (!summary || !existsSync(summary)) return 0;
  const log = JSON.parse(readFileSync(summary, "utf8")).log_path as string | undefined;
  if (!log || !existsSync(log)) return 0;
  const text = readFileSync(log, "utf8");
  const swift = [...text.matchAll(/^[\u2714\u2718] Test run with ([0-9]+) tests?/gm)].at(-1);
  const xctest = [...text.matchAll(/^Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at .+\r?\n[ \t]+Executed ([0-9]+) tests?/gm)].at(-1);
  return Math.max(swift ? Number(swift[1]) : 0, xctest ? Number(xctest[1]) : 0);
}

const running = new Set<ChildProcess>();
let stopping = false;

function stopAll(signal: NodeJS.Signals): void {
  stopping = true;
  for (const child of running) {
    if (child.pid) {
      try {
        process.kill(-child.pid, signal);
      } catch {
        // Already gone.
      }
    }
  }
}

type StepRun = { code: number; output: string };

function runStep(name: string, step: Step): Promise<StepRun> {
  if (stopping) return Promise.resolve({ code: 143, output: "" });
  console.log(`[batch-gate] ${name}: ${step.command} ${step.args.join(" ")}`);
  // Its own process group, so a stop reaches sim-pool, xcodebuild, and vitest workers.
  const child = spawn(step.command, step.args, {
    cwd: step.cwd,
    stdio: ["ignore", "pipe", "pipe"],
    // OPPI_SIM_POOL_GATE: a lane that finds every simulator slot busy queues for one (sim-pool's
    // gate wait) instead of failing after a developer run's 60 s: a gate lane has no caller to
    // retry it, and a busy pool is not a test failure. The wait itself is defined in sim-pool-ops.ts.
    env: { ...process.env, OPPI_SIM_POOL_GATE: "1", ...step.env },
    detached: true,
  });
  running.add(child);
  let output = "";
  for (const stream of [child.stdout!, child.stderr!]) {
    let pending = "";
    stream.setEncoding("utf8");
    stream.on("data", (chunk: string) => {
      output += chunk;
      const lines = (pending + chunk).split("\n");
      pending = lines.pop() ?? "";
      for (const line of lines) process.stdout.write(`[${name}] ${line}\n`);
    });
    stream.on("end", () => {
      if (pending) process.stdout.write(`[${name}] ${pending}\n`);
    });
  }
  return new Promise((resolve) => {
    child.on("error", (error) => {
      running.delete(child);
      const line = `[batch-gate] ${name} could not start: ${error.message}`;
      console.log(line);
      resolve({ code: 127, output: `${output}${line}\n` });
    });
    child.on("close", (status, signal) => {
      running.delete(child);
      resolve({ code: status ?? (signal ? 128 : 1), output });
    });
  });
}

/** A step's exit code, the tests still red after its rerun, and its output (with the gate's own lines about it). */
type GateStepRun = StepRun & { failed: string[] };

/**
 * Run one step: fail a sim-pool run that executed zero tests, naming its selectors; read its failed
 * tests; and rerun a failed E2E step's failed tests once (rerunE2E).
 */
async function runGateStep(lane: Lane, step: Step): Promise<GateStepRun> {
  const run = await runStep(lane.name, step);
  let { code, output } = run;
  const say = (line: string) => {
    console.log(`[batch-gate] ${lane.name}: ${line}`);
    output += `${line}\n`;
  };
  if (stopping) return { code, output, failed: [] };
  // Only a step that is a sim-pool run has its own log; a shard runner names its red tests itself.
  const artifact = step.requireTests ? lastArtifact(run.output) : undefined;
  const log = logOfSummary(artifact);
  if (step.requireTests && executedTests(run.output) === 0) {
    say(zeroTestLine(step.selectors ?? [], code === 0));
    if (code === 0) code = 1;
  }
  let failed = [...failedTestsInOutput(run.output), ...failedXCTestCases(log)];
  if (code !== 0 && failed.length === 0 && artifact && lane.name === "ios-unit") {
    const swift = runFailures(artifact);
    if ("ids" in swift) failed = swift.ids.map((id) => `OppiTests/${id}`);
  }
  if (code === 0 || !step.rerun) return { code, output, failed: code === 0 ? [] : failed };
  return rerunE2E(lane, step, { code, output, failed }, log, say);
}

/**
 * Rerun a failed E2E step's failed tests once, as the UI and unit shards do: through e2e.sh with the
 * step's own mode and `--only-testing` of each failed test (explicit tests replace a group's), or the
 * two-server wrapper once per test. All pass: the step passes, and each test is a flake in the rerun
 * ledger. A run that did not finish, failed outside any test, or failed more than XCTEST_RERUN_LIMIT
 * tests stays red without a rerun.
 */
async function rerunE2E(lane: Lane, step: Step, first: GateStepRun, log: string, say: (line: string) => void): Promise<GateStepRun> {
  const candidates = xctestRerun(log);
  if ("reason" in candidates) {
    say(`no rerun (${candidates.reason})`);
    return first;
  }
  const ids = candidates.ids;
  say(`rerunning ${ids.length} failed test${ids.length === 1 ? "" : "s"} once: ${ids.join(", ")}`);
  const reruns: Step[] = step.rerun === "two-server"
    ? ids.map((id) => ({ ...step, env: { ...step.env, TWO_SERVER_TEST: id.slice("OppiE2ETests/".length) }, selectors: [id] }))
    : [{ ...step, args: [...withoutOnlyTesting(step.args), ...ids.flatMap((id) => ["--only-testing", id])], selectors: ids }];
  const passed = new Set<string>();
  let code = 0;
  let output = first.output;
  for (const rerun of reruns) {
    const run = await runStep(lane.name, rerun);
    output += run.output;
    for (const id of passedXCTestCases(logOfSummary(lastArtifact(run.output)))) passed.add(id);
    if (code === 0) code = run.code;
  }
  if (stopping) return { code: 143, output, failed: first.failed };
  // A red rerun in which every test passed failed outside them: none of them is cleared.
  const cleared = code === 0 && ids.every((id) => passed.has(id));
  const red = new Set(cleared ? [] : ids.filter((id) => !passed.has(id)));
  if (!cleared && red.size === 0) for (const id of ids) red.add(id);
  for (const id of ids) {
    const outcome = red.has(id) ? "failed" : "flaky";
    const gates = recordRerun(step.cwd, { id, lane: lane.name, profile: lane.profile, outcome });
    const line = outcome === "flaky"
      ? `FLAKY ${id}: failed, then passed on rerun (flaked in ${gates} gate${gates === 1 ? "" : "s"})${gates >= 2 ? "; quarantine it in dev/testing/quarantine.json with an owner, an expiry, and a backlog key" : ""}`
      : `FAILED ${id}: failed again on rerun`;
    console.log(`[batch-gate] ${lane.name}: ${line}`);
    output += `${line}\n`;
  }
  return cleared ? { code: 0, output, failed: [] } : { code: first.code, output, failed: [...red] };
}

/** An e2e.sh argument list without its `--only-testing <target>` pairs. */
function withoutOnlyTesting(args: string[]): string[] {
  const kept: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--only-testing") i += 1;
    else kept.push(args[i]);
  }
  return kept;
}

type LaneResult = { lane: Lane; code: number; seconds: number; failed: string[]; output: string };

async function runLane(lane: Lane): Promise<LaneResult> {
  const started = Date.now();
  let code = 0;
  const failed: string[] = [];
  let output = "";
  for (const step of lane.steps.filter((step) => step.blocking !== false)) {
    const run = await runGateStep(lane, step);
    if (code === 0) code = run.code;
    failed.push(...run.failed);
    output += run.output;
  }
  for (const step of lane.steps.filter((step) => step.blocking === false)) {
    const run = await runStep(lane.name, step);
    console.log(`[batch-gate] ${lane.name}: quarantined (non-blocking): ${run.code === 0 ? "passed" : `failed (exit ${run.code})`} ${(step.selectors ?? []).join(", ")}`);
  }
  return { lane, code, seconds: Math.round((Date.now() - started) / 1000), failed: [...new Set(failed)], output };
}

/** A UI lane's budget comes from ui-shards, which measured its tests; other lanes are measured by their wall time. */
function laneBudget(result: LaneResult, budgets: ReturnType<typeof loadBudgets>["budgets"]): { line: string; warning?: string } {
  if (result.lane.name.startsWith("ui-")) {
    const line = [...result.output.matchAll(/^\[ui-shards\] (budget \S+: .*)$/gm)].at(-1)?.[1];
    const warning = [...result.output.matchAll(/^\[ui-shards\] (WARNING \S+ over budget: .*)$/gm)].at(-1)?.[1];
    if (line) return { line, ...(warning ? { warning } : {}) };
  }
  return budgetVerdict(result.lane.name, { wall: result.seconds }, budgets);
}

/** Record (in a land-queue batch) and print a red lane, with its guessed cause. */
function reportRed(worktree: string, lane: { lane: string; profile: string | null; exit: number; seconds: number | null; tests: string[]; output: string }): void {
  console.log(`[batch-gate] ${redLaneLine(lane.lane, recordRedLane(worktree, lane))}`);
}

async function main(argv: string[]): Promise<number> {
  if (argv.length === 1 && argv[0] === "--supports-profile-scope") {
    console.log(PROFILE_SCOPE_CAPABILITY);
    return 0;
  }
  let worktree = process.cwd();
  let target: string | undefined;
  const tests: string[] = [];
  const profiles: string[] = [];
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i + 1];
    switch (argv[i]) {
      case "--worktree": worktree = value; i += 1; break;
      case "--target": target = value; i += 1; break;
      case "--test": tests.push(value); i += 1; break;
      case "--profile": profiles.push(value); i += 1; break;
      default:
        console.error(`[batch-gate] unknown argument ${argv[i]}`);
        return 2;
    }
  }
  if (!existsSync(join(worktree, "clients", "apple"))) {
    console.error(`[batch-gate] not an Oppi checkout: ${worktree}`);
    return 2;
  }
  // Queues pass a symlinked temp path (/var/... -> /private/var/...), but the pre-push hook
  // builds from `git rev-parse --show-toplevel`, the canonical path. Xcode keys its build
  // plan on the spelled DerivedData path, so a non-canonical spelling recompiles the whole
  // app (~100 s) over the build pre-push just finished. Derive every path from the real one.
  worktree = realpathSync.native(worktree);
  // An expired or incomplete quarantine entry fails every gate until someone fixes the test,
  // extends the entry, or deletes it; the gate checks the batch's own copy of the file.
  const quarantinePath = join(worktree, "dev", "testing", "quarantine.json");
  const quarantine = loadQuarantine(quarantinePath, "OppiE2ETests");
  if (quarantine.problems.length > 0) {
    for (const problem of quarantine.problems) console.error(`[batch-gate] ${problem}`);
    reportRed(worktree, { lane: "quarantine", profile: null, exit: 1, seconds: null, tests: [], output: quarantine.problems.join("\n") });
    return 1;
  }
  const unitShards = prePushRanUnitShards(worktree, target);
  // The gate's own lanes are unit (ios-unit) and E2E; UI lanes read the file themselves (ui-shards.ts).
  const quarantined = [...loadQuarantine(quarantinePath, "OppiTests").active, ...quarantine.active];
  let plan = planGate(worktree, tests, profiles, undefined, { unitShardsRan: unitShards.ran, quarantined });
  for (const line of plan.resolutions) console.log(`[batch-gate] ${line}`);
  if (plan.errors.length > 0) {
    for (const error of plan.errors) console.error(`[batch-gate] ${error}`);
    reportRed(worktree, { lane: "plan", profile: null, exit: 2, seconds: null, tests: [], output: plan.errors.join("\n") });
    return 2;
  }
  if (plan.unit.length > 0) console.log(`[batch-gate] ios-unit: ${unitShards.why}`);
  // A dropped ios-unit lane no longer proves that a named selector names a test: the pre-push unit
  // run's results must show one. Without them, the lane runs after all.
  const results: LaneResult[] = [];
  if (unitShards.ran && plan.unit.length > 0) {
    const check = unmatchedUnitSelectors(worktree, headOf(worktree), plan.unit);
    if ("reason" in check) {
      console.log(`[batch-gate] ios-unit: cannot check the named unit selectors against the pre-push unit run (${check.reason}); running the ios-unit lane`);
      plan = planGate(worktree, tests, profiles, undefined, { unitShardsRan: false, quarantined });
    } else if (check.unmatched.length > 0) {
      const line = `${zeroTestLine(check.unmatched, true)}; checked against the tests the pre-push unit shards ran at this HEAD`;
      console.log(`[batch-gate] ios-unit: ${line}`);
      results.push({ lane: { name: "ios-unit", profile: "iphone", steps: [] }, code: 1, seconds: 0, failed: [], output: `${line}\n` });
    } else {
      console.log(`[batch-gate] ios-unit: every named unit selector matched a test the pre-push unit shards ran at this HEAD`);
    }
  }
  for (const note of plan.notes) console.log(`[batch-gate] ${note}`);
  if (plan.lanes.length === 0 && results.length === 0) {
    console.log("[batch-gate] no lanes to run; the pre-push gate is the whole gate");
    console.log(`[batch-gate] ${hiddenFlakesLine(flakesAtHead(worktree))}`);
    return 0;
  }
  for (const signal of ["SIGTERM", "SIGINT"] as const) process.on(signal, () => stopAll(signal));
  if (plan.lanes.length > 0) {
    // The pre-push gate only syncs server deps for server changes; named lanes may need them.
    const deps = await runStep("server-deps", { cwd: join(worktree, "server"), command: "node", args: ["scripts/ensure-installed-deps.mjs"] });
    if (deps.code !== 0) return deps.code;
    results.push(...await Promise.all(plan.lanes.map(runLane)));
  }
  if (stopping) return 143;
  // The batch's own budget file; one that cannot be read is a warning, never a failure.
  const { budgets, warnings } = loadBudgets(join(worktree, "dev", "testing", "lane-budgets.json"));
  console.log("[batch-gate] summary:");
  if (plan.notes.some((note) => note.startsWith("ios-unit: not run"))) console.log("[batch-gate] ios-unit: not run (covered by the pre-push unit shards)");
  for (const result of results) {
    const budget = laneBudget(result, budgets);
    if (budget.warning) warnings.push(budget.warning);
    console.log(`[batch-gate] ${result.lane.name}: ${result.code === 0 ? "PASS" : `FAIL (exit ${result.code})`} ${result.seconds}s; ${budget.line}`);
  }
  for (const warning of warnings) console.log(`[batch-gate] ${warning}`);
  // A red lane hid nothing: its failures are reported. Flakes of the lanes that passed were hidden.
  const red = new Set(results.filter((result) => result.code !== 0).map((result) => result.lane.name));
  console.log(`[batch-gate] ${hiddenFlakesLine(flakesAtHead(worktree).filter((row) => !red.has(row.lane)))}`);
  for (const result of results.filter((result) => result.code !== 0)) {
    reportRed(worktree, { lane: result.lane.name, profile: result.lane.profile, exit: result.code, seconds: result.seconds, tests: result.failed, output: result.output });
  }
  return results.every((result) => result.code === 0) ? 0 : 1;
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
