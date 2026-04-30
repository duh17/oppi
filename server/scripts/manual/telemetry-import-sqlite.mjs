#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";

const INGEST_PARSER_VERSION = 4;
const DEFAULT_BROKEN_BACKUP_KEEP_COUNT = 1;
const DEFAULT_LOCK_STALE_MS = 10 * 60 * 1000;

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
    PRAGMA busy_timeout = 5000;

    CREATE TABLE IF NOT EXISTS ingested_files (
      source_file TEXT PRIMARY KEY,
      file_kind TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      mtime_ms INTEGER NOT NULL,
      line_count INTEGER NOT NULL,
      processed_at_ms INTEGER NOT NULL,
      parser_version INTEGER NOT NULL DEFAULT 0,
      processed_offset_bytes INTEGER NOT NULL DEFAULT 0
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
  const hasProcessedOffset = ingestedFileColumns.some(
    (column) => column.name === "processed_offset_bytes",
  );

  if (!hasParserVersion) {
    db.exec("ALTER TABLE ingested_files ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 0");
  }
  if (!hasProcessedOffset) {
    db.exec(
      "ALTER TABLE ingested_files ADD COLUMN processed_offset_bytes INTEGER NOT NULL DEFAULT 0",
    );
  }
}

function brokenBackupKeepCountFromEnv() {
  const raw = process.env.OPPI_TELEMETRY_BROKEN_DB_KEEP_COUNT?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed >= 0) return parsed;
  return DEFAULT_BROKEN_BACKUP_KEEP_COUNT;
}

function staleLockMsFromEnv(intervalMs) {
  const raw = process.env.OPPI_TELEMETRY_IMPORT_LOCK_STALE_MS?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed >= 1000) return parsed;
  return Math.max(DEFAULT_LOCK_STALE_MS, intervalMs * 10);
}

function normalizedSourceFile(fileName) {
  return basename(fileName);
}

