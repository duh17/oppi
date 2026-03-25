#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";

const FILE_SUFFIX = ".jsonl";
const CHAT_PREFIX = "chat-metrics-";
const METRICKIT_PREFIX = "metrickit-";
const SERVER_METRICS_PREFIX = "server-metrics-";
const SERVER_OPS_PREFIX = "server-ops-metrics-";

function getArg(name) {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx < 0 || idx + 1 >= process.argv.length) {
    return undefined;
  }
  return process.argv[idx + 1];
}

function hasFlag(name) {
  return process.argv.includes(`--${name}`);
}

function toPositiveInt(raw, fallback) {
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return parsed;
}

function asOptionalString(value) {
  return typeof value === "string" ? value : null;
}

function ensureDbSchema(db) {
  db.exec(`
    PRAGMA journal_mode = DELETE;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS ingested_files (
      source_file TEXT PRIMARY KEY,
      file_kind TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      mtime_ms INTEGER NOT NULL,
      line_count INTEGER NOT NULL,
      processed_at_ms INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chat_metric_samples (
      id TEXT PRIMARY KEY,
      source_file TEXT NOT NULL,
      line_number INTEGER NOT NULL,
      sample_index INTEGER NOT NULL,
      ts_ms INTEGER NOT NULL,
      metric TEXT NOT NULL,
      value REAL NOT NULL,
      unit TEXT NOT NULL,
      generated_at_ms INTEGER,
      received_at_ms INTEGER,
      app_version TEXT,
      build_number TEXT,
      os_version TEXT,
      device_model TEXT,
      session_id TEXT,
      workspace_id TEXT,
      tags_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_chat_metric_metric_ts
      ON chat_metric_samples(metric, ts_ms);
    CREATE INDEX IF NOT EXISTS idx_chat_metric_ts
      ON chat_metric_samples(ts_ms);
    CREATE INDEX IF NOT EXISTS idx_chat_metric_build_ts
      ON chat_metric_samples(build_number, ts_ms);

    CREATE TABLE IF NOT EXISTS server_metric_samples (
      id TEXT PRIMARY KEY,
      source_file TEXT NOT NULL,
      line_number INTEGER NOT NULL,
      ts_ms INTEGER NOT NULL,
      cpu_user REAL NOT NULL,
      cpu_system REAL NOT NULL,
      cpu_total REAL NOT NULL,
      mem_heap_used REAL NOT NULL,
      mem_heap_total REAL NOT NULL,
      mem_rss REAL NOT NULL,
      mem_external REAL NOT NULL,
      sessions_busy INTEGER NOT NULL,
      sessions_ready INTEGER NOT NULL,
      sessions_starting INTEGER NOT NULL,
      sessions_total INTEGER NOT NULL,
      ws_connections INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_server_metric_ts
      ON server_metric_samples(ts_ms);

    CREATE TABLE IF NOT EXISTS server_ops_metric_samples (
      id TEXT PRIMARY KEY,
      source_file TEXT NOT NULL,
      line_number INTEGER NOT NULL,
      sample_index INTEGER NOT NULL,
      ts_ms INTEGER NOT NULL,
      metric TEXT NOT NULL,
      value REAL NOT NULL,
      tags_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_server_ops_metric_ts
      ON server_ops_metric_samples(metric, ts_ms);
    CREATE INDEX IF NOT EXISTS idx_server_ops_ts
      ON server_ops_metric_samples(ts_ms);

    CREATE TABLE IF NOT EXISTS metrickit_payloads (
      id TEXT PRIMARY KEY,
      source_file TEXT NOT NULL,
      line_number INTEGER NOT NULL,
      payload_index INTEGER NOT NULL,
      kind TEXT NOT NULL,
      window_start_ms INTEGER NOT NULL,
      window_end_ms INTEGER NOT NULL,
      generated_at_ms INTEGER,
      received_at_ms INTEGER,
      app_version TEXT,
      build_number TEXT,
      os_version TEXT,
      device_model TEXT,
      summary_json TEXT,
      raw_json TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_metrickit_window
      ON metrickit_payloads(window_start_ms, window_end_ms);
  `);
}

function fileKind(name) {
  if (name.startsWith(SERVER_OPS_PREFIX)) return "server-ops-metrics";
  if (name.startsWith(CHAT_PREFIX)) return "chat";
  if (name.startsWith(METRICKIT_PREFIX)) return "metrickit";
  if (name.startsWith(SERVER_METRICS_PREFIX)) return "server-metrics";
  return null;
}

