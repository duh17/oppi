import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createLogger, type Logger } from "../src/logger.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createTelemetryRoutes } from "../src/routes/telemetry.js";
import type { RouteContext } from "../src/routes/types.js";
import type { TelemetryEventRecord, TelemetryEventUploadResponse } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

/** Encoded by the generated Swift event structs; see protocol/README.md. */
const GOLDEN_UPLOAD_PATH = join(
  import.meta.dirname,
  "..",
  "..",
  "protocol",
  "telemetry-events-upload.json",
);

const CLIENT = { kind: "ios", appVersion: "1.0.0", buildNumber: "1", appInstanceId: "app-1" };
const DAY_MS = 24 * 60 * 60 * 1_000;

let dataDir: string;
const savedEnv: Record<string, string | undefined> = {};

function setEnv(name: string, value: string): void {
  if (!(name in savedEnv)) savedEnv[name] = process.env[name];
  process.env[name] = value;
}

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-"));
});

afterEach(() => {
  for (const [name, value] of Object.entries(savedEnv)) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
    delete savedEnv[name];
  }
  rmSync(dataDir, { recursive: true, force: true });
});

function telemetryDir(): string {
  return join(dataDir, "diagnostics", "telemetry");
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

async function post(path: string, body: unknown) {
  const ctx = { storage: { getDataDir: () => dataDir } } as unknown as RouteContext;
  const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
  const res = makeResponse();
  const handled = await dispatch({
    method: "POST",
    path,
    url: new URL(`http://localhost${path}`),
    req: makeRequest(body) as never,
    res: res as never,
  });
  return { handled, status: res.statusCode, body: res.body ? JSON.parse(res.body) : undefined };
}

function storedAppEvents(): TelemetryEventRecord[] {
  const path = join(telemetryDir(), `app-events-${today()}.jsonl`);
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as TelemetryEventRecord);
}

