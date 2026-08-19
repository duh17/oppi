import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import type { RouteContext } from "../src/routes/types.js";
import { SessionTraceService, type SessionTraceServiceDeps } from "../src/session-trace-service.js";
import type { Session, Workspace } from "../src/types.js";
import { resolveWorkspaceUserPath } from "../src/workspace-user-path.js";
import { makeResponse } from "./harness/route-test-helpers.js";

function makeWorkspace(hostMount: string, overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-sandbox",
    name: "deep-research",
    runtime: "sandbox",
    hostMount,
    createdAt: 1,
    updatedAt: 1,
    ...overrides,
  } as Workspace;
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-parent",
    workspaceId: "ws-sandbox",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeTraceService(dataDir: string, workspace: Workspace): SessionTraceService {
  const deps: SessionTraceServiceDeps = {
    storage: {
      getDataDir: vi.fn(() => dataDir),
      getSession: vi.fn(() => undefined),
      getWorkspace: vi.fn(() => workspace),
    },
    sessionRuntimes: {
      refreshSessionState: vi.fn(async () => null),
      getToolFullOutputPath: vi.fn(() => null),
    },
    ensureSessionContextWindow: vi.fn((session) => session),
  };
  return new SessionTraceService(deps);
}

describe("sandbox user browse of host-mount artifacts", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  function tempDir(prefix: string): string {
    const dir = mkdtempSync(join(tmpdir(), prefix));
    tempDirs.push(dir);
    return dir;
  }

  function seedSandboxMount(): {
    hostMount: string;
    workspace: Workspace;
    guestFile: string;
    guestDir: string;
    hostFile: string;
    hostDir: string;
  } {
    const hostMount = tempDir("oppi-sandbox-browse-");
    mkdirSync(join(hostMount, "reports"), { recursive: true });
    const hostFile = join(hostMount, "reports", "foo.png");
    writeFileSync(hostFile, "png-bytes");
    writeFileSync(join(hostMount, "notes.txt"), "notes\n");
    return {
      hostMount,
      workspace: makeWorkspace(hostMount),
      guestFile: "/workspace/deep-research/reports/foo.png",
      guestDir: "/workspace/deep-research/reports",
      hostFile,
      hostDir: join(hostMount, "reports"),
    };
  }

  describe("resolveWorkspaceUserPath", () => {
    it("maps a guest file and guest directory onto the host mount", () => {
      const { hostMount, workspace, guestFile, guestDir, hostFile, hostDir } = seedSandboxMount();

      expect(resolveWorkspaceUserPath({ workspace, requestedPath: guestFile })).toBe(
        resolve(hostFile),
      );
      expect(resolveWorkspaceUserPath({ workspace, requestedPath: guestDir })).toBe(
        resolve(hostDir),
      );
      expect(resolveWorkspaceUserPath({ workspace, requestedPath: "reports/foo.png" })).toBe(
        resolve(hostFile),
      );
      // Session-raw URL path segments drop the leading slash:
      // /raw/%2Fworkspace/... → pathname capture "workspace/<slug>/...".
      expect(
        resolveWorkspaceUserPath({
          workspace,
          requestedPath: "workspace/deep-research/reports/foo.png",
        }),
      ).toBe(resolve(hostFile));
    });

    it("rejects /etc/passwd, tilde paths, host-home, and a different workspace slug", () => {
      const { workspace } = seedSandboxMount();

      expect(resolveWorkspaceUserPath({ workspace, requestedPath: "/etc/passwd" })).toBeNull();
      expect(resolveWorkspaceUserPath({ workspace, requestedPath: "~/secret.txt" })).toBeNull();
      expect(resolveWorkspaceUserPath({ workspace, requestedPath: "~" })).toBeNull();
      expect(
        resolveWorkspaceUserPath({
          workspace,
          requestedPath: join(homedir(), "secret.txt"),
        }),
      ).toBeNull();
      expect(
        resolveWorkspaceUserPath({
          workspace,
          requestedPath: "/workspace/other-project/reports/foo.png",
        }),
      ).toBeNull();
    });

    it("uses the same mapping for a second session in the same sandbox workspace", () => {
      const { workspace, guestFile, hostFile } = seedSandboxMount();
      const parent = makeSession();
      const child = makeSession({
        id: "sess-child",
        launch: { source: "agent", parentSessionId: parent.id },
      });

      expect(
        resolveWorkspaceUserPath({ workspace, requestedPath: guestFile, session: parent }),
      ).toBe(resolve(hostFile));
      expect(
        resolveWorkspaceUserPath({ workspace, requestedPath: guestFile, session: child }),
      ).toBe(resolveWorkspaceUserPath({ workspace, requestedPath: guestFile, session: parent }));
    });
  });

  describe("workspace browse, directory list, and file index", () => {
    async function dispatchWorkspace(workspace: Workspace, method: string, path: string) {
      const dispatch = createWorkspaceFileRoutes(
        {
          storage: {
            getWorkspace: (workspaceId: string) =>
              workspaceId === workspace.id ? workspace : undefined,
            getDataDir: () => workspace.hostMount,
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();
      const handled = await dispatch({
        method,
        path,
        url: new URL(`http://localhost${path}`),
        req: { headers: {} } as never,
        res: res as never,
      });
      return { handled, res };
    }

    it("opens a guest file and lists a guest directory from the host mount", async () => {
      const { workspace, guestFile, guestDir } = seedSandboxMount();

      const file = await dispatchWorkspace(
        workspace,
        "HEAD",
        `/workspaces/${workspace.id}/raw/${encodeURIComponent(guestFile)}`,
      );
      expect(file.handled).toBe(true);
      expect(file.res.statusCode).toBe(200);
      expect(file.res.headers["Content-Length"]).toBe("9");

      const listing = await dispatchWorkspace(
        workspace,
        "GET",
        `/workspaces/${workspace.id}/contents/${encodeURIComponent(guestDir)}`,
      );
      expect(listing.handled).toBe(true);
      expect(listing.res.statusCode).toBe(200);
      const body = JSON.parse(listing.res.body) as { entries: Array<{ name: string }> };
      expect(body.entries.map((entry) => entry.name)).toContain("foo.png");
    });

    it("indexes sandbox artifacts from the host mount", async () => {
      const { workspace } = seedSandboxMount();

      const index = await dispatchWorkspace(workspace, "GET", `/workspaces/${workspace.id}/paths`);
      expect(index.handled).toBe(true);
      expect(index.res.statusCode).toBe(200);
      const body = JSON.parse(index.res.body) as { paths: string[] };
      expect(body.paths).toEqual(expect.arrayContaining(["notes.txt", "reports/foo.png"]));
    });

    it("rejects /etc/passwd, tilde paths, and a different workspace slug", async () => {
      const { workspace } = seedSandboxMount();

      for (const requestedPath of [
        "/etc/passwd",
        "~/secret.txt",
        "/workspace/other-project/reports/foo.png",
      ]) {
        const result = await dispatchWorkspace(
          workspace,
          "HEAD",
          `/workspaces/${workspace.id}/raw/${encodeURIComponent(requestedPath)}`,
        );
        expect(result.handled).toBe(true);
        expect(result.res.statusCode).toBe(404);
      }
    });
  });

  describe("getSessionRawFile", () => {
    it("succeeds for a guest path that exists on the host mount", async () => {
      const dataDir = tempDir("oppi-sandbox-raw-data-");
      const { workspace, guestFile, hostFile } = seedSandboxMount();
      const service = makeTraceService(dataDir, workspace);

      await expect(
        service.getSessionRawFile({
          workspace,
          session: makeSession(),
          path: guestFile,
        }),
      ).resolves.toMatchObject({
        kind: "ok",
        filePath: realpathSync(hostFile),
        size: 9,
      });
    });

    it("succeeds for a slash-stripped guest path from a session-raw URL", async () => {
      const dataDir = tempDir("oppi-sandbox-raw-stripped-");
      const { workspace, hostFile } = seedSandboxMount();
      const service = makeTraceService(dataDir, workspace);

      await expect(
        service.getSessionRawFile({
          workspace,
          session: makeSession(),
          path: "workspace/deep-research/reports/foo.png",
        }),
      ).resolves.toMatchObject({
        kind: "ok",
        filePath: realpathSync(hostFile),
        size: 9,
      });
    });

    it("uses the same mapping for a child Agent session in the same sandbox workspace", async () => {
      const dataDir = tempDir("oppi-sandbox-raw-child-");
      const { workspace, guestFile, hostFile } = seedSandboxMount();
      const service = makeTraceService(dataDir, workspace);
      const child = makeSession({
        id: "sess-child",
        launch: { source: "agent", parentSessionId: "sess-parent" },
      });

      await expect(
        service.getSessionRawFile({ workspace, session: child, path: guestFile }),
      ).resolves.toMatchObject({
        kind: "ok",
        filePath: realpathSync(hostFile),
        size: 9,
      });
    });

    it("rejects /etc/passwd, tilde paths, and a different workspace slug", async () => {
      const dataDir = tempDir("oppi-sandbox-raw-reject-");
      const { workspace } = seedSandboxMount();
      const service = makeTraceService(dataDir, workspace);
      const session = makeSession();

      await expect(
        service.getSessionRawFile({ workspace, session, path: "/etc/passwd" }),
      ).resolves.toEqual({ kind: "path-outside-workspace" });
      await expect(
        service.getSessionRawFile({ workspace, session, path: "~/secret.txt" }),
      ).resolves.toEqual({ kind: "path-outside-workspace" });
      await expect(
        service.getSessionRawFile({
          workspace,
          session,
          path: "/workspace/other-project/reports/foo.png",
        }),
      ).resolves.toEqual({ kind: "path-outside-workspace" });
    });
  });
});