function detectKind(fileName) {
  if (fileName.startsWith("chat-metrics-") && fileName.endsWith(".jsonl")) return "chat";
  if (fileName.startsWith("server-metrics-") && fileName.endsWith(".jsonl")) return "server";
  if (fileName.startsWith("server-ops-metrics-") && fileName.endsWith(".jsonl")) return "server_ops";
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

function readFileSlice(sourceFile, startOffset, endOffset) {
  const length = Math.max(0, endOffset - startOffset);
  if (length === 0) return Buffer.alloc(0);

  const fd = openSync(sourceFile, "r");
  try {
    const buffer = Buffer.alloc(length);
    let bytesRead = 0;
    while (bytesRead < length) {
      const n = readSync(fd, buffer, bytesRead, length - bytesRead, startOffset + bytesRead);
      if (n === 0) break;
      bytesRead += n;
    }
    return bytesRead === length ? buffer : buffer.subarray(0, bytesRead);
  } finally {
    closeSync(fd);
  }
}

function extractCompleteJsonlLines(buffer) {
  const lastNewline = buffer.lastIndexOf(0x0a);
  if (lastNewline === -1) {
    return { lines: [], consumedBytes: 0 };
  }

  const text = buffer.subarray(0, lastNewline + 1).toString("utf8");
  const lines = text.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return { lines, consumedBytes: lastNewline + 1 };
}

function getIngestState(db, sourceFile) {
  return (
    db
      .prepare(
        `
        SELECT source_file, file_kind, size_bytes, mtime_ms, line_count, parser_version,
               processed_offset_bytes
        FROM ingested_files
        WHERE source_file = ?
      `,
      )
      .get(sourceFile) ?? null
  );
}

function planIngest(state, meta) {
  if (!state) {
    return { action: "full", startOffset: 0, lineNumberStart: 0 };
  }

  if (state.parser_version !== INGEST_PARSER_VERSION) {
    return { action: "full", startOffset: 0, lineNumberStart: 0 };
  }

  if (meta.sizeBytes < state.processed_offset_bytes || meta.sizeBytes < state.size_bytes) {
    return { action: "full", startOffset: 0, lineNumberStart: 0 };
  }

  const fullyProcessed = state.processed_offset_bytes === meta.sizeBytes;
  const unchanged = fullyProcessed && meta.mtimeMs === state.mtime_ms;
  if (unchanged) {
    return { action: "skip", startOffset: state.processed_offset_bytes, lineNumberStart: state.line_count };
  }

  if (meta.sizeBytes === state.size_bytes && fullyProcessed && meta.mtimeMs !== state.mtime_ms) {
    return { action: "full", startOffset: 0, lineNumberStart: 0 };
  }

  return {
    action: "append",
    startOffset: state.processed_offset_bytes,
    lineNumberStart: state.line_count,
  };
}

function ingestChatFile(db, sourceFile, lines, options) {
  const { replaceExisting = false, lineNumberStart = 0 } = options;
  if (replaceExisting) {
    db.prepare("DELETE FROM chat_metric_samples WHERE source_file = ?").run(sourceFile);
  }

  const ins = db.prepare(`
    INSERT OR REPLACE INTO chat_metric_samples (
      id, source_file, line_number, sample_index, ts_ms, metric, value, unit,
      generated_at_ms, received_at_ms, app_version, build_number, os_version,
      device_model, session_id, workspace_id, tags_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const payload = JSON.parse(line);
    const samples = Array.isArray(payload.samples) ? payload.samples : [];
    const lineNumber = lineNumberStart + lineIndex + 1;
    for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex += 1) {
      const sample = samples[sampleIndex] ?? {};
      const ts = Number(sample.ts);
      const value = Number(sample.value);
      if (!Number.isFinite(ts) || !Number.isFinite(value) || typeof sample.metric !== "string") {
        continue;
      }

      ins.run(
        fileId([sourceFile, lineNumber, sampleIndex]),
        sourceFile,
        lineNumber,
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

  return count;
}

function ingestServerFile(db, sourceFile, lines, options) {
  const { replaceExisting = false, lineNumberStart = 0 } = options;
  if (replaceExisting) {
    db.prepare("DELETE FROM server_metric_samples WHERE source_file = ?").run(sourceFile);
  }

  const ins = db.prepare(`
    INSERT OR REPLACE INTO server_metric_samples (
      id, source_file, line_number, ts_ms, cpu_user, cpu_system, cpu_total,
      mem_heap_used, mem_heap_total, mem_rss, mem_external,
      sessions_busy, sessions_ready, sessions_starting, sessions_total, ws_connections
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const row = JSON.parse(line);
    const ts = Number(row.ts);
    if (!Number.isFinite(ts)) continue;

    const lineNumber = lineNumberStart + lineIndex + 1;
    ins.run(
      fileId([sourceFile, lineNumber]),
      sourceFile,
      lineNumber,
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

  return count;
}

function ingestServerOpsFile(db, sourceFile, lines, options) {
  const { replaceExisting = false, lineNumberStart = 0 } = options;
  if (replaceExisting) {
    db.prepare("DELETE FROM server_ops_metric_samples WHERE source_file = ?").run(sourceFile);
  }

  const ins = db.prepare(`
    INSERT OR REPLACE INTO server_ops_metric_samples (
      id, source_file, line_number, sample_index, ts_ms, metric, value, tags_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const payload = JSON.parse(line);
    const samples = Array.isArray(payload.samples) ? payload.samples : [];
    const lineNumber = lineNumberStart + lineIndex + 1;
    for (let sampleIndex = 0; sampleIndex < samples.length; sampleIndex += 1) {
      const sample = samples[sampleIndex] ?? {};
      const ts = Number(sample.ts);
      const value = Number(sample.value);
      if (!Number.isFinite(ts) || !Number.isFinite(value) || typeof sample.metric !== "string") {
        continue;
      }

      ins.run(
        fileId([sourceFile, lineNumber, sampleIndex]),
        sourceFile,
        lineNumber,
        sampleIndex,
        ts,
        sample.metric,
        value,
        toJson(sample.tags),
      );
      count += 1;
    }
  }

  return count;
}

function ingestMetricKitFile(db, sourceFile, lines, options) {
  const { replaceExisting = false, lineNumberStart = 0 } = options;
  if (replaceExisting) {
    db.prepare("DELETE FROM metrickit_payloads WHERE source_file = ?").run(sourceFile);
  }

  const ins = db.prepare(`
    INSERT OR REPLACE INTO metrickit_payloads (
      id, source_file, line_number, payload_index, kind, window_start_ms, window_end_ms,
      generated_at_ms, received_at_ms, app_version, build_number, os_version, device_model,
      summary_json, raw_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  let count = 0;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line.trim()) continue;
    const record = JSON.parse(line);
    const payloads = Array.isArray(record.payloads) ? record.payloads : [record];
    const lineNumber = lineNumberStart + lineIndex + 1;
    for (let payloadIndex = 0; payloadIndex < payloads.length; payloadIndex += 1) {
      const payload = payloads[payloadIndex] ?? {};
      const { start, end } = inferWindow(payload);
      ins.run(
        fileId([sourceFile, lineNumber, payloadIndex]),
        sourceFile,
        lineNumber,
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

  return count;
}

function ingestLinesForKind(db, kind, sourceFile, lines, options) {
  if (kind === "chat") return ingestChatFile(db, sourceFile, lines, options);
  if (kind === "server") return ingestServerFile(db, sourceFile, lines, options);
  if (kind === "server_ops") return ingestServerOpsFile(db, sourceFile, lines, options);
  if (kind === "metrickit") return ingestMetricKitFile(db, sourceFile, lines, options);
  throw new Error(`Unsupported telemetry kind: ${kind}`);
}

function upsertFileMeta(db, sourceFile, kind, meta, lineCount, processedOffsetBytes) {
  db.prepare(
    `
    INSERT INTO ingested_files (
      source_file, file_kind, size_bytes, mtime_ms, line_count, processed_at_ms,
      parser_version, processed_offset_bytes
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(source_file) DO UPDATE SET
      file_kind = excluded.file_kind,
      size_bytes = excluded.size_bytes,
      mtime_ms = excluded.mtime_ms,
      line_count = excluded.line_count,
      processed_at_ms = excluded.processed_at_ms,
      parser_version = excluded.parser_version,
      processed_offset_bytes = excluded.processed_offset_bytes
  `,
  ).run(
    sourceFile,
    kind,
    meta.sizeBytes,
    meta.mtimeMs,
    lineCount,
    Date.now(),
    INGEST_PARSER_VERSION,
    processedOffsetBytes,
  );
}

function maintainDb(db, filesIngested) {
  if (filesIngested <= 0) return;
  try {
    db.exec("PRAGMA wal_checkpoint(PASSIVE); PRAGMA optimize;");
  } catch {
    // Best effort maintenance only.
  }
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
      const sourcePath = join(telemetryDir, entry);
      const sourceFile = normalizedSourceFile(entry);
      const stats = statSync(sourcePath);
      const meta = { sizeBytes: stats.size, mtimeMs: Math.trunc(stats.mtimeMs) };
      const state = getIngestState(db, sourceFile);
      const plan = planIngest(state, meta);
      if (plan.action === "skip") continue;

      const slice = readFileSlice(sourcePath, plan.startOffset, meta.sizeBytes);
      const { lines, consumedBytes } = extractCompleteJsonlLines(slice);
      const lineNumberStart = plan.action === "append" ? plan.lineNumberStart : 0;
      const rows = ingestLinesForKind(db, kind, sourceFile, lines, {
        replaceExisting: plan.action === "full",
        lineNumberStart,
      });

      const nextLineCount = lineNumberStart + lines.length;
      const nextProcessedOffset = plan.startOffset + consumedBytes;
      upsertFileMeta(db, sourceFile, kind, meta, nextLineCount, nextProcessedOffset);

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

  maintainDb(db, summary.filesIngested);
  return summary;
}

function pruneBrokenDbBackups(dbPath) {
  const dir = dirname(dbPath);
  const prefix = `${basename(dbPath)}.broken-`;
  const keepCount = brokenBackupKeepCountFromEnv();

  if (!existsSync(dir)) return;

  const backups = readdirSync(dir)
    .filter((entry) => entry.startsWith(prefix))
    .map((entry) => {
      const path = join(dir, entry);
      let mtimeMs = 0;
      try {
        mtimeMs = statSync(path).mtimeMs;
      } catch {
        // Ignore stale entries we can no longer stat.
      }
      return { entry, path, mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs || b.entry.localeCompare(a.entry));

  for (const backup of backups.slice(keepCount)) {
    try {
      unlinkSync(backup.path);
    } catch {
      // Best effort.
    }
  }
}

function backupBrokenDb(dbPath, reason) {
  if (!existsSync(dbPath)) return null;
  const suffix = new Date().toISOString().replace(/[:.]/g, "-");
  const backupPath = `${dbPath}.broken-${suffix}`;
  renameSync(dbPath, backupPath);
  rmSync(`${dbPath}-wal`, { force: true });
  rmSync(`${dbPath}-shm`, { force: true });
  console.warn("[telemetry-import] rebuilt malformed database", { dbPath, backupPath, reason });
  pruneBrokenDbBackups(dbPath);
  return backupPath;
}

function openDbWithRecovery(dbPath) {
  pruneBrokenDbBackups(dbPath);
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

function acquireImportLock(dbPath, intervalMs) {
  const lockPath = `${dbPath}.import.lock`;
  const staleMs = staleLockMsFromEnv(intervalMs);
  const payload = JSON.stringify({
    pid: process.pid,
    startedAt: new Date().toISOString(),
  });

  const tryCreate = () => {
    writeFileSync(lockPath, payload, { encoding: "utf8", flag: "wx", mode: 0o600 });
    return lockPath;
  };

  try {
    return tryCreate();
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;

    try {
      const ageMs = Date.now() - statSync(lockPath).mtimeMs;
      if (ageMs > staleMs) {
        unlinkSync(lockPath);
        return tryCreate();
      }
    } catch {
      // If we can't stat/delete it, treat it as an active lock.
    }

    return null;
  }
}

function releaseImportLock(lockPath) {
  if (!lockPath) return;
  try {
    unlinkSync(lockPath);
  } catch {
    // Best effort.
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  mkdirSync(dirname(args.db), { recursive: true });

  const run = () => {
    const lockPath = acquireImportLock(args.db, args.intervalMs);
    if (!lockPath) {
      console.log("[telemetry-import] skipped; another importer run is active");
      return;
    }

    const startedAt = Date.now();
    let db = null;
    try {
      db = openDbWithRecovery(args.db);
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
        db?.close();
      } catch {
        // Best effort.
      }
      db = null;
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
    } finally {
      try {
        db?.close();
      } catch {
        // Best effort.
      }
      releaseImportLock(lockPath);
    }
  };

  run();

  if (!args.watch) {
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
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    clearInterval(timer);
    process.exit(0);
  });
}

main().catch((error) => {
  console.error("[telemetry-import] failed", error);
  process.exit(1);
});
