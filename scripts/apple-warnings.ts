#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Compiler-warning ratchet for the Apple client, over the xcodebuild log the pre-push Apple lane
 * already writes (sim-pool's `.build/logs/build-*.log`): no extra build.
 *
 * Unique warnings (file, line, column, message) are counted per group, the first folder under
 * clients/apple (`Oppi`, `OppiTests`, ...), and per kind:
 *
 *  - compiler:   swiftc and clang diagnostics, including `#expect` macro expansions (grouped by
 *                the module in the expansion's file name);
 *  - swiftlint:  the SwiftLint build phase's findings, counted apart so a lint rule never hides
 *                a compiler regression;
 *  - dependency: SwiftPM and other warnings that name no repository file (group `SwiftPM`).
 *
 * A count may not exceed scripts/apple-warnings-baseline.json (absent means 0), per group and per
 * file; decreases pass. A group the log did not build has no warnings in it, so a unit-scheme
 * build still checks what it compiled, and a build that recompiled only some files still catches
 * a new warning in one of them. A failure prints the warnings of every file whose count rose.
 *
 *   bun scripts/apple-warnings.ts <build log>
 *   bun scripts/apple-warnings.ts --latest <log dir>   newest build-*.log in the directory
 *   bun scripts/apple-warnings.ts <log> --update       lower the baseline to this log
 *
 * `--update` never raises a count, and lowers a count only when the log is complete for it: every
 * Swift file of the group compiled (a build that reused earlier output compiled a subset and
 * would report fewer warnings than exist), the SwiftLint phase ran, or a SwiftPM package built.
 * Take it from a build into fresh DerivedData; sim-pool's shared compilation cache keeps that
 * fast and replays warnings faithfully.
 */

export type Kind = "compiler" | "swiftlint" | "dependency";
export type Warning = { group: string; kind: Kind; file: string; line: number; message: string };
export type Counts = Record<string, Partial<Record<Kind, number>>>;
export type Baseline = {
  counts: Counts;
  /** Warnings per file, to name the culprit when a count rises. Keys are `<group>/<path>`. */
  files: Partial<Record<Kind, Record<string, number>>>;
};
export type ParsedLog = {
  warnings: Warning[];
  /** Repository Swift files that a SwiftCompile step handled, relative to clients/apple. */
  compiled: Set<string>;
  swiftlintRan: boolean;
  externalBuilt: boolean;
};

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const apple = join(repoRoot, "clients/apple");
const baselinePath = join(repoRoot, "scripts/apple-warnings-baseline.json");
const kinds: Kind[] = ["compiler", "swiftlint", "dependency"];
const externalGroup = "SwiftPM";
const maxPrinted = 200;

const headerLine = /^(\/\S.*?):(\d+):(\d+): warning: (.*)$/;
const bareWarning = /^warning: (.*)$/;
const swiftlintMessage = /Violation: .*\(([a-z][a-z0-9_]*)\)$/;
const macroFile = /\/@__swiftmacro_(\d+)(.+)$/;
const compileStep = /^SwiftCompile \S+ \S+ (?:Compiling\\ \S+ )?(\/\S+\.swift) \(in target /;

/** The group and repository-relative file a diagnostic path belongs to. */
function locate(path: string): { group: string; file: string; kind: "repo" | "macro" | "external" } {
  const repo = /\/clients\/apple\/(.+)$/.exec(path);
  if (repo) {
    const rel = repo[1]!;
    return { group: rel.split("/")[0]!, file: rel, kind: "repo" };
  }
  // `@__swiftmacro_<module length><module>...`: an `#expect` expansion has no source file, only
  // the module's name inside a mangled one.
  const macro = macroFile.exec(path);
  if (macro) {
    const module = macro[2]!.slice(0, Number(macro[1]));
    // One file per module: the expansion's mangled name moves when a test above it is added.
    return { group: module, file: `${module}/(macro expansions)`, kind: "macro" };
  }
  return { group: externalGroup, file: `${externalGroup}/${path.replace(/^.*\/checkouts\//, "")}`, kind: "external" };
}

export function parseLog(text: string): ParsedLog {
  const seen = new Set<string>();
  const warnings: Warning[] = [];
  const compiled = new Set<string>();
  let swiftlintRan = false;
  let externalBuilt = false;
  const add = (warning: Warning, key: string) => {
    if (seen.has(key)) return;
    seen.add(key);
    warnings.push(warning);
  };
  for (const line of text.split("\n")) {
    const header = headerLine.exec(line);
    if (header) {
      const path = header[1]!;
      const message = header[4]!;
      const where = locate(path);
      const kind: Kind = where.kind === "external" ? "dependency" : swiftlintMessage.test(message) ? "swiftlint" : "compiler";
      add({ group: where.group, kind, file: where.file, line: Number(header[2]), message }, `${path}:${header[2]}:${message}`);
      continue;
    }
    const bare = bareWarning.exec(line);
    if (bare) {
      add({ group: externalGroup, kind: "dependency", file: `${externalGroup}/(package scan)`, line: 0, message: bare[1]! }, `bare:${bare[1]}`);
      continue;
    }
    const step = compileStep.exec(line);
    if (step) {
      const repo = /\/clients\/apple\/(.+)$/.exec(step[1]!);
      if (repo) compiled.add(repo[1]!);
    }
    if (line.startsWith("PhaseScriptExecution SwiftLint ")) swiftlintRan = true;
    if (/ \(in target '[^']+' from project '(?!Oppi')/.test(line)) externalBuilt = true;
  }
  return { warnings, compiled, swiftlintRan, externalBuilt };
}

export function countWarnings(warnings: Warning[]): Counts {
  const counts: Counts = {};
  for (const w of warnings) {
    const group = (counts[w.group] ??= {});
    group[w.kind] = (group[w.kind] ?? 0) + 1;
  }
  return counts;
}

export function fileCounts(warnings: Warning[]): Partial<Record<Kind, Record<string, number>>> {
  const files: Partial<Record<Kind, Record<string, number>>> = {};
  for (const w of warnings) {
    const byFile = (files[w.kind] ??= {});
    byFile[w.file] = (byFile[w.file] ?? 0) + 1;
  }
  return files;
}

/** Swift files under a clients/apple group folder, relative to clients/apple. */
function sourceFiles(group: string): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const name of readdirSync(join(apple, dir))) {
      const rel = `${dir}/${name}`;
      if (statSync(join(apple, rel)).isDirectory()) walk(rel);
      else if (name.endsWith(".swift")) out.push(rel);
    }
  };
  if (existsSync(join(apple, group))) walk(group);
  return out;
}

/** Whether the log holds every warning of this group and kind, so its count may lower the baseline. */
function isComplete(log: ParsedLog, group: string, kind: Kind, files: (group: string) => string[]): boolean {
  if (kind === "swiftlint") return log.swiftlintRan;
  if (kind === "dependency") return log.externalBuilt;
  const sources = files(group);
  return sources.length > 0 && sources.every((file) => log.compiled.has(file));
}

export type Regression = { group: string; kind: Kind; baseline: number; now: number };

/** Counts above the baseline. A group the log did not build has no warnings in it, so it cannot rise. */
export function regressions(counts: Counts, baseline: Baseline): Regression[] {
  const out: Regression[] = [];
  for (const [group, byKind] of Object.entries(counts)) {
    for (const kind of kinds) {
      const now = byKind[kind] ?? 0;
      const was = baseline.counts[group]?.[kind] ?? 0;
      if (now > was) out.push({ group, kind, baseline: was, now });
    }
  }
  return out;
}

/**
 * The warnings of every file with more of them than the baseline holds. A build that reused earlier
 * output compiled only the files it changed, so a group's total can sit under its baseline while a
 * recompiled file gained a warning: a file's count is checked on its own. (A file's warnings come
 * together, so a count above the baseline is real even from a partial log.) A warning moved to
 * another file counts as new there.
 */
export function newWarnings(warnings: Warning[], baseline: Baseline): string[] {
  const now = fileCounts(warnings);
  const lines: string[] = [];
  for (const kind of kinds) {
    for (const [file, count] of Object.entries(now[kind] ?? {})) {
      const was = baseline.files[kind]?.[file] ?? 0;
      if (count <= was) continue;
      lines.push(`${file} [${kind}]: ${count} warnings, baseline ${was}`);
      for (const w of warnings) {
        if (w.kind === kind && w.file === file) lines.push(`    ${w.line > 0 ? `:${w.line} ` : ""}${w.message}`);
      }
    }
  }
  return lines;
}

/** The baseline lowered to the log where the log is complete for a count; never raised. */
export function lowered(
  baseline: Baseline,
  counts: Counts,
  warnings: Warning[],
  log: ParsedLog,
  files: (group: string) => string[] = sourceFiles,
): Baseline {
  const next: Baseline = { counts: {}, files: {} };
  const now = fileCounts(warnings);
  const groups = new Set([...Object.keys(baseline.counts), ...Object.keys(counts)]);
  for (const group of [...groups].sort()) {
    for (const kind of kinds) {
      const was = baseline.counts[group]?.[kind] ?? 0;
      const here = counts[group]?.[kind] ?? 0;
      const complete = isComplete(log, group, kind, files);
      const value = complete ? Math.min(was, here) : was;
      if (value > 0) (next.counts[group] ??= {})[kind] = value;
      const byFile = (next.files[kind] ??= {});
      // A complete group takes its files from the log; any other keeps the baseline's.
      const source = complete ? now[kind] ?? {} : baseline.files[kind] ?? {};
      for (const [file, count] of Object.entries(source)) {
        if (file.startsWith(`${group}/`) && count > 0) byFile[file] = count;
      }
    }
  }
  for (const kind of kinds) if (Object.keys(next.files[kind] ?? {}).length === 0) delete next.files[kind];
  return next;
}

function sorted<T>(value: Record<string, T>): Record<string, T> {
  return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)));
}

