#!/usr/bin/env bun

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const DEFAULT_SCHEMES = ["OppiUnitTests", "OppiMac"];
const DEFAULT_REPORT_INCLUDES = ["Oppi/**/*.swift", "Shared/**/*.swift", "OppiMac/**/*.swift"];

type Options = {
  json: boolean;
  strict: boolean;
  cleanBuild: boolean;
  skipXcodegen: boolean;
  verbose: boolean;
  writeResults?: string;
  reportIncludes: string[];
  passthrough: string[];
};

function usage(exitCode = 0): never {
  const message = `periphery-scan.ts — run Periphery with Oppi Apple defaults

Usage:
  bun scripts/periphery-scan.ts [options] [-- <extra periphery args>]

Defaults:
  - regenerates Oppi.xcodeproj with xcodegen
  - scans schemes: ${DEFAULT_SCHEMES.join(", ")}
  - reports only app sources: ${DEFAULT_REPORT_INCLUDES.join(", ")}
  - retains ObjC-accessible declarations, Codable properties, and SwiftUI previews

Options:
  --json                   Emit structured JSON to stdout
  --strict                 Exit non-zero when unused code is found
  --clean-build            Ask Periphery to clean before building
  --skip-xcodegen          Skip xcodegen project regeneration
  --write-results <path>   Persist raw Periphery results to this path
  --report-include <glob>  Override report include globs (repeatable)
  --verbose                Enable verbose Periphery logging
  -h, --help               Show this help

Examples:
  bun scripts/periphery-scan.ts
  bun scripts/periphery-scan.ts --strict
  bun scripts/periphery-scan.ts --json --report-include 'Oppi/Core/Services/**/*.swift'
  bun scripts/periphery-scan.ts -- --retain-files 'Oppi/App/UIHangHarnessView.swift'
`;
  const stream = exitCode === 0 ? process.stdout : process.stderr;
  stream.write(message);
  process.exit(exitCode);
}

function parseArgs(argv: string[]): Options {
  const options: Options = {
    json: false,
    strict: false,
    cleanBuild: false,
    skipXcodegen: false,
    verbose: false,
    reportIncludes: [],
    passthrough: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg) continue;
    if (arg === "--") {
      options.passthrough.push(...argv.slice(i + 1));
      break;
    }
    if (arg === "-h" || arg === "--help") usage(0);
    if (arg === "--json") {
      options.json = true;
      continue;
    }
    if (arg === "--strict") {
      options.strict = true;
      continue;
    }
    if (arg === "--clean-build") {
      options.cleanBuild = true;
      continue;
    }
    if (arg === "--skip-xcodegen") {
      options.skipXcodegen = true;
      continue;
    }
    if (arg === "--verbose") {
      options.verbose = true;
      continue;
    }
    if (arg === "--write-results") {
      const value = argv[i + 1];
      if (!value) usage(2);
      options.writeResults = value;
      i += 1;
      continue;
    }
    if (arg.startsWith("--write-results=")) {
      options.writeResults = arg.slice("--write-results=".length);
      continue;
    }
    if (arg === "--report-include") {
      const value = argv[i + 1];
      if (!value) usage(2);
      options.reportIncludes.push(value);
      i += 1;
      continue;
    }
    if (arg.startsWith("--report-include=")) {
      options.reportIncludes.push(arg.slice("--report-include=".length));
      continue;
    }

    process.stderr.write(`error: unknown argument: ${arg}\n`);
    usage(2);
  }

  if (options.reportIncludes.length === 0) {
    options.reportIncludes = [...DEFAULT_REPORT_INCLUDES];
  }

  return options;
}

function run(command: string, args: string[], cwd: string, quiet = false): void {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    stdio: quiet ? "pipe" : "inherit",
  });

  if (result.status === 0) {
    return;
  }

  if (quiet) {
    if (result.stdout) process.stderr.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
  }

  const detail = result.error?.message ?? `exit ${result.status ?? 1}`;
  throw new Error(`${command} failed: ${detail}`);
}