describe("POST /telemetry/events", () => {
  it("accepts every event of the Swift-encoded golden upload and stores v2 records", async () => {
    const upload = JSON.parse(readFileSync(GOLDEN_UPLOAD_PATH, "utf8")) as {
      client: Record<string, string>;
      events: Array<{ name: string; ts: number }>;
    };

    const { handled, status, body } = await post("/telemetry/events", upload);

    expect(handled).toBe(true);
    expect(status).toBe(200);
    expect(body).toEqual({
      ok: true,
      accepted: upload.events.length,
      dropped: {},
    } satisfies TelemetryEventUploadResponse);

    const records = storedAppEvents();
    expect(records.map((record) => record.name)).toEqual(upload.events.map((event) => event.name));
    expect(records[0]).toEqual({
      v: 2,
      ts: upload.events[0]!.ts,
      origin: "app",
      name: "app.session_load",
      fields: { duration_ms: 412, items: 87 },
      tags: { load_path: "cache_hit" },
      sessionId: "sess-golden-1",
      workspaceId: "ws-golden-1",
      client: upload.client,
    });
  });

  it("drops invalid events by reason and stores the valid ones", async () => {
    const ts = Date.now();
    const ok = { ts, name: "app.ttft", fields: { duration_ms: 900 }, tags: { model: "gpt-5" } };
    const { status, body } = await post("/telemetry/events", {
      generatedAt: ts,
      client: CLIENT,
      events: [
        ok,
        { ...ok, name: "chat.ttft_ms" },
        { ...ok, name: "server.turn_ttft" },
        { ...ok, ts: "yesterday" },
        { ...ok, fields: {} },
        { ...ok, fields: { duration_ms: 900, value: 1 } },
        { ...ok, fields: { duration_ms: "900" } },
        { ...ok, tags: { host: "studio.local" } },
        { ts, name: "app.session_switch", fields: { duration_ms: 5, cached: 2 } },
        { ts, name: "app.catchup", fields: { duration_ms: 40 } },
        { ts, name: "app.catchup", fields: { duration_ms: 40 }, tags: { result: "cache_seeded" } },
        // Under the 4 ms emit floor.
        { ts, name: "app.timeline_apply", fields: { duration_ms: 1, items: 3, changed: 1 } },
        "not an event",
      ],
    });

    expect(status).toBe(200);
    expect(body).toEqual({
      ok: true,
      accepted: 1,
      dropped: {
        unknown_event: 1,
        wrong_origin: 1,
        invalid_timestamp: 1,
        missing_field: 1,
        unknown_field: 1,
        invalid_field_value: 2,
        unknown_tag: 1,
        missing_tag: 1,
        invalid_tag_value: 1,
        emit_policy: 1,
        malformed: 1,
      },
    });
    expect(storedAppEvents().map((record) => record.fields)).toEqual([{ duration_ms: 900 }]);
  });

  describe("drop logging", () => {
    function droppingUpload(client: Record<string, string>): unknown {
      const ts = Date.now();
      return {
        generatedAt: ts,
        client,
        events: [
          { ts, name: "chat.ttft_ms", fields: { duration_ms: 1 } },
          { ts, name: "app.ttft", fields: { duration_ms: 900 } },
        ],
      };
    }

    async function postWith(
      dispatch: ReturnType<typeof createTelemetryRoutes>,
      body: unknown,
    ): Promise<void> {
      await dispatch({
        method: "POST",
        path: "/telemetry/events",
        url: new URL("http://localhost/telemetry/events"),
        req: makeRequest(body) as never,
        res: makeResponse() as never,
      });
    }

    /** A logger of its own: the process logger's level and sink depend on the environment. */
    function capturingLogger(): { logger: Logger; lines: Array<Record<string, unknown>> } {
      const lines: Array<Record<string, unknown>> = [];
      const logger = createLogger({
        level: "debug",
        sink: (_level, line) => lines.push(JSON.parse(line) as Record<string, unknown>),
      });
      return { logger, lines };
    }

    it("logs drops by reason with the client build, once per reason and build", async () => {
      const { logger, lines } = capturingLogger();
      const ctx = { storage: { getDataDir: () => dataDir } } as unknown as RouteContext;
      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers(), logger);

      await postWith(dispatch, droppingUpload({ ...CLIENT, buildNumber: "412" }));
      await postWith(dispatch, droppingUpload({ ...CLIENT, buildNumber: "412" }));
      await postWith(dispatch, droppingUpload({ ...CLIENT, buildNumber: "413" }));

      const drops = lines.filter((line) => line.event === "telemetry_events.dropped");
      expect(drops).toHaveLength(2);
      expect(drops[0]).toMatchObject({
        level: "warn",
        dropped: { unknown_event: 1 },
        clientKind: "ios",
        buildNumber: "412",
      });
      expect(drops[1]).toMatchObject({ buildNumber: "413", dropped: { unknown_event: 1 } });
    });

    it("logs nothing when every event is accepted", async () => {
      const { logger, lines } = capturingLogger();
      const ctx = { storage: { getDataDir: () => dataDir } } as unknown as RouteContext;
      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers(), logger);
      const ts = Date.now();
      await postWith(dispatch, {
        generatedAt: ts,
        client: CLIENT,
        events: [{ ts, name: "app.ttft", fields: { duration_ms: 900 } }],
      });
      expect(lines.filter((line) => line.event === "telemetry_events.dropped")).toHaveLength(0);
    });
  });

  it("stores unsafe name-tag values as unknown instead of dropping the event", async () => {
    const ts = Date.now();
    const { body } = await post("/telemetry/events", {
      generatedAt: ts,
      client: CLIENT,
      events: [
        {
          ts,
          name: "app.cell_configure",
          fields: { duration_ms: 3 },
          tags: { row_type: "tool", tool: "/Users/me/secret file.txt" },
        },
      ],
    });
    expect(body.accepted).toBe(1);
    expect(storedAppEvents()[0]?.tags).toEqual({ row_type: "tool", tool: "unknown" });
  });

  it("applies an emit rule only to events matching its tags", async () => {
    const ts = Date.now();
    const command = (command: string, roundtripMs: number) => ({
      ts,
      name: "app.command",
      fields: { send_ms: 5, roundtrip_ms: roundtripMs },
      tags: { command, transport: "lan", status: "ok" },
    });
    const { body } = await post("/telemetry/events", {
      generatedAt: ts,
      client: CLIENT,
      events: [command("get_queue", 40), command("get_queue", 600), command("prompt", 40)],
    });
    expect(body).toMatchObject({ accepted: 2, dropped: { emit_policy: 1 } });
  });

  it("caps an upload and counts the overflow", async () => {
    const ts = Date.now();
    const events = Array.from({ length: 503 }, () => ({
      ts,
      name: "app.ws_ping",
      fields: { rtt_ms: 30, socks_generation: 0 },
    }));
    const { body } = await post("/telemetry/events", { generatedAt: ts, client: CLIENT, events });
    expect(body).toMatchObject({ accepted: 500, dropped: { over_batch_limit: 3 } });
  });

  it("rejects an upload without the client envelope", async () => {
    const ts = Date.now();
    const events = [{ ts, name: "app.ttft", fields: { duration_ms: 1 } }];
    expect((await post("/telemetry/events", { generatedAt: ts, events })).status).toBe(400);
    expect(
      (await post("/telemetry/events", { generatedAt: ts, client: { kind: "android" }, events }))
        .status,
    ).toBe(400);
  });

  it("accepts but does not append past the daily file cap", async () => {
    setEnv("OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES", "32");
    mkdirSync(telemetryDir(), { recursive: true });
    const dayFile = join(telemetryDir(), `app-events-${today()}.jsonl`);
    writeFileSync(dayFile, '{"existing":true}\n');

    const ts = Date.now();
    const { status } = await post("/telemetry/events", {
      generatedAt: ts,
      client: CLIENT,
      events: [{ ts, name: "app.ttft", fields: { duration_ms: 1 } }],
    });

    expect(status).toBe(200);
    expect(readFileSync(dayFile, "utf8")).toBe('{"existing":true}\n');
  });

  it("prunes expired app event files and the pre-v2 chat-metrics files", async () => {
    setEnv("OPPI_CHAT_METRICS_RETENTION_DAYS", "1");
    mkdirSync(telemetryDir(), { recursive: true });
    const old = new Date(Date.now() - 12 * DAY_MS).toISOString().slice(0, 10);
    writeFileSync(join(telemetryDir(), `app-events-${old}.jsonl`), "{}\n");
    writeFileSync(join(telemetryDir(), `chat-metrics-${old}.jsonl`), "{}\n");
    writeFileSync(join(telemetryDir(), `client-logs-${old}.jsonl`), "{}\n");

    const ts = Date.now();
    await post("/telemetry/events", {
      generatedAt: ts,
      client: CLIENT,
      events: [{ ts, name: "app.ttft", fields: { duration_ms: 1 } }],
    });

    // Client logs prune on their own upload, not on event uploads.
    expect(readdirSync(telemetryDir()).sort()).toEqual([
      `app-events-${today()}.jsonl`,
      `client-logs-${old}.jsonl`,
    ]);
  });
});

