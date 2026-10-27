import { describe, expect, it } from "vitest";

import {
  httpRequestEvent,
  observeHttpResponseBody,
  shouldRecordHttpRequestMetric,
} from "../src/http-request-metrics.js";
import type { IncomingMessage, ServerResponse } from "node:http";

function fakeResponse(init?: {
  statusCode?: number;
  headers?: Record<string, string>;
  upgrade?: string;
}): { req: IncomingMessage; res: ServerResponse; writes: unknown[] } {
  const headers = new Map(Object.entries(init?.headers ?? {}));
  const writes: unknown[] = [];
  const res = {
    statusCode: init?.statusCode ?? 200,
    writableEnded: false,
    getHeader: (name: string) => headers.get(name.toLowerCase()),
    write(chunk: unknown) {
      writes.push(chunk);
      return true;
    },
    end(chunk?: unknown) {
      if (chunk !== undefined && typeof chunk !== "function") writes.push(chunk);
      this.writableEnded = true;
      return this;
    },
  };
  return {
    req: { headers: init?.upgrade ? { upgrade: init.upgrade } : {} } as IncomingMessage,
    res: res as unknown as ServerResponse,
    writes,
  };
}

describe("http response metrics", () => {
  it("gates fast routine routes and records duration and bytes as one event", () => {
    const gated = httpRequestEvent({
      method: "GET",
      pathPattern: "/health",
      statusCode: 200,
      durationMs: 1,
      responseBytes: 12,
    });
    expect(gated).toBeUndefined();
    expect(shouldRecordHttpRequestMetric("/health", 200, 1)).toBe(false);

    const recorded = httpRequestEvent({
      method: "GET",
      pathPattern: "/sessions/:sessionId/trace",
      statusCode: 200,
      durationMs: 4,
      responseBytes: 18,
    });
    expect(recorded).toEqual({
      fields: { duration_ms: 4, response_bytes: 18 },
      tags: {
        method: "GET",
        path_pattern: "/sessions/:sessionId/trace",
        status_code: "200",
      },
    });
  });

  it("omits bytes when the count would be garbage, and still records duration", () => {
    const event = httpRequestEvent({
      method: "GET",
      pathPattern: "/sessions/:id",
      statusCode: 101,
      durationMs: 3,
      responseBytes: undefined,
    });
    expect(event?.fields).toEqual({ duration_ms: 3 });
  });

  it("counts bytes actually written, not Content-Length", () => {
    const { req, res } = fakeResponse({ headers: { "content-length": "9999" } });
    const read = observeHttpResponseBody(req, res);
    res.write(Buffer.from("ab"));
    res.end("cd");
    expect(read()).toBe(4);
  });

  it("does not count a WebSocket upgrade", () => {
    const upgrade = fakeResponse({ upgrade: "websocket" });
    const upgradeBytes = observeHttpResponseBody(upgrade.req, upgrade.res);
    upgrade.res.end("not-http");
    expect(upgradeBytes()).toBeUndefined();

    const switching = fakeResponse({ statusCode: 101 });
    const switchingBytes = observeHttpResponseBody(switching.req, switching.res);
    switching.res.end();
    expect(switchingBytes()).toBeUndefined();
  });

  it("drops the sample when a chunk size cannot be measured", () => {
    const { req, res } = fakeResponse();
    const read = observeHttpResponseBody(req, res);
    res.write({ not: "bytes" });
    res.end();
    expect(read()).toBeUndefined();
  });
});
