import { describe, expect, it } from "vitest";

import { mcpConnectTags } from "../src/mcp-connect-metrics.js";

describe("MCP connect metrics", () => {
  it("maps connection state to bounded status and error kind", () => {
    expect(mcpConnectTags("connected")).toEqual({ status: "ok" });
    expect(mcpConnectTags("needs-auth")).toEqual({ status: "error", error_kind: "auth" });
    expect(mcpConnectTags("failed")).toEqual({ status: "error", error_kind: "connect" });
    expect(mcpConnectTags(undefined)).toEqual({ status: "error", error_kind: "connect" });
  });
});
