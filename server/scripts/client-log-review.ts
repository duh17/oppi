#!/usr/bin/env bun

/**
 * Oppi client log review — reads uploaded client-logs JSONL files and
 * summarizes warning/error volume, top signatures, and recent examples.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const HOUR_MS = 60 * 60 * 1_000;
const DAY_MS = 24 * HOUR_MS;
const CLIENT_LOG_PREFIX = "client-logs-";
const JSONL_SUFFIX = ".jsonl";

type ClientLogLevel = "debug" | "info" | "warn" | "warning" | "error";

interface ClientLogEntry {
  receivedAt?: number;
  clientKind?: string;
  appInstanceId?: string;
  bootId?: string;
  ts?: number;
  seq?: number;
  level?: ClientLogLevel;
  category?: string;
  message?: string;
  metadata?: Record<string, string>;
  sessionId?: string;
  workspaceId?: string;
}

interface ClientLogRecord {
  receivedAt?: number;
  generatedAt?: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  clientKind?: string;
  appInstanceId?: string;
  bootId?: string;
  droppedCount?: number;
  entryCount?: number;
  entries?: ClientLogEntry[];
}

interface IssueSummary {
  key: string;
  count: number;
  level: string;
  category: string;
  message: string;
  signature: string;
  firstTs: number;
  lastTs: number;
  sessions: Set<string>;
  workspaces: Set<string>;
  builds: Set<string>;
  examples: Array<Record<string, string>>;
}

interface RecentEntry {
  ts: number;
  level: string;
  category: string;
  message: string;
  metadata: Record<string, string>;
  sessionId?: string;
  workspaceId?: string;
  buildNumber?: string;
}

export interface ClientLogReviewResult {
  days: number;
  windowLabel: string;
  requestedSinceMs: number;
  telemetryDir: string;
  telemetryAvailable: boolean;
  evidenceState: "available" | "unavailable" | "invalid" | "stale";
  filesRead: number;
  parsedRecords: number;
  malformedRecords: number;
  uploads: number;
  entries: number;
  dropped: number;
  firstTs: number | null;
  lastTs: number | null;
  levelCounts: Record<string, number>;
  categoryCounts: Record<string, number>;
  issues: Array<{
    key: string;
    count: number;
    level: string;
    category: string;
    message: string;
    signature: string;
    firstTs: number;
    lastTs: number;
    sessions: string[];
    workspaces: string[];
    builds: string[];
    examples: Array<Record<string, string>>;
  }>;
  recent: RecentEntry[];
}

interface ParsedArgs {
  dataDir?: string;
  days: number;
  hours?: number;
  since?: string;
  json: boolean;
  help: boolean;
  limit: number;
  levels: Set<string> | null;
  match?: string;
}

function normalizeLevel(level: unknown): string {
  if (level === "warning") return "warn";
  if (level === "debug" || level === "info" || level === "warn" || level === "error") {
    return level;
  }
  return "unknown";
}

function telemetryDir(dataDir: string): string {
  return join(dataDir, "diagnostics", "telemetry");
}

function safeNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : null;
}

function truncate(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, Math.max(1, max - 1))}…` : value;
}

function formatTs(ts: number | null): string {
  if (ts == null || !Number.isFinite(ts)) return "?";
  return new Date(ts).toISOString().replace("T", " ").replace(".000Z", "Z");
}

function formatWindowValue(value: number): string {
  return Number.isInteger(value)
    ? String(value)
    : value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function inc(map: Record<string, number>, key: string, by = 1): void {
  map[key] = (map[key] ?? 0) + by;
}

function signatureParts(entry: ClientLogEntry, normalizedLevel: string): string[] {
  const metadata = entry.metadata ?? {};
  const parts = [normalizedLevel, entry.category || "General", entry.message || ""];

  // Low-cardinality fields that distinguish different root causes without
  // exploding reconnect attempts by connectionID/status/session.
  for (const key of [
    "errorDomain",
    "errorCode",
    "urlErrorCode",
    "httpStatusCode",
    "webSocketCloseCode",
    "transportPath",
    "streamRole",
    "phase",
    "reason",
    "capabilityStatus",
  ]) {
    const value = metadata[key];
    if (value) parts.push(`${key}=${value}`);
  }

  return parts;
}

function displaySignature(entry: ClientLogEntry): string {
  const metadata = entry.metadata ?? {};
  const parts: string[] = [];
  for (const key of [
    "errorDomain",
    "errorCode",
    "urlErrorCode",
    "httpStatusCode",
    "webSocketCloseCode",
    "transportPath",
    "streamRole",
    "phase",
    "reason",
    "capabilityStatus",
  ]) {
    const value = metadata[key];
    if (value) parts.push(`${key}=${value}`);
  }
  return parts.join(" ");
}

function addIssue(
  issues: Map<string, IssueSummary>,
  entry: ClientLogEntry,
  ts: number,
  buildNumber: string,
): void {
  const level = normalizeLevel(entry.level);
  const key = signatureParts(entry, level).join("\t");
  let issue = issues.get(key);
  if (!issue) {
    issue = {
      key,
      count: 0,
      level,
      category: entry.category || "General",
      message: entry.message || "",
      signature: displaySignature(entry),
      firstTs: ts,
      lastTs: ts,
      sessions: new Set(),
      workspaces: new Set(),
      builds: new Set(),
      examples: [],
    };
    issues.set(key, issue);
  }

  issue.count += 1;
  issue.firstTs = Math.min(issue.firstTs, ts);
  issue.lastTs = Math.max(issue.lastTs, ts);
  if (entry.sessionId) issue.sessions.add(entry.sessionId);
  if (entry.workspaceId) issue.workspaces.add(entry.workspaceId);
  if (buildNumber) issue.builds.add(buildNumber);
  if (entry.metadata && issue.examples.length < 3) {
    const serialized = JSON.stringify(entry.metadata);
    if (!issue.examples.some((existing) => JSON.stringify(existing) === serialized)) {
      issue.examples.push(entry.metadata);
    }
  }
}

function listFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((file) => file.startsWith(CLIENT_LOG_PREFIX) && file.endsWith(JSONL_SUFFIX))
    .sort();
}

function parseJsonLine(line: string): ClientLogRecord | null {
  try {
    const parsed = JSON.parse(line) as ClientLogRecord;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) && Array.isArray(parsed.entries)
      ? parsed
      : null;
  } catch {
    return null;
  }
}

export function buildClientLogReview(options: {
  dataDir: string;
  days?: number;
  hours?: number;
  sinceMs?: number;
  limit?: number;
  levels?: Set<string> | null;
  match?: RegExp;
}): ClientLogReviewResult {
  const dir = telemetryDir(options.dataDir);
  const days = Math.max(0, options.days ?? 7);
  const hours = options.hours == null ? undefined : Math.max(0, options.hours);
  const explicitSinceMs = safeNumber(options.sinceMs);
  const windowMs = hours != null ? hours * HOUR_MS : days * DAY_MS;
  const cutoffMs = explicitSinceMs ?? Date.now() - windowMs;
  const windowLabel =
    explicitSinceMs != null
      ? `since ${formatTs(explicitSinceMs)}`
      : hours != null
        ? `${formatWindowValue(hours)}h`
        : `${formatWindowValue(days)}d`;
  const levels = options.levels;
  const levelCounts: Record<string, number> = {};
  const categoryCounts: Record<string, number> = {};
  const issues = new Map<string, IssueSummary>();
  const recent: RecentEntry[] = [];

  const telemetryAvailable = existsSync(dir);
  let filesRead = 0;
  let parsedRecords = 0;
  let malformedRecords = 0;
  let uploads = 0;
  let entries = 0;
  let dropped = 0;
  let firstTs: number | null = null;
  let lastTs: number | null = null;

  for (const file of listFiles(dir)) {
    const text = readFileSync(join(dir, file), "utf8");
    filesRead += 1;
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      const record = parseJsonLine(line);
      if (!record) {
        malformedRecords += 1;
        continue;
      }
      parsedRecords += 1;
      const buildNumber = record.buildNumber ?? "unknown";
      const recordFallbackTs = safeNumber(record.generatedAt) ?? safeNumber(record.receivedAt) ?? 0;
      let recordInWindow = false;

      for (const entry of record.entries ?? []) {
        const ts = safeNumber(entry.ts) ?? recordFallbackTs;
        if (ts < cutoffMs) continue;
        recordInWindow = true;
        const level = normalizeLevel(entry.level);
        if (levels && !levels.has(level)) continue;
        entries += 1;
        firstTs = firstTs == null ? ts : Math.min(firstTs, ts);
        lastTs = lastTs == null ? ts : Math.max(lastTs, ts);
        inc(levelCounts, level);
        inc(categoryCounts, entry.category || "General");

        if (level === "warn" || level === "error") {
          addIssue(issues, entry, ts, buildNumber);
          recent.push({
            ts,
            level,
            category: entry.category || "General",
            message: entry.message || "",
            metadata: entry.metadata ?? {},
            sessionId: entry.sessionId,
            workspaceId: entry.workspaceId,
            buildNumber,
          });
        }
      }

      if (!recordInWindow && (record.entries?.length ?? 0) === 0 && recordFallbackTs >= cutoffMs) {
        recordInWindow = true;
      }
      if (recordInWindow) {
        uploads += 1;
        dropped += Math.max(0, safeNumber(record.droppedCount) ?? 0);
      }
    }
  }

  recent.sort((a, b) => b.ts - a.ts);
  const limit = Math.max(1, options.limit ?? 20);

  return {
    days: Math.max(0, (Date.now() - cutoffMs) / DAY_MS),
    windowLabel,
    requestedSinceMs: cutoffMs,
    telemetryDir: dir,
    telemetryAvailable,
    evidenceState: !telemetryAvailable || filesRead === 0
      ? "unavailable"
      : parsedRecords === 0
        ? "invalid"
        : uploads === 0
          ? "stale"
          : "available",
    filesRead,
    parsedRecords,
    malformedRecords,
    uploads,
    entries,
    dropped,
    firstTs,
    lastTs,
    levelCounts,
    categoryCounts: Object.fromEntries(Object.entries(categoryCounts).sort((a, b) => b[1] - a[1])),
    issues: [...issues.values()]
      .sort((a, b) => {
        const aMatch = options.match?.test(`${a.category} ${a.message} ${a.signature}`) ? 1 : 0;
        const bMatch = options.match?.test(`${b.category} ${b.message} ${b.signature}`) ? 1 : 0;
        return bMatch - aMatch || b.count - a.count || b.lastTs - a.lastTs;
      })
      .slice(0, limit)
      .map((issue) => ({
        key: issue.key,
        count: issue.count,
        level: issue.level,
        category: issue.category,
        message: issue.message,
        signature: issue.signature,
        firstTs: issue.firstTs,
        lastTs: issue.lastTs,
        sessions: [...issue.sessions].slice(0, 8),
        workspaces: [...issue.workspaces].slice(0, 8),
        builds: [...issue.builds].slice(0, 8),
        examples: issue.examples,
      })),
    recent: recent.slice(0, limit),
  };
}

function printHuman(result: ClientLogReviewResult): void {
  console.log(`Oppi Client Log Review (${result.windowLabel})`);
  console.log(`  telemetry: ${result.telemetryDir}`);
  console.log(
    `  evidence=${result.evidenceState} files=${result.filesRead} parsed=${result.parsedRecords} malformed=${result.malformedRecords} uploads=${result.uploads} entries=${result.entries} dropped=${result.dropped}`,
  );
  console.log(`  window=${formatTs(result.firstTs)} -> ${formatTs(result.lastTs)}`);
  console.log();

  console.log("Levels");
  for (const [level, count] of Object.entries(result.levelCounts).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${level.padEnd(7)} ${String(count).padStart(7)}`);
  }
  console.log();

  console.log("Top warning/error signatures");
  if (result.issues.length === 0) {
    console.log("  (none)");
  } else {
    for (const issue of result.issues) {
      const signature = issue.signature ? ` ${issue.signature}` : "";
      const scope = [
        issue.builds.length ? `builds=${issue.builds.join(",")}` : "",
        issue.sessions.length ? `sessions=${issue.sessions.length}` : "",
        issue.workspaces.length ? `workspaces=${issue.workspaces.length}` : "",
      ]
        .filter(Boolean)
        .join(" ");
      console.log(
        `  ${String(issue.count).padStart(5)} ${issue.level.padEnd(5)} ${issue.category.padEnd(18)} ${truncate(issue.message, 64)}${signature}`,
      );
      console.log(
        `        ${formatTs(issue.firstTs)} -> ${formatTs(issue.lastTs)} ${scope}`.trimEnd(),
      );
    }
  }
  console.log();

  console.log("Recent warning/error entries");
  if (result.recent.length === 0) {
    console.log("  (none)");
  } else {
    for (const entry of result.recent) {
      const metadata = Object.keys(entry.metadata).length
        ? ` ${JSON.stringify(entry.metadata)}`
        : "";
      console.log(
        `  ${formatTs(entry.ts)} ${entry.level.padEnd(5)} ${entry.category.padEnd(18)} ${truncate(entry.message, 72)}${metadata}`,
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
    days: 7,
    json: false,
    help: false,
    limit: 20,
    levels: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith("--match=")) {
      args.match = arg.slice("--match=".length);
      if (!args.match) throw new Error("--match requires a value");
      continue;
    }
    switch (arg) {
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
      case "--level": {
        const raw = requiredArg(argv, ++i, arg);
        args.levels = new Set(
          raw
            .split(",")
            .map((value) => normalizeLevel(value.trim()))
            .filter((value) => value !== "unknown"),
        );
        break;
      }
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
  console.error(`Oppi Client Log Review

  bun server/scripts/client-log-review.ts
  bun server/scripts/client-log-review.ts --days 1 --limit 30
  bun server/scripts/client-log-review.ts --hours 3 --limit 30
  bun server/scripts/client-log-review.ts --since 2026-07-22T20:00:00Z --limit 30
  bun server/scripts/client-log-review.ts --level warn,error --json

Options:
  --data-dir <path>     Oppi data dir (default: ~/.config/oppi)
  --days <n>            Days of uploaded client logs (default: 7)
  --hours <n>           Hours of uploaded client logs; overrides --days
  --since <timestamp>   Exact ISO-8601 window start; overrides --days/--hours
  --limit <n>           Number of top/recent entries (default: 20)
  --match <regex>       Prioritize matching signatures before applying --limit
  --level <levels>      Comma-separated levels: debug,info,warn,error
  --json                Machine-readable JSON
  --help                Show this help
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
  const result = buildClientLogReview({
    dataDir,
    days: args.days,
    hours: args.hours,
    sinceMs,
    limit: args.limit,
    levels: args.levels,
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
