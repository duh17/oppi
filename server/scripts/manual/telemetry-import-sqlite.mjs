#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, renameSync, rmSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { mkdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const INGEST_PARSER_VERSION = 2;

function parseArgs(argv) {
  const args = {
    watch: false,
    intervalMs: 15000,
    telemetryDir: resolve(
      process.env.OPPI_DATA_DIR || join(process.env.HOME || ".", ".config/oppi"),
      "diagnostics/telemetry",
    ),
    db: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--watch") {
      args.watch = true;
    } else if (arg === "--interval-ms") {
      args.intervalMs = Number.parseInt(argv[++i] || "", 10);
    } else if (arg === "--telemetry-dir") {
      args.telemetryDir = resolve(argv[++i] || "");
    } else if (arg === "--db") {
      args.db = resolve(argv[++i] || "");
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isFinite(args.intervalMs) || args.intervalMs < 1000) {
    throw new Error(`Invalid --interval-ms: ${args.intervalMs}`);
  }

  if (!args.db) {
    args.db = join(args.telemetryDir, "telemetry.db");
  }

  return args;
}

function ensureSchema(db) {
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS ingested_files (
      source_file TEXT PRIMARY KEY,
      file_kind TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      mtime_ms INTEGER NOT NULL,
      line_count INTEGER NOT NULL,
      processed_at_ms INTEGER NOT NULL,
      parser_version INTEGER NOT NULL DEFAULT 0
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
    CREATE INDEX IF NOT EXISTS idx_chat_metric_metric_ts ON chat_metric_samples(metric, ts_ms);
    CREATE INDEX IF NOT EXISTS idx_chat_metric_ts ON chat_metric_samples(ts_ms);
    CREATE INDEX IF NOT EXISTS idx_chat_metric_build_ts ON chat_metric_samples(build_number, ts_ms);

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
    CREATE INDEX IF NOT EXISTS idx_server_metric_ts ON server_metric_samples(ts_ms);

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
    CREATE INDEX IF NOT EXISTS idx_server_ops_metric_ts ON server_ops_metric_samples(metric, ts_ms);
    CREATE INDEX IF NOT EXISTS idx_server_ops_ts ON server_ops_metric_samples(ts_ms);

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
    CREATE INDEX IF NOT EXISTS idx_metrickit_window ON metrickit_payloads(window_start_ms, window_end_ms);
  `);

  const ingestedFileColumns = db.prepare("PRAGMA table_info(ingested_files)").all();
  const hasParserVersion = ingestedFileColumns.some((column) => column.name === "parser_version");
  if (!hasParserVersion) {
    db.exec("ALTER TABLE ingested_files ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 0");
  }
}

function detectKind(fileName) {
  if (fileName.startsWith("chat-metrics-") && fileName.endsWith(".jsonl")) return "chat";
  if (fileName.startsWith("server-metrics-") && fileName.endsWith(".jsonl")) return "server";
  if (fileName.startsWith("server-ops-metrics-") && fileName.endsWith(".jsonl"))
    return "server_ops";
  if (fileName.startsWith("metrickit-") && fileName.endsWith(".jsonl")) return "metrickit";
  return null;
}

function fileId(parts) {
  return createHash("sha1").update(parts.join("|")).digest("hex");
}

function toJson(value) {
  return value && typeof value === "object" ? JSON.stringify(value) : null;
}

function safeNumber(value) {
  return Number.isFinite(value) ? value : null;
}

function normalizeSummary(payload) {
  if (payload?.summary && typeof payload.summary === "object") return payload.summary;
  if (payload?.metrics && typeof payload.metrics === "object") return payload.metrics;
  if (payload?.diagnostics && typeof payload.diagnostics === "object") return payload.diagnostics;
  return null;
}

function inferWindow(payload) {
  const candidates = [
    payload.windowStartMs,
    payload.windowStart,
    payload.startMs,
    payload.start,
    payload.periodStartMs,
    payload.timeRange?.startMs,
  ]
    .map((v) => Number(v))
    .filter(Number.isFinite);
  const endCandidates = [
    payload.windowEndMs,
    payload.windowEnd,
    payload.endMs,
    payload.end,
    payload.periodEndMs,
    payload.timeRange?.endMs,
    payload.generatedAt,
    payload.generatedAtMs,
    payload.receivedAt,
    payload.receivedAtMs,
  ]
    .map((v) => Number(v))
    .filter(Number.isFinite);

  const start = candidates[0] ?? endCandidates[0] ?? 0;
  const end = endCandidates[0] ?? start;
  return { start, end };
}

function ingestChatFile(db, sourceFile, lines, meta) {
  const del = db.prepare("DELETE FROM chat_metric_samples WHERE source_file = ?");
  const ins = db.prepare(`
    INSERT INTO chat_metric_samples (
      id, source_file, line_number, sample_index, ts_ms, metric, value, unit,
      generated_at_ms, received_at_ms, app_version, build_number, os_version,
      device_model, session_id, workspace_id, tags_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  del.run(sourceFile);
  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const payload = JSON.parse(line);
    const samples = Array.isArray(payload.samples) ? payload.samples : [];
    for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex += 1) {
      const sample = samples[sampleIndex] ?? {};
      const ts = Number(sample.ts);
      const value = Number(sample.value);
      if (!Number.isFinite(ts) || !Number.isFinite(value) || typeof sample.metric !== "string")
        continue;
      ins.run(
        fileId([sourceFile, lineIndex + 1, sampleIndex]),
        sourceFile,
        lineIndex + 1,
        sampleIndex,
        ts,
        sample.metric,
        value,
        typeof sample.unit === "string" ? sample.unit : "count",
        safeNumber(Number(payload.generatedAt)),
        safeNumber(Number(payload.receivedAt)),
        payload.appVersion ?? null,
        payload.buildNumber ?? null,
        payload.osVersion ?? null,
        payload.deviceModel ?? null,
        sample.sessionId ?? null,
        sample.workspaceId ?? null,
        toJson(sample.tags),
      );
      count += 1;
    }
  }
  upsertFileMeta(db, sourceFile, "chat", meta, lines.length);
  return count;
}

