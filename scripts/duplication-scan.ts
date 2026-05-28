#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type ScanConfig = {
  id: string;
  title: string;
  paths: string[];
  format: string;
  minLines: number;
  minTokens: number;
  mode: "strict" | "mild" | "weak";
  ignore: string[];
};

type JscpdFileLocation = {
  name: string;
  start: number;
  end: number;
};

type JscpdDuplicate = {
  format: string;
  lines: number;
  tokens?: number;
  firstFile: JscpdFileLocation;
  secondFile: JscpdFileLocation;
};

type JscpdTotals = {
  lines?: number;
  tokens?: number;
  sources?: number;
  clones?: number;
  duplicatedLines?: number;
  duplicatedTokens?: number;
  percentage?: number;
  percentageTokens?: number;
};

type JscpdReport = {
  duplicates?: JscpdDuplicate[];
  statistics?: {
    total?: JscpdTotals;
  };
};

type ScanResult = {
  config: ScanConfig;
  outputDir: string;
  reportPath: string;
  markdownReportPath: string;
  totals: Required<JscpdTotals>;
  duplicates: JscpdDuplicate[];
};

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const argv = process.argv.slice(2);
const argSet = new Set(argv);

function usage(): string {
  return `Usage: bun scripts/duplication-scan.ts [options]\n\nReport-first copy/paste scan for Oppi. The existing Apple check-duplication.sh\nscript is still the architecture guardrail; this script finds generic code clones.\n\nOptions:\n  --include-tests     Also scan Apple and server test targets with looser thresholds\n  --fail-on-clones    Exit 1 when any configured scan reports clones\n  --output <path>     Report directory, relative to repo root by default\n                     (default: .pi/reports/duplication-scan)\n  --verbose           Print jscpd stdout/stderr for each pass\n  --help              Show this help\n`;
}

