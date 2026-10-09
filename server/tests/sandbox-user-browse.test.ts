import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createHostFileRoutes } from "../src/routes/host-files.js";
import { createWorkspaceFileRoutes } from "../src/routes/workspace-files.js";
import type { RouteContext } from "../src/routes/types.js";
import { resolveSdkSessionCwd } from "../src/sdk-backend.js";
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
      // A guest path whose leading slash was dropped still maps onto the mount.
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
    async function dispatchWorkspace(
      workspace: Workspace,
      method: string,
      path: string,
      search = "",
    ) {
      const dispatch = createWorkspaceFileRoutes(
        {
          storage: {
            getWorkspace: (workspaceId: string) =>
              workspaceId === workspace.id ? workspace : undefined,
            getDataDir: () => workspace.hostMount ?? "",
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();
      const handled = await dispatch({
        method,
        path,
        url: new URL(`http://localhost${path}${search}`),
        req: { headers: {} } as never,
        res: res as never,
      });
      return { handled, res };
    }

    /** `/files/current` read for a workspace or session origin over the same storage. */
    async function readCurrentFile(
      workspace: Workspace,
      params: Record<string, string>,
      options: { method?: string; session?: Session } = {},
    ) {
      const dispatch = createHostFileRoutes(
        {
          storage: {
            getWorkspace: (workspaceId: string) =>
              workspaceId === workspace.id ? workspace : undefined,
            getSession: (sessionId: string) =>
              options.session?.id === sessionId ? options.session : undefined,
            getDataDir: () => workspace.hostMount ?? "",
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const url = new URL(`http://localhost/files/current?${new URLSearchParams(params)}`);
      const res = makeResponse();
      const handled = await dispatch({
        method: options.method ?? "HEAD",
        path: url.pathname,
        url,
        req: { headers: {} } as never,
        res: res as never,
      });
      return { handled, res };
    }

    it("opens a guest file and lists a guest directory from the host mount", async () => {
      const { workspace, guestFile, guestDir } = seedSandboxMount();

      const file = await readCurrentFile(workspace, {
        origin: "workspace",
        workspaceId: workspace.id,
        path: guestFile,
      });
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

    it("serves an empty-folder sandbox from its persisted ~/sandbox/<slug> folder when worktree id is main", async () => {
      const name = `wiki-main-${Date.now()}`;
      const slug = name
        .toLowerCase()
        .replace(/[^a-z0-9-_]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "");
      const workspace = makeWorkspace(`~/sandbox/${slug}`, {
        id: "ws-mountless",
        name,
      });
      const home = tempDir("oppi-sandbox-browse-home-");
      const previousHome = process.env.HOME;
      try {
        process.env.HOME = home;
        writeFileSync(join(home, "owner-only.txt"), "owner home\n");
        const backing = resolveSdkSessionCwd(workspace);
        writeFileSync(join(backing, "demo-tool-rendering-prompt.md"), "sandbox note\n");

        const listing = await dispatchWorkspace(
          workspace,
          "GET",
          `/workspaces/${workspace.id}/contents/`,
          "?worktreeId=main",
        );
        expect(listing.handled).toBe(true);
        expect(listing.res.statusCode).toBe(200);
        const body = JSON.parse(listing.res.body) as { entries: Array<{ name: string }> };
        expect(body.entries.map((entry) => entry.name)).toContain("demo-tool-rendering-prompt.md");

        const file = await readCurrentFile(workspace, {
          origin: "workspace",
          workspaceId: workspace.id,
          worktreeId: "main",
          path: "demo-tool-rendering-prompt.md",
        });
        expect(file.handled).toBe(true);
        expect(file.res.statusCode).toBe(200);
        expect(file.res.headers["Content-Length"]).toBe("13");

        const otherId = await dispatchWorkspace(
          workspace,
          "GET",
          `/workspaces/${workspace.id}/contents/`,
          "?worktreeId=not-a-worktree",
        );
        expect(otherId.handled).toBe(true);
        expect(otherId.res.statusCode).toBe(200);
        const otherNames = (
          JSON.parse(otherId.res.body) as { entries: Array<{ name: string }> }
        ).entries.map((entry) => entry.name);
        expect(otherNames).toContain("demo-tool-rendering-prompt.md");
        expect(otherNames).not.toContain("owner-only.txt");
      } finally {
        if (previousHome === undefined) delete process.env.HOME;
        else process.env.HOME = previousHome;
      }
    });

    it("keeps a mounted sandbox main id on the host mount", async () => {
      const name = `wiki-mounted-${Date.now()}`;
      const slug = name
        .toLowerCase()
        .replace(/[^a-z0-9-_]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "");
      tempDirs.push(join(homedir(), "sandbox", slug));
      const hostMount = tempDir("oppi-sandbox-mounted-");
      writeFileSync(join(hostMount, "only-on-host-mount.txt"), "mounted\n");
      const workspace = makeWorkspace(hostMount, { id: "ws-mounted", name });

      const listing = await dispatchWorkspace(
        workspace,
        "GET",
        `/workspaces/${workspace.id}/contents/`,
        "?worktreeId=main",
      );
      expect(listing.handled).toBe(true);
      expect(listing.res.statusCode).toBe(200);
      const body = JSON.parse(listing.res.body) as { entries: Array<{ name: string }> };
      expect(body.entries.map((entry) => entry.name)).toContain("only-on-host-mount.txt");
    });

    it("does not treat a mountless host workspace main id as the user home", async () => {
      const workspace = makeWorkspace("/tmp/unused-mountless-host", {
        id: "ws-host-mountless",
        name: "mountless-host",
        runtime: "host",
        hostMount: undefined,
      });

      const listing = await dispatchWorkspace(
        workspace,
        "GET",
        `/workspaces/${workspace.id}/contents/`,
        "?worktreeId=main",
      );
      expect(listing.handled).toBe(true);
      expect(listing.res.statusCode).toBe(404);
      expect(JSON.parse(listing.res.body)).toEqual({ error: "Worktree not found" });
    });

    it("does not follow file or directory symlinks out of the sandbox mount", async () => {
      const { hostMount, workspace } = seedSandboxMount();
      const outside = tempDir("oppi-sandbox-outside-");
      writeFileSync(join(outside, "secret.txt"), "host-secret");
      symlinkSync(join(outside, "secret.txt"), join(hostMount, "escape.txt"));
      symlinkSync(outside, join(hostMount, "escape-dir"));
      writeFileSync(join(hostMount, "inside.txt"), "inside");
      symlinkSync("inside.txt", join(hostMount, "inside-alias.txt"));

      for (const requestedPath of [
        "escape.txt",
        "escape-dir/secret.txt",
        "/workspace/deep-research/escape.txt",
        "/workspace/deep-research/escape-dir/secret.txt",
      ]) {
        const file = await readCurrentFile(workspace, {
          origin: "workspace",
          workspaceId: workspace.id,
          path: requestedPath,
        });
        expect(file.handled).toBe(true);
        expect({ path: requestedPath, status: file.res.statusCode }).toEqual({
          path: requestedPath,
          status: 403,
        });
      }

      for (const requestedPath of ["escape-dir", "/workspace/deep-research/escape-dir"]) {
        const listing = await dispatchWorkspace(
          workspace,
          "GET",
          `/workspaces/${workspace.id}/contents/${encodeURIComponent(requestedPath)}`,
        );
        expect(listing.handled).toBe(true);
        expect({ path: requestedPath, status: listing.res.statusCode }).toEqual({
          path: requestedPath,
          status: 404,
        });
        expect(listing.res.body).not.toContain("secret.txt");
      }

      // An in-mount symlink keeps working.
      const alias = await readCurrentFile(workspace, {
        origin: "workspace",
        workspaceId: workspace.id,
        path: "inside-alias.txt",
      });
      expect(alias.res.statusCode).toBe(200);
      expect(alias.res.headers["Content-Length"]).toBe("6");
    });

    it("rejects /etc/passwd, tilde paths, and a different workspace slug", async () => {
      const { workspace } = seedSandboxMount();

      for (const requestedPath of [
        "/etc/passwd",
        "~/secret.txt",
        "/workspace/other-project/reports/foo.png",
      ]) {
        const result = await readCurrentFile(workspace, {
          origin: "workspace",
          workspaceId: workspace.id,
          path: requestedPath,
        });
        expect(result.handled).toBe(true);
        expect({ path: requestedPath, status: result.res.statusCode }).toEqual({
          path: requestedPath,
          status: 403,
        });
      }
    });
  });

  describe("session-origin current-file reads", () => {
    async function readSessionFile(workspace: Workspace, session: Session, path: string) {
      const dispatch = createHostFileRoutes(
        {
          storage: {
            getWorkspace: () => workspace,
            getSession: (sessionId: string) => (sessionId === session.id ? session : undefined),
            getDataDir: () => tempDir("oppi-sandbox-session-data-"),
          },
        } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const url = new URL(
        `http://localhost/files/current?${new URLSearchParams({ origin: "session", sessionId: session.id, path })}`,
      );
      const res = makeResponse();
      await dispatch({
        method: "HEAD",
        path: url.pathname,
        url,
        req: { headers: {} } as never,
        res: res as never,
      });
      return res;
    }

    it("maps a guest path for a session and for a child Agent session in the same sandbox workspace", async () => {
      const { workspace, guestFile } = seedSandboxMount();
      const child = makeSession({
        id: "sess-child",
        launch: { source: "agent", parentSessionId: "sess-parent" },
      });

      for (const session of [makeSession(), child]) {
        const res = await readSessionFile(workspace, session, guestFile);
        expect(res.statusCode).toBe(200);
        expect(res.headers["Content-Length"]).toBe("9");
      }
    });

    it("rejects /etc/passwd, tilde paths, and a different workspace slug", async () => {
      const { workspace } = seedSandboxMount();
      const session = makeSession();

      for (const path of [
        "/etc/passwd",
        "~/secret.txt",
        "/workspace/other-project/reports/foo.png",
      ]) {
        const res = await readSessionFile(workspace, session, path);
        expect({ path, status: res.statusCode }).toEqual({ path, status: 403 });
      }
    });
  });
});
