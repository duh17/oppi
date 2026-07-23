#!/usr/bin/env bun

/**
 * Oppi server log review — parses ~/.config/oppi/server.log JSONL, groups
 * problem events, and keeps noisy lifecycle lines separate from real failures.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const HOUR_MS = 60 * 60 * 1_000;
const DAY_MS = 24 * HOUR_MS;

interface ServerLogRecord {
  ts?: string;
  level?: string;
  event?: string;
  component?: string;
  message?: string;
  msg?: string;
  error?: string;
  sessionId?: string;
  workspaceId?: string;
  [key: string]: unknown;
}

interface ProblemSummary {
  key: string;
  count: number;
  level: string;
  component: string;
  event: string;
  message: string;
  firstTs: number;
  lastTs: number;
  sessions: Set<string>;
  workspaces: Set<string>;
  example: ServerLogRecord;
}

interface RecentProblem {
  ts: number;
  level: string;
  component: string;
  event: string;
  message: string;
  sessionId?: string;
  workspaceId?: string;
}

export interface ServerLogReviewResult {
  days: number;
  windowLabel: string;
  requestedSinceMs: number;
  logPath: string;
  logAvailable: boolean;
  evidenceState: "available" | "unavailable" | "invalid" | "stale";
  lines: number;
  parsed: number;
  unparsed: number;
  inWindow: number;
  firstTs: number | null;
  lastTs: number | null;
  levelCounts: Record<string, number>;
  componentCounts: Record<string, number>;
  eventCounts: Record<string, number>;
  problems: Array<{
    key: string;
    count: number;
    level: string;
    component: string;
    event: string;
    message: string;
    firstTs: number;
    lastTs: number;
    sessions: string[];
    workspaces: string[];
    example: ServerLogRecord;
  }>;
  recent: RecentProblem[];
}

interface ParsedArgs {
  path?: string;
  dataDir?: string;
  days: number;
  hours?: number;
  since?: string;
  json: boolean;
  help: boolean;
  limit: number;
  match?: string;
}

function inc(map: Record<string, number>, key: string, by = 1): void {
  map[key] = (map[key] ?? 0) + by;
}

function parseTs(value: unknown): number | null {
  if (typeof value !== "string" || !value) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatTs(ts: number | null | undefined): string {
  if (ts == null || !Number.isFinite(ts)) return "?";
  return new Date(ts).toISOString().replace("T", " ").replace(".000Z", "Z");
}

function truncate(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, Math.max(1, max - 1))}…` : value;
}

function parseJsonLine(line: string): ServerLogRecord | null {
  try {
    const parsed = JSON.parse(line) as ServerLogRecord;
    return parsed &&
      typeof parsed === "object" &&
      !Array.isArray(parsed) &&
      typeof parsed.ts === "string" &&
      Number.isFinite(Date.parse(parsed.ts))
      ? parsed
      : null;
  } catch {
    return null;
  }
}

function messageFor(record: ServerLogRecord): string {
  const message = record.message ?? record.msg ?? record.error;
  return typeof message === "string" ? message : "";
}

function normalizedLevel(record: ServerLogRecord): string {
  const level = typeof record.level === "string" ? record.level.toLowerCase() : "unknown";
  return level === "warning" ? "warn" : level;
}

function isBenign(record: ServerLogRecord): boolean {
  const event = typeof record.event === "string" ? record.event : "";
  const component = typeof record.component === "string" ? record.component : "";
  if (event === "session_lifecycle.idle_timeout") return true;
  if (event === "gate.policy_decision") return true;
  if (component === "gate" && event.includes("policy")) return true;
  return false;
}

function isProblem(record: ServerLogRecord): boolean {
  if (isBenign(record)) return false;
  const level = normalizedLevel(record);
  if (level === "error" || level === "warn" || level === "fatal") return true;
  const haystack = `${record.event ?? ""} ${messageFor(record)}`.toLowerCase();
  return /failed|failure|error|exception|crash|fatal|unhandled|timeout|eaddr|econn/.test(haystack);
}

function addProblem(
  problems: Map<string, ProblemSummary>,
  record: ServerLogRecord,
  ts: number,
): void {
  const level = normalizedLevel(record);
  const component = typeof record.component === "string" ? record.component : "unknown";
  const event = typeof record.event === "string" ? record.event : "unknown";
  const message = messageFor(record);
  const key = [level, component, event, message].join("\t");
  let problem = problems.get(key);
  if (!problem) {
    problem = {
      key,
      count: 0,
      level,
      component,
      event,
      message,
      firstTs: ts,
      lastTs: ts,
      sessions: new Set(),
      workspaces: new Set(),
      example: record,
    };
    problems.set(key, problem);
  }
  problem.count += 1;
  problem.firstTs = Math.min(problem.firstTs, ts);
  problem.lastTs = Math.max(problem.lastTs, ts);
  if (typeof record.sessionId === "string") problem.sessions.add(record.sessionId);
  if (typeof record.workspaceId === "string") problem.workspaces.add(record.workspaceId);
}

export function buildServerLogReview(options: {
  logPath: string;
  days?: number;
  hours?: number;
  sinceMs?: number;
  limit?: number;
  match?: RegExp;
}): ServerLogReviewResult {
  const days = Math.max(0, options.days ?? 1);
  const hours = options.hours == null ? undefined : Math.max(0, options.hours);
  const explicitSinceMs =
    typeof options.sinceMs === "number" && Number.isFinite(options.sinceMs)
      ? Math.trunc(options.sinceMs)
      : null;
  const cutoffMs = explicitSinceMs ?? Date.now() - (hours != null ? hours * HOUR_MS : days * DAY_MS);
  const windowLabel =
    explicitSinceMs != null
      ? `since ${formatTs(explicitSinceMs)}`
      : hours != null
        ? `${hours}h`
        : `${days}d`;
  const levelCounts: Record<string, number> = {};
  const componentCounts: Record<string, number> = {};
  const eventCounts: Record<string, number> = {};
  const problems = new Map<string, ProblemSummary>();
  const recent: RecentProblem[] = [];

  let lines = 0;
  let parsed = 0;
  let unparsed = 0;
  let inWindow = 0;
  let firstTs: number | null = null;
  let lastTs: number | null = null;

  if (!existsSync(options.logPath)) {
    return {
      days: Math.max(0, (Date.now() - cutoffMs) / DAY_MS),
      windowLabel,
      requestedSinceMs: cutoffMs,
      logPath: options.logPath,
      logAvailable: false,
      evidenceState: "unavailable",
      lines,
      parsed,
      unparsed,
      inWindow,
      firstTs,
      lastTs,
      levelCounts,
      componentCounts,
      eventCounts,
      problems: [],
      recent: [],
    };
  }

  const text = readFileSync(options.logPath, "utf8");
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    lines += 1;
    const record = parseJsonLine(line);
    if (!record) {
      unparsed += 1;
      continue;
    }
    parsed += 1;
    const ts = parseTs(record.ts);
    if (ts == null || ts < cutoffMs) continue;
    inWindow += 1;
    firstTs = firstTs == null ? ts : Math.min(firstTs, ts);
    lastTs = lastTs == null ? ts : Math.max(lastTs, ts);

    const level = normalizedLevel(record);
    const component = typeof record.component === "string" ? record.component : "unknown";
    const event = typeof record.event === "string" ? record.event : "unknown";
    inc(levelCounts, level);
    inc(componentCounts, component);
    inc(eventCounts, event);

    if (isProblem(record)) {
      addProblem(problems, record, ts);
      recent.push({
        ts,
        level,
        component,
        event,
        message: messageFor(record),
        sessionId: typeof record.sessionId === "string" ? record.sessionId : undefined,
        workspaceId: typeof record.workspaceId === "string" ? record.workspaceId : undefined,
      });
    }
  }

  const limit = Math.max(1, options.limit ?? 20);
  recent.sort((a, b) => b.ts - a.ts);

  return {
    days: Math.max(0, (Date.now() - cutoffMs) / DAY_MS),
    windowLabel,
    requestedSinceMs: cutoffMs,
    logPath: options.logPath,
    logAvailable: true,
    evidenceState:
      lines === 0 ? "unavailable" : parsed === 0 ? "invalid" : inWindow === 0 ? "stale" : "available",
    lines,
    parsed,
    unparsed,
    inWindow,
    firstTs,
    lastTs,
    levelCounts,
    componentCounts: Object.fromEntries(
      Object.entries(componentCounts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, limit),
    ),
    eventCounts: Object.fromEntries(
      Object.entries(eventCounts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, limit),
    ),
    problems: [...problems.values()]
      .sort((a, b) => {
        const aMatch = options.match?.test(`${a.component} ${a.event} ${a.message}`) ? 1 : 0;
        const bMatch = options.match?.test(`${b.component} ${b.event} ${b.message}`) ? 1 : 0;
        return bMatch - aMatch || b.count - a.count || b.lastTs - a.lastTs;
      })
      .slice(0, limit)
      .map((problem) => ({
        key: problem.key,
        count: problem.count,
        level: problem.level,
        component: problem.component,
        event: problem.event,
        message: problem.message,
        firstTs: problem.firstTs,
        lastTs: problem.lastTs,
        sessions: [...problem.sessions].slice(0, 8),
        workspaces: [...problem.workspaces].slice(0, 8),
        example: problem.example,
      })),
    recent: recent.slice(0, limit),
  };
}

function printHuman(result: ServerLogReviewResult): void {
  console.log(`Oppi Server Log Review (${result.windowLabel})`);
  console.log(`  log: ${result.logPath}`);
  console.log(
    `  evidence=${result.evidenceState} lines=${result.lines} parsed=${result.parsed} unparsed=${result.unparsed} in_window=${result.inWindow}`,
  );
  console.log(`  window=${formatTs(result.firstTs)} -> ${formatTs(result.lastTs)}`);
  console.log();

  console.log("Levels");
  if (Object.keys(result.levelCounts).length === 0) {
    console.log("  (none)");
  } else {
    for (const [level, count] of Object.entries(result.levelCounts).sort((a, b) => b[1] - a[1])) {
      console.log(`  ${level.padEnd(7)} ${String(count).padStart(7)}`);
    }
  }
  console.log();

  console.log("Top problem signatures");
  if (result.problems.length === 0) {
    console.log("  (none)");
  } else {
    for (const problem of result.problems) {
      const scope = [
        problem.sessions.length ? `sessions=${problem.sessions.length}` : "",
        problem.workspaces.length ? `workspaces=${problem.workspaces.length}` : "",
      ]
        .filter(Boolean)
        .join(" ");
      console.log(
        `  ${String(problem.count).padStart(5)} ${problem.level.padEnd(5)} ${problem.component.padEnd(22)} ${truncate(problem.event, 44)} ${truncate(problem.message, 70)}`.trimEnd(),
      );
      console.log(
        `        ${formatTs(problem.firstTs)} -> ${formatTs(problem.lastTs)} ${scope}`.trimEnd(),
      );
    }
  }
  console.log();

  console.log("Recent problems");
  if (result.recent.length === 0) {
    console.log("  (none)");
  } else {
    for (const item of result.recent) {
      console.log(
        `  ${formatTs(item.ts)} ${item.level.padEnd(5)} ${item.component.padEnd(22)} ${truncate(item.event, 36)} ${truncate(item.message, 80)}`.trimEnd(),
      );
    }
  }
}

function requiredArg(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function patternArg(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (value === undefined || value.length === 0 || value.startsWith("--")) {
    throw new Error(`${flag} requires a value; use ${flag}=<pattern> for patterns beginning with --`);
  }
  return value;
}

function positiveNumber(raw: string, flag: string): number {
  if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(raw)) {
    throw new Error(`${flag} requires a positive number`);
  }
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${flag} requires a positive number`);
  return value;
}

function parseArgs(argv: string[]): ParsedArgs {
  const args: ParsedArgs = {
    days: 1,
    json: false,
    help: false,
    limit: 20,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith("--match=")) {
      args.match = arg.slice("--match=".length);
      if (!args.match) throw new Error("--match requires a value");
      continue;
    }
    switch (arg) {
      case "--path":
        args.path = requiredArg(argv, ++i, arg);
        break;
      case "--data-dir":
        args.dataDir = requiredArg(argv, ++i, arg);
        break;
      case "--days":
        args.days = positiveNumber(requiredArg(argv, ++i, arg), arg);
        args.hours = undefined;
        args.since = undefined;
        break;
      case "--hours":
        args.hours = positiveNumber(requiredArg(argv, ++i, arg), arg);
        args.since = undefined;
        break;
      case "--since":
        args.since = requiredArg(argv, ++i, arg);
        args.hours = undefined;
        break;
      case "--limit":
        args.limit = Math.ceil(positiveNumber(requiredArg(argv, ++i, arg), arg));
        break;
      case "--match":
        args.match = patternArg(argv, ++i, arg);
        break;
      case "--json":
        args.json = true;
        break;
      case "--help":
      case "-h":
        args.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function printHelp(): void {
  console.error(`Oppi Server Log Review

  bun server/scripts/server-log-review.ts
  bun server/scripts/server-log-review.ts --days 1 --limit 30
  bun server/scripts/server-log-review.ts --hours 3 --limit 30
  bun server/scripts/server-log-review.ts --since 2026-07-22T20:00:00Z --limit 30
  bun server/scripts/server-log-review.ts --path ~/.config/oppi/server.log --json

Options:
  --path <path>       Server log path (default: <data-dir>/server.log)
  --data-dir <path>   Oppi data dir (default: ~/.config/oppi)
  --days <n>          Days to include by JSON ts field (default: 1)
  --hours <n>         Hours to include; overrides --days
  --since <timestamp> Exact ISO-8601 window start; overrides --days/--hours
  --limit <n>         Number of top/recent entries (default: 20)
  --match <regex>     Prioritize matching problems before applying --limit
  --json              Machine-readable JSON
  --help              Show this help
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
  const logPath = resolve(args.path ?? join(dataDir, "server.log"));
  const sinceMs = args.since ? Date.parse(args.since) : undefined;
  if (args.since && !Number.isFinite(sinceMs)) {
    throw new Error(`Invalid --since timestamp: ${args.since}`);
  }
  let match: RegExp | undefined;
  try {
    match = args.match ? new RegExp(args.match, "i") : undefined;
  } catch {
    throw new Error(`Invalid --match regex: ${args.match}`);
  }
  const result = buildServerLogReview({
    logPath,
    days: args.days,
    hours: args.hours,
    sinceMs,
    limit: args.limit,
    match,
  });

  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  printHuman(result);
}

if (import.meta.main) {
  main();
}
