#!/usr/bin/env bun

import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  findIosLayerViolations,
  findServerLayerViolations,
} from "./architecture-layer-rules.mjs"; // kept as .mjs — also imported by eslint.config.js under Node

function parseArgs(argv) {
  const options = {
    scope: "all",
    format: "text",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === "--scope") {
      const next = argv[index + 1];
      if (!next) {
        throw new Error("Missing value for --scope");
      }

      if (!["all", "server", "ios"].includes(next)) {
        throw new Error(`Invalid --scope value: ${next}`);
      }

      options.scope = next;
      index += 1;
      continue;
    }

    if (token === "--format") {
      const next = argv[index + 1];
      if (!next) {
        throw new Error("Missing value for --format");
      }

      if (!["text", "xcode"].includes(next)) {
        throw new Error(`Invalid --format value: ${next}`);
      }

      options.format = next;
      index += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${token}`);
  }

  return options;
}

function formatPlainText(violations) {
  console.error("Architecture boundary check failed.");

  for (const violation of violations) {
    const line = violation.line ?? 1;
    const column = violation.column ?? 1;
    console.error(`- ${violation.file}:${line}:${column} [${violation.rule}] ${violation.reason}`);

    if (violation.importer && violation.target) {
      console.error(`    edge: ${violation.importer} -> ${violation.target}`);
    }

    console.error(`    remediation: ${violation.remediation}`);
    console.error(`    guide: ${violation.guide}`);
  }
}

function formatXcode(violations, repoRoot) {
  for (const violation of violations) {
    const line = violation.line ?? 1;
    const column = violation.column ?? 1;
    const absoluteFile = path.join(repoRoot, violation.file);
    const edge =
      violation.importer && violation.target
        ? ` Edge: ${violation.importer} -> ${violation.target}.`
        : "";

    console.error(
      `${absoluteFile}:${line}:${column}: error: [architecture/${violation.rule}] ${violation.reason} ${violation.remediation} See ${violation.guide}.${edge}`,
    );
  }
}

function run(options) {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const repoRoot = path.resolve(scriptDir, "../..");

  const checks = [];
  if (options.scope === "all" || options.scope === "server") {
    checks.push(...findServerLayerViolations(repoRoot));
  }

  if (options.scope === "all" || options.scope === "ios") {
    checks.push(...findIosLayerViolations(repoRoot));
  }

  const violations = checks.sort((a, b) => {
    if (a.file !== b.file) {
      return a.file.localeCompare(b.file);
    }

    if ((a.line ?? 1) !== (b.line ?? 1)) {
      return (a.line ?? 1) - (b.line ?? 1);
    }

    if ((a.column ?? 1) !== (b.column ?? 1)) {
      return (a.column ?? 1) - (b.column ?? 1);
    }

    return a.rule.localeCompare(b.rule);
  });

  if (violations.length === 0) {
    console.log(`Architecture boundary checks passed (scope: ${options.scope}).`);
    return;
  }

  if (options.format === "xcode") {
    formatXcode(violations, repoRoot);
  } else {
    formatPlainText(violations);
  }

  process.exit(1);
}

try {
  const options = parseArgs(process.argv.slice(2));
  run(options);
} catch (error) {
  console.error(
    `check-architecture-boundaries error: ${error instanceof Error ? error.message : String(error)}`,
  );
  process.exit(1);
}
