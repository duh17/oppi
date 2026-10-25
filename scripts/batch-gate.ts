#!/usr/bin/env bun
// Repository gate for a batch of commits: a merge queue or CI runs it after `.githooks/pre-push`
// passes on the batch, with the named suites every commit in the batch asked for.
//
//   bun scripts/batch-gate.ts --worktree <path> [--target <branch>] [--test <s>]... [--profile <p>]...
//
// --worktree defaults to the current directory; the gate resolves symlinks in it, so lanes run
// at the checkout's canonical path (the one pre-push built in). --target is accepted and ignored: callers
// pass the branch the batch will land on, and this gate does not need it.
//
// Exit codes: 0 every lane passed (or no suites were named); 1 a lane failed; 2 a bad
// argument, test selector, or not an Oppi checkout; 143 stopped by SIGTERM/SIGINT; the
// failing exit code of the server-deps sync, which runs before any lane.
//
// --test values:
//   OppiTests/<Suite>[/<test>]      iOS unit filter; one OppiUnitTests run on the iPhone pool
//   OppiUITests/<Suite>[/<test>]    UI test filter; one `-scheme Oppi` run per --profile
//                                   (iphone, ipad, duo; default iphone), profiles in parallel
//   OppiE2ETests/<Suite>[/<test>]   paired-server E2E filter (clients/apple/scripts/e2e.sh --native)
//   <Suite>Tests[/<test>]           a bare iOS selector (suite name ending in Tests): runs as
//                                   <Target>/<Suite>Tests[/<test>] for the one test target
//                                   (OppiTests, OppiUITests, OppiE2ETests) that declares it; the gate
//                                   logs the resolution. Declared in no target, or in several
//                                   (QAVerificationSupport is in both UI and E2E), is an error that
//                                   lists the prefixed forms to choose from. Other bare names are unknown.
//   e2e-group:<name>                an E2E group (clients/apple/scripts/e2e.sh --group <name>)
//   server/tests/<file>.test.ts     a server Vitest file (the `server/` prefix is optional)
// Anything else fails the gate: a typo must not pass as "nothing to run". So does a suite
// that the test target does not declare, and an iOS run that executed zero tests.
// Every lane runs even when an earlier one failed, so one gate reports every red suite.
// Lane output is prefixed with the lane name; SIGTERM/SIGINT stop every lane's process group.
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";

/** `requireTests`: a sim-pool run whose log must show at least one executed test. */
type Step = { cwd: string; command: string; args: string[]; env?: NodeJS.ProcessEnv; requireTests?: boolean };
/** Lanes run in parallel; a lane's steps run in order and all run even after one fails. */
type Lane = { name: string; steps: Step[] };

const PROFILES = new Set(["iphone", "ipad", "duo"]);

/** `resolutions`: one line per bare iOS selector, naming the prefixed filter it became. */
export type Plan = { lanes: Lane[]; errors: string[]; resolutions: string[] };

/** `functionsOf`: functions declared in the files that declare or extend each type. */
export type Declarations = { types: Set<string>; functionsOf: Map<string, Set<string>> };

/** Swift string literals (kept) and comments (dropped), so prose in a comment is not a declaration. */
const STRINGS_AND_COMMENTS = /"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|(\/\*[\s\S]*?\*\/|\/\/[^\n]*)/g;
const stripComments = (text: string) => text.replace(STRINGS_AND_COMMENTS, (all, comment) => (comment === undefined ? all : " "));

