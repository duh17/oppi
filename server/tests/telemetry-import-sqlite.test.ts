import { execFileSync, spawn } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";

const scriptPath = join(process.cwd(), "scripts/manual/telemetry-import-sqlite.mjs");

function runImport(telemetryDir: string, dbPath: string): void {
  execFileSync(process.execPath, [scriptPath, "--telemetry-dir", telemetryDir, "--db", dbPath], {
    stdio: "pipe",
  });
}

async function runWatchUntilImportLogs(
  telemetryDir: string,
  dbPath: string,
  importLogCount: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [
        scriptPath,
        "--watch",
        "--interval-ms",
        "1000",
        "--telemetry-dir",
        telemetryDir,
        "--db",
        dbPath,
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );

    let output = "";
    let timedOutError: Error | null = null;
    const timeout = setTimeout(() => {
      timedOutError = new Error(
        `timed out waiting for ${importLogCount} importer logs:\n${output}`,
      );
      child.kill("SIGTERM");
    }, 8000);

    const appendOutput = (chunk: Buffer) => {
      output += chunk.toString("utf8");
      const count = output.match(/\[telemetry-import\] \{/g)?.length ?? 0;
      if (count >= importLogCount) {
        child.kill("SIGTERM");
      }
    };

    child.stdout.on("data", appendOutput);
    child.stderr.on("data", appendOutput);
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("exit", (code, signal) => {
      clearTimeout(timeout);
      if (timedOutError) {
        reject(timedOutError);
        return;
      }
      if (code === 0 || signal === "SIGTERM") {
        resolve(output);
        return;
      }
      reject(new Error(`watch importer exited with code ${code ?? signal}:\n${output}`));
    });
  });
}

