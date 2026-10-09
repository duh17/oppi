import type { ServerMetricCollector } from "./server-metric-collector.js";

export type McpConnectStatus = "connected" | "failed" | "error";

/** Map a Pi MCP connection state to a bounded status and reason. No error text. */
export function mcpConnectTags(state: string | undefined): {
  status: McpConnectStatus;
  reason?: string;
} {
  if (state === "connected") return { status: "connected" };
  if (state === "needs-auth") return { status: "failed", reason: "auth" };
  return { status: "failed", reason: "connect" };
}

export function recordMcpConnect(
  metrics: ServerMetricCollector | undefined,
  input: {
    sessionId: string;
    startedAt: number;
    now?: number;
    state?: string;
    configError?: boolean;
  },
): void {
  const tags: Record<string, string> = { sessionId: input.sessionId };
  if (input.configError) {
    tags.status = "error";
    tags.reason = "config";
    metrics?.record("server.mcp_connect_ms", 0, tags);
    return;
  }
  const mapped = mcpConnectTags(input.state);
  tags.status = mapped.status;
  if (mapped.reason) tags.reason = mapped.reason;
  metrics?.record(
    "server.mcp_connect_ms",
    Math.max(0, Math.round((input.now ?? Date.now()) - input.startedAt)),
    tags,
  );
}
