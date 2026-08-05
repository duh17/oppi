import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

function writeSearchableTrace(path: string, text: string): void {
  const timestamp = new Date().toISOString();
  writeFileSync(
    path,
    [
      JSON.stringify({ type: "session", id: randomUUID(), cwd: "/tmp/search-wiring", timestamp }),
      JSON.stringify({
        type: "message",
        id: "wiring-user",
        parentId: null,
        timestamp,
        message: { role: "user", content: [{ type: "text", text }] },
      }),
    ].join("\n") + "\n",
  );
}

async function yieldToEventLoop(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

describe("Server search index wiring", () => {
  it("warms persisted session content after real server startup", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-search-index-startup-"));
    const storage = new Storage(dataDir);
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "disabled" },
    });
    const token = storage.ensurePaired();
    const session = storage.createSession("startup wiring title");
    session.workspaceId = "startup-wiring-workspace";
    const tracePath = join(dataDir, "startup-wiring.jsonl");
    session.piSessionFile = tracePath;
    writeSearchableTrace(tracePath, "startup wiring searchable token");
    storage.saveSession(session);

    const server = new Server(storage);
    try {
      await server.start();
      const searchUrl = `http://127.0.0.1:${server.port}/sessions/search?q=${encodeURIComponent(
        "startup wiring searchable token",
      )}&workspaceId=startup-wiring-workspace&limit=10`;
      let results: Array<{ sessionId: string; workspaceId: string; title: string }> = [];
      for (let attempt = 0; attempt < 20; attempt++) {
        const response = await fetch(searchUrl, {
          headers: { Authorization: `Bearer ${token}` },
        });
        expect(response.status).toBe(200);
        const body = (await response.json()) as {
          results?: Array<{ sessionId: string; workspaceId: string; title: string }>;
        };
        results = body.results ?? [];
        if (results.length > 0) break;
        await yieldToEventLoop();
      }

      expect(results).toMatchObject([
        {
          sessionId: session.id,
          workspaceId: "startup-wiring-workspace",
          title: "startup wiring title",
        },
      ]);
    } finally {
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("wires SessionManager.searchIndex after SearchIndex initialization", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-search-index-wiring-"));
    const storage = new Storage(dataDir);
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "disabled" },
    });

    const server = new Server(storage) as unknown as {
      searchIndex: { close: () => void } | null;
      sessions: { searchIndex: unknown | null };
    };

    try {
      expect(server.searchIndex).toBeTruthy();
      expect(server.sessions.searchIndex).toBe(server.searchIndex);
    } finally {
      server.searchIndex?.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