/** Type and function names declared in a test target's Swift sources, for checking filters. */
export function declarations(sources: string[]): Declarations {
  const types = new Set<string>();
  const functionsOf = new Map<string, Set<string>>();
  for (const source of sources) {
    const text = stripComments(source);
    const functions = [...text.matchAll(/\bfunc\s+(\w+)/g)].map((match) => match[1]);
    for (const match of text.matchAll(/\b(struct|class|enum|actor|extension)\s+(\w+)/g)) {
      if (match[1] !== "extension") types.add(match[2]);
      const known = functionsOf.get(match[2]) ?? new Set<string>();
      for (const name of functions) known.add(name);
      functionsOf.set(match[2], known);
    }
  }
  return { types, functionsOf };
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

export function planGate(
  worktree: string,
  tests: string[],
  profiles: string[],
  declaredIn: (target: string) => Declarations = (target) =>
    declarations((TARGET_SOURCES[target] ?? [target]).flatMap((dir) => swiftSources(join(worktree, "clients", "apple", dir)))),
): Plan {
  const errors: string[] = [];
  const unit: string[] = [];
  const ui: string[] = [];
  const e2e: string[] = [];
  const groups: string[] = [];
  const server: string[] = [];
  const resolved: { filter: string; line: string }[] = [];
  const known = new Map<string, Declarations>();
  const declared = (target: string) => {
    if (!known.has(target)) known.set(target, declaredIn(target));
    return known.get(target)!;
  };
  for (const test of tests) {
    if (/^OppiTests(?:\/[\w.()-]+)+$/.test(test)) unit.push(test);
    else if (/^OppiUITests(?:\/[\w.()-]+)+$/.test(test)) ui.push(test);
    else if (/^OppiE2ETests(?:\/[\w.()-]+)+$/.test(test)) e2e.push(test);
    else if (/^e2e-group:[\w-]+$/.test(test)) groups.push(test.slice("e2e-group:".length));
    else if (/^(?:server\/)?tests\/[\w./-]+\.test\.ts$/.test(test) && !test.includes("..")) server.push(test.replace(/^server\//, ""));
    else if (BARE_IOS_SELECTOR.test(test) && !NOT_BARE.has(test.split("/")[0])) {
      // A bare `<Suite>[/<test>]` names the one test target that declares <Suite>.
      const suite = test.split("/")[0];
      const owners = Object.keys(TARGET_SOURCES).filter((target) => declared(target).types.has(suite));
      if (owners.length === 0) errors.push(`unknown --test '${test}': no test target declares ${suite}`);
      else if (owners.length > 1) errors.push(`ambiguous --test '${test}': declared in ${owners.length} test targets; use ${owners.map((target) => `'${target}/${test}'`).join(" or ")}`);
      else {
        const filter = `${owners[0]}/${test}`;
        resolved.push({ filter, line: `--test '${test}' resolved to ${filter}` });
        (owners[0] === "OppiTests" ? unit : owners[0] === "OppiUITests" ? ui : e2e).push(filter);
      }
    } else errors.push(`unknown --test '${test}'`);
  }
  for (const profile of profiles) {
    if (!PROFILES.has(profile)) errors.push(`unknown --profile '${profile}' (iphone, ipad, duo)`);
  }
  const failed = new Set<string>();
  for (const filter of [...unit, ...ui, ...e2e]) {
    const problem = undeclaredFilter(filter, declared(filter.split("/")[0]));
    if (problem) {
      errors.push(`--test '${filter}': ${problem}`);
      failed.add(filter);
    }
  }
  const resolutions = resolved.filter(({ filter }) => !failed.has(filter)).map(({ line }) => line);
  const apple = join(worktree, "clients", "apple");
  const simPool = join(apple, "scripts", "sim-pool.sh");
  const e2eScript = join(apple, "scripts", "e2e.sh");
  // sim-pool prefers an inherited OPPI_ROOT over the cwd; a caller's own checkout must not
  // win over the worktree under test, or the gate would build and test different code.
  const pinned = { OPPI_ROOT: worktree };
  const lanes: Lane[] = [];
  if (server.length > 0) {
    lanes.push({ name: "server", steps: [{ cwd: join(worktree, "server"), command: "npm", args: ["exec", "--offline", "--", "vitest", "run", ...server] }] });
  }
  if (unit.length > 0) {
    lanes.push({
      name: "ios-unit",
      steps: [{
        cwd: apple,
        command: simPool,
        args: ["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "OppiUnitTests", "test", ...unit.map((f) => `-only-testing:${f}`)],
        env: pinned,
        requireTests: true,
      }],
    });
  }
  if (ui.length > 0) {
    for (const profile of profiles.length > 0 ? profiles : ["iphone"]) {
      lanes.push({
        name: `ui-${profile}`,
        steps: [{
          cwd: apple,
          command: simPool,
          args: ["run", "--device-profile", profile, "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", "Oppi", "test", ...ui.map((f) => `-only-testing:${f}`)],
          env: pinned,
          requireTests: true,
        }],
      });
    }
  }
  // E2E runs start a paired server each; keep them one after another in a single lane.
  const e2eArgs = [
    ...e2e.map((filter) => ["--native", "--only-testing", filter]),
    ...groups.map((group) => ["--group", group]),
  ];
  if (e2eArgs.length > 0) {
    lanes.push({
      name: "e2e",
      // One filter or group per step, so a step that ran zero tests is caught exactly.
      steps: e2eArgs.map((args) => ({ cwd: worktree, command: e2eScript, args, env: pinned, requireTests: true })),
    });
  }
  return { lanes, errors, resolutions };
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

function runStep(name: string, step: Step): Promise<number> {
  if (stopping) return Promise.resolve(143);
  console.log(`[batch-gate] ${name}: ${step.command} ${step.args.join(" ")}`);
  // Its own process group, so a stop reaches sim-pool, xcodebuild, and vitest workers.
  const child = spawn(step.command, step.args, {
    cwd: step.cwd,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ...step.env },
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
      console.log(`[batch-gate] ${name} could not start: ${error.message}`);
      resolve(127);
    });
    child.on("close", (status, signal) => {
      running.delete(child);
      const code = status ?? (signal ? 128 : 1);
      if (code === 0 && step.requireTests && executedTests(output) === 0) {
        console.log(`[batch-gate] ${name}: the run executed zero tests`);
        resolve(1);
        return;
      }
      resolve(code);
    });
  });
}

async function runLane(lane: Lane): Promise<{ lane: Lane; code: number; seconds: number }> {
  const started = Date.now();
  let code = 0;
  for (const step of lane.steps) {
    const status = await runStep(lane.name, step);
    if (code === 0) code = status;
  }
  return { lane, code, seconds: Math.round((Date.now() - started) / 1000) };
}

async function main(argv: string[]): Promise<number> {
  let worktree = process.cwd();
  const tests: string[] = [];
  const profiles: string[] = [];
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i + 1];
    switch (argv[i]) {
      case "--worktree": worktree = value; i += 1; break;
      case "--target": i += 1; break;
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
  const plan = planGate(worktree, tests, profiles);
  for (const line of plan.resolutions) console.log(`[batch-gate] ${line}`);
  if (plan.errors.length > 0) {
    for (const error of plan.errors) console.error(`[batch-gate] ${error}`);
    return 2;
  }
  if (plan.lanes.length === 0) {
    console.log("[batch-gate] no named suites; the pre-push gate is the whole gate");
    return 0;
  }
  for (const signal of ["SIGTERM", "SIGINT"] as const) process.on(signal, () => stopAll(signal));
  // The pre-push gate only syncs server deps for server changes; named lanes may need them.
  const deps = await runStep("server-deps", { cwd: join(worktree, "server"), command: "node", args: ["scripts/ensure-installed-deps.mjs"] });
  if (deps !== 0) return deps;
  const results = await Promise.all(plan.lanes.map(runLane));
  for (const result of results) {
    console.log(`[batch-gate] ${result.lane.name}: ${result.code === 0 ? "PASS" : `FAIL (exit ${result.code})`} ${result.seconds}s`);
  }
  if (stopping) return 143;
  return results.every((result) => result.code === 0) ? 0 : 1;
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
