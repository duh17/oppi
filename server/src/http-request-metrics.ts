import type { IncomingMessage, ServerResponse } from "node:http";

/**
 * Decide which HTTP requests become server.http_request_ms samples.
 * server.http_response_bytes uses the same decision.
 *
 * Fast successful routine/navigation/poll routes are omitted so they do not
 * dominate ops telemetry. Errors and slow requests still record.
 */

const ROUTINE_HTTP_METRIC_SLOW_MS = 50;

const ROUTINE_HTTP_METRIC_PATTERNS = new Set([
  "/health",
  "/server/info",
  "/server/stats",
  "/workspaces",
  "/skills",
  "/sessions/recent",
  "/sessions/:sessionId/events",
  "/sessions/:sessionId/dialogs",
  "/workspaces/:workspaceId/attention",
  "/workspaces/:workspaceId/paths",
  "/models",
  "/telemetry/chat-metrics",
  "/telemetry/client-logs",
  "/telemetry/metrickit",
]);

export function shouldRecordHttpRequestMetric(
  pathPattern: string,
  statusCode: number,
  durationMs: number,
): boolean {
  if (statusCode >= 400) return true;
  if (durationMs >= ROUTINE_HTTP_METRIC_SLOW_MS) return true;
  return !ROUTINE_HTTP_METRIC_PATTERNS.has(pathPattern);
}

export interface HttpOpsMetricSample {
  metric: "server.http_request_ms" | "server.http_response_bytes";
  value: number;
  tags: Record<string, string>;
}

/** One gating decision for duration and response bytes. Same tags on both. */
export function httpOpsMetricSamples(input: {
  method: string;
  pathPattern: string;
  statusCode: number;
  durationMs: number;
  responseBytes: number | undefined;
}): HttpOpsMetricSample[] {
  if (!shouldRecordHttpRequestMetric(input.pathPattern, input.statusCode, input.durationMs)) {
    return [];
  }
  const tags = {
    method: input.method,
    path_pattern: input.pathPattern,
    status_code: String(input.statusCode),
  };
  const samples: HttpOpsMetricSample[] = [
    { metric: "server.http_request_ms", value: input.durationMs, tags },
  ];
  if (input.responseBytes !== undefined) {
    samples.push({ metric: "server.http_response_bytes", value: input.responseBytes, tags });
  }
  return samples;
}

function chunkByteLength(chunk: unknown, encoding: BufferEncoding | undefined): number | undefined {
  if (chunk === undefined || chunk === null || typeof chunk === "function") return 0;
  if (typeof chunk === "string") return Buffer.byteLength(chunk, encoding);
  if (Buffer.isBuffer(chunk) || chunk instanceof Uint8Array) return chunk.byteLength;
  return undefined;
}

function encodingOf(value: unknown): BufferEncoding | undefined {
  return typeof value === "string" ? (value as BufferEncoding) : undefined;
}

function headerIncludes(value: number | string | string[] | undefined, needle: string): boolean {
  const text = Array.isArray(value) ? value.join(";") : String(value ?? "");
  return text.toLowerCase().includes(needle);
}

function isWebSocketUpgrade(req: IncomingMessage): boolean {
  const upgrade = req.headers.upgrade;
  return typeof upgrade === "string" && upgrade.toLowerCase() === "websocket";
}

/**
 * Count body bytes passed to write/end. Returns undefined when the count would
 * be garbage: WebSocket upgrade, HTTP 101, an unfinished event stream, or a
 * chunk whose size cannot be measured. Does not use socket.bytesWritten or
 * Content-Length.
 */
export function observeHttpResponseBody(
  req: IncomingMessage,
  res: ServerResponse,
): () => number | undefined {
  if (isWebSocketUpgrade(req)) return () => undefined;

  let bytes = 0;
  let unmeasurable = false;
  const add = (chunk: unknown, encoding: BufferEncoding | undefined): void => {
    const length = chunkByteLength(chunk, encoding);
    if (length === undefined) {
      unmeasurable = true;
      return;
    }
    bytes += length;
  };

  const write = res.write.bind(res);
  const end = res.end.bind(res);
  res.write = ((chunk: unknown, encodingOrCb?: unknown, cb?: unknown) => {
    add(chunk, encodingOf(encodingOrCb));
    return write(chunk as never, encodingOrCb as never, cb as never);
  }) as typeof res.write;
  res.end = ((chunk?: unknown, encodingOrCb?: unknown, cb?: unknown) => {
    add(chunk, encodingOf(encodingOrCb));
    return end(chunk as never, encodingOrCb as never, cb as never);
  }) as typeof res.end;

  return () => {
    if (unmeasurable || res.statusCode === 101) return undefined;
    if (headerIncludes(res.getHeader("upgrade"), "websocket")) return undefined;
    if (!Number.isInteger(bytes) || bytes < 0) return undefined;
    return bytes;
  };
}