export function render(baseline: Baseline): string {
  const counts = sorted(Object.fromEntries(Object.entries(baseline.counts).map(([g, c]) => [g, sorted(c as Record<string, number>)])));
  const files = sorted(Object.fromEntries(Object.entries(baseline.files).map(([k, f]) => [k, sorted(f as Record<string, number>)])));
  return `${JSON.stringify({ counts, files }, null, 2)}\n`;
}

function readBaseline(): Baseline {
  return existsSync(baselinePath) ? (JSON.parse(readFileSync(baselinePath, "utf8")) as Baseline) : { counts: {}, files: {} };
}

function table(counts: Counts, baseline: Baseline): string[] {
  const groups = [...new Set([...Object.keys(counts), ...Object.keys(baseline.counts)])].sort();
  const rows = ["group                     compiler        swiftlint       dependency"];
  for (const group of groups) {
    const cells = kinds.map((kind) => {
      const now = counts[group]?.[kind] ?? 0;
      const was = baseline.counts[group]?.[kind] ?? 0;
      return `${now}/${was}`.padEnd(15);
    });
    rows.push(`${group.padEnd(25)} ${cells.join(" ")}`);
  }
  rows.push("(now/baseline)");
  return rows;
}

function newestLog(dir: string): string | undefined {
  if (!existsSync(dir)) return undefined;
  const logs = readdirSync(dir)
    .filter((name) => /^build-.*\.log$/.test(name))
    .map((name) => join(dir, name))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return logs[0];
}

