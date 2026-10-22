#!/usr/bin/env bun
// Run the whole OppiUnitTests suite as N parallel shards from one build.
//
//   bun clients/apple/scripts/unit-shards.ts [--shards N]
//   bun clients/apple/scripts/unit-shards.ts --record <sim-pool log of a full run>
//
// 1. Build once without a simulator slot (`sim-pool.sh run -- ... build-for-testing`).
// 2. Clone the products under the checkout build lock, so a rebuild cannot change them.
// 3. Split the top-level test types of OppiTests into N shards by recorded suite seconds
//    (unit-shard-seconds.json; unknown types count TEST_SECONDS per @Test). Shards 1..N-1
//    run `-only-testing` lists; the last shard runs `-skip-testing` of everything the
//    others run, so a test type the scan misses still runs.
// 4. Run every shard in its own pool slot with `test-without-building -xctestrun` at once.
// Fails when any shard fails or runs zero tests. Default N: OPPI_UNIT_SHARDS or 3.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, readdirSync, writeFileSync, closeSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { checkoutDerivedData, cloneProducts, findXctestrun, runDirectory, waitForFlock } from "./sim-pool-build";

const SCHEME = "OppiUnitTests";
const BUNDLE = "OppiTests";
const TEST_SECONDS = 0.05;
const scriptDir = dirname(fileURLToPath(import.meta.url));
const appleDir = dirname(scriptDir);
const weightsPath = join(scriptDir, "unit-shard-seconds.json");

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

type ShardResult = { index: number; code: number; tests: number; seconds: number; output: string; summary?: string };

async function runShard(index: number, xctestrun: string, flags: string[], outDir: string): Promise<ShardResult> {
  const output = join(outDir, `shard-${index + 1}.out`);
  const fd = openSync(output, "w");
  const started = Date.now();
  const child = spawn(join(scriptDir, "sim-pool.sh"), ["run", "--", "xcodebuild", "test-without-building", "-xctestrun", xctestrun, ...flags], {
    cwd: appleDir,
    stdio: ["ignore", fd, fd],
  });
  closeSync(fd);
  const code = await new Promise<number>((resolve) => child.on("exit", (status, signal) => resolve(status ?? (signal ? 128 : 1))));
  const summary = /^Artifact: (.+)$/m.exec(readFileSync(output, "utf8"))?.[1];
  return { index, code, tests: executedTests(summary), seconds: Math.round((Date.now() - started) / 1000), output, summary };
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

  const build = spawnSync(join(scriptDir, "sim-pool.sh"), ["run", "--", "xcodebuild", "-project", "Oppi.xcodeproj", "-scheme", SCHEME, "build-for-testing"], {
    cwd: appleDir,
    stdio: "inherit",
  });
  if (build.status !== 0) {
    console.error(`[unit-shards] build failed (exit ${build.status ?? build.signal})`);
    return build.status || 1;
  }

  const buildBase = join(appleDir, ".build");
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
  const runDir = runDirectory(buildBase, `shards-${stamp}`);
  const dd = checkoutDerivedData(buildBase);
  const lock = await waitForFlock(`${dd}.lock`, "exclusive", { canceled: false, waitWhileIdle: async (ms) => { await sleep(ms); } }, () =>
    console.error("[unit-shards] waiting for this checkout's build lock to clone products"),
  );
  let xctestrun: string;
  try {
    xctestrun = findXctestrun(cloneProducts(dd, runDir), SCHEME);
  } finally {
    lock?.release();
  }

  const weights: Record<string, number> = existsSync(weightsPath) ? JSON.parse(readFileSync(weightsPath, "utf8")) : {};
  const parts = partition(loadTypes(), weights, shards);
  const outDir = join(runDir, "shards");
  mkdirSync(outDir, { recursive: true });
  console.log(`[unit-shards] ${shards} shards from ${relative(appleDir, xctestrun)}; outputs in ${outDir}`);
  const results = await Promise.all(parts.map((_, index) => runShard(index, xctestrun, shardFlags(parts, index), outDir)));
  let failed = false;
  for (const result of results) {
    const ok = result.code === 0 && result.tests > 0;
    failed ||= !ok;
    console.log(`[unit-shards] shard ${result.index + 1}/${shards}: ${ok ? "PASS" : "FAIL"} exit=${result.code} tests=${result.tests} ${result.seconds}s output=${result.output}${result.summary ? ` summary=${result.summary}` : ""}`);
    if (!ok) {
      // sim-pool's own summary (failures, log path) ends the shard output.
      process.stdout.write(`${readFileSync(result.output, "utf8").trimEnd().split("\n").slice(-40).join("\n")}\n`);
    }
  }
  const total = results.reduce((sum, result) => sum + result.tests, 0);
  console.log(`[unit-shards] ${failed ? "FAILED" : "PASSED"}: ${total} tests in ${shards} shards, longest ${Math.max(...results.map((r) => r.seconds))}s`);
  return failed ? 1 : 0;
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)));
}
