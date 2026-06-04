#!/usr/bin/env bun

/**
 * Oppi diagnostics snapshot — one command that captures telemetry, client logs,
 * MetricKit diagnostics, server log health, and optional external crash sources.
 */

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

interface ParsedArgs {
  dataDir?: string;
  days: number;
  out?: string;
  limit: number;
  json: boolean;
  help: boolean;
  external: boolean;
}

interface CommandResult {
  title: string;
  command: string;
  status: number | null;
  stdout: string;
  stderr: string;
}

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "..", "..");
const bunExecutable = process.execPath || "bun";

function parseArgs(argv: string[]): ParsedArgs {
  const args: ParsedArgs = {
    days: 1,
    limit: 20,
    json: false,
    help: false,
    external: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--data-dir":
        args.dataDir = argv[++i];
        break;
      case "--days":
        args.days = Math.max(1, Number.parseInt(argv[++i] ?? "1", 10) || 1);
        break;
      case "--limit":
        args.limit = Math.max(1, Number.parseInt(argv[++i] ?? "20", 10) || 20);
        break;
      case "--out":
        args.out = argv[++i];
        break;
      case "--external":
      case "--include-external":
        args.external = true;
        break;
      case "--json":
        args.json = true;
        break;
      case "--help":
      case "-h":
        args.help = true;
        break;
    }
  }

  return args;
}

function commandString(command: string, args: string[]): string {
  return [command, ...args]
    .map((part) => (part.includes(" ") ? JSON.stringify(part) : part))
    .join(" ");
}

function run(title: string, command: string, args: string[], cwd = repoRoot): CommandResult {
  const result = spawnSync(command, args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      NO_COLOR: "1",
      FORCE_COLOR: "0",
    },
    timeout: 120_000,
  });

  return {
    title,
    command: commandString(command, args),
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function stripAnsi(value: string): string {
  return value.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "");
}

function defaultReportPath(): string {
  const stamp = new Date()
    .toISOString()
    .replaceAll(":", "")
    .replace(/\.\d{3}Z$/, "Z");
  return join(repoRoot, ".internal", "reports", `diagnostics-${stamp}.md`);
}

function externalCommands(
  days: number,
): Array<{ title: string; command: string; args: string[]; cwd?: string }> {
  const home = homedir();
  const sentryDir = join(home, ".pi", "agent", "skills", "sentry");
  const sentryList = join(sentryDir, "scripts", "list-issues.js");
  const ascScript = join(home, ".pi", "agent", "skills", "oppi-dev", "scripts", "apple", "asc.ts");
  const commands: Array<{ title: string; command: string; args: string[]; cwd?: string }> = [];

  if (existsSync(sentryList)) {
    commands.push({
      title: "Sentry unresolved errors",
      command: sentryList,
      args: ["--status", "unresolved", "--level", "error", "--period", `${days}d`, "--limit", "20"],
      cwd: sentryDir,
    });
    commands.push({
      title: "Sentry unresolved fatal issues",
      command: sentryList,
      args: ["--status", "unresolved", "--level", "fatal", "--period", `${days}d`, "--limit", "20"],
      cwd: sentryDir,
    });
  }

  if (existsSync(ascScript)) {
    commands.push({
      title: "App Store Connect recent build usage",
      command: bunExecutable,
      args: [ascScript, "build-usage-recent", "10"],
      cwd: repoRoot,
    });
  }

  return commands;
}

function buildMarkdown(args: ParsedArgs, dataDir: string, results: CommandResult[]): string {
  const generatedAt = new Date().toISOString();
  const lines: string[] = [
    `# Oppi Diagnostics Snapshot`,
    "",
    `- Generated: ${generatedAt}`,
    `- Window: last ${args.days} day(s)`,
    `- Data dir: \`${dataDir}\``,
    `- External sources: ${args.external ? "included" : "not included"}`,
    "",
  ];

  for (const result of results) {
    lines.push(`## ${result.title}`);
    lines.push("");
    lines.push(`Command: \`${result.command}\``);
    lines.push(`Exit: ${result.status ?? "signal/timeout"}`);
    lines.push("");
    lines.push("```text");
    const output = stripAnsi(
      [result.stdout.trimEnd(), result.stderr.trimEnd()].filter(Boolean).join("\n"),
    );
    lines.push(output || "(no output)");
    lines.push("```");
    lines.push("");
  }

  return `${lines.join("\n")}\n`;
}

function printHelp(): void {
  console.error(`Oppi Diagnostics Review

  bun server/scripts/diagnostics-review.ts
  bun server/scripts/diagnostics-review.ts --days 3 --external
  bun server/scripts/diagnostics-review.ts --out .internal/reports/diagnostics.md

Options:
  --data-dir <path>       Oppi data dir (default: ~/.config/oppi)
  --days <n>              Days to include (default: 1)
  --limit <n>             Top/recent rows for subreports (default: 20)
  --out <path>            Markdown report path (default: .internal/reports/diagnostics-*.md)
  --external              Include Sentry and App Store Connect if configured
  --json                  Print command result metadata as JSON
  --help                  Show this help
`);
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    process.exit(0);
  }

  const dataDir = resolve(
    args.dataDir ?? process.env.OPPI_DATA_DIR ?? join(homedir(), ".config", "oppi"),
  );
  const commonArgs = [
    "--data-dir",
    dataDir,
    "--days",
    String(args.days),
    "--limit",
    String(args.limit),
  ];
  const commands: Array<{ title: string; command: string; args: string[]; cwd?: string }> = [
    {
      title: "Telemetry SLO review",
      command: bunExecutable,
      args: [
        join(scriptDir, "telemetry-review.ts"),
        "--data-dir",
        dataDir,
        "--days",
        String(args.days),
        "--wide",
        "--no-color",
      ],
    },
    {
      title: "Client log review",
      command: bunExecutable,
      args: [join(scriptDir, "client-log-review.ts"), ...commonArgs],
    },
    {
      title: "MetricKit diagnostics review",
      command: bunExecutable,
      args: [join(scriptDir, "metrickit-review.ts"), ...commonArgs],
    },
    {
      title: "Server log review",
      command: bunExecutable,
      args: [join(scriptDir, "server-log-review.ts"), ...commonArgs],
    },
  ];

  if (args.external) {
    commands.push(...externalCommands(args.days));
  }

  const results = commands.map((item) => run(item.title, item.command, item.args, item.cwd));
  const reportPath = resolve(args.out ?? defaultReportPath());
  mkdirSync(dirname(reportPath), { recursive: true });
  writeFileSync(reportPath, buildMarkdown(args, dataDir, results), "utf8");

  if (args.json) {
    console.log(JSON.stringify({ reportPath, results }, null, 2));
    return;
  }

  for (const result of results) {
    console.log(`==> ${result.title}`);
    console.log(stripAnsi(result.stdout.trimEnd() || result.stderr.trimEnd() || "(no output)"));
    if (result.status !== 0) {
      console.log(`  exit=${result.status ?? "signal/timeout"}`);
    }
    console.log();
  }
  console.log(`Diagnostics report: ${reportPath}`);
}

if (import.meta.main) {
  main();
}
