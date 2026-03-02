#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import {
  findServerLayerViolations,
  normalizeRepoPath,
  readImportsFromFile,
} from "./architecture-layer-rules.mjs";

const PROTOCOL_FILES = [
  "server/src/types.ts",
  "ios/Oppi/Core/Models/ServerMessage.swift",
  "ios/Oppi/Core/Models/ClientMessage.swift",
];

export function parseArgs(argv) {
  const options = {
    staged: false,
    commits: null,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === "--staged") {
      options.staged = true;
      continue;
    }

    if (token === "--commits") {
      const next = argv[index + 1];
      if (!next) {
        throw new Error("Missing value for --commits");
      }

      const parsed = Number.parseInt(next, 10);
      if (!Number.isInteger(parsed) || parsed <= 0) {
        throw new Error("--commits must be a positive integer");
      }

      options.commits = parsed;
      index += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${token}`);
  }

  if (options.staged && options.commits !== null) {
    throw new Error("Use either --staged or --commits N, not both");
  }

  if (!options.staged && options.commits === null) {
    options.staged = true;
  }

  return options;
}

function runGit(repoRoot, args, { allowFailure = false } = {}) {
  const result = spawnSync("git", ["-C", repoRoot, ...args], {
    encoding: "utf8",
  });

  if (result.status !== 0 && !allowFailure) {
    const stderr = result.stderr.trim();
    throw new Error(`git ${args.join(" ")} failed: ${stderr}`);
  }

  return {
    status: result.status ?? 1,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

function getRepoRoot() {
  const result = spawnSync("git", ["rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  });

  if (result.status !== 0) {
    throw new Error("Not inside a git repository");
  }

  return result.stdout.trim();
}

function getDiffAndFiles(repoRoot, options) {
  if (options.staged) {
    const diff = runGit(repoRoot, ["diff", "--cached", "--no-color", "--unified=3"]).stdout;
    const names = runGit(repoRoot, ["diff", "--cached", "--name-only"]).stdout;
    const changedFiles = names
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0);

    return {
      mode: "staged",
      diff,
      changedFiles,
    };
  }

  const baseRef = `HEAD~${options.commits}`;
  runGit(repoRoot, ["rev-parse", "--verify", baseRef]);
  const range = `${baseRef}..HEAD`;

  const diff = runGit(repoRoot, ["diff", "--no-color", "--unified=3", range]).stdout;
  const names = runGit(repoRoot, ["diff", "--name-only", range]).stdout;
  const changedFiles = names
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  return {
    mode: `last-${options.commits}-commits`,
    diff,
    changedFiles,
  };
}

function extractSection(markdown, headingText) {
  const lines = markdown.split("\n");
  const start = lines.findIndex((line) => line.trim() === headingText);

  if (start === -1) {
    return "";
  }

  const headingMatch = lines[start].match(/^(#+)\s+/);
  const headingLevel = headingMatch ? headingMatch[1].length : 1;

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const match = lines[index].match(/^(#+)\s+/);
    if (!match) {
      continue;
    }

    if (match[1].length <= headingLevel) {
      end = index;
      break;
    }
  }

  return lines.slice(start, end).join("\n").trim();
}

function getReviewContext(repoRoot) {
  const architecture = readFileSync(path.join(repoRoot, "ARCHITECTURE.md"), "utf8");
  const goldenPrinciples = readFileSync(path.join(repoRoot, "docs/golden-principles.md"), "utf8");
  const agentsGuide = readFileSync(path.join(repoRoot, "AGENTS.md"), "utf8");

  const architectureRules = extractSection(
    architecture,
    "### Dependency direction rules (current code)",
  );
  const protocolDiscipline = extractSection(agentsGuide, "## Protocol Discipline");

  return {
    architectureRules,
    goldenPrinciples,
    protocolDiscipline,
  };
}

export { readImportsFromFile };

export function extractFileDiff(diffText, relativePath) {
  const header = `diff --git a/${relativePath} b/${relativePath}`;
  const lines = diffText.split("\n");
  const startIndex = lines.findIndex((line) => line === header);

  if (startIndex === -1) {
    return "";
  }

  let endIndex = lines.length;
  for (let index = startIndex + 1; index < lines.length; index += 1) {
    if (lines[index].startsWith("diff --git ")) {
      endIndex = index;
      break;
    }
  }

  return lines.slice(startIndex, endIndex).join("\n");
}

export function isPackageJsonCiTestingChange(packageJsonDiff) {
  if (packageJsonDiff.trim().length === 0) {
    return false;
  }

  const ciScriptPrefixes = ["test", "check", "review"];

  return packageJsonDiff.split("\n").some((line) => {
    if (!(line.startsWith("+") || line.startsWith("-"))) {
      return false;
    }

    if (line.startsWith("+++") || line.startsWith("---")) {
      return false;
    }

    const withoutSign = line.slice(1).trimStart();
    const match = withoutSign.match(/^"([^\"]+)"\s*:/);
    if (!match) {
      return false;
    }

    const key = match[1];
    return ciScriptPrefixes.some((prefix) => key === prefix || key.startsWith(`${prefix}:`));
  });
}

export function buildChecks(changedFiles, layerViolations, diffText) {
  const checks = [];

  if (changedFiles.length === 0) {
    checks.push({
      id: "diff-non-empty",
      status: "fail",
      reason: "No changed files found for the selected diff scope.",
    });
  }

  const protocolTouched = PROTOCOL_FILES.filter((file) => changedFiles.includes(file));
  if (protocolTouched.length > 0 && protocolTouched.length < PROTOCOL_FILES.length) {
    const missing = PROTOCOL_FILES.filter((file) => !changedFiles.includes(file));
    checks.push({
      id: "protocol-lockstep",
      status: "fail",
      reason: "Protocol files changed without full lockstep updates.",
      details: {
        touched: protocolTouched,
        missing,
      },
    });
  } else if (protocolTouched.length === PROTOCOL_FILES.length) {
    checks.push({
      id: "protocol-lockstep",
      status: "pass",
      reason: "All protocol contract files changed together.",
      details: {
        touched: protocolTouched,
      },
    });
  } else {
    checks.push({
      id: "protocol-lockstep",
      status: "pass",
      reason: "No protocol contract files changed.",
    });
  }

  if (changedFiles.length >= 5) {
    checks.push({
      id: "major-change-file-count",
      status: "warn",
      reason: `Major change flag: ${changedFiles.length} files changed (threshold: 5).`,
    });
  } else {
    checks.push({
      id: "major-change-file-count",
      status: "pass",
      reason: `File count below major threshold (${changedFiles.length}/5).`,
    });
  }

  const sensitiveDocs = ["AGENTS.md", "ARCHITECTURE.md", "docs/golden-principles.md"].filter(
    (file) => changedFiles.includes(file),
  );
  if (sensitiveDocs.length > 0) {
    checks.push({
      id: "sensitive-doc-review",
      status: "warn",
      reason: "Critical guidance docs changed; requires careful review.",
      details: {
        files: sensitiveDocs,
      },
    });
  } else {
    checks.push({
      id: "sensitive-doc-review",
      status: "pass",
      reason: "No critical guidance docs changed.",
    });
  }

  const ciTestingInfraTouched = changedFiles.filter(
    (file) =>
      file.startsWith(".github/workflows/") ||
      file.startsWith("docs/testing/") ||
      file === "server/testing-policy.json" ||
      file.startsWith("server/scripts/testing-"),
  );

  if (changedFiles.includes("server/package.json")) {
    const packageJsonDiff = extractFileDiff(diffText, "server/package.json");
    if (isPackageJsonCiTestingChange(packageJsonDiff)) {
      ciTestingInfraTouched.push("server/package.json");
    }
  }
  if (ciTestingInfraTouched.length > 0) {
    checks.push({
      id: "ci-testing-infra-review",
      status: "warn",
      reason: "CI/testing infrastructure changed; verify gate intent and coherence.",
      details: {
        files: ciTestingInfraTouched,
      },
    });
  } else {
    checks.push({
      id: "ci-testing-infra-review",
      status: "pass",
      reason: "No CI/testing infrastructure files changed.",
    });
  }

  if (layerViolations.length > 0) {
    checks.push({
      id: "architecture-layer-rules",
      status: "fail",
      reason: "Detected import directions that violate ARCHITECTURE.md rules.",
      details: {
        violations: layerViolations,
      },
    });
  } else {
    checks.push({
      id: "architecture-layer-rules",
      status: "pass",
      reason: "No mechanical layer-direction violations detected in changed server/src files.",
    });
  }

  return checks;
}

function deriveOverallStatus(checks) {
  if (checks.some((check) => check.status === "fail")) {
    return "fail";
  }

  if (checks.some((check) => check.status === "warn")) {
    return "warn";
  }

  return "pass";
}

function buildReviewPrompt({ mode, changedFiles, diff, context, checks }) {
  const checklist = [
    "1. Does this change follow ARCHITECTURE.md dependency directions?",
    "2. Are golden principles respected?",
    "3. If protocol changed, are both sides updated with tests?",
    "4. Are new files placed in the correct layer?",
    "5. Is documentation updated to reflect the change?",
    "6. Are there obvious regressions or missing edge cases?",
  ].join("\n");

  const checkSummary = checks
    .map((check) => `- [${check.status.toUpperCase()}] ${check.id}: ${check.reason}`)
    .join("\n");

  const changedFileList =
    changedFiles.length > 0 ? changedFiles.map((file) => `- ${file}`).join("\n") : "- (none)";

  return [
    "You are reviewing a code change for Oppi.",
    `Diff scope: ${mode}`,
    "",
    "### Mechanical pre-check summary",
    checkSummary,
    "",
    "### Changed files",
    changedFileList,
    "",
    "### ARCHITECTURE.md dependency rules",
    context.architectureRules,
    "",
    "### Golden principles",
    context.goldenPrinciples,
    "",
    "### Protocol discipline (AGENTS.md)",
    context.protocolDiscipline,
    "",
    "### Review checklist",
    checklist,
    "",
    "### Diff",
    "```diff",
    diff.trim().length > 0 ? diff.trimEnd() : "# Empty diff",
    "```",
  ].join("\n");
}

export function main() {
  const options = parseArgs(process.argv.slice(2));
  const repoRoot = getRepoRoot();
  const diffData = getDiffAndFiles(repoRoot, options);
  const normalizedFiles = diffData.changedFiles.map(normalizeRepoPath);

  const context = getReviewContext(repoRoot);
  const layerViolations = findServerLayerViolations(repoRoot, normalizedFiles);
  const checks = buildChecks(normalizedFiles, layerViolations, diffData.diff);
  const status = deriveOverallStatus(checks);

  const summary = {
    status,
    mode: diffData.mode,
    changedFileCount: normalizedFiles.length,
    changedFiles: normalizedFiles,
    checks,
  };

  const reviewPrompt = buildReviewPrompt({
    mode: diffData.mode,
    changedFiles: normalizedFiles,
    diff: diffData.diff,
    context,
    checks,
  });

  console.log("=== AI Review Summary ===");
  console.log(JSON.stringify(summary, null, 2));
  console.log("\n=== AI Review Prompt ===");
  console.log(reviewPrompt);

  if (status === "fail") {
    process.exit(1);
  }
}

const isDirectExecution =
  process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  try {
    main();
  } catch (error) {
    console.error(`ai-review error: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
