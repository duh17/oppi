import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { MCP_HTTP_SNAPSHOT_FILE, serializeMcpHttpFixture } from "./mcp-protocol-fixtures.js";

it("matches the committed MCP HTTP contract without writing fixtures", () => {
  expect(readFileSync(MCP_HTTP_SNAPSHOT_FILE, "utf8")).toBe(serializeMcpHttpFixture());
});
