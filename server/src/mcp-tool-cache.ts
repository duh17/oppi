import { createHash } from "node:crypto";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { McpServerEntry } from "@earendil-works/pi-coding-agent";
import { isRecord } from "./json-shape.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { McpTool } from "./pi-mcp-internals.js";
import { writeFileAtomic } from "./storage/atomic-file.js";

const log = createLogger({ base: { component: "mcp_tool_cache" } });

const CACHE_VERSION = 1;
/** Entries kept, oldest write first out: one per distinct server config ever connected. */
const MAX_ENTRIES = 64;

/** What a server's connection reports that the session's tools, resource tools, and section need. */
export interface McpServerSnapshot {
  /** The server's tool objects as it listed them. */
  tools: McpTool[];
  hasResources: boolean;
  instructions: string | undefined;
}

export function mcpToolCachePath(dataDir: string): string {
  return join(dataDir, "mcp-tool-cache.json");
}

/**
 * Identity of a cached list: the server's name and config, and whether it runs in a sandbox
 * VM. A changed config reads as a server never seen, so a stale list never outlives an edit.
 */
export function mcpToolCacheKey(entry: McpServerEntry, sandbox: boolean): string {
  return createHash("sha256")
    .update(JSON.stringify([entry.name, entry.config, sandbox]))
    .digest("hex");
}

function isSnapshot(value: unknown): value is McpServerSnapshot {
  return (
    isRecord(value) &&
    typeof value.hasResources === "boolean" &&
    (value.instructions === undefined || typeof value.instructions === "string") &&
    Array.isArray(value.tools) &&
    value.tools.every(
      (tool) => isRecord(tool) && typeof tool.name === "string" && isRecord(tool.inputSchema),
    )
  );
}

/**
 * The last tool list each MCP server reported, in a file in the data directory. A durable
 * session builds a codemode-only server's tools, and codemode's type declarations, from here and
 * connects the server at its first call instead of at session start. Best effort: an unreadable
 * file is an empty cache and a failed write costs one more connect, never a session.
 */
export class McpToolCache {
  constructor(private readonly path: string) {}

  /** Entries by key; read per call, as sessions of one server share the file. */
  load(): Map<string, McpServerSnapshot> {
    const entries = new Map<string, McpServerSnapshot>();
    try {
      const parsed: unknown = JSON.parse(readFileSync(this.path, "utf8"));
      if (isRecord(parsed) && parsed.version === CACHE_VERSION && isRecord(parsed.servers))
        for (const [key, value] of Object.entries(parsed.servers))
          if (isSnapshot(value)) entries.set(key, value);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT")
        log.warn("mcp_tool_cache.unreadable", { error: safeErrorMessage(error) });
    }
    return entries;
  }

  save(key: string, snapshot: McpServerSnapshot): void {
    try {
      const entries = this.load();
      // Re-insert so the entry just written is the newest.
      entries.delete(key);
      entries.set(key, snapshot);
      const kept = [...entries].slice(-MAX_ENTRIES);
      mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
      writeFileAtomic(
        this.path,
        `${JSON.stringify({ version: CACHE_VERSION, servers: Object.fromEntries(kept) })}\n`,
        { durable: false },
      );
    } catch (error) {
      log.warn("mcp_tool_cache.write_failed", { error: safeErrorMessage(error) });
    }
  }
}