function ingestServerFile(db, sourceFile, lines, meta) {
  const del = db.prepare("DELETE FROM server_metric_samples WHERE source_file = ?");
  const ins = db.prepare(`
    INSERT INTO server_metric_samples (
      id, source_file, line_number, ts_ms, cpu_user, cpu_system, cpu_total,
      mem_heap_used, mem_heap_total, mem_rss, mem_external,
      sessions_busy, sessions_ready, sessions_starting, sessions_total, ws_connections
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  del.run(sourceFile);
  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const row = JSON.parse(line);
    const ts = Number(row.ts);
    if (!Number.isFinite(ts)) continue;
    ins.run(
      fileId([sourceFile, lineIndex + 1]),
      sourceFile,
      lineIndex + 1,
      ts,
      Number(row.cpu?.user ?? 0),
      Number(row.cpu?.system ?? 0),
      Number(row.cpu?.total ?? 0),
      Number(row.memory?.heapUsed ?? 0),
      Number(row.memory?.heapTotal ?? 0),
      Number(row.memory?.rss ?? 0),
      Number(row.memory?.external ?? 0),
      Number(row.sessions?.busy ?? 0),
      Number(row.sessions?.ready ?? 0),
      Number(row.sessions?.starting ?? 0),
      Number(row.sessions?.total ?? 0),
      Number(row.wsConnections ?? 0),
    );
    count += 1;
  }
  upsertFileMeta(db, sourceFile, "server", meta, lines.length);
  return count;
}

function ingestServerOpsFile(db, sourceFile, lines, meta) {
  const del = db.prepare("DELETE FROM server_ops_metric_samples WHERE source_file = ?");
  const ins = db.prepare(`
    INSERT INTO server_ops_metric_samples (
      id, source_file, line_number, sample_index, ts_ms, metric, value, tags_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  del.run(sourceFile);
  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const payload = JSON.parse(line);
    const samples = Array.isArray(payload.samples) ? payload.samples : [];
    for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex += 1) {
      const sample = samples[sampleIndex] ?? {};
      const ts = Number(sample.ts);
      const value = Number(sample.value);
      if (!Number.isFinite(ts) || !Number.isFinite(value) || typeof sample.metric !== "string")
        continue;
      ins.run(
        fileId([sourceFile, lineIndex + 1, sampleIndex]),
        sourceFile,
        lineIndex + 1,
        sampleIndex,
        ts,
        sample.metric,
        value,
        toJson(sample.tags),
      );
      count += 1;
    }
  }
  upsertFileMeta(db, sourceFile, "server_ops", meta, lines.length);
  return count;
}

