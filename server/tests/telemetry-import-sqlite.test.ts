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

function appEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    v: 2,
    ts: 1000,
    origin: "app",
    name: "app.session_load",
    fields: { duration_ms: 1200 },
    tags: {},
    sessionId: "s1",
    workspaceId: "w1",
    client: {
      kind: "ios",
      appVersion: "1.2.0",
      buildNumber: "412",
      gitCommit: "abc123def456",
      deviceModel: "iPhone17,1",
    },
    ...overrides,
  };
}

function serverResourcesEvent(): Record<string, unknown> {
  return {
    v: 2,
    ts: 10,
    origin: "server",
    name: "server.resources",
    fields: { rss_mb: 300 },
    tags: { host_scope: "host" },
  };
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
      expect(meta.parser_version).toBe(7);
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
      ).toBe(7);
    } finally {
      db.close();
    }
  });

  it("appends only new lines for hot files instead of reimporting the entire file", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    const filePath = join(tempDir, "app-events-2026-10-27.jsonl");

    const line1 = JSON.stringify(appEvent({ ts: 1000, fields: { duration_ms: 1200 } }));
    const line2 = JSON.stringify(appEvent({ ts: 2000, fields: { duration_ms: 800 } }));

    writeFileSync(filePath, `${line1}\n`);
    runImport(tempDir, dbPath);

    writeFileSync(filePath, `${line1}\n${line2}\n`);
    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      expect((db.prepare("SELECT count(*) AS c FROM events").get() as { c: number }).c).toBe(2);
      expect(
        db
          .prepare(
            "SELECT line_count, processed_offset_bytes, source_file FROM ingested_files WHERE source_file = ?",
          )
          .get("app-events-2026-10-27.jsonl") as {
          line_count: number;
          processed_offset_bytes: number;
          source_file: string;
        },
      ).toMatchObject({
        line_count: 2,
        processed_offset_bytes: Buffer.byteLength(`${line1}\n${line2}\n`),
        source_file: "app-events-2026-10-27.jsonl",
      });
    } finally {
      db.close();
    }
  });

  it("runs SQLite integrity checks only once in watch mode by default", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "server-events-2026-10-27.jsonl"),
      JSON.stringify(serverResourcesEvent()) + "\n",
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

    const fileName = "app-events-2026-10-27.jsonl";
    writeFileSync(join(dirA, fileName), JSON.stringify(appEvent({ ts: 1000 })) + "\n");
    cpSync(join(dirA, fileName), join(dirB, fileName));

    runImport(dirA, dbPath);
    runImport(dirB, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      expect((db.prepare("SELECT count(*) AS c FROM events").get() as { c: number }).c).toBe(1);
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

  it("stores each v2 event with its origin, client identity, fields, and tags", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "app-events-2026-10-27.jsonl"),
      JSON.stringify(
        appEvent({
          ts: 1_793_000_000_000,
          fields: { duration_ms: 412, items: 87 },
          tags: { load_path: "cache_hit" },
        }),
      ) + "\n",
    );
    writeFileSync(
      join(tempDir, "server-events-2026-10-27.jsonl"),
      JSON.stringify(serverResourcesEvent()) + "\n",
    );

    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      const rows = db
        .prepare(
          `SELECT ts_ms, origin, name, session_id, workspace_id, client_kind, app_version,
                  build_number, git_commit, device_model,
                  json_extract(fields_json, '$.duration_ms') AS duration_ms,
                  json_extract(tags_json, '$.load_path') AS load_path,
                  fields_json, tags_json
           FROM events ORDER BY origin`,
        )
        .all();
      expect(rows).toEqual([
        {
          ts_ms: 1_793_000_000_000,
          origin: "app",
          name: "app.session_load",
          session_id: "s1",
          workspace_id: "w1",
          client_kind: "ios",
          app_version: "1.2.0",
          build_number: "412",
          git_commit: "abc123def456",
          device_model: "iPhone17,1",
          duration_ms: 412,
          load_path: "cache_hit",
          fields_json: '{"duration_ms":412,"items":87}',
          tags_json: '{"load_path":"cache_hit"}',
        },
        {
          ts_ms: 10,
          origin: "server",
          name: "server.resources",
          session_id: null,
          workspace_id: null,
          client_kind: null,
          app_version: null,
          build_number: null,
          git_commit: null,
          device_model: null,
          duration_ms: null,
          load_path: null,
          fields_json: '{"rss_mb":300}',
          tags_json: '{"host_scope":"host"}',
        },
      ]);
    } finally {
      db.close();
    }
  });

  it("ignores pre-v2 files and skips lines that are not v2 events", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    writeFileSync(
      join(tempDir, "chat-metrics-2026-10-20.jsonl"),
      JSON.stringify({ samples: [{ ts: 1, metric: "chat.ttft_ms", value: 1, unit: "ms" }] }) +
        "\n",
    );
    writeFileSync(
      join(tempDir, "app-events-2026-10-27.jsonl"),
      [
        JSON.stringify({ ts: 1, metric: "chat.ttft_ms", value: 1 }),
        "not json",
        JSON.stringify({ ...appEvent({ ts: 5 }), v: 3 }),
        JSON.stringify(appEvent({ ts: 6 })),
      ].join("\n") + "\n",
    );

    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      expect(db.prepare("SELECT ts_ms FROM events").all()).toEqual([{ ts_ms: 6 }]);
      expect(
        (db.prepare("SELECT count(*) AS c FROM ingested_files").get() as { c: number }).c,
      ).toBe(1);
    } finally {
      db.close();
    }
  });

  it("leaves legacy tables of an existing database in place", () => {
    tempDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-import-"));
    const dbPath = join(tempDir, "telemetry.db");
    const oldDb = new DatabaseSync(dbPath);
    oldDb.exec(`
      CREATE TABLE chat_metric_samples (id TEXT PRIMARY KEY, metric TEXT);
      INSERT INTO chat_metric_samples VALUES ('a', 'chat.ttft_ms');
    `);
    oldDb.close();
    writeFileSync(
      join(tempDir, "app-events-2026-10-27.jsonl"),
      JSON.stringify(appEvent({ ts: 6 })) + "\n",
    );

    runImport(tempDir, dbPath);

    const db = new DatabaseSync(dbPath);
    try {
      expect(db.prepare("SELECT metric FROM chat_metric_samples").all()).toEqual([
        { metric: "chat.ttft_ms" },
      ]);
      expect((db.prepare("SELECT count(*) AS c FROM events").get() as { c: number }).c).toBe(1);
    } finally {
      db.close();
    }
  });
});
