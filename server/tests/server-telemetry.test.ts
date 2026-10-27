import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TelemetryEventWriter, type TelemetryEventSink } from "../src/telemetry/event-writer.js";
import { ServerTelemetry } from "../src/telemetry/server-telemetry.js";
import type { TelemetryEventRecord } from "../src/types.js";

class MemorySink implements TelemetryEventSink {
  batches: TelemetryEventRecord[][] = [];
  write(_origin: "app" | "server", records: readonly TelemetryEventRecord[]): void {
    this.batches.push([...records]);
  }
  get records(): TelemetryEventRecord[] {
    return this.batches.flat();
  }
}

const DAY_MS = 24 * 60 * 60 * 1_000;
const ROUTE = { runtime: "durable", provider: "anthropic", model: "claude-sonnet-4-0" } as const;

describe("ServerTelemetry", () => {
  it("folds catalog-aggregated events per tag set, session, and flush window", () => {
    const sink = new MemorySink();
    const telemetry = new ServerTelemetry(sink);

    const usage = (input: number, output: number, cost: number, sessionId: string) =>
      telemetry.record(
        "server.turn_usage",
        { input_tokens: input, output_tokens: output, cost_usd_micros: cost },
        ROUTE,
        { sessionId },
      );
    usage(100, 10, 1_000, "s1");
    usage(40, 5, 500, "s1");
    usage(7, 1, 70, "s2");
    telemetry.record("server.broadcast_fanout", { subscribers: 2 }, { message_type: "text_delta" });
    telemetry.record("server.broadcast_fanout", { subscribers: 5 }, { message_type: "text_delta" });
    telemetry.record("server.broadcast_fanout", { subscribers: 3 }, { message_type: "text_delta" });
    // Tag key order does not split a window.
    telemetry.record(
      "server.ws_message_received",
      { messages: 1, binary_bytes: 640 },
      {
        stream: "dictation",
        message_type: "binary_audio",
      },
    );
    telemetry.record(
      "server.ws_message_received",
      { messages: 1, binary_bytes: 320 },
      {
        message_type: "binary_audio",
        stream: "dictation",
      },
    );
    expect(telemetry.bufferedCount).toBe(4);
    telemetry.flush();

    const byKey = new Map(
      sink.records.map((record) => [`${record.name}:${record.sessionId ?? ""}`, record]),
    );
    expect(byKey.get("server.turn_usage:s1")?.fields).toEqual({
      input_tokens: 140,
      output_tokens: 15,
      cost_usd_micros: 1_500,
    });
    expect(byKey.get("server.turn_usage:s2")?.fields.input_tokens).toBe(7);
    expect(byKey.get("server.broadcast_fanout:")?.fields).toEqual({ subscribers: 5 });
    expect(byKey.get("server.ws_message_received:")?.fields).toEqual({
      messages: 2,
      binary_bytes: 960,
    });

    // The next window starts from zero.
    usage(1, 1, 1, "s1");
    telemetry.flush();
    expect(sink.batches[1]?.[0]?.fields).toEqual({
      input_tokens: 1,
      output_tokens: 1,
      cost_usd_micros: 1,
    });
  });

  it("stores each non-aggregated event as one v2 record with ids outside the tags", () => {
    const sink = new MemorySink();
    const telemetry = new ServerTelemetry(sink);

    telemetry.record(
      "server.tool_call",
      { duration_ms: 40 },
      { ...ROUTE, tool: "bash", status: "ok" },
      { sessionId: "s1", workspaceId: "w1" },
    );
    telemetry.record("server.tool_call", {}, { ...ROUTE, tool: "read", status: "error" });
    telemetry.flush();

    expect(sink.records).toEqual([
      {
        v: 2,
        ts: expect.any(Number),
        origin: "server",
        name: "server.tool_call",
        fields: { duration_ms: 40 },
        tags: { ...ROUTE, tool: "bash", status: "ok" },
        sessionId: "s1",
        workspaceId: "w1",
      },
      expect.objectContaining({ fields: {}, tags: { ...ROUTE, tool: "read", status: "error" } }),
    ]);
  });

  it("drops events the catalog refuses and sanitizes name tags", () => {
    const sink = new MemorySink();
    const telemetry = new ServerTelemetry(sink);

    telemetry.record("server.turn_ttft", { duration_ms: Number.NaN }, ROUTE);
    telemetry.record("server.session_end", {}, { reason: "exploded" as never });
    const request = (pathPattern: string) =>
      telemetry.record(
        "server.http_request",
        { duration_ms: 3 },
        { method: "GET", path_pattern: pathPattern, status_code: "200" },
      );
    request("/files/my secret.txt");
    request("/workspaces/:workspaceId/sessions/:sessionId/tool-output/:toolCallId");
    request(`/${"a".repeat(128)}`);
    telemetry.flush();

    expect(sink.records.map((record) => record.tags.path_pattern)).toEqual([
      "unknown",
      "/workspaces/:workspaceId/sessions/:sessionId/tool-output/:toolCallId",
      "unknown",
    ]);
  });

  it("flushes when the buffer fills, on stop, and never throws from a failing sink", () => {
    const sink = new MemorySink();
    const telemetry = new ServerTelemetry(sink, { maxBufferSize: 2 });
    telemetry.record("server.ws_ping", { rtt_ms: 1 }, {});
    expect(sink.batches).toHaveLength(0);
    telemetry.record("server.ws_ping", { rtt_ms: 2 }, {});
    expect(sink.batches).toHaveLength(1);

    telemetry.record("server.ws_ping", { rtt_ms: 3 }, {});
    telemetry.stop();
    expect(sink.records.map((record) => record.fields.rtt_ms)).toEqual([1, 2, 3]);

    const failing = new ServerTelemetry({
      write: () => {
        throw new Error("disk full");
      },
    });
    failing.record("server.ws_ping", { rtt_ms: 1 }, {});
    expect(() => failing.flush()).not.toThrow();
    expect(() => failing.recordNow("server.ws_ping", { rtt_ms: 1 }, {})).not.toThrow();
  });

  it("writes recordNow events immediately without draining the buffer", () => {
    const sink = new MemorySink();
    const telemetry = new ServerTelemetry(sink);
    telemetry.record("server.ws_ping", { rtt_ms: 1 }, {});
    telemetry.recordNow("server.session_create", { duration_ms: 12 }, {});
    expect(sink.records.map((record) => record.name)).toEqual(["server.session_create"]);
    expect(telemetry.bufferedCount).toBe(1);
  });

  it("flushes on its timer", () => {
    vi.useFakeTimers();
    try {
      const sink = new MemorySink();
      const telemetry = new ServerTelemetry(sink, { flushIntervalMs: 1_000 });
      telemetry.start();
      telemetry.record("server.ws_ping", { rtt_ms: 1 }, {});
      vi.advanceTimersByTime(1_000);
      expect(sink.records).toHaveLength(1);
      telemetry.stop();
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("TelemetryEventWriter", () => {
  let dir: string;
  const saved: Record<string, string | undefined> = {};
  const setEnv = (name: string, value: string) => {
    if (!(name in saved)) saved[name] = process.env[name];
    process.env[name] = value;
  };

  beforeEach(() => {
    dir = join(mkdtempSync(join(tmpdir(), "oppi-telemetry-writer-")), "telemetry");
  });

  afterEach(() => {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
      delete saved[name];
    }
    rmSync(join(dir, ".."), { recursive: true, force: true });
  });

  const record = (name: string): TelemetryEventRecord => ({
    v: 2,
    ts: Date.now(),
    origin: "server",
    name,
    fields: {},
    tags: {},
  });

  it("appends one JSON line per record to the origin's daily file", () => {
    const writer = new TelemetryEventWriter(dir);
    writer.write("server", [record("server.ws_ping_timeout"), record("server.session_create")]);
    writer.write("server", [record("server.ws_ping_timeout")]);
    writer.write("app", []);

    const today = new Date().toISOString().slice(0, 10);
    expect(readdirSync(dir)).toEqual([`server-events-${today}.jsonl`]);
    const lines = readFileSync(join(dir, `server-events-${today}.jsonl`), "utf8")
      .trim()
      .split("\n");
    expect(lines.map((line) => (JSON.parse(line) as TelemetryEventRecord).name)).toEqual([
      "server.ws_ping_timeout",
      "server.session_create",
      "server.ws_ping_timeout",
    ]);
  });

  it("keeps writing server.resources after ops events fill the daily cap", () => {
    setEnv("OPPI_SERVER_METRICS_DAILY_FILE_MAX_BYTES", "400");
    const writer = new TelemetryEventWriter(dir);
    for (let i = 0; i < 20; i += 1) writer.write("server", [record("server.ws_ping_timeout")]);
    const resources = record("server.resources");
    writer.write("server", [resources, record("server.session_create")]);
    writer.write("server", [resources]);

    const today = new Date().toISOString().slice(0, 10);
    const names = readFileSync(join(dir, `server-events-${today}.jsonl`), "utf8")
      .trim()
      .split("\n")
      .map((line) => (JSON.parse(line) as TelemetryEventRecord).name);
    expect(names.filter((name) => name === "server.resources")).toHaveLength(2);
    // The cap still holds for everything else: far fewer than 20 + 1 ops lines fit in 400 bytes.
    expect(names.filter((name) => name !== "server.resources").length).toBeLessThan(10);
  });

  it("prunes expired server event files and every pre-v2 server prefix on the server retention", () => {
    setEnv("OPPI_SERVER_METRICS_RETENTION_DAYS", "3");
    mkdirSync(dir, { recursive: true });
    const old = new Date(Date.now() - 10 * DAY_MS).toISOString().slice(0, 10);
    const recent = new Date(Date.now() - 1 * DAY_MS).toISOString().slice(0, 10);
    for (const name of [
      `server-events-${old}.jsonl`,
      `server-ops-metrics-${old}.jsonl`,
      `server-metrics-${old}.jsonl`,
      `server-metrics-${recent}.jsonl`,
      `app-events-${old}.jsonl`,
      `metrickit-${old}.jsonl`,
    ]) {
      writeFileSync(join(dir, name), "{}\n");
    }

    new TelemetryEventWriter(dir).prune("server");

    expect(readdirSync(dir).sort()).toEqual([
      `app-events-${old}.jsonl`,
      `metrickit-${old}.jsonl`,
      `server-metrics-${recent}.jsonl`,
    ]);
  });
});
