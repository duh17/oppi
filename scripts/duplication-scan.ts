#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
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

type GuardrailViolation = {
  title: string;
  fix: string;
  details: string[];
};

type GuardrailResult = {
  title: string;
  violations: GuardrailViolation[];
};

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const appleRoot = join(repoRoot, "clients/apple");
const argv = process.argv.slice(2);
const argSet = new Set(argv);

function usage(): string {
  return `Usage: bun scripts/duplication-scan.ts [options]\n\nSingle duplication and Apple UI guardrail check for Oppi. Generates a generic\ncopy/paste report with jscpd, then runs the bespoke Apple architecture guardrails\nin the same command.\n\nOptions:\n  --include-tests     Also scan Apple and server test targets with looser thresholds\n  --fail-on-clones    Exit 1 when any configured jscpd scan reports clones\n  --output <path>     Report directory, relative to repo root by default\n                     (default: .pi/reports/duplication-scan)\n  --verbose           Print jscpd stdout/stderr for each pass\n  --help              Show this help\n`;
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

function runCommand(command: string, args: string[], cwd: string): string {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status === 1) {
    return "";
  }
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed with exit ${result.status}\n${result.stdout}\n${result.stderr}`,
    );
  }
  return result.stdout;
}

function rgFiles(
  pattern: string,
  paths: string[],
  options: { cwd?: string; pcre2?: boolean; type?: string } = {},
): string[] {
  const args: string[] = [];
  if (options.pcre2) {
    args.push("--pcre2");
  }
  args.push("-l", pattern);
  if (options.type) {
    args.push("--type", options.type);
  }
  args.push(...paths);

  return runCommand("rg", args, options.cwd ?? repoRoot)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function filterAllowed(files: string[], allowed: RegExp): string[] {
  return files.filter((file) => !allowed.test(file));
}

function findNamedFiles(root: string, fileName: string): string[] {
  if (!existsSync(root)) {
    return [];
  }

  const result: string[] = [];
  for (const entry of readdirSync(root)) {
    const fullPath = join(root, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      result.push(...findNamedFiles(fullPath, fileName));
    } else if (entry === fileName) {
      result.push(fullPath);
    }
  }
  return result;
}

function privateFunctionNames(relativePath: string): Set<string> {
  const path = join(appleRoot, relativePath);
  if (!existsSync(path)) {
    return new Set();
  }

  const content = readFileSync(path, "utf8");
  const names = new Set<string>();
  for (const match of content.matchAll(/private\s+func\s+(\w+)/g)) {
    names.add(match[1]);
  }
  return names;
}

function intersectionCount(left: Set<string>, right: Set<string>): number {
  let count = 0;
  for (const item of left) {
    if (right.has(item)) {
      count += 1;
    }
  }
  return count;
}

function runAppleGuardrails(): GuardrailResult {
  const violations: GuardrailViolation[] = [];
  const err = (title: string, fix: string, details: string[] = []) => {
    violations.push({ title, fix, details });
  };

  let hits = filterAllowed(
    rgFiles("UIActivityViewController\\(", ["Oppi/"], { cwd: appleRoot, type: "swift" }),
    /FileSharePresenter\.swift|FileShareService\.swift|AssistantMarkdownContentView\.swift/,
  );
  if (hits.length > 0) {
    err(
      `Raw UIActivityViewController found in: ${hits.join(", ")}`,
      "Use FileSharePresenter.share() or .makeShareBarButtonItem()",
      hits,
    );
  }

  hits = filterAllowed(
    rgFiles("(?:\\.sheet.*FullScreenCodeView|FullScreenCodeView.*\\.sheet)", ["Oppi/"], {
      cwd: appleRoot,
      type: "swift",
    }),
    /FullScreenCodeView\.swift/,
  );
  if (hits.length > 0) {
    err(
      `Raw .sheet + FullScreenCodeView in: ${hits.join(", ")}`,
      "Use .fullScreenViewer(isPresented:content:piRouter:) modifier",
      hits,
    );
  }

  hits = filterAllowed(
    rgFiles("FullScreenCodeViewController\\(", ["Oppi/"], { cwd: appleRoot, type: "swift" }),
    /FullScreenCodeView\.swift|FullScreenCodeViewController\.swift|EmbeddedFileViewerView\.swift|ToolTimelineRowHelpers\.swift/,
  );
  if (hits.length > 0) {
    err(
      `Direct FullScreenCodeViewController creation in: ${hits.join(", ")}`,
      "Use .fullScreenViewer() (SwiftUI) or ToolTimelineRowPresentationHelpers.presentFullScreenContent() (UIKit)",
      hits,
    );
  }

  hits = filterAllowed(
    rgFiles("presentationDetents\\(\\[\\.large\\]\\)", ["Oppi/"], { cwd: appleRoot, type: "swift" }),
    /FullScreenCodeView\.swift/,
  );
  if (hits.length > 0) {
    err(
      `Manual .presentationDetents([.large]) in: ${hits.join(", ")}`,
      "Use .fullScreenViewer() modifier — it handles sheet configuration",
      hits,
    );
  }

  for (const view of ["MarkdownFileView", "LaTeXFileView", "MermaidFileView", "OrgModeFileView", "HTMLFileView"]) {
    const [file] = findNamedFiles(join(appleRoot, "Oppi"), `${view}.swift`);
    if (file && !readFileSync(file, "utf8").includes("RenderableDocumentWrapper")) {
      const relativeFile = relative(appleRoot, file);
      err(
        `${view} does not use RenderableDocumentWrapper`,
        "Renderable file views must use RenderableDocumentWrapper for shared chrome",
        [relativeFile],
      );
    }
  }

  const chatInputFunctions = privateFunctionNames("Oppi/Features/Chat/Composer/ChatInputBar.swift");
  const expandedComposerFunctions = privateFunctionNames("Oppi/Features/Chat/Composer/ExpandedComposerView.swift");
  const sharedComposerFunctionCount = intersectionCount(chatInputFunctions, expandedComposerFunctions);
  if (sharedComposerFunctionCount > 5) {
    err(
      `ChatInputBar and ExpandedComposerView share ${sharedComposerFunctionCount} private funcs`,
      "Extract shared logic to a ComposerShared module",
    );
  }

  const askCardFunctions = privateFunctionNames("Oppi/Features/Chat/Composer/AskCard.swift");
  const askCardExpandedFunctions = privateFunctionNames("Oppi/Features/Chat/Composer/AskCardExpanded.swift");
  const sharedAskFunctionCount = intersectionCount(askCardFunctions, askCardExpandedFunctions);
  if (sharedAskFunctionCount > 3) {
    err(
      `AskCard and AskCardExpanded share ${sharedAskFunctionCount} private funcs`,
      "Extract shared AskQuestion logic to AskCardShared",
    );
  }

  hits = rgFiles("elapsed\\.components\\.attoseconds", ["Oppi/"], { cwd: appleRoot, type: "swift" });
  if (hits.length > 1) {
    err(
      `elapsedMs(ContinuousClock) duplicated in ${hits.length} files`,
      "Extract to a shared ContinuousClock extension",
      hits,
    );
  }

  hits = rgFiles("private func formatTokens", ["Oppi/"], { cwd: appleRoot, type: "swift" });
  if (hits.length > 1) {
    err(
      `formatTokens duplicated in ${hits.length} files`,
      "Extract to a shared formatting extension",
      hits,
    );
  }

  hits = rgFiles("private var statusColor: Color", ["Oppi/Features/Review/"], {
    cwd: appleRoot,
    type: "swift",
  });
  if (hits.length > 1) {
    err(
      `Git statusColor duplicated in ${hits.length} Review files`,
      "Extract to GitStatusColor.color(for:)",
      hits,
    );
  }

  hits = rgFiles("func nowMs", ["Oppi/"], { cwd: appleRoot, type: "swift" });
  if (hits.length > 2) {
    err(`nowMs() duplicated in ${hits.length} files`, "Use a single shared static func", hits);
  }

  hits = filterAllowed(
    rgFiles("(?<!ReviewComment)(?<!Pi)WKWebView\\(frame:", ["Oppi/"], {
      cwd: appleRoot,
      pcre2: true,
      type: "swift",
    }),
    /ReviewCommentWKWebView\.swift|HTMLContentTracker|PDFFileView\.swift/,
  );
  if (hits.length > 0) {
    err(
      `Plain WKWebView instantiation in: ${hits.join(", ")}`,
      "Use ReviewCommentWKWebView so review comments appear on text selection",
      hits,
    );
  }

  return {
    title: "Apple UI architecture guardrails",
    violations,
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

function renderMarkdown(results: ScanResult[], guardrailResult: GuardrailResult): string {
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
    "This report combines generic jscpd clone detection with Apple UI architecture guardrails in one command.",
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
  lines.push("## Apple guardrails");
  lines.push("");
  if (guardrailResult.violations.length === 0) {
    lines.push("Apple UI architecture guardrails passed.");
  } else {
    lines.push(`Apple UI architecture guardrails found ${guardrailResult.violations.length} violation(s).`);
    lines.push("");
    for (const violation of guardrailResult.violations) {
      lines.push(`- **${markdownEscape(violation.title)}**`);
      lines.push(`  - Fix: ${markdownEscape(violation.fix)}`);
      for (const detail of violation.details) {
        lines.push(`  - \`${markdownEscape(detail)}\``);
      }
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

  lines.push("### Apple UI architecture guardrails");
  lines.push("");
  lines.push("- Scope: `clients/apple/Oppi` UI and rendering hot paths");
  lines.push("- Checks: shared full-screen viewer, file renderer chrome, share sheet helper, WKWebView wrapper, and known duplicated helper patterns");
  lines.push("");

  lines.push("## Gate policy");
  lines.push("");
  lines.push("- Default mode always fails on Apple guardrail violations.");
  lines.push("- Generic jscpd clone detection is report-only by default.");
  lines.push("- Use `--fail-on-clones` when an explicit clone-free gate is desired.");
  lines.push("- Prefer gating on new clones touching changed production files instead of historical repo-wide debt.");
  lines.push("- Use jscpd ignore blocks only for intentional, documented duplication.");
  lines.push("");

  return `${lines.join("\n")}\n`;
}

