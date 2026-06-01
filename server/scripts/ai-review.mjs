#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  findIosLayerViolations,
  findServerLayerViolations,
  readImportsFromFile,
} from "./architecture-layer-rules.mjs";

export { readImportsFromFile } from "./architecture-layer-rules.mjs";

const SERVER_TYPES = "server/src/types.ts";
const APPLE_PROTOCOL_FILES = [
  "clients/apple/Oppi/Core/Models/ServerMessage.swift",
  "clients/apple/Oppi/Core/Models/ClientMessage.swift",
];
const REVIEW_INFRA_FILES = new Set([
  "server/scripts/ai-review.mjs",
  "server/scripts/check-architecture-boundaries.ts",
  "server/scripts/architecture-layer-rules.mjs",
  "server/tests/ai-review-script.test.ts",
  "server/tests/architecture-layer-rules.test.ts",
  "server/vitest.config.ts",
  "server/tsconfig.json",
]);

function repoRoot() {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
}

const GIT_OUTPUT_MAX_BUFFER = 64 * 1024 * 1024;

function git(args, options = {}) {
  return execFileSync("git", args, {
    cwd: options.cwd ?? repoRoot(),
    encoding: "utf8",
    maxBuffer: GIT_OUTPUT_MAX_BUFFER,
    stdio: ["ignore", "pipe", options.allowFailure ? "pipe" : "inherit"],
  });
}

