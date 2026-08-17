/**
 * Decide which HTTP requests become server.http_request_ms samples.
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
