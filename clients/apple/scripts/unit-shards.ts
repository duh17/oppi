#!/usr/bin/env bun
// Run the whole OppiUnitTests suite as N parallel shards from one build.
//
//   bun clients/apple/scripts/unit-shards.ts [--shards N] [--strict]
//   bun clients/apple/scripts/unit-shards.ts --record <sim-pool log of a full run>
//
// 1. Build once without a simulator slot (`sim-pool.sh run -- ... build-for-testing`).
// 2. sim-pool clones the products (OPPI_SIM_POOL_PRODUCTS_DIR) under the build's checkout
//    lock, so a rebuild cannot change them.
// 3. Split the top-level test types of OppiTests into N shards by recorded suite seconds
//    (unit-shard-seconds.json; unknown types count TEST_SECONDS per @Test). Shards 1..N-1
//    run `-only-testing` lists; the last shard runs `-skip-testing` of everything the
//    others run, so a test type the scan misses still runs.
// 4. Run every shard in its own pool slot with `test-without-building -xctestrun` at once.
// Fails when any shard fails or runs zero tests. Default N: OPPI_UNIT_SHARDS or 3.
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, writeFileSync, closeSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { findXctestrun, runDirectory } from "./sim-pool-build";

const SCHEME = "OppiUnitTests";
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

/** A known-flaky test the gate runs without blocking until its owner decides by `expires`. */
export type QuarantineEntry = { id: string; owner: string; reason: string; addedAt: string; expires: string };

/** Entries still in force on `today` (YYYY-MM-DD), and the ones whose decision is overdue. */
export function splitQuarantine(entries: QuarantineEntry[], today: string): { active: QuarantineEntry[]; expired: QuarantineEntry[] } {
  return {
    active: entries.filter((entry) => entry.expires >= today),
    expired: entries.filter((entry) => entry.expires < today),
  };
}

/** Failed test identifiers (`Suite/test()`) in an xcresult, or undefined when it cannot be read. */
export function failedTestIds(xcresultTestsJson: string): string[] | undefined {
  try {
    const failed: string[] = [];
    const walk = (node: { nodeType?: string; result?: string; nodeIdentifier?: string; children?: unknown[] }) => {
      if (node.nodeType === "Test Case" && node.result === "Failed" && node.nodeIdentifier) failed.push(node.nodeIdentifier);
      for (const child of node.children ?? []) walk(child as typeof node);
    };
    for (const node of JSON.parse(xcresultTestsJson).testNodes ?? []) walk(node);
    return failed;
  } catch {
    return undefined;
  }
}

const RERUN_LIMIT = 20;

type ShardResult = { index: number; label: string; code: number; tests: number; seconds: number; output: string; summary?: string };

async function runShard(index: number, xctestrun: string, flags: string[], outDir: string, label = `shard-${index + 1}`): Promise<ShardResult> {
  const output = join(outDir, `${label}.out`);
  const fd = openSync(output, "w");
  const started = Date.now();
  const child = spawn(join(scriptDir, "sim-pool.sh"), ["run", "--", "xcodebuild", "test-without-building", "-xctestrun", xctestrun, ...flags], {
    cwd: appleDir,
    stdio: ["ignore", fd, fd],
  });
  closeSync(fd);
  const code = await new Promise<number>((resolve) => child.on("exit", (status, signal) => resolve(status ?? (signal ? 128 : 1))));
  const summary = /^Artifact: (.+)$/m.exec(readFileSync(output, "utf8"))?.[1];
  return { index, label, code, tests: executedTests(summary), seconds: Math.round((Date.now() - started) / 1000), output, summary };
}

/** Failed tests of a finished run, read from the xcresult in its run directory. */
function runFailures(summary: string | undefined): string[] | undefined {
  if (!summary || !existsSync(summary)) return undefined;
  const derivedData = JSON.parse(readFileSync(summary, "utf8")).derived_data_path as string | undefined;
  const testLogs = derivedData ? join(derivedData, "Logs", "Test") : "";
  if (!testLogs || !existsSync(testLogs)) return undefined;
  const bundle = readdirSync(testLogs).filter((name) => name.endsWith(".xcresult")).sort().at(-1);
  if (!bundle) return undefined;
  const tool = spawnSync("xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", join(testLogs, bundle)], { encoding: "utf8", timeout: 60_000 });
  return tool.status === 0 ? failedTestIds(tool.stdout) : undefined;
}

/** Append a pass-on-rerun to the repository's flake log; returns how many gates saw this test flake. */
function recordFlake(id: string): number {
  const commonDir = spawnSync("git", ["rev-parse", "--git-common-dir"], { cwd: appleDir, encoding: "utf8" }).stdout.trim();
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: appleDir, encoding: "utf8" }).stdout.trim();
  const dir = join(resolve(appleDir, commonDir), "oppi");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "test-flakes.jsonl");
  appendFileSync(path, `${JSON.stringify({ id, head, at: new Date().toISOString() })}\n`);
  const heads = new Set(
    readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line) as { id: string; head: string })
      .filter((entry) => entry.id === id).map((entry) => entry.head),
  );
  return heads.size;
}