function buildPeripheryArgs(options: Options, resultPath: string): string[] {
  const args = [
    "scan",
    "--project-root",
    process.cwd(),
    "--project",
    "Oppi.xcodeproj",
    "--relative-results",
    "--retain-objc-accessible",
    "--retain-codable-properties",
    "--retain-swift-ui-previews",
    "--format",
    options.json ? "json" : "xcode",
    "--write-results",
    resultPath,
  ];

  for (const scheme of DEFAULT_SCHEMES) {
    args.push("--schemes", scheme);
  }
  for (const include of options.reportIncludes) {
    args.push("--report-include", include);
  }
  if (options.strict) args.push("--strict");
  if (options.cleanBuild) args.push("--clean-build");
  if (options.verbose) args.push("--verbose");
  else args.push("--quiet");
  args.push(...options.passthrough);
  return args;
}

function parseJsonResults(resultPath: string, fallbackRaw: string): unknown[] {
  const raw = existsSync(resultPath) ? readFileSync(resultPath, "utf8").trim() : fallbackRaw.trim();
  if (raw.length === 0) return [];
  const parsed = JSON.parse(raw);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function main(): void {
  const options = parseArgs(process.argv.slice(2));
  const cwd = process.cwd();
  const startedAt = new Date().toISOString();
  const timestamp = startedAt.replace(/[:.]/g, "-");
  const defaultReportDir = resolve(cwd, ".pi/reports/periphery", timestamp);
  mkdirSync(defaultReportDir, { recursive: true });
  const resultPath = options.writeResults
    ? resolve(cwd, options.writeResults)
    : join(defaultReportDir, options.json ? "periphery-results.json" : "periphery-results.txt");

  try {
    if (!options.skipXcodegen) {
      run("xcodegen", ["generate"], cwd, true);
    }

    const args = buildPeripheryArgs(options, resultPath);
    const result = spawnSync("periphery", args, {
      cwd,
      encoding: "utf8",
      stdio: "pipe",
    });

    const stdout = result.stdout ?? "";
    const stderr = result.stderr ?? "";
    if (stderr.trim().length > 0 && !options.json) {
      process.stderr.write(stderr);
    }

    if (options.json) {
      let findings: unknown[] = [];
      let parseError: string | undefined;
      if (!existsSync(resultPath) && stdout.trim().length > 0) {
        writeFileSync(resultPath, stdout);
      }
      try {
        findings = parseJsonResults(resultPath, stdout);
      } catch (error) {
        parseError = error instanceof Error ? error.message : String(error);
      }

      const payload = {
        fetched_at: new Date().toISOString(),
        started_at: startedAt,
        command: ["periphery", ...args],
        exit_code: result.status ?? 1,
        strict: options.strict,
        schemes: DEFAULT_SCHEMES,
        report_includes: options.reportIncludes,
        results_path: resultPath,
        summary: {
          findings: findings.length,
          success: result.status === 0,
          xcodegenRan: !options.skipXcodegen,
        },
        ...(parseError ? { parse_error: parseError } : {}),
        ...(stdout.trim().length > 0 ? { stdout } : {}),
        ...(stderr.trim().length > 0 ? { stderr } : {}),
        results: findings,
      };
      process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
    } else {
      if (!existsSync(resultPath) && stdout.trim().length > 0) {
        writeFileSync(resultPath, stdout);
      }
      const rawResults = existsSync(resultPath) ? readFileSync(resultPath, "utf8") : stdout;
      if (rawResults.trim().length > 0) {
        process.stdout.write(rawResults);
        if (!rawResults.endsWith("\n")) process.stdout.write("\n");
      } else {
        process.stdout.write("No Periphery findings.\n");
      }
      if (stdout.trim().length > 0) {
        process.stdout.write(stdout);
      }
      process.stdout.write(`periphery results: ${resultPath}\n`);
    }

    process.exit(result.status ?? 1);
  } finally {
    // Keep report artifacts on disk for follow-up review.
  }
}

main();
