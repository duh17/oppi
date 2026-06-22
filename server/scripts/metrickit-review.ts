#!/usr/bin/env bun

/**
 * Oppi MetricKit review — summarizes uploaded MXMetric/MXDiagnostic payloads
 * and extracts actionable app-frame candidates from crash/hang/CPU diagnostics.
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const DAY_MS = 24 * 60 * 60 * 1_000;
const METRICKIT_PREFIX = "metrickit-";
const JSONL_SUFFIX = ".jsonl";

const DIAGNOSTIC_FIELDS = [
  { field: "crashDiagnostics", summaryKey: "crashDiagnosticCount", label: "crash" },
  { field: "hangDiagnostics", summaryKey: "hangDiagnosticCount", label: "hang" },
  {
    field: "cpuExceptionDiagnostics",
    summaryKey: "cpuExceptionDiagnosticCount",
    label: "cpu_exception",
  },
  {
    field: "diskWriteExceptionDiagnostics",
    summaryKey: "diskWriteExceptionDiagnosticCount",
    label: "disk_write_exception",
  },
  { field: "appLaunchDiagnostics", summaryKey: "appLaunchDiagnosticCount", label: "app_launch" },
] as const;

interface MetricKitPayload {
  kind?: "metric" | "diagnostic";
  windowStartMs?: number;
  windowEndMs?: number;
  summary?: Record<string, string>;
  raw?: unknown;
}

interface MetricKitRecord {
  receivedAt?: number;
  generatedAt?: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  clientKind?: string;
  payloadCount?: number;
  payloads?: MetricKitPayload[];
}

interface StackFrame {
  binaryName?: string;
  binaryUUID?: string;
  address?: number;
  offsetIntoBinaryTextSegment?: number;
  sampleCount?: number;
  depth?: number;
  isLeaf?: boolean;
  symbolicated?: string;
  symbolicationIssue?: string;
  symbolicationTargetUUIDs?: string[];
}

interface SymbolicationTarget {
  inputPath: string;
  binaryPath: string;
  uuids: string[];
}

interface DiagnosticSummary {
  type: string;
  windowStartMs: number;
  windowEndMs: number;
  receivedAt: number | null;
  generatedAt: number | null;
  appVersion: string;
  buildNumber: string;
  osVersion: string;
  deviceModel: string;
  clientKind: string;
  count: number;
  sessionId?: string;
  workspaceId?: string;
  streamState?: string;
  appFrames: StackFrame[];
  rootFrames: StackFrame[];
}

export interface MetricKitReviewResult {
  days: number;
  telemetryDir: string;
  filesRead: number;
  records: number;
  payloads: number;
  diagnostics: number;
  countsByType: Record<string, number>;
  countsByBuild: Record<string, Record<string, number>>;
  recentDiagnostics: DiagnosticSummary[];
  symbolicationTarget?: SymbolicationTarget;
}

interface ParsedArgs {
  dataDir?: string;
  days: number;
  json: boolean;
  help: boolean;
  limit: number;
  symbolicatePath?: string;
}

function telemetryDir(dataDir: string): string {
  return join(dataDir, "diagnostics", "telemetry");
}

function safeNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : null;
}

function formatTs(ts: number | null | undefined): string {
  if (ts == null || !Number.isFinite(ts)) return "?";
  return new Date(ts).toISOString().replace("T", " ").replace(".000Z", "Z");
}

function truncate(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, Math.max(1, max - 1))}…` : value;
}

function inc(map: Record<string, number>, key: string, by = 1): void {
  map[key] = (map[key] ?? 0) + by;
}

function incNested(
  map: Record<string, Record<string, number>>,
  outer: string,
  inner: string,
  by = 1,
): void {
  if (!map[outer]) map[outer] = {};
  inc(map[outer], inner, by);
}

function listFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((file) => file.startsWith(METRICKIT_PREFIX) && file.endsWith(JSONL_SUFFIX))
    .sort();
}

function parseJsonLine(line: string): MetricKitRecord | null {
  try {
    const parsed = JSON.parse(line) as MetricKitRecord;
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

function parseRawPayload(raw: unknown): Record<string, unknown> {
  if (!raw) return {};
  if (typeof raw === "string") {
    try {
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch {
      return {};
    }
  }
  if (typeof raw === "object" && !Array.isArray(raw)) {
    const object = raw as Record<string, unknown>;
    const payload = object.payload;
    if (typeof payload === "string") {
      try {
        const parsed = JSON.parse(payload);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : object;
      } catch {
        return object;
      }
    }
    return object;
  }
  return {};
}

function diagnosticCount(payload: MetricKitPayload, summaryKey: string, rawField: string): number {
  const summaryValue = Number(payload.summary?.[summaryKey] ?? 0);
  if (Number.isFinite(summaryValue) && summaryValue > 0) return Math.trunc(summaryValue);
  const raw = parseRawPayload(payload.raw);
  const value = raw[rawField];
  return Array.isArray(value) ? value.length : 0;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function numberField(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function frameFromRecord(
  record: Record<string, unknown>,
  depth: number,
  isLeaf: boolean,
): StackFrame {
  return {
    binaryName: stringField(record, "binaryName"),
    binaryUUID: stringField(record, "binaryUUID"),
    address: numberField(record, "address"),
    offsetIntoBinaryTextSegment: numberField(record, "offsetIntoBinaryTextSegment"),
    sampleCount: numberField(record, "sampleCount"),
    depth,
    isLeaf,
  };
}

function collectFrames(value: unknown, frames: StackFrame[] = [], depth = 0): StackFrame[] {
  const record = asRecord(value);
  if (!record) return frames;

  const children = ["callStackRootFrames", "subFrames"].flatMap((childKey) => {
    const childValue = record[childKey];
    return Array.isArray(childValue) ? childValue : [];
  });

  if (typeof record.binaryName === "string") {
    frames.push(frameFromRecord(record, depth, children.length === 0));
  }

  for (const child of children) collectFrames(child, frames, depth + 1);

  return frames;
}

function framesFromDiagnostic(value: unknown): StackFrame[] {
  const diagnostic = asRecord(value);
  if (!diagnostic) return [];
  const tree = asRecord(diagnostic.callStackTree);
  const callStacks = Array.isArray(tree?.callStacks) ? tree.callStacks : [];
  const frames: StackFrame[] = [];
  for (const callStack of callStacks) collectFrames(callStack, frames);
  return frames;
}

function isAppFrame(frame: StackFrame): boolean {
  const binary = frame.binaryName ?? "";
  return binary === "Oppi" || binary === "OppiMac" || binary.startsWith("Oppi");
}

function dedupeFrames(frames: StackFrame[], limit: number): StackFrame[] {
  const byKey = new Map<string, StackFrame>();
  for (const frame of frames) {
    const key = [
      frame.binaryName ?? "?",
      frame.binaryUUID ?? "?",
      String(frame.offsetIntoBinaryTextSegment ?? frame.address ?? "?"),
    ].join("|");
    const existing = byKey.get(key);
    if (!existing) {
      byKey.set(key, { ...frame });
      continue;
    }
    existing.sampleCount = (existing.sampleCount ?? 0) + (frame.sampleCount ?? 0);
    existing.depth = Math.max(existing.depth ?? 0, frame.depth ?? 0);
    existing.isLeaf = existing.isLeaf || frame.isLeaf;
  }
  return [...byKey.values()]
    .sort(
      (a, b) =>
        (b.sampleCount ?? 0) - (a.sampleCount ?? 0) ||
        (b.depth ?? 0) - (a.depth ?? 0) ||
        Number(b.isLeaf === true) - Number(a.isLeaf === true),
    )
    .slice(0, limit);
}

function hex(value: number): string {
  return `0x${Math.trunc(value).toString(16)}`;
}

function normalizeUUID(value: string): string {
  return value.trim().toUpperCase();
}

function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function firstExistingPath(paths: string[]): string | undefined {
  return paths.find((path) => existsSync(path));
}

function resolveSymbolicationBinaryPath(inputPath: string): string {
  const path = resolve(inputPath);
  if (!isDirectory(path)) return path;

  const archiveCandidates = [
    join(path, "dSYMs", "Oppi.app.dSYM", "Contents", "Resources", "DWARF", "Oppi"),
    join(path, "dSYMs", "OppiMac.app.dSYM", "Contents", "Resources", "DWARF", "OppiMac"),
    join(path, "Products", "Applications", "Oppi.app", "Oppi"),
    join(path, "Products", "Applications", "OppiMac.app", "Contents", "MacOS", "OppiMac"),
  ];
  const archiveMatch = firstExistingPath(archiveCandidates);
  if (archiveMatch) return archiveMatch;

  const dsymCandidates = [
    join(path, "Contents", "Resources", "DWARF", "Oppi"),
    join(path, "Contents", "Resources", "DWARF", "OppiMac"),
  ];
  const dsymMatch = firstExistingPath(dsymCandidates);
  if (dsymMatch) return dsymMatch;

  const appCandidates = [join(path, "Oppi"), join(path, "Contents", "MacOS", "OppiMac")];
  return firstExistingPath(appCandidates) ?? path;
}

function readBinaryUUIDs(binaryPath: string): string[] {
  if (!existsSync(binaryPath)) return [];
  const result = spawnSync("xcrun", ["dwarfdump", "--uuid", binaryPath], {
    encoding: "utf8",
    timeout: 5_000,
  });
  if (result.status !== 0) return [];
  const uuids = new Set<string>();
  for (const line of result.stdout.split("\n")) {
    const match = line.match(/UUID:\s*([0-9a-fA-F-]+)/);
    if (match?.[1]) uuids.add(normalizeUUID(match[1]));
  }
  return [...uuids].sort();
}

function resolveSymbolicationTarget(
  inputPath: string | undefined,
): SymbolicationTarget | undefined {
  if (!inputPath) return undefined;
  const binaryPath = resolveSymbolicationBinaryPath(inputPath);
  return {
    inputPath: resolve(inputPath),
    binaryPath,
    uuids: readBinaryUUIDs(binaryPath),
  };
}

function symbolicateFrame(
  frame: StackFrame,
  target: SymbolicationTarget,
): Pick<StackFrame, "symbolicated" | "symbolicationIssue" | "symbolicationTargetUUIDs"> {
  if (!existsSync(target.binaryPath)) return { symbolicationIssue: "symbol_file_missing" };
  const frameUUID = frame.binaryUUID ? normalizeUUID(frame.binaryUUID) : undefined;
  if (frameUUID && target.uuids.length > 0 && !target.uuids.includes(frameUUID)) {
    return {
      symbolicationIssue: "uuid_mismatch",
      symbolicationTargetUUIDs: target.uuids,
    };
  }
  if (frame.address == null || frame.offsetIntoBinaryTextSegment == null) {
    return { symbolicationIssue: "missing_address" };
  }
  const loadAddress = frame.address - frame.offsetIntoBinaryTextSegment;
  if (!Number.isFinite(loadAddress) || loadAddress <= 0) {
    return { symbolicationIssue: "invalid_load_address" };
  }

  const result = spawnSync(
    "xcrun",
    ["atos", "-arch", "arm64", "-o", target.binaryPath, "-l", hex(loadAddress), hex(frame.address)],
    { encoding: "utf8", timeout: 5_000 },
  );
  if (result.status !== 0) return { symbolicationIssue: "atos_failed" };
  const out = result.stdout.trim();
  if (!out || out.includes(hex(frame.address))) return { symbolicationIssue: "symbol_not_found" };
  return { symbolicated: out };
}

function symbolicateFrames(
  frames: StackFrame[],
  target: SymbolicationTarget | undefined,
): StackFrame[] {
  if (!target) return frames;
  return frames.map((frame) => ({
    ...frame,
    ...symbolicateFrame(frame, target),
  }));
}

function diagnosticsFromPayload(
  record: MetricKitRecord,
  payload: MetricKitPayload,
  symbolicationTarget: SymbolicationTarget | undefined,
): DiagnosticSummary[] {
  const raw = parseRawPayload(payload.raw);
  const summaries: DiagnosticSummary[] = [];
  const summary = payload.summary ?? {};
  const windowStartMs = safeNumber(payload.windowStartMs) ?? safeNumber(record.generatedAt) ?? 0;
  const windowEndMs = safeNumber(payload.windowEndMs) ?? windowStartMs;

  for (const diagnosticField of DIAGNOSTIC_FIELDS) {
    const count = diagnosticCount(payload, diagnosticField.summaryKey, diagnosticField.field);
    if (count <= 0) continue;

    const rawDiagnostics = raw[diagnosticField.field];
    const diagnostics =
      Array.isArray(rawDiagnostics) && rawDiagnostics.length > 0 ? rawDiagnostics : [null];
    const allFrames = diagnostics.flatMap(framesFromDiagnostic);
    const appFrames = symbolicateFrames(
      dedupeFrames(allFrames.filter(isAppFrame), 8),
      symbolicationTarget,
    );
    const rootFrames = dedupeFrames(allFrames.slice(0, 12), 5);

    summaries.push({
      type: diagnosticField.label,
      windowStartMs,
      windowEndMs,
      receivedAt: safeNumber(record.receivedAt),
      generatedAt: safeNumber(record.generatedAt),
      appVersion: record.appVersion ?? "unknown",
      buildNumber: record.buildNumber ?? "unknown",
      osVersion: record.osVersion ?? "unknown",
      deviceModel: record.deviceModel ?? "unknown",
      clientKind: record.clientKind ?? "unknown",
      count,
      sessionId: summary.lastSessionId,
      workspaceId: summary.lastWorkspaceId,
      streamState: summary.lastStreamState,
      appFrames,
      rootFrames,
    });
  }

  return summaries;
}

export function buildMetricKitReview(options: {
  dataDir: string;
  days: number;
  limit?: number;
  symbolicatePath?: string;
}): MetricKitReviewResult {
  const dir = telemetryDir(options.dataDir);
  const symbolicationTarget = resolveSymbolicationTarget(options.symbolicatePath);
  const cutoffMs = Date.now() - options.days * DAY_MS;
  const countsByType: Record<string, number> = {};
  const countsByBuild: Record<string, Record<string, number>> = {};
  const recentDiagnostics: DiagnosticSummary[] = [];

  let filesRead = 0;
  let records = 0;
  let payloads = 0;
  let diagnostics = 0;

  for (const file of listFiles(dir)) {
    const text = readFileSync(join(dir, file), "utf8");
    filesRead += 1;
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      const record = parseJsonLine(line);
      if (!record) continue;
      records += 1;
      for (const payload of record.payloads ?? []) {
        const ts = safeNumber(payload.windowEndMs) ?? safeNumber(record.generatedAt) ?? 0;
        if (ts < cutoffMs) continue;
        payloads += 1;
        const payloadDiagnostics = diagnosticsFromPayload(record, payload, symbolicationTarget);
        for (const diagnostic of payloadDiagnostics) {
          diagnostics += diagnostic.count;
          inc(countsByType, diagnostic.type, diagnostic.count);
          incNested(countsByBuild, diagnostic.buildNumber, diagnostic.type, diagnostic.count);
          recentDiagnostics.push(diagnostic);
        }
      }
    }
  }

  const limit = Math.max(1, options.limit ?? 20);
  recentDiagnostics.sort((a, b) => b.windowEndMs - a.windowEndMs);

  return {
    days: options.days,
    telemetryDir: dir,
    filesRead,
    records,
    payloads,
    diagnostics,
    countsByType,
    countsByBuild,
    recentDiagnostics: recentDiagnostics.slice(0, limit),
    symbolicationTarget,
  };
}

function frameLabel(frame: StackFrame): string {
  const binary = frame.binaryName ?? "?";
  const offset =
    frame.offsetIntoBinaryTextSegment == null ? "?" : `+${hex(frame.offsetIntoBinaryTextSegment)}`;
  const samples = frame.sampleCount == null ? "" : ` samples=${frame.sampleCount}`;
  const depth = frame.depth == null ? "" : ` depth=${frame.depth}`;
  const leaf = frame.isLeaf ? " leaf" : "";
  const uuid = frame.binaryUUID ? ` uuid=${frame.binaryUUID}` : "";
  const targetUUIDs = frame.symbolicationTargetUUIDs?.length
    ? ` targetUUIDs=${frame.symbolicationTargetUUIDs.join(",")}`
    : "";
  const issue = frame.symbolicationIssue
    ? ` symbolication=${frame.symbolicationIssue}${targetUUIDs}`
    : "";
  const symbol = frame.symbolicated ? ` ${truncate(frame.symbolicated, 100)}` : "";
  return `${binary} ${offset}${samples}${depth}${leaf}${uuid}${issue}${symbol}`;
}

function printHuman(result: MetricKitReviewResult): void {
  console.log(`Oppi MetricKit Review (last ${result.days}d)`);
  console.log(`  telemetry: ${result.telemetryDir}`);
  console.log(
    `  files=${result.filesRead} records=${result.records} payloads=${result.payloads} diagnostics=${result.diagnostics}`,
  );
  if (result.symbolicationTarget) {
    const uuids =
      result.symbolicationTarget.uuids.length > 0
        ? result.symbolicationTarget.uuids.join(", ")
        : "unknown";
    console.log(`  symbolicate: ${result.symbolicationTarget.binaryPath}`);
    console.log(`  symbol UUIDs: ${uuids}`);
  }
  console.log();

  console.log("Diagnostic counts");
  if (Object.keys(result.countsByType).length === 0) {
    console.log("  (none)");
  } else {
    for (const [type, count] of Object.entries(result.countsByType).sort((a, b) => b[1] - a[1])) {
      console.log(`  ${type.padEnd(24)} ${String(count).padStart(5)}`);
    }
  }
  console.log();

  console.log("Counts by build");
  if (Object.keys(result.countsByBuild).length === 0) {
    console.log("  (none)");
  } else {
    for (const [build, counts] of Object.entries(result.countsByBuild).sort((a, b) =>
      a[0].localeCompare(b[0]),
    )) {
      const pieces = Object.entries(counts)
        .sort((a, b) => b[1] - a[1])
        .map(([type, count]) => `${type}:${count}`)
        .join(" ");
      console.log(`  ${build.padEnd(8)} ${pieces}`);
    }
  }
  console.log();

  console.log("Recent diagnostics");
  if (result.recentDiagnostics.length === 0) {
    console.log("  (none)");
    return;
  }

  for (const diagnostic of result.recentDiagnostics) {
    const context = [
      diagnostic.sessionId ? `session=${diagnostic.sessionId}` : "",
      diagnostic.workspaceId ? `workspace=${diagnostic.workspaceId}` : "",
      diagnostic.streamState ? `stream=${diagnostic.streamState}` : "",
    ]
      .filter(Boolean)
      .join(" ");
    console.log(
      `  ${formatTs(diagnostic.windowEndMs)} ${diagnostic.type} count=${diagnostic.count} build=${diagnostic.buildNumber} ${context}`.trimEnd(),
    );
    if (diagnostic.appFrames.length > 0) {
      console.log("    app frames:");
      for (const frame of diagnostic.appFrames.slice(0, 5)) {
        console.log(`      ${frameLabel(frame)}`);
      }
    } else if (diagnostic.rootFrames.length > 0) {
      console.log("    root frames:");
      for (const frame of diagnostic.rootFrames.slice(0, 3)) {
        console.log(`      ${frameLabel(frame)}`);
      }
    } else {
      console.log("    frames: unavailable in uploaded payload");
    }
  }
}

function parseArgs(argv: string[]): ParsedArgs {
  const args: ParsedArgs = {
    days: 7,
    json: false,
    help: false,
    limit: 20,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--data-dir":
        args.dataDir = argv[++i];
        break;
      case "--days":
        args.days = Math.max(1, Number.parseInt(argv[++i] ?? "7", 10) || 7);
        break;
      case "--limit":
        args.limit = Math.max(1, Number.parseInt(argv[++i] ?? "20", 10) || 20);
        break;
      case "--symbolicate":
        args.symbolicatePath = argv[++i];
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

function printHelp(): void {
  console.error(`Oppi MetricKit Review

  bun server/scripts/metrickit-review.ts
  bun server/scripts/metrickit-review.ts --days 14 --limit 50
  bun server/scripts/metrickit-review.ts --symbolicate /path/to/Oppi.xcarchive

Options:
  --data-dir <path>       Oppi data dir (default: ~/.config/oppi)
  --days <n>              Days of MetricKit payloads (default: 7)
  --limit <n>             Number of recent diagnostics (default: 20)
  --symbolicate <path>    Best-effort atos symbolication for app frames; accepts .xcarchive, .dSYM, .app, or binary paths
  --json                  Machine-readable JSON
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
  const result = buildMetricKitReview({
    dataDir,
    days: args.days,
    limit: args.limit,
    symbolicatePath: args.symbolicatePath,
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