function argValue(name: string, fallback: string): string {
  const index = argv.indexOf(name);
  if (index === -1) {
    return fallback;
  }
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${name} requires a value`);
  }
  return value;
}

if (argSet.has("--help") || argSet.has("-h")) {
  console.log(usage());
  process.exit(0);
}

const includeTests = argSet.has("--include-tests");
const failOnClones = argSet.has("--fail-on-clones");
const verbose = argSet.has("--verbose");
const outputArg = argValue("--output", ".pi/reports/duplication-scan");
const outputRoot = isAbsolute(outputArg) ? outputArg : join(repoRoot, outputArg);
const reportsRoot = join(repoRoot, ".pi/reports");
const relativeOutputRoot = relative(resolve(reportsRoot), resolve(outputRoot));
if (
  relativeOutputRoot === "" ||
  relativeOutputRoot.startsWith("..") ||
  isAbsolute(relativeOutputRoot)
) {
  throw new Error("--output must be a child directory of .pi/reports");
}
const markdownPath = join(dirname(outputRoot), "duplication-scan.md");

const appleIgnore = [
  "**/.build/**",
  "**/build/**",
  "**/DerivedData/**",
  "**/Oppi.xcodeproj/**",
];

const serverIgnore = [
  "**/dist/**",
  "**/node_modules/**",
  "**/coverage/**",
];

const scans: ScanConfig[] = [
  {
    id: "apple-prod",
    title: "Apple Swift production",
    paths: [
      "clients/apple/Oppi",
      "clients/apple/Shared",
      "clients/apple/OppiMac",
      "clients/apple/OppiActivityExtension",
      "clients/apple/OppiControlWidget",
    ],
    format: "swift",
    minLines: 12,
    minTokens: 120,
    mode: "weak",
    ignore: appleIgnore,
  },
  {
    id: "server-prod",
    title: "Server TypeScript production",
    paths: ["server/src", "server/extensions", "server/scripts", "protocol"],
    format: "typescript,javascript",
    minLines: 12,
    minTokens: 120,
    mode: "weak",
    ignore: serverIgnore,
  },
];

if (includeTests) {
  scans.push(
    {
      id: "apple-tests",
      title: "Apple Swift tests",
      paths: [
        "clients/apple/OppiTests",
        "clients/apple/OppiPerfTests",
        "clients/apple/OppiMacTests",
        "clients/apple/OppiE2ETests",
        "clients/apple/OppiUITests",
      ],
      format: "swift",
      minLines: 20,
      minTokens: 180,
      mode: "weak",
      ignore: appleIgnore,
    },
    {
      id: "server-tests",
      title: "Server TypeScript tests",
      paths: ["server/tests", "server/e2e"],
      format: "typescript,javascript",
      minLines: 20,
      minTokens: 180,
      mode: "weak",
      ignore: serverIgnore,
    },
  );
}

function totalsWithDefaults(totals: JscpdTotals | undefined): Required<JscpdTotals> {
  return {
    lines: totals?.lines ?? 0,
    tokens: totals?.tokens ?? 0,
    sources: totals?.sources ?? 0,
    clones: totals?.clones ?? 0,
    duplicatedLines: totals?.duplicatedLines ?? 0,
    duplicatedTokens: totals?.duplicatedTokens ?? 0,
    percentage: totals?.percentage ?? 0,
    percentageTokens: totals?.percentageTokens ?? 0,
  };
}

function existingPaths(paths: string[]): string[] {
  return paths.filter((path) => existsSync(join(repoRoot, path)));
}

function runScan(config: ScanConfig): ScanResult | undefined {
  const paths = existingPaths(config.paths);
  if (paths.length === 0) {
    console.warn(`Skipping ${config.id}: no configured paths exist`);
    return undefined;
  }

  const outputDir = join(outputRoot, config.id);
  mkdirSync(outputDir, { recursive: true });

  const args = [
    "--yes",
    "jscpd",
    ...paths,
    "--format",
    config.format,
    "--min-lines",
    String(config.minLines),
    "--min-tokens",
    String(config.minTokens),
    "--max-lines",
    "2500",
    "--max-size",
    "500kb",
    "--mode",
    config.mode,
    "--reporters",
    "json",
    "--output",
    outputDir,
    "--ignore",
    config.ignore.join(","),
    "--exitCode",
    "0",
    "--noTips",
    "--silent",
  ];

  const result = spawnSync("npx", args, {
    cwd: repoRoot,
    encoding: "utf8",
  });

  if (verbose && result.stdout) {
    console.log(result.stdout.trim());
  }
  if (verbose && result.stderr) {
    console.error(result.stderr.trim());
  }

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `jscpd failed for ${config.id} with exit ${result.status}\n${result.stdout}\n${result.stderr}`,
    );
  }

  const reportPath = join(outputDir, "jscpd-report.json");
  const rawReport = readFileSync(reportPath, "utf8");
  const report = JSON.parse(rawReport) as JscpdReport;

  return {
    config,
    outputDir,
    reportPath,
    markdownReportPath: markdownPath,
    totals: totalsWithDefaults(report.statistics?.total),
    duplicates: report.duplicates ?? [],
  };
}

function number(value: number): string {
  return value.toLocaleString("en-US");
}

function percent(value: number): string {
  return `${value.toFixed(2)}%`;
}

function rel(path: string): string {
  return relative(repoRoot, path) || ".";
}

function locationText(file: JscpdFileLocation): string {
  return `${file.name}:${file.start}-${file.end}`;
}

function markdownEscape(value: string): string {
  return value.replaceAll("|", "\\|");
}

function renderMarkdown(results: ScanResult[]): string {
  const generatedAt = new Date().toISOString();
  const allDuplicates = results.flatMap((result) =>
    result.duplicates.map((duplicate) => ({ result, duplicate })),
  );
  allDuplicates.sort((a, b) => b.duplicate.lines - a.duplicate.lines);

  const lines: string[] = [];
  lines.push("# Duplication Scan");
  lines.push("");
  lines.push(`Generated: ${generatedAt}`);
  lines.push("");
  lines.push(
    "This is a generic clone detector report. Keep `clients/apple/scripts/check-duplication.sh` for bespoke Apple architecture guardrails.",
  );
  lines.push("");
  lines.push("## Summary");
  lines.push("");
  lines.push(
    "| Scan | Sources | Clones | Duplicated lines | Duplicated tokens | Line % | Token % | JSON |",
  );
  lines.push("|---|---:|---:|---:|---:|---:|---:|---|");
  for (const result of results) {
    const jsonPath = rel(result.reportPath);
    lines.push(
      `| ${markdownEscape(result.config.title)} | ${number(result.totals.sources)} | ${number(result.totals.clones)} | ${number(result.totals.duplicatedLines)} | ${number(result.totals.duplicatedTokens)} | ${percent(result.totals.percentage)} | ${percent(result.totals.percentageTokens)} | \`${jsonPath}\` |`,
    );
  }

  lines.push("");
  lines.push("## Top clones");
  lines.push("");
  if (allDuplicates.length === 0) {
    lines.push("No clones found with the configured thresholds.");
  } else {
    lines.push("| Lines | Scan | First location | Second location |");
    lines.push("|---:|---|---|---|");
    for (const { result, duplicate } of allDuplicates.slice(0, 25)) {
      lines.push(
        `| ${number(duplicate.lines)} | ${markdownEscape(result.config.title)} | \`${markdownEscape(locationText(duplicate.firstFile))}\` | \`${markdownEscape(locationText(duplicate.secondFile))}\` |`,
      );
    }
  }

  lines.push("");
  lines.push("## Configured passes");
  lines.push("");
  for (const result of results) {
    lines.push(`### ${result.config.title}`);
    lines.push("");
    lines.push(`- Paths: ${result.config.paths.map((path) => `\`${path}\``).join(", ")}`);
    lines.push(`- Format: \`${result.config.format}\``);
    lines.push(
      `- Threshold: \`${result.config.minLines}\` lines, \`${result.config.minTokens}\` tokens, \`${result.config.mode}\` mode`,
    );
    lines.push("");
  }

  lines.push("## Gate policy");
  lines.push("");
  lines.push("- Default mode is report-only and exits 0.");
  lines.push("- Use `--fail-on-clones` only for an explicit gate.");
  lines.push("- Prefer gating on new clones touching changed production files instead of historical repo-wide debt.");
  lines.push("- Use jscpd ignore blocks only for intentional, documented duplication.");
  lines.push("");

  return `${lines.join("\n")}\n`;
}

rmSync(outputRoot, { recursive: true, force: true });
mkdirSync(outputRoot, { recursive: true });

const results = scans.map(runScan).filter((result): result is ScanResult => Boolean(result));
writeFileSync(markdownPath, renderMarkdown(results));

const totalClones = results.reduce((sum, result) => sum + result.totals.clones, 0);
const totalDuplicatedLines = results.reduce(
  (sum, result) => sum + result.totals.duplicatedLines,
  0,
);

console.log(`Duplication scan complete: ${number(totalClones)} clone(s), ${number(totalDuplicatedLines)} duplicated line(s).`);
console.log(`Markdown: ${rel(markdownPath)}`);
for (const result of results) {
  console.log(`JSON: ${rel(result.reportPath)}`);
}

if (failOnClones && totalClones > 0) {
  process.exit(1);
}
