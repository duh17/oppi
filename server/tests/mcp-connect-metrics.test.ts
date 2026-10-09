import { describe, expect, it } from "vitest";

import { mcpConnectTags, recordMcpConnect } from "../src/mcp-connect-metrics.js";
import type { ServerMetricCollector } from "../src/server-metric-collector.js";

describe("MCP connect metrics", () => {
  it("maps connection state to bounded status and reason", () => {
    expect(mcpConnectTags("connected")).toEqual({ status: "connected" });
    expect(mcpConnectTags("needs-auth")).toEqual({ status: "failed", reason: "auth" });
    expect(mcpConnectTags("failed")).toEqual({ status: "failed", reason: "connect" });
    expect(mcpConnectTags(undefined)).toEqual({ status: "failed", reason: "connect" });
  });

  it("records connect latency without server names or error text", () => {
    const samples: Array<{ metric: string; value: number; tags?: Record<string, string> }> = [];
    const metrics = {
      record(metric: string, value: number, tags?: Record<string, string>) {
        samples.push({ metric, value, tags });
      },
    } as unknown as ServerMetricCollector;

    recordMcpConnect(metrics, {
      sessionId: "sess-1",
      startedAt: 100,
      now: 340,
      state: "failed",
    });
    recordMcpConnect(metrics, {
      sessionId: "sess-1",
      startedAt: 100,
      configError: true,
    });

    expect(samples).toEqual([
      {
        metric: "server.mcp_connect_ms",
        value: 240,
        tags: { sessionId: "sess-1", status: "failed", reason: "connect" },
      },
      {
        metric: "server.mcp_connect_ms",
        value: 0,
        tags: { sessionId: "sess-1", status: "error", reason: "config" },
      },
    ]);
    expect(JSON.stringify(samples)).not.toContain("mcp.example");
  });
});
