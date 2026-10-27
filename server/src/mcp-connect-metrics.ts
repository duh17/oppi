import type { EventTags } from "./telemetry/catalog.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";

/** Map a Pi MCP connection state to a bounded status and error kind. No error text. */
export function mcpConnectTags(state: string | undefined): EventTags<"server.mcp_connect"> {
  if (state === "connected") return { status: "ok" };
  if (state === "needs-auth") return { status: "error", error_kind: "auth" };
  return { status: "error", error_kind: "connect" };
}

export function recordMcpConnect(
  metrics: ServerTelemetry | undefined,
  input: {
    sessionId: string;
    startedAt: number;
    now?: number;
    state?: string;
    configError?: boolean;
  },
): void {
  const ids = { sessionId: input.sessionId };
  if (input.configError) {
    metrics?.record(
      "server.mcp_connect",
      { duration_ms: 0 },
      { status: "error", error_kind: "config" },
      ids,
    );
    return;
  }
  metrics?.record(
    "server.mcp_connect",
    { duration_ms: Math.max(0, Math.round((input.now ?? Date.now()) - input.startedAt)) },
    mcpConnectTags(input.state),
    ids,
  );
}
