import { writeFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import {
  McpToolCache,
  mcpToolCacheKey,
  mcpToolCachePath,
  type McpServerSnapshot,
} from "../src/mcp-tool-cache.js";
import { makeTempDir } from "./harness/temp-dir.js";

const snapshot = (name: string): McpServerSnapshot => ({
  tools: [{ name, inputSchema: { type: "object" } }],
  hasResources: false,
  instructions: undefined,
});

describe("MCP tool cache", () => {
  it("keys a list by name, config, and sandbox, so an edited server reads as never seen", () => {
    const entry = { name: "echo", config: { command: "echo-server" } } as never;
    const key = mcpToolCacheKey(entry, false);
    expect(mcpToolCacheKey(entry, false)).toBe(key);
    expect(mcpToolCacheKey(entry, true)).not.toBe(key);
    expect(
      mcpToolCacheKey({ name: "echo", config: { command: "other" } } as never, false),
    ).not.toBe(key);
  });

  it("returns what was saved, drops malformed entries, and keeps the newest 64", () => {
    const path = mcpToolCachePath(makeTempDir("oppi-mcp-tool-cache-"));
    const cache = new McpToolCache(path);
    expect(cache.load().size).toBe(0);

    writeFileSync(path, "{not json");
    expect(cache.load().size).toBe(0);

    for (let index = 0; index < 66; index++) cache.save(`key-${index}`, snapshot(`tool-${index}`));
    const loaded = cache.load();
    expect(loaded.size).toBe(64);
    expect(loaded.has("key-1")).toBe(false);
    expect(loaded.get("key-65")).toEqual({
      tools: [{ name: "tool-65", inputSchema: { type: "object" } }],
      hasResources: false,
    });

    writeFileSync(
      path,
      JSON.stringify({
        version: 1,
        servers: { good: snapshot("a"), bad: { tools: [{ name: 1 }], hasResources: false } },
      }),
    );
    expect([...cache.load().keys()]).toEqual(["good"]);
  });
});
