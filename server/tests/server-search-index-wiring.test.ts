import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

describe("Server search index wiring", () => {
  it("wires SessionManager.searchIndex after SearchIndex initialization", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-search-index-wiring-"));
    const storage = new Storage(dataDir);
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "disabled" },
    });

    const server = new Server(storage) as unknown as {
      searchIndex?: unknown;
      sessions: { searchIndex: unknown | null };
    };

    try {
      expect(server.searchIndex).toBeTruthy();
      expect(server.sessions.searchIndex).toBe(server.searchIndex);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
