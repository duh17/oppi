import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createTelemetryRoutes } from "../src/routes/telemetry.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

describe("telemetry module", () => {
  it("stores normalized MetricKit payloads in daily JSONL files", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-"));
    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const generatedAt = Date.now();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/metrickit",
        url: new URL("http://localhost/telemetry/metrickit"),
        req: makeRequest({
          generatedAt,
          appVersion: "1.0.0",
          buildNumber: "1",
          clientKind: "ios",
          appInstanceId: "app-instance-1",
          bootId: "boot-1",
          payloads: [
            {
              kind: "metric",
              windowStartMs: generatedAt - 4_000,
              windowEndMs: generatedAt,
              summary: { kind: "metric", count: 2 },
              raw: { payload: "{" },
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const dayFile = join(
        dataDir,
        "diagnostics",
        "telemetry",
        `metrickit-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
      );
      const lines = readFileSync(dayFile, "utf8").trim().split("\n");
      expect(lines).toHaveLength(1);

      const record = JSON.parse(lines[0]) as {
        appVersion?: string;
        clientKind?: string;
        appInstanceId?: string;
        bootId?: string;
        payloadCount: number;
        payloads: Array<{ kind: string }>;
      };
      expect(record.appVersion).toBe("1.0.0");
      expect(record.clientKind).toBe("ios");
      expect(record.appInstanceId).toBe("app-instance-1");
      expect(record.bootId).toBe("boot-1");
      expect(record.payloadCount).toBe(1);
      expect(record.payloads[0]?.kind).toBe("metric");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("stores normalized chat metric payloads in daily JSONL files", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-"));
    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const generatedAt = Date.now();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt,
          appVersion: "1.0.0",
          samples: [
            {
              ts: generatedAt - 250,
              metric: "chat.ttft_ms",
              value: 812,
              unit: "ms",
              sessionId: "session-1",
              workspaceId: "workspace-1",
              tags: { phase: "baseline" },
            },
            {
              ts: generatedAt,
              metric: "chat.catchup_ring_miss",
              value: 1,
              unit: "count",
            },
            {
              ts: generatedAt + 15,
              metric: "chat.fresh_content_lag_ms",
              value: 420,
              unit: "ms",
              tags: { reason: "history_applied", cache: "1" },
            },
            {
              ts: generatedAt + 22,
              metric: "chat.queue_sync_ms",
              value: 52,
              unit: "ms",
              tags: { transport: "paired", status: "ok" },
            },
            {
              ts: generatedAt + 24,
              metric: "chat.session_message_count",
              value: 10,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 25,
              metric: "chat.session_input_tokens",
              value: 1_250,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 26,
              metric: "chat.session_output_tokens",
              value: 640,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 28,
              metric: "chat.session_mutating_tool_calls",
              value: 3,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 29,
              metric: "chat.session_files_changed",
              value: 2,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 30,
              metric: "chat.session_added_lines",
              value: 48,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 31,
              metric: "chat.session_removed_lines",
              value: 13,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 32,
              metric: "chat.session_context_tokens",
              value: 3_200,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
            {
              ts: generatedAt + 33,
              metric: "chat.session_context_window",
              value: 200_000,
              unit: "count",
              sessionId: "session-1",
              tags: { provider: "anthropic", model: "claude-sonnet-4-5" },
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const dayFile = join(
        dataDir,
        "diagnostics",
        "telemetry",
        `chat-metrics-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
      );
      const lines = readFileSync(dayFile, "utf8").trim().split("\n");
      expect(lines).toHaveLength(1);

      const record = JSON.parse(lines[0]) as {
        appVersion?: string;
        sampleCount: number;
        samples: Array<{ metric: string; value: number }>;
      };
      expect(record.appVersion).toBe("1.0.0");
      expect(record.sampleCount).toBe(13);
      expect(record.samples[0]?.metric).toBe("chat.ttft_ms");
      expect(record.samples[2]?.metric).toBe("chat.fresh_content_lag_ms");
      expect(record.samples[3]?.metric).toBe("chat.queue_sync_ms");
      expect(record.samples[4]?.metric).toBe("chat.session_message_count");
      expect(record.samples[5]?.metric).toBe("chat.session_input_tokens");
      expect(record.samples[6]?.metric).toBe("chat.session_output_tokens");
      expect(record.samples[7]?.metric).toBe("chat.session_mutating_tool_calls");
      expect(record.samples[8]?.metric).toBe("chat.session_files_changed");
      expect(record.samples[9]?.metric).toBe("chat.session_added_lines");
      expect(record.samples[10]?.metric).toBe("chat.session_removed_lines");
      expect(record.samples[11]?.metric).toBe("chat.session_context_tokens");
      expect(record.samples[12]?.metric).toBe("chat.session_context_window");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("normalizes chat metric tag keys to snake_case", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-tag-normalize-"));
    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const generatedAt = Date.now();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt,
          samples: [
            {
              ts: generatedAt,
              metric: "chat.voice_setup_ms",
              value: 210,
              unit: "ms",
              tags: {
                traceEvents: "120",
                trace_events: "999",
                "HTTP-Status": "200",
                " phase ": "total",
                __status__: "ok",
                already_snake: "1",
                "%%%%": "ignored",
              },
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const dayFile = join(
        dataDir,
        "diagnostics",
        "telemetry",
        `chat-metrics-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
      );
      const lines = readFileSync(dayFile, "utf8").trim().split("\n");
      expect(lines).toHaveLength(1);

      const record = JSON.parse(lines[0]) as {
        sampleCount: number;
        samples: Array<{ tags?: Record<string, string> }>;
      };
      expect(record.sampleCount).toBe(1);
      expect(record.samples[0]?.tags).toEqual({
        trace_events: "120",
        http_status: "200",
        phase: "total",
        status: "ok",
        already_snake: "1",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects chat metrics payloads when all samples are invalid", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-invalid-"));
    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const generatedAt = Date.now();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt,
          samples: [
            {
              ts: generatedAt,
              metric: "plot.not_real",
              value: 1,
              unit: "count",
            },
            {
              ts: generatedAt + 1,
              metric: "plot.scroll_enabled",
              value: 1,
              unit: "wat",
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({
        error: "samples must be a non-empty array of valid metrics",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects chat metrics payloads when units don't match metric contracts", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-unit-contracts-"));
    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const generatedAt = Date.now();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt,
          samples: [
            {
              ts: generatedAt,
              metric: "chat.ttft_ms",
              value: 250,
              unit: "count",
            },
            {
              ts: generatedAt + 1,
              metric: "plot.scroll_enabled",
              value: 1,
              unit: "count",
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({
        error: "samples must be a non-empty array of valid metrics",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("drops invalid chat metric samples while persisting valid ones", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-mixed-"));
    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const generatedAt = Date.now();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt,
          samples: [
            {
              ts: generatedAt,
              metric: "chat.ttft_ms",
              value: 120,
              unit: "ms",
            },
            {
              ts: generatedAt + 1,
              metric: "chat.unknown_metric",
              value: 3,
              unit: "count",
            },
            {
              ts: generatedAt + 2,
              metric: "chat.catchup_ms",
              value: 50,
              unit: "banana",
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const dayFile = join(
        dataDir,
        "diagnostics",
        "telemetry",
        `chat-metrics-${new Date(generatedAt).toISOString().slice(0, 10)}.jsonl`,
      );
      const lines = readFileSync(dayFile, "utf8").trim().split("\n");
      expect(lines).toHaveLength(1);

      const record = JSON.parse(lines[0]) as {
        sampleCount: number;
        samples: Array<{ metric: string; unit: string; value: number }>;
      };
      expect(record.sampleCount).toBe(1);
      expect(record.samples[0]?.metric).toBe("chat.ttft_ms");
      expect(record.samples[0]?.unit).toBe("ms");
      expect(record.samples[0]?.value).toBe(120);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects telemetry uploads when OPPI_TELEMETRY_MODE disables telemetry", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-gate-"));
    const previousMode = process.env.OPPI_TELEMETRY_MODE;
    process.env.OPPI_TELEMETRY_MODE = "public";

    try {
      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const generatedAt = Date.now();

      const metrickitRes = makeResponse();
      const metrickitHandled = await dispatch({
        method: "POST",
        path: "/telemetry/metrickit",
        url: new URL("http://localhost/telemetry/metrickit"),
        req: makeRequest({
          generatedAt,
          payloads: [
            {
              kind: "metric",
              windowStartMs: generatedAt - 100,
              windowEndMs: generatedAt,
              summary: { key: "value" },
              raw: { payload: "{}" },
            },
          ],
        }) as never,
        res: metrickitRes as never,
      });

      expect(metrickitHandled).toBe(true);
      expect(metrickitRes.statusCode).toBe(403);
      expect(JSON.parse(metrickitRes.body)).toEqual({
        error: "telemetry uploads disabled by OPPI_TELEMETRY_MODE",
      });

      const chatRes = makeResponse();
      const chatHandled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt,
          samples: [
            {
              ts: generatedAt,
              metric: "chat.ttft_ms",
              value: 200,
              unit: "ms",
            },
          ],
        }) as never,
        res: chatRes as never,
      });

      expect(chatHandled).toBe(true);
      expect(chatRes.statusCode).toBe(403);
      expect(JSON.parse(chatRes.body)).toEqual({
        error: "telemetry uploads disabled by OPPI_TELEMETRY_MODE",
      });
    } finally {
      if (previousMode === undefined) {
        delete process.env.OPPI_TELEMETRY_MODE;
      } else {
        process.env.OPPI_TELEMETRY_MODE = previousMode;
      }
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("prunes old telemetry files based on retention window", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-telemetry-prune-"));
    const previousRetention = process.env.OPPI_METRICKIT_RETENTION_DAYS;
    process.env.OPPI_METRICKIT_RETENTION_DAYS = "1";

    try {
      const telemetryDir = join(dataDir, "diagnostics", "telemetry");
      mkdirSync(telemetryDir, { recursive: true });

      const oldDate = new Date(Date.now() - 10 * 24 * 60 * 60 * 1_000);
      const oldPath = join(telemetryDir, `metrickit-${oldDate.toISOString().slice(0, 10)}.jsonl`);
      writeFileSync(oldPath, '{"legacy":true}\n');

      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/metrickit",
        url: new URL("http://localhost/telemetry/metrickit"),
        req: makeRequest({
          generatedAt: Date.now(),
          payloads: [
            {
              kind: "metric",
              windowStartMs: Date.now() - 2_000,
              windowEndMs: Date.now(),
              summary: { reason: "prune-test" },
              raw: { payload: "{}" },
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const files = readdirSync(telemetryDir);
      expect(files.length).toBe(1);
      expect(files[0]).not.toContain(oldDate.toISOString().slice(0, 10));
    } finally {
      if (previousRetention === undefined) {
        delete process.env.OPPI_METRICKIT_RETENTION_DAYS;
      } else {
        process.env.OPPI_METRICKIT_RETENTION_DAYS = previousRetention;
      }
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("prunes old chat metrics files based on retention window", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-test-chat-metrics-prune-"));
    const previousRetention = process.env.OPPI_CHAT_METRICS_RETENTION_DAYS;
    process.env.OPPI_CHAT_METRICS_RETENTION_DAYS = "1";

    try {
      const telemetryDir = join(dataDir, "diagnostics", "telemetry");
      mkdirSync(telemetryDir, { recursive: true });

      const oldDate = new Date(Date.now() - 12 * 24 * 60 * 60 * 1_000);
      const oldPath = join(
        telemetryDir,
        `chat-metrics-${oldDate.toISOString().slice(0, 10)}.jsonl`,
      );
      writeFileSync(oldPath, '{"legacy":true}\n');

      const ctx = {
        storage: {
          getDataDir: () => dataDir,
        },
      } as unknown as RouteContext;

      const dispatch = createTelemetryRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      const handled = await dispatch({
        method: "POST",
        path: "/telemetry/chat-metrics",
        url: new URL("http://localhost/telemetry/chat-metrics"),
        req: makeRequest({
          generatedAt: Date.now(),
          samples: [
            {
              ts: Date.now(),
              metric: "chat.timeline_apply_ms",
              value: 32,
              unit: "ms",
            },
          ],
        }) as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);

      const files = readdirSync(telemetryDir);
      expect(files.length).toBe(1);
      expect(files[0]).not.toContain(oldDate.toISOString().slice(0, 10));
    } finally {
      if (previousRetention === undefined) {
        delete process.env.OPPI_CHAT_METRICS_RETENTION_DAYS;
      } else {
        process.env.OPPI_CHAT_METRICS_RETENTION_DAYS = previousRetention;
      }
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("returns false for unrelated routes", async () => {
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
