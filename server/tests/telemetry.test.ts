import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createTelemetryRoutes } from "../src/routes/telemetry.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";

function makeHarness(body: unknown): {
  ctx: RouteContext;
  helpers: RouteHelpers;
  dataDir: string;
  responses: unknown[];
  errors: Array<{ status: number; message: string }>;
} {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-telemetry-test-"));
  const responses: unknown[] = [];
  const errors: Array<{ status: number; message: string }> = [];

  const helpers: RouteHelpers = {
    parseBody: async () => body,
    json: (_res, data) => {
      responses.push(data);
    },
    compressedJson: (_req, _res, data) => {
      responses.push(data);
    },
    error: (_res, status, message) => {
      errors.push({ status, message });
    },
  };

  const ctx = {
    storage: {
      getDataDir: () => dataDir,
    },
  } as RouteContext;

  return { ctx, helpers, dataDir, responses, errors };
}

describe("telemetry routes", () => {
  const originalMode = process.env.OPPI_TELEMETRY_MODE;

  beforeEach(() => {
    process.env.OPPI_TELEMETRY_MODE = "internal";
  });

  afterEach(() => {
    if (originalMode === undefined) {
      delete process.env.OPPI_TELEMETRY_MODE;
    } else {
      process.env.OPPI_TELEMETRY_MODE = originalMode;
    }
  });

  it("accepts and stores sanitized client log batches", async () => {
    const generatedAt = Date.parse("2026-05-25T12:00:00Z");
    const harness = makeHarness({
      generatedAt,
      appVersion: "1.0",
      buildNumber: "34",
      osVersion: "iOS test",
      deviceModel: "iPhone",
      clientKind: "ios",
      appInstanceId: "app-1",
      bootId: "boot-1",
      droppedCount: 2,
      entries: [
        {
          ts: generatedAt + 10,
          seq: 7,
          level: "warning",
          category: "Network",
          message: "request failed Bearer abcdefghi",
          metadata: {
            url: "https://example.test/path?token=secret-token",
            authorization: "plain secret that does not match value regex",
            accessToken: "another plain secret",
            apiKey: "unpatterned-api-key",
            sessionId: "sess-meta",
            ignoredNumber: 42,
          },
          sessionId: "sess-1",
          workspaceId: "ws-1",
        },
      ],
    });

    try {
      const route = createTelemetryRoutes(harness.ctx, harness.helpers);
      const handled = await route({
        method: "POST",
        path: "/telemetry/client-logs",
        url: new URL("http://localhost/telemetry/client-logs"),
        req: {} as IncomingMessage,
        res: {} as ServerResponse,
      });

      expect(handled).toBe(true);
      expect(harness.errors).toEqual([]);
      expect(harness.responses[0]).toMatchObject({
        ok: true,
        accepted: 1,
        droppedCount: 2,
        windowStartMs: generatedAt + 10,
        windowEndMs: generatedAt + 10,
      });

      const path = join(
        harness.dataDir,
        "diagnostics",
        "telemetry",
        "client-logs-2026-05-25.jsonl",
      );
      const record = JSON.parse(readFileSync(path, "utf8").trim()) as Record<string, unknown>;
      expect(record).toMatchObject({
        generatedAt,
        clientKind: "ios",
        appInstanceId: "app-1",
        bootId: "boot-1",
        droppedCount: 2,
        entryCount: 1,
      });

      const entries = record.entries as Array<Record<string, unknown>>;
      expect(entries).toHaveLength(1);
      expect(entries[0]).toMatchObject({
        clientKind: "ios",
        level: "warn",
        category: "Network",
        sessionId: "sess-1",
        workspaceId: "ws-1",
      });
      expect(entries[0].message).toBe("request failed Bearer [REDACTED]");
      expect(entries[0].metadata).toEqual({
        url: "https://example.test/path?token=[REDACTED]",
        authorization: "[REDACTED]",
        accessToken: "[REDACTED]",
        apiKey: "[REDACTED]",
        sessionId: "sess-meta",
      });
    } finally {
      rmSync(harness.dataDir, { recursive: true, force: true });
    }
  });

  it("rejects client log uploads with invalid generatedAt instead of throwing", async () => {
    const harness = makeHarness({
      generatedAt: Number.MAX_VALUE,
      clientKind: "ios",
      appInstanceId: "app-1",
      bootId: "boot-1",
      entries: [
        {
          ts: Date.now(),
          seq: 1,
          level: "warn",
          category: "Network",
          message: "bad timestamp",
        },
      ],
    });

    try {
      const route = createTelemetryRoutes(harness.ctx, harness.helpers);
      const handled = await route({
        method: "POST",
        path: "/telemetry/client-logs",
        url: new URL("http://localhost/telemetry/client-logs"),
        req: {} as IncomingMessage,
        res: {} as ServerResponse,
      });

      expect(handled).toBe(true);
      expect(harness.responses).toEqual([]);
      expect(harness.errors).toEqual([
        { status: 400, message: "entries must be a non-empty array of valid client logs" },
      ]);
    } finally {
      rmSync(harness.dataDir, { recursive: true, force: true });
    }
  });

  it("rejects client log uploads when telemetry is disabled", async () => {
    process.env.OPPI_TELEMETRY_MODE = "off";
    const harness = makeHarness({ entries: [] });

    try {
      const route = createTelemetryRoutes(harness.ctx, harness.helpers);
      const handled = await route({
        method: "POST",
        path: "/telemetry/client-logs",
        url: new URL("http://localhost/telemetry/client-logs"),
        req: {} as IncomingMessage,
        res: {} as ServerResponse,
      });

      expect(handled).toBe(true);
      expect(harness.responses).toEqual([]);
      expect(harness.errors).toEqual([
        { status: 403, message: "telemetry uploads disabled by OPPI_TELEMETRY_MODE" },
      ]);
    } finally {
      rmSync(harness.dataDir, { recursive: true, force: true });
    }
  });
});