function ingestMetricKitFile(db, sourceFile, lines, meta) {
  const del = db.prepare("DELETE FROM metrickit_payloads WHERE source_file = ?");
  const ins = db.prepare(`
    INSERT INTO metrickit_payloads (
      id, source_file, line_number, payload_index, kind, window_start_ms, window_end_ms,
      generated_at_ms, received_at_ms, app_version, build_number, os_version, device_model,
      summary_json, raw_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  del.run(sourceFile);
  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const record = JSON.parse(line);
    const payloads = Array.isArray(record.payloads) ? record.payloads : [record];
    for (let payloadIndex = 0; payloadIndex < payloads.length; payloadIndex += 1) {
      const payload = payloads[payloadIndex] ?? {};
      const { start, end } = inferWindow(payload);
      ins.run(
        fileId([sourceFile, lineIndex + 1, payloadIndex]),
        sourceFile,
        lineIndex + 1,
        payloadIndex,
        payload.kind ?? payload.payloadType ?? "metrickit",
        start,
        end,
        safeNumber(
          Number(
            record.generatedAt ??
              record.generatedAtMs ??
              payload.generatedAt ??
              payload.generatedAtMs,
          ),
        ),
        safeNumber(
          Number(
            record.receivedAt ?? record.receivedAtMs ?? payload.receivedAt ?? payload.receivedAtMs,
          ),
        ),
        record.appVersion ?? payload.appVersion ?? null,
        record.buildNumber ?? payload.buildNumber ?? null,
        record.osVersion ?? payload.osVersion ?? null,
        record.deviceModel ?? payload.deviceModel ?? null,
        toJson(normalizeSummary(payload)),
        payload.raw === undefined ? JSON.stringify(payload) : JSON.stringify(payload.raw),
      );
      count += 1;
    }
  }
  upsertFileMeta(db, sourceFile, "metrickit", meta, lines.length);
  return count;
}

function upsertFileMeta(db, sourceFile, kind, meta, lineCount) {
  db.prepare(
    `
    INSERT INTO ingested_files (
      source_file, file_kind, size_bytes, mtime_ms, line_count, processed_at_ms, parser_version
    ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(source_file) DO UPDATE SET
      file_kind = excluded.file_kind,
      size_bytes = excluded.size_bytes,
      mtime_ms = excluded.mtime_ms,
      line_count = excluded.line_count,
      processed_at_ms = excluded.processed_at_ms,
      parser_version = excluded.parser_version
  `,
  ).run(
    sourceFile,
    kind,
    meta.sizeBytes,
    meta.mtimeMs,
    lineCount,
    Date.now(),
    INGEST_PARSER_VERSION,
  );
}

function shouldIngest(db, sourceFile, meta, kind) {
  const row = db
    .prepare(
      "SELECT size_bytes, mtime_ms, parser_version FROM ingested_files WHERE source_file = ?",
    )
    .get(sourceFile);
  if (!row) return true;
  return (
    row.size_bytes !== meta.sizeBytes ||
    row.mtime_ms !== meta.mtimeMs ||
    (kind === "metrickit" && row.parser_version !== INGEST_PARSER_VERSION)
  );
}

function ingestOnce(db, telemetryDir) {
  const entries = existsSync(telemetryDir) ? readdirSync(telemetryDir).sort() : [];
  const summary = { filesScanned: 0, filesIngested: 0, rowsIngested: 0 };

  db.exec("BEGIN");
  try {
    for (const entry of entries) {
      const kind = detectKind(entry);
      if (!kind) continue;
      summary.filesScanned += 1;
      const sourceFile = join(telemetryDir, entry);
      const stats = statSync(sourceFile);
      const meta = { sizeBytes: stats.size, mtimeMs: Math.trunc(stats.mtimeMs) };
      if (!shouldIngest(db, sourceFile, meta, kind)) continue;

      const content = readFileSync(sourceFile, "utf8");
      const lines = content.split("\n");
      if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();

      let rows = 0;
      if (kind === "chat") rows = ingestChatFile(db, sourceFile, lines, meta);
      else if (kind === "server") rows = ingestServerFile(db, sourceFile, lines, meta);
      else if (kind === "server_ops") rows = ingestServerOpsFile(db, sourceFile, lines, meta);
      else if (kind === "metrickit") rows = ingestMetricKitFile(db, sourceFile, lines, meta);

      summary.filesIngested += 1;
      summary.rowsIngested += rows;
    }
    db.exec("COMMIT");
  } catch (error) {
    try {
      db.exec("ROLLBACK");
    } catch {
      // Preserve the original ingestion error. SQLite may already have ended
      // the transaction for some failure modes.
    }
    throw error;
  }

  return summary;
}

function backupBrokenDb(dbPath, reason) {
  if (!existsSync(dbPath)) return null;
  const suffix = new Date().toISOString().replace(/[:.]/g, "-");
  const backupPath = `${dbPath}.broken-${suffix}`;
  renameSync(dbPath, backupPath);
  rmSync(`${dbPath}-wal`, { force: true });
  rmSync(`${dbPath}-shm`, { force: true });
  console.warn("[telemetry-import] rebuilt malformed database", { dbPath, backupPath, reason });
  return backupPath;
}

function openDbWithRecovery(dbPath) {
  try {
    const db = new DatabaseSync(dbPath);
    ensureSchema(db);
    const row = db.prepare("PRAGMA integrity_check").get();
    const verdict = row ? Object.values(row)[0] : "ok";
    if (verdict !== "ok") {
      db.close();
      backupBrokenDb(dbPath, String(verdict));
      const freshDb = new DatabaseSync(dbPath);
      ensureSchema(freshDb);
      return freshDb;
    }
    return db;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("malformed")) throw error;
    backupBrokenDb(dbPath, message);
    const db = new DatabaseSync(dbPath);
    ensureSchema(db);
    return db;
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  mkdirSync(dirname(args.db), { recursive: true });
  let db = openDbWithRecovery(args.db);

  const run = () => {
    const startedAt = Date.now();
    try {
      const summary = ingestOnce(db, args.telemetryDir);
      console.log("[telemetry-import]", {
        telemetryDir: args.telemetryDir,
        db: args.db,
        durationMs: Date.now() - startedAt,
        ...summary,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!message.includes("malformed")) throw error;
      try {
        db.close();
      } catch {}
      backupBrokenDb(args.db, message);
      db = openDbWithRecovery(args.db);
      const summary = ingestOnce(db, args.telemetryDir);
      console.log("[telemetry-import]", {
        telemetryDir: args.telemetryDir,
        db: args.db,
        durationMs: Date.now() - startedAt,
        recovered: true,
        ...summary,
      });
    }
  };

  run();

  if (!args.watch) {
    db.close();
    return;
  }

  let running = false;
  const runOnceIfIdle = () => {
    if (running) return;
    running = true;
    try {
      run();
    } finally {
      running = false;
    }
  };

  const timer = setInterval(runOnceIfIdle, args.intervalMs);
  process.on("SIGINT", () => {
    clearInterval(timer);
    db.close();
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    clearInterval(timer);
    db.close();
    process.exit(0);
  });
}

main().catch((error) => {
  console.error("[telemetry-import] failed", error);
  process.exit(1);
});
