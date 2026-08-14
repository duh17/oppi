#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import { stat } from "node:fs/promises";
import { join, resolve } from "node:path";

import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { performance } from "node:perf_hooks";

import {
  resolveRegisteredResourceUsageSources,
  type ResourceUsageBackfillSource,
} from "../src/resource-usage-backfill.js";
import type { Session } from "../src/types.js";
import { ResourceUsageService } from "../src/resource-usage-service.js";
import { DEFAULT_OPPI_EXTENSION_SETTINGS } from "../src/oppi-extension-settings.js";
import { ServerResourceService } from "../src/server-resource-service.js";
import { ResourceUsageStore } from "../src/storage/resource-usage-store.js";

const QUERY_SAMPLES = 7;

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
const serverResources = new ServerResourceService({
  dataDir: outputDir,
  agentDir: getAgentDir(),
  oppiSettings: {
    get: () => DEFAULT_OPPI_EXTENSION_SETTINGS,
    getLoadError: () => undefined,
  },
});
const catalog = await serverResources.resourceUsageCatalog();
const skillCatalogEntries = [...catalog.skillPrimaryFiles].map(([primaryFile, skill]) => ({
  ...skill,
  primaryFile,
}));

service.configureBackfillSnapshotProvider(async () => ({ sources, catalog }));
const started = performance.now();
const trigger = service.triggerBackfill();
if (!trigger.accepted) throw new Error("fresh benchmark backfill was not accepted");
await service.waitForBackfill();
const durationMs = performance.now() - started;
const backfill = service.getBackfillStatus();
const endpointLatencyMs: Record<string, QueryLatencySummary> = {};
for (const range of [7, 30, 90] as const) {
  endpointLatencyMs[`tools-${range}`] = await sampleQueryLatency(() =>
    service.getUsage({ kind: "tools" }, range, "UTC"),
  );
}
const skillCounts: Record<string, number | null> = {};
for (const name of ["writing", "testing", "herdr-pi-launch"]) {
  const skill = skillCatalogEntries.find((entry) => entry.name === name);
  if (!skill) {
    skillCounts[name] = null;
    continue;
  }
  let recordedActions = 0;
  endpointLatencyMs[`skill-${name}-90`] = await sampleQueryLatency(async () => {
    const usage = await service.getUsage({ kind: "skill", id: skill.id }, 90, "UTC");
    recordedActions = usage.recordedActions;
  });
  skillCounts[name] = recordedActions;
}
const dbSizeBytes = (await stat(dbPath)).size;
const walSizeBytes = await fileSizeOrZero(`${dbPath}-wal`);
const shmSizeBytes = await fileSizeOrZero(`${dbPath}-shm`);
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
  skillCatalogSource: "ServerResourceService.resourceUsageCatalog",
  skillCatalogCount: skillCatalogEntries.length,
  querySamples: QUERY_SAMPLES,
  skillCounts,
  durationMs,
  dbSizeBytes,
  walSizeBytes,
  shmSizeBytes,
  storageSizeBytes: dbSizeBytes + walSizeBytes + shmSizeBytes,
  sandboxMappingCoverage: {
    coveredSources: 0,
    // This isolated benchmark reads session-state only. Production bindings live
    // in ResourceUsageStore and are validated separately by focused store/backfill tests.
    caveat: "not exercised: benchmark does not import production sandbox binding evidence",
  },
  endpointLatencyMs,
  // Bun reports Darwin maxRSS in bytes; Linux follows Node's KiB contract.
  processMaxRssBytes: process.resourceUsage().maxRSS * (process.platform === "darwin" ? 1 : 1024),
};
console.log(JSON.stringify(report, null, 2));
await service.close();

async function fileSizeOrZero(path: string): Promise<number> {
  try {
    return (await stat(path)).size;
  } catch {
    return 0;
  }
}

interface QueryLatencySummary {
  samples: number;
  min: number;
  median: number;
  p95: number;
  max: number;
}

async function sampleQueryLatency(query: () => Promise<unknown>): Promise<QueryLatencySummary> {
  const values: number[] = [];
  for (let sample = 0; sample < QUERY_SAMPLES; sample += 1) {
    const started = performance.now();
    await query();
    values.push(performance.now() - started);
  }
  values.sort((left, right) => left - right);
  return {
    samples: values.length,
    min: values[0] ?? 0,
    median: percentile(values, 0.5),
    p95: percentile(values, 0.95),
    max: values.at(-1) ?? 0,
  };
}

function percentile(sorted: readonly number[], quantile: number): number {
  if (sorted.length === 0) return 0;
  const index = Math.min(sorted.length - 1, Math.ceil(sorted.length * quantile) - 1);
  return sorted[index] ?? 0;
}

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
