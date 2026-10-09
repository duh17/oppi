import { describe, expect, it } from "vitest";

import { mcpConnectTags } from "../src/mcp-connect-metrics.js";

describe("MCP connect metrics", () => {
  it("maps connection state to bounded status and reason", () => {
    expect(mcpConnectTags("connected")).toEqual({ status: "connected" });
    expect(mcpConnectTags("needs-auth")).toEqual({ status: "failed", reason: "auth" });
    expect(mcpConnectTags("failed")).toEqual({ status: "failed", reason: "connect" });
    expect(mcpConnectTags(undefined)).toEqual({ status: "failed", reason: "connect" });
  });
});