describe("telemetry SQLite importer", () => {
  let tempDir: string | undefined;

  afterEach(() => {
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  it("imports each MetricKit payload item with its own kind, window, summary, and raw JSON", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "metrickit-2026-04-29.jsonl"),
      JSON.stringify({
        receivedAt: 1_777_334_473_690,
        generatedAt: 1_777_334_473_553,
        appVersion: "1.1.0",
        buildNumber: "28",
        osVersion: "Version 26.3.1",
        deviceModel: "iPhone",
        payloads: [
          {
            kind: "metric",
            windowStartMs: 1_777_331_541_000,
            windowEndMs: 1_777_331_542_000,
            summary: { cpuMetrics: '{"cumulativeCPUTime":"12 sec"}' },
            raw: { payload: '{"memoryMetrics":{"peakMemoryUsage":"12345 kB"}}' },
          },
          {
            kind: "diagnostic",
            windowStartMs: 1_777_339_680_000,
            windowEndMs: 1_777_339_680_000,
            summary: { crashDiagnostics: "[]" },
            raw: { payload: '{"crashDiagnostics":[]}' },
          },
        ],
      }) + "\n",
    );

    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      const rows = db
        .prepare(
          `
        SELECT kind, window_start_ms, window_end_ms,
               json_extract(summary_json, '$.cpuMetrics') AS cpu_metrics,
               json_extract(raw_json, '$.payload') AS raw_payload
        FROM metrickit_payloads
        ORDER BY payload_index
      `,
        )
        .all() as Array<{
        kind: string;
        window_start_ms: number;
        window_end_ms: number;
        cpu_metrics: string | null;
        raw_payload: string | null;
      }>;

      expect(rows).toHaveLength(2);
      expect(rows[0]).toMatchObject({
        kind: "metric",
        window_start_ms: 1_777_331_541_000,
        window_end_ms: 1_777_331_542_000,
        cpu_metrics: '{"cumulativeCPUTime":"12 sec"}',
      });
      expect(rows[0]?.raw_payload).toContain("peakMemoryUsage");
      expect(rows[1]).toMatchObject({ kind: "diagnostic" });

      const meta = db.prepare("SELECT parser_version FROM ingested_files").get() as {
        parser_version: number;
      };
      expect(meta.parser_version).toBe(5);
    } finally {
      db.close();
    }
  });

  it("reimports files parsed by an older parser even when file metadata is unchanged", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "metrickit-2026-04-29.jsonl"),
      JSON.stringify({
        receivedAt: 1,
        generatedAt: 1,
        payloads: [{ kind: "metric", windowStartMs: 10, windowEndMs: 20, summary: {}, raw: {} }],
      }) + "\n",
    );

    runImport(tempDir, dbPath);

    let db = new DatabaseSync(dbPath);
    db.exec(
      "UPDATE metrickit_payloads SET kind = 'metrickit'; UPDATE ingested_files SET parser_version = 0;",
    );
    db.close();

    runImport(tempDir, dbPath);

    db = new DatabaseSync(dbPath);
    try {
      expect(
        (db.prepare("SELECT kind FROM metrickit_payloads").get() as { kind: string }).kind,
      ).toBe("metric");
      expect(
        (
          db.prepare("SELECT parser_version FROM ingested_files").get() as {
            parser_version: number;
          }
        ).parser_version,
      ).toBe(5);
    } finally {
      db.close();
    }
  });

  it("appends only new lines for hot files instead of reimporting the entire file", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    const filePath = join(tempDir, "chat-metrics-2026-04-29.jsonl");

    const line1 = JSON.stringify({
      receivedAt: 100,
      generatedAt: 90,
      appVersion: "1.1.0",
      buildNumber: "29",
      samples: [{ ts: 1000, metric: "chat.ttft_ms", value: 1200, unit: "ms" }],
    });
    const line2 = JSON.stringify({
      receivedAt: 200,
      generatedAt: 190,
      appVersion: "1.1.0",
      buildNumber: "29",
      samples: [{ ts: 2000, metric: "chat.ttft_ms", value: 800, unit: "ms" }],
    });

    writeFileSync(filePath, `${line1}\n`);
    runImport(tempDir, dbPath);

    writeFileSync(filePath, `${line1}\n${line2}\n`);
    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      expect(
        (db.prepare("SELECT count(*) AS c FROM chat_metric_samples").get() as { c: number }).c,
      ).toBe(2);
      expect(
        db
          .prepare(
            "SELECT line_count, processed_offset_bytes, source_file FROM ingested_files WHERE source_file = ?",
          )
          .get("chat-metrics-2026-04-29.jsonl") as {
          line_count: number;
          processed_offset_bytes: number;
          source_file: string;
        },
      ).toMatchObject({
        line_count: 2,
        processed_offset_bytes: Buffer.byteLength(`${line1}\n${line2}\n`),
        source_file: "chat-metrics-2026-04-29.jsonl",
      });
    } finally {
      db.close();
    }
  });

  it("runs SQLite integrity checks only once in watch mode by default", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "server-metrics-2026-05-28.jsonl"),
      JSON.stringify({
        ts: 1,
        cpu: { user: 1, system: 2, total: 3 },
        memory: { heapUsed: 4, heapTotal: 5, rss: 6, external: 7 },
        sessions: { busy: 0, ready: 1, starting: 0, total: 1 },
        wsConnections: 1,
      }) + "\n",
    );

    const output = await runWatchUntilImportLogs(tempDir, dbPath, 3);

    expect(output.match(/integrityCheck: true/g)?.length ?? 0).toBe(1);
    expect(output.match(/integrityCheck: false/g)?.length ?? 0).toBeGreaterThanOrEqual(2);
  });

  it("uses normalized source file keys so host and container imports do not duplicate rows", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    const dirA = join(tempDir, "a");
    const dirB = join(tempDir, "b");
    mkdirSync(dirA);
    mkdirSync(dirB);

    const fileName = "chat-metrics-2026-04-29.jsonl";
    const contents =
      JSON.stringify({
        receivedAt: 100,
        generatedAt: 90,
        appVersion: "1.1.0",
        buildNumber: "29",
        samples: [{ ts: 1000, metric: "chat.ttft_ms", value: 1200, unit: "ms" }],
      }) + "\n";

    writeFileSync(join(dirA, fileName), contents);
    cpSync(join(dirA, fileName), join(dirB, fileName));

    runImport(dirA, dbPath);
    runImport(dirB, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      expect(
        (db.prepare("SELECT count(*) AS c FROM chat_metric_samples").get() as { c: number }).c,
      ).toBe(1);
      expect(
        (db.prepare("SELECT count(*) AS c FROM ingested_files").get() as { c: number }).c,
      ).toBe(1);
      expect(
        (
          db.prepare("SELECT source_file FROM ingested_files LIMIT 1").get() as {
            source_file: string;
          }
        ).source_file,
      ).toBe(fileName);
    } finally {
      db.close();
    }
  });

  it("migrates older server ops tables before importing flattened tags", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    const oldDb = new DatabaseSync(dbPath);
    oldDb.exec(`
      CREATE TABLE server_ops_metric_samples (
        id TEXT PRIMARY KEY,
        source_file TEXT NOT NULL,
        line_number INTEGER NOT NULL,
        sample_index INTEGER NOT NULL,
        ts_ms INTEGER NOT NULL,
        metric TEXT NOT NULL,
        value REAL NOT NULL,
        tags_json TEXT
      );
    `);
    oldDb.close();

    writeFileSync(
      join(tempDir, "server-ops-metrics-2026-05-08.jsonl"),
      JSON.stringify({
        samples: [
          {
            ts: 1,
            metric: "server.ws_handshake_ms",
            value: 12,
            tags: { path: "bound_session_stream" },
          },
        ],
      }) + "\n",
    );

    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      const row = db.prepare("SELECT tag_path FROM server_ops_metric_samples").get() as {
        tag_path: string;
      };
      expect(row.tag_path).toBe("bound_session_stream");
    } finally {
      db.close();
    }
  });

  it("flattens server ops metric tags used by split-stream dashboards", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "server-ops-metrics-2026-05-08.jsonl"),
      JSON.stringify({
        flushedAt: 1_778_254_400_000,
        samples: [
          {
            ts: 1_778_254_400_001,
            metric: "server.ws_message_sent",
            value: 1,
            tags: { path: "bound_session_stream", type: "text_delta", level: "bound_session" },
          },
          {
            ts: 1_778_254_400_002,
            metric: "server.catchup_events",
            value: 3,
            tags: { lane: "session", ring: "session", outcome: "success" },
          },
          {
            ts: 1_778_254_400_003,
            metric: "server.ws_close_code",
            value: 1,
            tags: { path: "session_audio_stream", code: "1000" },
          },
        ],
      }) + "\n",
    );

    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      const rows = db
        .prepare(
          `
        SELECT metric, tag_path, tag_type, tag_level, tag_lane, tag_ring, tag_code, tag_outcome
        FROM server_ops_metric_samples
        ORDER BY ts_ms
      `,
        )
        .all() as Array<{
        metric: string;
        tag_path: string | null;
        tag_type: string | null;
        tag_level: string | null;
        tag_lane: string | null;
        tag_ring: string | null;
        tag_code: string | null;
        tag_outcome: string | null;
      }>;

      expect(rows).toEqual([
        {
          metric: "server.ws_message_sent",
          tag_path: "bound_session_stream",
          tag_type: "text_delta",
          tag_level: "bound_session",
          tag_lane: null,
          tag_ring: null,
          tag_code: null,
          tag_outcome: null,
        },
        {
          metric: "server.catchup_events",
          tag_path: null,
          tag_type: null,
          tag_level: null,
          tag_lane: "session",
          tag_ring: "session",
          tag_code: null,
          tag_outcome: "success",
        },
        {
          metric: "server.ws_close_code",
          tag_path: "session_audio_stream",
          tag_type: null,
          tag_level: null,
          tag_lane: null,
          tag_ring: null,
          tag_code: "1000",
          tag_outcome: null,
        },
      ]);
    } finally {
      db.close();
    }
  });
});