function printGuardrailResult(result: GuardrailResult): void {
  if (result.violations.length === 0) {
    console.log("Apple guardrails: passed.");
    return;
  }

  console.error(`Apple guardrails: ${result.violations.length} violation(s) found.`);
  for (const violation of result.violations) {
    console.error(`ERROR: ${violation.title}`);
    console.error(`  FIX: ${violation.fix}`);
    for (const detail of violation.details) {
      console.error(`  ${detail}`);
    }
    console.error("");
  }
}

rmSync(outputRoot, { recursive: true, force: true });
mkdirSync(outputRoot, { recursive: true });

const results = scans.map(runScan).filter((result): result is ScanResult => Boolean(result));
const guardrailResult = runAppleGuardrails();
writeFileSync(markdownPath, renderMarkdown(results, guardrailResult));

const totalClones = results.reduce((sum, result) => sum + result.totals.clones, 0);
const totalDuplicatedLines = results.reduce(
  (sum, result) => sum + result.totals.duplicatedLines,
  0,
);

console.log(`Duplication scan complete: ${number(totalClones)} clone(s), ${number(totalDuplicatedLines)} duplicated line(s).`);
printGuardrailResult(guardrailResult);
console.log(`Markdown: ${rel(markdownPath)}`);
for (const result of results) {
  console.log(`JSON: ${rel(result.reportPath)}`);
}

if (guardrailResult.violations.length > 0) {
  process.exit(1);
}

if (failOnClones && totalClones > 0) {
  process.exit(1);
}