function main(args: string[]): number {
  const latest = args.indexOf("--latest");
  const update = args.includes("--update");
  const logPath = latest >= 0 ? newestLog(args[latest + 1] ?? "") : args.find((arg) => !arg.startsWith("--"));
  if (!logPath || !existsSync(logPath)) {
    console.error("Apple warnings: no build log. Usage: bun scripts/apple-warnings.ts (<log> | --latest <dir>) [--update]");
    return 2;
  }
  const log = parseLog(readFileSync(logPath, "utf8"));
  const baseline = readBaseline();
  const counts = countWarnings(log.warnings);
  const regressed = regressions(counts, baseline);
  const added = newWarnings(log.warnings, baseline);

  console.log(`Apple warnings: ${logPath}`);
  for (const row of table(counts, baseline)) console.log(`  ${row}`);

  if (regressed.length > 0 || added.length > 0) {
    console.log("\nApple warnings: FAIL — more warnings than scripts/apple-warnings-baseline.json:");
    for (const r of regressed) console.log(`  ${r.group} ${r.kind}: ${r.now} (baseline ${r.baseline})`);
    console.log("\nNew warnings (every warning of each file whose count rose):");
    for (const line of added.slice(0, maxPrinted)) console.log(`  ${line}`);
    if (added.length > maxPrinted) console.log(`  ... ${added.length - maxPrinted} more lines; the build log has them all`);
    console.log("\nFix them. A count only goes down: --update lowers the baseline, never raises it.");
    return 1;
  }
  if (!update) {
    console.log("\nApple warnings: PASS — no count above the baseline.");
    return 0;
  }
  const next = render(lowered(baseline, counts, log.warnings, log));
  if (next === render(baseline)) {
    console.log("\nApple warnings: baseline already at or below this log; unchanged.");
    return 0;
  }
  writeFileSync(baselinePath, next);
  console.log("\nApple warnings: baseline lowered; commit scripts/apple-warnings-baseline.json.");
  return 0;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