function parseArgs(argv) {
  const options = { commits: null, staged: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--staged") {
      options.staged = true;
    } else if (token === "--json") {
      options.json = true;
    } else if (token === "--commits") {
      const value = argv[index + 1];
      if (!value || !/^\d+$/.test(value)) throw new Error("--commits requires a positive integer");
      options.commits = Number(value);
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${token}`);
    }
  }
  if (!options.staged && options.commits === null) options.commits = 1;
  return options;
}

function getReviewInput(options) {
  if (options.staged) {
    return {
      label: "staged changes",
      files: splitLines(git(["diff", "--cached", "--name-only", "--diff-filter=ACMR"])),
      diff: git(["diff", "--cached", "--no-ext-diff"]),
      baseRef: "HEAD",
      nextRef: ":",
    };
  }

  const baseRef = `HEAD~${options.commits}`;
  return {
    label: `last ${options.commits} commit${options.commits === 1 ? "" : "s"}`,
    files: splitLines(git(["diff", "--name-only", "--diff-filter=ACMR", baseRef, "HEAD"])),
    diff: git(["diff", "--no-ext-diff", baseRef, "HEAD"]),
    baseRef,
    nextRef: "HEAD",
  };
}

function splitLines(text) {
  return text.split(/\r?\n/).filter(Boolean);
}

export function extractFileDiff(diffText, filePath) {
  const header = `diff --git a/${filePath} b/${filePath}`;
  const start = diffText.indexOf(header);
  if (start === -1) return "";
  const next = diffText.indexOf("\ndiff --git ", start + header.length);
  return diffText.slice(start, next === -1 ? undefined : next);
}

export function isPackageJsonCiTestingChange(fileDiff) {
  if (!fileDiff) return false;
  return fileDiff
    .split(/\r?\n/)
    .filter((line) => /^[+-]\s*"/.test(line))
    .some((line) => /"(?:test|check|review|lint|build|prepare|prepublishOnly)(?::[^"]*)?"\s*:/.test(line));
}

function extractTypeBlock(source, typeName) {
  const match = source.match(new RegExp(`export\\s+type\\s+${typeName}\\s*=`));
  if (!match || match.index === undefined) return "";
  const start = match.index;
  const rest = source.slice(start);
  const next = rest.search(/\nexport\s+(?:type|interface|const|class|enum|function)\s+/);
  return rest.slice(0, next === -1 ? undefined : next).replace(/\s+/g, " ").trim();
}

export function getWebSocketContractChanges(previousSource, nextSource) {
  return {
    clientMessageChanged:
      extractTypeBlock(previousSource, "ClientMessage") !== extractTypeBlock(nextSource, "ClientMessage"),
    serverMessageChanged:
      extractTypeBlock(previousSource, "ServerMessage") !== extractTypeBlock(nextSource, "ServerMessage"),
  };
}

export function didWebSocketContractChange(previousSource, nextSource) {
  const changes = getWebSocketContractChanges(previousSource, nextSource);
  return changes.clientMessageChanged || changes.serverMessageChanged;
}

function changedAppleProtocolFiles(files) {
  return files.filter((file) => APPLE_PROTOCOL_FILES.includes(file));
}

function checkProtocolLockstep(files, context) {
  const appleProtocolTouched = changedAppleProtocolFiles(files);
  const serverTypesTouched = files.includes(SERVER_TYPES);
  const clientMessageChanged = Boolean(
    context.clientMessageChanged ?? context.serverTypesWireContractChanged ?? serverTypesTouched,
  );
  const serverMessageChanged = Boolean(
    context.serverMessageChanged ?? context.serverTypesWireContractChanged ?? serverTypesTouched,
  );
  const serverWireChanged = clientMessageChanged || serverMessageChanged;

  if (serverTypesTouched && serverWireChanged) {
    const requiredAppleFiles = [];
    if (serverMessageChanged) requiredAppleFiles.push("clients/apple/Oppi/Core/Models/ServerMessage.swift");
    if (clientMessageChanged) requiredAppleFiles.push("clients/apple/Oppi/Core/Models/ClientMessage.swift");
    const missing = requiredAppleFiles.filter((file) => !files.includes(file));
    if (missing.length > 0) {
      return fail("protocol-lockstep", "server wire contract changed without Apple protocol lockstep", {
        touched: [SERVER_TYPES, ...appleProtocolTouched],
        missing,
      });
    }
  }

  if (appleProtocolTouched.length > 0 && !serverTypesTouched) {
    return fail("protocol-lockstep", "Apple protocol model changed without server/src/types.ts lockstep", {
      touched: appleProtocolTouched,
      missing: [SERVER_TYPES],
    });
  }

  return pass(
    "protocol-lockstep",
    serverTypesTouched && !serverWireChanged
      ? "server/src/types.ts changed, but ClientMessage/ServerMessage wire contract shapes did not"
      : "protocol files are unchanged or changed in lockstep",
  );
}

function checkCiTestingInfra(files, diffText) {
  const flagged = files.filter((file) => {
    if (REVIEW_INFRA_FILES.has(file)) return true;
    if (/^server\/tests?\//.test(file) || /^server\/scripts\//.test(file)) return /(?:test|check|review|architecture|gate|ci)/i.test(file);
    if (file === "server/package.json") return isPackageJsonCiTestingChange(extractFileDiff(diffText, file));
    if (file === "server/package-lock.json") return files.includes("server/package.json");
    if (/^\.github\/workflows\//.test(file)) return true;
    return false;
  });
  return flagged.length === 0
    ? pass("ci-testing-infra-review", "CI/testing/review infra unchanged")
    : warn("ci-testing-infra-review", "CI/testing/review infra changed; verify the gate itself still runs", { files: flagged });
}

function checkBroadRisk(files, diffText) {
  const addedRemoved = diffText.split(/\r?\n/).filter((line) => /^[+-]/.test(line) && !/^(---|\+\+\+)/.test(line)).length;
  const risky = files.length >= 20 || addedRemoved >= 800;
  return risky
    ? warn("broad-risk", "large change set; consider extra review and targeted test runs", { fileCount: files.length, changedLines: addedRemoved })
    : pass("broad-risk", "change set size is within mechanical-review thresholds", { fileCount: files.length, changedLines: addedRemoved });
}

function checkArchitecture(repoRootPath, files) {
  const violations = [
    ...findServerLayerViolations(repoRootPath, files),
    ...findIosLayerViolations(repoRootPath, files),
  ];
  return violations.length === 0
    ? pass("architecture-boundaries", "changed source files respect layer boundaries")
    : fail("architecture-boundaries", "architecture layer violations found", { violations });
}

export function buildChecks(files, architectureViolations = [], diffText = "", context = {}) {
  const checks = [];
  checks.push(
    architectureViolations.length === 0
      ? pass("architecture-boundaries", "changed source files respect layer boundaries")
      : fail("architecture-boundaries", "architecture layer violations found", { violations: architectureViolations }),
  );
  checks.push(checkProtocolLockstep(files, context));
  checks.push(checkCiTestingInfra(files, diffText));
  checks.push(checkBroadRisk(files, diffText));
  return checks;
}

function pass(id, reason, details = undefined) {
  return { id, status: "pass", reason, ...(details ? { details } : {}) };
}
function warn(id, reason, details = undefined) {
  return { id, status: "warn", reason, ...(details ? { details } : {}) };
}
function fail(id, reason, details = undefined) {
  return { id, status: "fail", reason, ...(details ? { details } : {}) };
}

function readFileAt(ref, file) {
  try {
    return git(["show", ref === ":" ? `:${file}` : `${ref}:${file}`], { allowFailure: true });
  } catch {
    return "";
  }
}

function computeContext(input) {
  if (!input.files.includes(SERVER_TYPES)) return {};
  const nextSource = input.nextRef === ":"
    ? readFileAt(":", SERVER_TYPES) || (existsSync(path.join(repoRoot(), SERVER_TYPES)) ? readFileSync(path.join(repoRoot(), SERVER_TYPES), "utf8") : "")
    : readFileAt(input.nextRef, SERVER_TYPES);
  const previousSource = readFileAt(input.baseRef, SERVER_TYPES);
  const changes = getWebSocketContractChanges(previousSource, nextSource);
  return { serverTypesWireContractChanged: changes.clientMessageChanged || changes.serverMessageChanged, ...changes };
}

function formatCheck(check) {
  const label = check.status.toUpperCase().padEnd(4);
  const lines = [`${label} ${check.id}: ${check.reason}`];
  if (Array.isArray(check.details?.files)) lines.push(`     files: ${check.details.files.join(", ")}`);
  if (check.details?.missing) lines.push(`     missing: ${check.details.missing.join(", ")}`);
  if (check.details?.changedLines !== undefined) lines.push(`     size: ${check.details.fileCount} files, ${check.details.changedLines} changed lines`);
  if (check.details?.violations) {
    for (const violation of check.details.violations.slice(0, 20)) {
      lines.push(`     ${violation.file}:${violation.line ?? 1}:${violation.column ?? 1} [${violation.rule}] ${violation.reason}`);
      if (violation.importer && violation.target) lines.push(`       edge: ${violation.importer} -> ${violation.target}`);
    }
    if (check.details.violations.length > 20) lines.push(`     ... ${check.details.violations.length - 20} more violations`);
  }
  return lines.join("\n");
}

function runCli() {
  const options = parseArgs(process.argv.slice(2));
  const input = getReviewInput(options);
  const root = repoRoot();
  const architecture = checkArchitecture(root, input.files);
  const context = computeContext(input);
  const checks = buildChecks(input.files, architecture.details?.violations ?? [], input.diff, context);

  if (options.json) {
    console.log(JSON.stringify({ scope: input.label, files: input.files, checks }, null, 2));
  } else {
    console.log(`AI mechanical review gate (${input.label})`);
    console.log(`Changed files: ${input.files.length}`);
    for (const check of checks) console.log(`\n${formatCheck(check)}`);
  }

  if (checks.some((check) => check.status === "fail")) process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    runCli();
  } catch (error) {
    console.error(`ai-review error: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}
