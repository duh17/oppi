#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import { stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";

import {
  resolveRegisteredResourceUsageSources,
  type ResourceUsageBackfillCatalog,
  type ResourceUsageBackfillSource,
} from "../src/resource-usage-backfill.js";
import type { Session } from "../src/types.js";
import { ResourceUsageService } from "../src/resource-usage-service.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";

const [sessionStateDbArg, outputDirArg] = process.argv.slice(2);
if (!sessionStateDbArg || !outputDirArg) {
  throw new Error(
    "usage: resource-usage-backfill-benchmark.ts <session-state-db> <fresh-output-dir>",
  );
}
const sessionStateDb = resolve(sessionStateDbArg);
const outputDir = resolve(outputDirArg);
const dbPath = join(outputDir, "resource-usage-benchmark.db");
const registered = registeredSources(sessionStateDb);
const readable = await Promise.all(
  registered.map(async (source) => {
    try {
      return { source, size: (await stat(source.path)).size };
    } catch {
      return undefined;
    }
  }),
);
const readableSources = readable.flatMap((item) => (item ? [item.source] : []));
const sizes = readable.flatMap((item) => (item ? [item.size] : []));
const missingSources = registered.length - readableSources.length;
const sources = registered;
const now = Date.now();
const store = new ResourceUsageStore(outputDir, { dbPath, now: () => now });
const service = new ResourceUsageService(store, { now: () => now });
const catalog: ResourceUsageBackfillCatalog = {
  skills: new Map(),
  commands: new Map(),
  tools: new Map(),
  builtInTools: new Set([
    "bash",
    "edit",
    "find",
    "grep",
    "ls",
    "read",
    "write",
    "ask",
    "todo",
    "web_fetch",
    "web_search",
    "web_search_read",
    "research_web_fetch",
    "research_web_search",
    "research_web_search_read",
    "research_youtube_transcribe",
    "hacker_news",
    "x_read",
    "goal_update",
    "imagen",
    "oppi",
  ]),
};

service.configureBackfillSnapshotProvider(async () => ({ sources, catalog }));
const started = performance.now();
const trigger = service.triggerBackfill();
if (!trigger.accepted) throw new Error("fresh benchmark backfill was not accepted");
await service.waitForBackfill();
const durationMs = performance.now() - started;
const backfill = service.getBackfillStatus();
const endpointLatencyMs: Record<string, number> = {};
for (const range of [7, 30, 90] as const) {
  const queryStarted = performance.now();
  await service.getUsage({ kind: "tools" }, range, "UTC");
  endpointLatencyMs[String(range)] = performance.now() - queryStarted;
}
const dbSizeBytes = (await stat(dbPath)).size;
const report = {
  sourceCount: sources.length,
  readableSources: readableSources.length,
  missingSources,
  sourceBytes: sizes.reduce((sum, size) => sum + size, 0),
  parsedBytes: backfill.processedBytes,
  lines: backfill.processedLines,
  historicalEvents: backfill.historicalEvents,
  corruptLines: backfill.corruptLines,
  oversizedLines: backfill.oversizedLines,
  backfillStatus: backfill,
  durationMs,
  dbSizeBytes,
  endpointLatencyMs,
  // Bun reports Darwin maxRSS in bytes; Linux follows Node's KiB contract.
  processMaxRssBytes: process.resourceUsage().maxRSS * (process.platform === "darwin" ? 1 : 1024),
};
console.log(JSON.stringify(report, null, 2));
await service.close();

export function registeredSources(path: string): ResourceUsageBackfillSource[] {
  const db = new Database(path, { readonly: true });
  try {
    const rows = db
      .query(
        `SELECT id, created_at, workspace_id, runtime, pi_session_file, pi_session_files_json
         FROM session_state_sessions
         WHERE runtime IN ('oppi', 'pi-tui')`,
      )
      .all() as Array<{
      id: string;
      created_at: number;
      workspace_id: string | null;
      runtime: "oppi" | "pi-tui";
      pi_session_file: string | null;
      pi_session_files_json: string | null;
    }>;
    const sessions = rows.map((row) => ({
      id: row.id,
      createdAt: row.created_at,
      ...(row.workspace_id ? { workspaceId: row.workspace_id } : {}),
      runtime: row.runtime,
      ...(row.pi_session_file ? { piSessionFile: row.pi_session_file } : {}),
      piSessionFiles: sessionFiles(row),
    })) as Pick<
      Session,
      "id" | "createdAt" | "workspaceId" | "runtime" | "piSessionFile" | "piSessionFiles"
    >[];
    return resolveRegisteredResourceUsageSources(sessions);
  } finally {
    db.close();
  }
}

function sessionFiles(row: {
  pi_session_file: string | null;
  pi_session_files_json: string | null;
}): string[] {
  const files = new Set<string>();
  if (row.pi_session_file) files.add(row.pi_session_file);
  if (row.pi_session_files_json) {
    try {
      const values = JSON.parse(row.pi_session_files_json) as unknown;
      if (Array.isArray(values)) {
        for (const value of values) {
          if (typeof value === "string" && value.length > 0) files.add(value);
        }
      }
    } catch {
      // Ignore malformed catalog metadata; the benchmark measures readable registered traces.
    }
  }
  return [...files];
}
