import { describe, expect, it } from "vitest";

import {
  httpOpsMetricSamples,
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
  it("uses one gating decision and the same tags for duration and bytes", () => {
    const gated = httpOpsMetricSamples({
      method: "GET",
      pathPattern: "/health",
      statusCode: 200,
      durationMs: 1,
      responseBytes: 12,
    });
    expect(gated).toEqual([]);
    expect(shouldRecordHttpRequestMetric("/health", 200, 1)).toBe(false);

    const recorded = httpOpsMetricSamples({
      method: "GET",
      pathPattern: "/sessions/:sessionId/trace",
      statusCode: 200,
      durationMs: 4,
      responseBytes: 18,
    });
    expect(recorded).toEqual([
      {
        metric: "server.http_request_ms",
        value: 4,
        tags: {
          method: "GET",
          path_pattern: "/sessions/:sessionId/trace",
          status_code: "200",
        },
      },
      {
        metric: "server.http_response_bytes",
        value: 18,
        tags: {
          method: "GET",
          path_pattern: "/sessions/:sessionId/trace",
          status_code: "200",
        },
      },
    ]);
    expect(recorded[0]?.tags).toBe(recorded[1]?.tags);
  });

  it("omits bytes when the count would be garbage, and still records duration", () => {
    const samples = httpOpsMetricSamples({
      method: "GET",
      pathPattern: "/sessions/:id",
      statusCode: 101,
      durationMs: 3,
      responseBytes: undefined,
    });
    expect(samples.map((sample) => sample.metric)).toEqual(["server.http_request_ms"]);
  });

  it("counts bytes actually written, not Content-Length", () => {
    const { req, res } = fakeResponse({ headers: { "content-length": "9999" } });
    const read = observeHttpResponseBody(req, res);
    res.write(Buffer.from("ab"));
    res.end("cd");
    expect(read()).toBe(4);
  });

  it("does not count a WebSocket upgrade or an unfinished event stream", () => {
    const upgrade = fakeResponse({ upgrade: "websocket" });
    const upgradeBytes = observeHttpResponseBody(upgrade.req, upgrade.res);
    upgrade.res.end("not-http");
    expect(upgradeBytes()).toBeUndefined();

    const switching = fakeResponse({ statusCode: 101 });
    const switchingBytes = observeHttpResponseBody(switching.req, switching.res);
    switching.res.end();
    expect(switchingBytes()).toBeUndefined();

    const sse = fakeResponse({ headers: { "content-type": "text/event-stream" } });
    const sseBytes = observeHttpResponseBody(sse.req, sse.res);
    sse.res.write("data: hi\n\n");
    expect(sseBytes()).toBeUndefined();
    sse.res.end();
    expect(sseBytes()).toBe(Buffer.byteLength("data: hi\n\n"));
  });

  it("drops the sample when a chunk size cannot be measured", () => {
    const { req, res } = fakeResponse();
    const read = observeHttpResponseBody(req, res);
    res.write({ not: "bytes" });
    res.end();
    expect(read()).toBeUndefined();
  });
});
