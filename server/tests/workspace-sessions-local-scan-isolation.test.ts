/**
 * Regression: workspace session list must not depend on the developer home
 * Pi sessions tree. Vitest setup points OPPI_LOCAL_SESSIONS_ROOT at a temp
 * root; this HTTP check proves the endpoint stays green under that isolation.
 */
import { describe, expect, it } from "vitest";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";

describe("workspace sessions local scan isolation", () => {
  it("GET /workspaces/:id/sessions uses the isolated Pi sessions root and returns empty sections", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-ws-sessions-isolation-data-"));
    const mountDir = mkdtempSync(join(tmpdir(), "oppi-ws-sessions-isolation-mount-"));
    const storage = new Storage(dataDir);
    storage.updateConfig({
      port: 0,
      host: "127.0.0.1",
      tls: { mode: "disabled" },
    });
    const token = storage.ensurePaired();
    const server = new Server(storage);

    try {
      // Guardrail: workers must not point at ~/.pi/agent/sessions.
      const root = realpathSync(getPiSessionsRoot());
      const homeRoot = resolve(join(homedir(), ".pi", "agent", "sessions"));
      const tempRoot = realpathSync(tmpdir());
      expect(root).not.toBe(homeRoot);
      expect(root === tempRoot || root.startsWith(`${tempRoot}/`)).toBe(true);

      await server.start();
      const baseUrl = `http://127.0.0.1:${server.port}`;
      const workspace = storage.createWorkspace({
        name: "isolated-sessions",
        hostMount: mountDir,
      });

      const res = await fetch(
        `${baseUrl}/workspaces/${workspace.id}/sessions?status=active,stopped&sinceMs=0&untilMs=${Date.now()}`,
        { headers: { Authorization: `Bearer ${token}` } },
      );
      expect(res.status).toBe(200);
      const body = (await res.json()) as {
        workspaceId: string;
        active: unknown[];
        stopped: unknown[];
      };
      expect(body.workspaceId).toBe(workspace.id);
      expect(body.active).toEqual([]);
      expect(body.stopped).toEqual([]);
    } finally {
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
      rmSync(mountDir, { recursive: true, force: true });
    }
  });
});