function listTelemetryFiles(telemetryDir) {
  return readdirSync(telemetryDir)
    .filter((name) => {
      if (!name.endsWith(FILE_SUFFIX)) return false;
      return fileKind(name) !== null;
    })
    .sort((a, b) => a.localeCompare(b))
    .map((name) => ({
      name,
      path: join(telemetryDir, name),
      kind: fileKind(name),
    }));
}

function importOnce({ telemetryDir, dbPath, verbose = false }) {
  const startedAt = Date.now();

  if (!existsSync(telemetryDir)) {
    throw new Error(`Telemetry directory not found: ${telemetryDir}`);
  }

  mkdirSync(dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  ensureDbSchema(db);

  const getIngested = db.prepare(
    "SELECT size_bytes, mtime_ms FROM ingested_files WHERE source_file = ?",
  );

  const deleteChatByFile = db.prepare(
    "DELETE FROM chat_metric_samples WHERE source_file = ?",
  );
  const deleteMetricKitByFile = db.prepare(
    "DELETE FROM metrickit_payloads WHERE source_file = ?",
  );

  const upsertIngested = db.prepare(`
    INSERT INTO ingested_files (
      source_file,
      file_kind,
      size_bytes,
      mtime_ms,
      line_count,
      processed_at_ms
    )
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(source_file) DO UPDATE SET
      file_kind = excluded.file_kind,
      size_bytes = excluded.size_bytes,
      mtime_ms = excluded.mtime_ms,
      line_count = excluded.line_count,
      processed_at_ms = excluded.processed_at_ms
  `);

  const insertChat = db.prepare(`
    INSERT OR REPLACE INTO chat_metric_samples (
      id,
      source_file,
      line_number,
      sample_index,
      ts_ms,
      metric,
      value,
      unit,
      generated_at_ms,
      received_at_ms,
      app_version,
      build_number,
      os_version,
      device_model,
      session_id,
      workspace_id,
      tags_json
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  const insertMetricKit = db.prepare(`
    INSERT OR REPLACE INTO metrickit_payloads (
      id,
      source_file,
      line_number,
      payload_index,
      kind,
      window_start_ms,
      window_end_ms,
      generated_at_ms,
      received_at_ms,
      app_version,
      build_number,
      os_version,
      device_model,
      summary_json,
      raw_json
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  const deleteServerMetricsByFile = db.prepare(
    "DELETE FROM server_metric_samples WHERE source_file = ?",
  );

  const deleteServerOpsByFile = db.prepare(
    "DELETE FROM server_ops_metric_samples WHERE source_file = ?",
  );

  const insertServerOps = db.prepare(`
    INSERT OR REPLACE INTO server_ops_metric_samples (
      id,
      source_file,
      line_number,
      sample_index,
      ts_ms,
      metric,
      value,
      tags_json
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  const insertServerMetric = db.prepare(`
    INSERT OR REPLACE INTO server_metric_samples (
      id,
      source_file,
      line_number,
      ts_ms,
      cpu_user,
      cpu_system,
      cpu_total,
      mem_heap_used,
      mem_heap_total,
      mem_rss,
      mem_external,
      sessions_busy,
      sessions_ready,
      sessions_starting,
      sessions_total,
      ws_connections
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  const files = listTelemetryFiles(telemetryDir);

  const summary = {
    filesSeen: files.length,
    filesImported: 0,
    filesSkipped: 0,
    chatSamplesImported: 0,
    metrickitPayloadsImported: 0,
    serverMetricSamplesImported: 0,
    serverOpsSamplesImported: 0,
    parseErrors: 0,
    invalidRecords: 0,
  };

  db.exec("BEGIN");
  try {
    for (const file of files) {
      const stat = statSync(file.path);
      const sizeBytes = stat.size;
      const mtimeMs = Math.trunc(stat.mtimeMs);

      const existing = getIngested.get(file.path);
      if (
        existing
        && Number(existing.size_bytes) === sizeBytes
        && Number(existing.mtime_ms) === mtimeMs
      ) {
        summary.filesSkipped += 1;
        continue;
      }

      if (file.kind === "chat") {
        deleteChatByFile.run(file.path);
      } else if (file.kind === "metrickit") {
        deleteMetricKitByFile.run(file.path);
      } else if (file.kind === "server-metrics") {
        deleteServerMetricsByFile.run(file.path);
      } else if (file.kind === "server-ops-metrics") {
        deleteServerOpsByFile.run(file.path);
      }

      const text = readFileSync(file.path, "utf8");
      const lines = text.split("\n");
      let nonEmptyLineCount = 0;

      for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i];
        if (!line || line.trim().length === 0) continue;
        nonEmptyLineCount += 1;

        let record;
        try {
          record = JSON.parse(line);
        } catch {
          summary.parseErrors += 1;
          continue;
        }

        const lineNumber = i + 1;

        if (file.kind === "chat") {
          const samples = Array.isArray(record.samples) ? record.samples : [];
          const generatedAtMs = Number.isFinite(record.generatedAt)
            ? Math.trunc(record.generatedAt)
            : null;
          const receivedAtMs = Number.isFinite(record.receivedAt)
            ? Math.trunc(record.receivedAt)
            : null;

          for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex += 1) {
            const sample = samples[sampleIndex];
            if (!sample || typeof sample !== "object") {
              summary.invalidRecords += 1;
              continue;
            }

            const tsMs = Number.isFinite(sample.ts) ? Math.trunc(sample.ts) : null;
            const value = Number.isFinite(sample.value) ? Number(sample.value) : null;
            const metric = asOptionalString(sample.metric);
            const unit = asOptionalString(sample.unit);

            if (tsMs === null || value === null || !metric || !unit) {
              summary.invalidRecords += 1;
              continue;
            }

            const id = `${file.path}#${lineNumber}:${sampleIndex}`;
            insertChat.run(
              id,
              file.path,
              lineNumber,
              sampleIndex,
              tsMs,
              metric,
              value,
              unit,
              generatedAtMs,
              receivedAtMs,
              asOptionalString(record.appVersion),
              asOptionalString(record.buildNumber),
              asOptionalString(record.osVersion),
              asOptionalString(record.deviceModel),
              asOptionalString(sample.sessionId),
              asOptionalString(sample.workspaceId),
              sample.tags && typeof sample.tags === "object" ? JSON.stringify(sample.tags) : null,
            );
            summary.chatSamplesImported += 1;
          }
        } else if (file.kind === "server-metrics") {
          // Server metrics: one record per line with ts, cpu, memory, sessions
          const tsMs = Number.isFinite(record.ts) ? Math.trunc(record.ts) : null;
          if (tsMs === null || !record.cpu || !record.memory || !record.sessions) {
            summary.invalidRecords += 1;
            continue;
          }

          const id = `${file.path}#${lineNumber}`;
          insertServerMetric.run(
            id,
            file.path,
            lineNumber,
            tsMs,
            Number(record.cpu.user) || 0,
            Number(record.cpu.system) || 0,
            Number(record.cpu.total) || 0,
            Number(record.memory.heapUsed) || 0,
            Number(record.memory.heapTotal) || 0,
            Number(record.memory.rss) || 0,
            Number(record.memory.external) || 0,
            Number(record.sessions.busy) || 0,
            Number(record.sessions.ready) || 0,
            Number(record.sessions.starting) || 0,
            Number(record.sessions.total) || 0,
            Number(record.wsConnections) || 0,
          );
          summary.serverMetricSamplesImported += 1;
        } else if (file.kind === "server-ops-metrics") {
          // Server ops metrics: batched samples with flushedAt
          const samples = Array.isArray(record.samples) ? record.samples : [];
          for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex += 1) {
            const sample = samples[sampleIndex];
            if (!sample || typeof sample !== "object") {
              summary.invalidRecords += 1;
              continue;
            }

            const tsMs = Number.isFinite(sample.ts) ? Math.trunc(sample.ts) : null;
            const value = Number.isFinite(sample.value) ? Number(sample.value) : null;
            const metric = asOptionalString(sample.metric);

            if (tsMs === null || value === null || !metric) {
              summary.invalidRecords += 1;
              continue;
            }

            const id = `${file.path}#${lineNumber}:${sampleIndex}`;
            insertServerOps.run(
              id,
              file.path,
              lineNumber,
              sampleIndex,
              tsMs,
              metric,
              value,
              sample.tags && typeof sample.tags === "object" ? JSON.stringify(sample.tags) : null,
            );
            summary.serverOpsSamplesImported += 1;
          }
        } else {
          const payloads = Array.isArray(record.payloads) ? record.payloads : [];
          const generatedAtMs = Number.isFinite(record.generatedAt)
            ? Math.trunc(record.generatedAt)
            : null;
          const receivedAtMs = Number.isFinite(record.receivedAt)
            ? Math.trunc(record.receivedAt)
            : null;

          for (let payloadIndex = 0; payloadIndex < payloads.length; payloadIndex += 1) {
            const payload = payloads[payloadIndex];
            if (!payload || typeof payload !== "object") {
              summary.invalidRecords += 1;
              continue;
            }

            const kind = asOptionalString(payload.kind) ?? "metric";
            const windowStartMs = Number.isFinite(payload.windowStartMs)
              ? Math.trunc(payload.windowStartMs)
              : null;
            const windowEndMs = Number.isFinite(payload.windowEndMs)
              ? Math.trunc(payload.windowEndMs)
              : null;

            if (windowStartMs === null || windowEndMs === null) {
              summary.invalidRecords += 1;
              continue;
            }

            const id = `${file.path}#${lineNumber}:${payloadIndex}`;
            insertMetricKit.run(
              id,
              file.path,
              lineNumber,
              payloadIndex,
              kind,
              windowStartMs,
              windowEndMs,
              generatedAtMs,
              receivedAtMs,
              asOptionalString(record.appVersion),
              asOptionalString(record.buildNumber),
              asOptionalString(record.osVersion),
              asOptionalString(record.deviceModel),
              payload.summary && typeof payload.summary === "object"
                ? JSON.stringify(payload.summary)
                : null,
              payload.raw === undefined ? null : JSON.stringify(payload.raw),
            );
            summary.metrickitPayloadsImported += 1;
          }
        }
      }

      upsertIngested.run(
        file.path,
        file.kind,
        sizeBytes,
        mtimeMs,
        nonEmptyLineCount,
        Date.now(),
      );

      summary.filesImported += 1;
      if (verbose) {
        console.log(`[import] ${file.kind}: ${file.name}`);
      }
    }

    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  } finally {
    db.close();
  }

  summary.durationMs = Date.now() - startedAt;
  return summary;
}

function printUsage() {
  console.log(`
Usage:
  node scripts/manual/telemetry-import-sqlite.mjs [options]

Options:
  --data-dir <path>        Oppi data dir (default: $OPPI_DATA_DIR or ~/.config/oppi)
  --telemetry-dir <path>   Telemetry JSONL dir (default: <data-dir>/diagnostics/telemetry)
  --db <path>              SQLite DB path (default: <telemetry-dir>/telemetry.db)
  --watch                  Re-import on an interval
  --interval-ms <ms>       Watch poll interval (default: 5000)
  --verbose                Log each imported file
  --help                   Show this help
`);
}

async function main() {
  if (hasFlag("help") || hasFlag("h")) {
    printUsage();
    return;
  }

  const dataDir = resolve(
    getArg("data-dir")
      ?? process.env.OPPI_DATA_DIR
      ?? join(homedir(), ".config", "oppi"),
  );

  const telemetryDir = resolve(
    getArg("telemetry-dir")
      ?? join(dataDir, "diagnostics", "telemetry"),
  );

  const dbPath = resolve(
    getArg("db")
      ?? join(telemetryDir, "telemetry.db"),
  );

  const watch = hasFlag("watch");
  const intervalMs = toPositiveInt(getArg("interval-ms"), 5_000);
  const verbose = hasFlag("verbose");

  const runImport = () => {
    const result = importOnce({ telemetryDir, dbPath, verbose });
    console.log(
      `[telemetry-import] files=${result.filesSeen} imported=${result.filesImported} `
        + `skipped=${result.filesSkipped} chatSamples=${result.chatSamplesImported} `
        + `metrickitPayloads=${result.metrickitPayloadsImported} `
        + `serverMetrics=${result.serverMetricSamplesImported} `
        + `serverOps=${result.serverOpsSamplesImported} parseErrors=${result.parseErrors} `
        + `invalid=${result.invalidRecords} durationMs=${result.durationMs}`,
    );
  };

  runImport();

  if (!watch) {
    return;
  }

  console.log(`[telemetry-import] watch mode enabled, interval=${intervalMs}ms`);

  let running = false;
  const timer = setInterval(() => {
    if (running) return;
    running = true;
    try {
      runImport();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[telemetry-import] watch cycle failed: ${message}`);
    } finally {
      running = false;
    }
  }, intervalMs);

  const stop = () => {
    clearInterval(timer);
    process.exit(0);
  };

  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`[telemetry-import] fatal: ${message}`);
  process.exit(1);
});