/** Tests the shard's xcodebuild ran, from the Swift Testing result line in its log. */
function executedTests(summary: string | undefined): number {
  if (!summary || !existsSync(summary)) return 0;
  const log = JSON.parse(readFileSync(summary, "utf8")).log_path as string | undefined;
  if (!log || !existsSync(log)) return 0;
  const run = [...readFileSync(log, "utf8").matchAll(/^[✔✘] Test run with ([0-9]+) tests? in [0-9]+ suites? (?:passed|failed) after/gm)].at(-1);
  return run ? Number(run[1]) : 0;
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

  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
  const runDir = runDirectory(join(appleDir, ".build"), `shards-${stamp}`);
  // sim-pool clones the products into runDir under the same checkout lock as the build, so
  // another run in this checkout cannot swap them in between.
  const build = spawnSync(join(scriptDir, "sim-pool.sh"), ["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", SCHEME, "build-for-testing"], {
    cwd: appleDir,
    stdio: "inherit",
    env: { ...process.env, OPPI_SIM_POOL_PRODUCTS_DIR: runDir },
  });
  if (build.status !== 0) {
    console.error(`[unit-shards] build failed (exit ${build.status ?? build.signal})`);
    return build.status || 1;
  }
  const xctestrun = findXctestrun(join(runDir, "Build", "Products"), SCHEME);

  // --strict (release): every test blocks; no quarantine, no pass-on-rerun.
  const strict = argv.includes("--strict");
  const quarantine = !strict && existsSync(quarantinePath)
    ? splitQuarantine(JSON.parse(readFileSync(quarantinePath, "utf8")) as QuarantineEntry[], new Date().toISOString().slice(0, 10))
    : { active: [], expired: [] };
  if (quarantine.expired.length > 0) {
    for (const entry of quarantine.expired) {
      console.error(`[unit-shards] quarantine expired ${entry.expires}: ${entry.id} (owner ${entry.owner}); fix it, extend it, or delete it in dev/testing/quarantine.json`);
    }
    return 1;
  }
  const skipQuarantined = quarantine.active.map((entry) => `-skip-testing:${entry.id}`);

  const weights: Record<string, number> = existsSync(weightsPath) ? JSON.parse(readFileSync(weightsPath, "utf8")) : {};
  const parts = partition(loadTypes(), weights, shards);
  const outDir = join(runDir, "shards");
  mkdirSync(outDir, { recursive: true });
  console.log(`[unit-shards] ${shards} shards from ${relative(appleDir, xctestrun)}; outputs in ${outDir}`);
  const results = await Promise.all(parts.map((_, index) => runShard(index, xctestrun, [...shardFlags(parts, index), ...skipQuarantined], outDir)));
  let failed = false;
  for (const result of results) {
    let ok = result.code === 0 && result.tests > 0;
    console.log(`[unit-shards] shard ${result.index + 1}/${shards}: ${ok ? "PASS" : "FAIL"} exit=${result.code} tests=${result.tests} ${result.seconds}s output=${result.output}${result.summary ? ` summary=${result.summary}` : ""}`);
    if (!ok) {
      // sim-pool's own summary (failures, log path) ends the shard output.
      process.stdout.write(`${readFileSync(result.output, "utf8").trimEnd().split("\n").slice(-40).join("\n")}\n`);
      if (!strict) ok = await rerunFailures(result, xctestrun, outDir);
    }
    failed ||= !ok;
  }
  if (quarantine.active.length > 0) {
    // Quarantined tests still run, on the same products, but never block.
    const watch = await runShard(shards, xctestrun, quarantine.active.map((entry) => `-only-testing:${entry.id}`), outDir, "quarantined");
    console.log(`[unit-shards] quarantined (non-blocking): ${watch.code === 0 ? "passed" : "failed"} ${quarantine.active.map((entry) => entry.id).join(", ")} output=${watch.output}`);
  }
  const total = results.reduce((sum, result) => sum + result.tests, 0);
  console.log(`[unit-shards] ${failed ? "FAILED" : "PASSED"}: ${total} tests in ${shards} shards, longest ${Math.max(...results.map((r) => r.seconds))}s`);
  return failed ? 1 : 0;
}

/**
 * Rerun a failed shard's failing tests once on the same products. A test that passes on the
 * rerun is a flake: it does not block, and the flake log counts the gates it flaked in. Crashes,
 * unreadable results, zero tests, or more than RERUN_LIMIT failures stay red.
 */
async function rerunFailures(result: ShardResult, xctestrun: string, outDir: string): Promise<boolean> {
  const ids = result.tests > 0 ? runFailures(result.summary) : undefined;
  if (!ids || ids.length === 0 || ids.length > RERUN_LIMIT) {
    console.log(`[unit-shards] ${result.label}: no rerun (${ids ? `${ids.length} failed tests` : "failures unreadable"})`);
    return false;
  }
  const rerun = await runShard(result.index, xctestrun, ids.map((id) => `-only-testing:${BUNDLE}/${id}`), outDir, `${result.label}-rerun`);
  const ok = rerun.code === 0 && rerun.tests >= ids.length;
  console.log(`[unit-shards] ${result.label} rerun of ${ids.length} failed tests: ${ok ? "PASS" : "FAIL"} output=${rerun.output}`);
  if (ok) {
    for (const id of ids) {
      const gates = recordFlake(`${BUNDLE}/${id}`);
      console.log(`[unit-shards] FLAKY ${BUNDLE}/${id}: failed, then passed on rerun (flaked in ${gates} gate${gates === 1 ? "" : "s"})${gates >= 2 ? "; quarantine it in dev/testing/quarantine.json with an owner and an expiry" : ""}`);
    }
  }
  return ok;
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