describe("POST /telemetry/metrickit", () => {
  it("stores normalized payloads with the client envelope flattened", async () => {
    const generatedAt = Date.now();
    const { status } = await post("/telemetry/metrickit", {
      generatedAt,
      client: { ...CLIENT, bootId: "boot-1", gitCommit: "not-a-sha" },
      payloads: [
        {
          kind: "metric",
          windowStartMs: generatedAt - 4_000,
          windowEndMs: generatedAt,
          summary: { kind: "metric", count: 2 },
          raw: { payload: "{" },
        },
      ],
    });
    expect(status).toBe(200);

    const lines = readFileSync(join(telemetryDir(), `metrickit-${today()}.jsonl`), "utf8")
      .trim()
      .split("\n");
    expect(lines).toHaveLength(1);
    const record = JSON.parse(lines[0]!) as Record<string, unknown>;
    expect(record).toMatchObject({
      appVersion: "1.0.0",
      clientKind: "ios",
      appInstanceId: "app-1",
      bootId: "boot-1",
      payloadCount: 1,
    });
    expect(record.gitCommit).toBeUndefined();
  });

  it("rejects a generatedAt outside the Date range instead of naming a file after it", async () => {
    const { status } = await post("/telemetry/metrickit", {
      generatedAt: Number.MAX_VALUE,
      client: CLIENT,
      payloads: [{ kind: "metric", windowStartMs: 1, windowEndMs: 2, summary: {}, raw: {} }],
    });

    expect(status).toBe(400);
    expect(existsSync(telemetryDir())).toBe(false);
  });

  it("accepts but does not append past the daily file cap", async () => {
    setEnv("OPPI_TELEMETRY_DAILY_FILE_MAX_BYTES", "32");
    mkdirSync(telemetryDir(), { recursive: true });
    const dayFile = join(telemetryDir(), `metrickit-${today()}.jsonl`);
    writeFileSync(dayFile, '{"existing":true}\n');

    const { status } = await post("/telemetry/metrickit", {
      generatedAt: Date.now(),
      client: CLIENT,
      payloads: [{ kind: "metric", windowStartMs: 1, windowEndMs: 2, summary: {}, raw: {} }],
    });

    expect(status).toBe(200);
    expect(readFileSync(dayFile, "utf8")).toBe('{"existing":true}\n');
  });

  it("prunes old MetricKit files on its retention", async () => {
    setEnv("OPPI_METRICKIT_RETENTION_DAYS", "1");
    mkdirSync(telemetryDir(), { recursive: true });
    const old = new Date(Date.now() - 10 * DAY_MS).toISOString().slice(0, 10);
    writeFileSync(join(telemetryDir(), `metrickit-${old}.jsonl`), "{}\n");

    await post("/telemetry/metrickit", {
      generatedAt: Date.now(),
      client: CLIENT,
      payloads: [{ kind: "metric", windowStartMs: 1, windowEndMs: 2, summary: {}, raw: {} }],
    });

    expect(readdirSync(telemetryDir())).toEqual([`metrickit-${today()}.jsonl`]);
  });
});

describe("telemetry upload gate", () => {
  it("refuses every upload when OPPI_TELEMETRY_MODE disables telemetry", async () => {
    setEnv("OPPI_TELEMETRY_MODE", "public");
    for (const path of ["/telemetry/metrickit", "/telemetry/events", "/telemetry/client-logs"]) {
      const { handled, status, body } = await post(path, { client: CLIENT });
      expect(handled).toBe(true);
      expect(status).toBe(403);
      expect(body).toEqual({ error: "telemetry uploads disabled by OPPI_TELEMETRY_MODE" });
    }
  });

  it("does not handle the removed chat-metrics route or unrelated routes", async () => {
    expect((await post("/telemetry/chat-metrics", {})).handled).toBe(false);
    const dispatch = createTelemetryRoutes({} as RouteContext, createRouteHelpers());
    const handled = await dispatch({
      method: "GET",
      path: "/telemetry/missing",
      url: new URL("http://localhost/telemetry/missing"),
      req: {} as never,
      res: makeResponse() as never,
    });
    expect(handled).toBe(false);
  });
});
