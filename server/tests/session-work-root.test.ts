import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  attachmentWorkRoot,
  sessionWorkRoot,
  workspaceMountRoot,
  type SessionWorkRootStore,
} from "../src/session-work-root.js";
import type { Session, Workspace } from "../src/types.js";
import { createWorkspaceWorktree, WorkspaceWorktreeError } from "../src/worktrees.js";

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `oppi-work-root-${label}-`));
  dirs.push(dir);
  return dir;
}

function workspaceAt(hostMount: string, overrides: Partial<Workspace> = {}): Workspace {
  return { id: "ws-1", name: "Workspace", hostMount, runtime: "host", ...overrides } as Workspace;
}

function storeOf(dataDir: string, ...workspaces: Workspace[]): SessionWorkRootStore {
  return {
    getWorkspace: (id) => workspaces.find((workspace) => workspace.id === id),
    getDataDir: () => dataDir,
  };
}

function sessionOf(overrides: Partial<Session> = {}): Session {
  return { id: "sess-1", workspaceId: "ws-1", ...overrides } as Session;
}

const declaredControl = { control: { domain: "agents", intent: "create" } } as const;

describe("sessionWorkRoot", () => {
  describe("workspace sessions", () => {
    it("resolves the host mount and returns the workspace", async () => {
      const mount = tempDir("host");
      const workspace = workspaceAt(mount);
      const result = await sessionWorkRoot(sessionOf(), storeOf(tempDir("data"), workspace), {
        create: false,
      });
      expect(result).toEqual({ kind: "ok", root: mount, workspace });
    });

    it("reports a missing host mount without creating it when create is false", async () => {
      const mount = join(tempDir("host"), "not-there");
      const result = await sessionWorkRoot(
        sessionOf(),
        storeOf(tempDir("data"), workspaceAt(mount)),
        { create: false },
      );
      expect(result).toEqual({ kind: "root-missing" });
      expect(existsSync(mount)).toBe(false);
    });

    it("creates only a sandbox's backing folder, and only when asked", async () => {
      const mount = join(tempDir("sandbox"), "backing");
      const workspace = workspaceAt(mount, { runtime: "sandbox" });
      const store = storeOf(tempDir("data"), workspace);

      expect(await sessionWorkRoot(sessionOf(), store, { create: false })).toEqual({
        kind: "root-missing",
      });
      expect(existsSync(mount)).toBe(false);

      expect(await sessionWorkRoot(sessionOf(), store, { create: true })).toEqual({
        kind: "ok",
        root: mount,
        workspace,
      });
      expect(lstatSync(mount).isDirectory()).toBe(true);
    });

    it("does not create a missing host mount even when create is true", async () => {
      const mount = join(tempDir("host"), "not-there");
      const result = await sessionWorkRoot(
        sessionOf(),
        storeOf(tempDir("data"), workspaceAt(mount)),
        { create: true },
      );
      expect(result).toMatchObject({ kind: "ok", root: mount });
      expect(existsSync(mount)).toBe(false);
    });

    it("ignores a worktreeId for a sandbox workspace", async () => {
      const mount = tempDir("sandbox");
      const workspace = workspaceAt(mount, { runtime: "sandbox" });
      const result = await sessionWorkRoot(
        sessionOf({ worktreeId: "wt_anything" }),
        storeOf(tempDir("data"), workspace),
        { create: false },
      );
      expect(result).toMatchObject({ kind: "ok", root: mount });
    });

    it("reports a session whose workspace row is gone", async () => {
      const result = await sessionWorkRoot(sessionOf(), storeOf(tempDir("data")), {
        create: false,
      });
      expect(result).toEqual({ kind: "workspace-missing" });
    });

    it("resolves a host worktree, and reports a removed one with the legacy error", async () => {
      const repo = tempDir("repo");
      const git = (...args: string[]): string =>
        execFileSync("git", args, { cwd: repo, encoding: "utf8" }).trim();
      git("init", "-b", "main");
      git("config", "user.email", "t@example.com");
      git("config", "user.name", "T");
      git("commit", "--allow-empty", "-m", "init");
      const workspace = workspaceAt(repo);
      const dataDir = tempDir("data");
      const created = await createWorkspaceWorktree(
        workspace,
        { branch: "feature/x" },
        { dataDir },
      );
      const store = storeOf(dataDir, workspace);

      expect(
        await sessionWorkRoot(sessionOf({ worktreeId: created.id }), store, { create: false }),
      ).toEqual({ kind: "ok", root: created.path, workspace });

      const missing = await sessionWorkRoot(sessionOf({ worktreeId: "wt_removed" }), store, {
        create: false,
      });
      if (missing.kind !== "worktree-unavailable") throw new Error(`got ${missing.kind}`);
      expect(missing.error).toBeInstanceOf(WorkspaceWorktreeError);
      expect(missing.error.statusCode).toBe(409);
      expect(missing.error.message).toBe("Session worktree is no longer available");
    });
  });

  describe("control-route sessions", () => {
    it("resolves the declared Pi Control directory without a workspace", async () => {
      const dataDir = tempDir("data");
      const result = await sessionWorkRoot(
        sessionOf({ workspaceId: undefined, ...declaredControl }),
        storeOf(dataDir),
        { create: true },
      );
      const root = join(dataDir, "control-sessions", "cwd");
      expect(result).toEqual({ kind: "ok", root });
      expect(lstatSync(root).mode & 0o777).toBe(0o700);
      expect(lstatSync(join(dataDir, "control-sessions")).mode & 0o777).toBe(0o700);
    });

    it("resolves the durable control conversation directory", async () => {
      const dataDir = tempDir("data");
      const result = await sessionWorkRoot(
        sessionOf({ workspaceId: undefined, serverDurable: { role: "control" } }),
        storeOf(dataDir),
        { create: true },
      );
      const root = join(dataDir, "control-conversation", "cwd");
      expect(result).toEqual({ kind: "ok", root });
      expect(lstatSync(root).mode & 0o777).toBe(0o700);
    });

    it("never creates control directories when create is false", async () => {
      const dataDir = tempDir("data");
      const store = storeOf(dataDir);
      for (const session of [
        sessionOf({ workspaceId: undefined, ...declaredControl }),
        sessionOf({ workspaceId: undefined, serverDurable: { role: "control" } }),
      ]) {
        expect(await sessionWorkRoot(session, store, { create: false })).toEqual({
          kind: "root-missing",
        });
      }
      expect(existsSync(join(dataDir, "control-sessions"))).toBe(false);
      expect(existsSync(join(dataDir, "control-conversation"))).toBe(false);
    });

    it("finds an existing control directory without changing it", async () => {
      const dataDir = tempDir("data");
      const root = join(dataDir, "control-sessions", "cwd");
      mkdirSync(root, { recursive: true });
      const result = await sessionWorkRoot(
        sessionOf({ workspaceId: undefined, ...declaredControl }),
        storeOf(dataDir),
        { create: false },
      );
      expect(result).toEqual({ kind: "ok", root });
    });

    it("refuses a symlinked control parent or cwd and never follows it", async () => {
      const dataDir = tempDir("data");
      const outside = tempDir("outside");
      symlinkSync(outside, join(dataDir, "control-sessions"));
      const session = sessionOf({ workspaceId: undefined, ...declaredControl });

      for (const create of [false, true]) {
        expect(await sessionWorkRoot(session, storeOf(dataDir), { create })).toEqual({
          kind: "invalid-root",
          message: "Control session cwd parent must be a real directory",
        });
      }
      expect(existsSync(join(outside, "cwd"))).toBe(false);

      const conversationData = tempDir("data");
      mkdirSync(join(conversationData, "control-conversation"));
      symlinkSync(outside, join(conversationData, "control-conversation", "cwd"));
      expect(
        await sessionWorkRoot(
          sessionOf({ workspaceId: undefined, serverDurable: { role: "control" } }),
          storeOf(conversationData),
          { create: false },
        ),
      ).toEqual({
        kind: "invalid-root",
        message: "Control conversation cwd must be a real directory",
      });
    });
  });

  it("has no directory for a workspace-less session that is not a control route", async () => {
    const result = await sessionWorkRoot(
      sessionOf({ workspaceId: undefined }),
      storeOf(tempDir("data")),
      { create: true },
    );
    expect(result).toEqual({ kind: "no-workspace" });
  });
});

describe("workspaceMountRoot", () => {
  it("expands a tilde hostMount to an absolute path", () => {
    expect(workspaceMountRoot(workspaceAt("~/workspace/oppi"), { create: false })).toBe(
      resolve(homedir(), "workspace", "oppi"),
    );
    expect(workspaceMountRoot(workspaceAt("~"), { create: false })).toBe(homedir());
  });

  it("creates a sandbox's backing folder only when asked", () => {
    const backing = join(tempDir("sandbox"), "backing");
    const sandbox = workspaceAt(backing, { runtime: "sandbox" });

    expect(workspaceMountRoot(sandbox, { create: false })).toBe(backing);
    expect(existsSync(backing)).toBe(false);
    expect(workspaceMountRoot(sandbox, { create: true })).toBe(backing);
    expect(existsSync(backing)).toBe(true);
  });
});

describe("attachmentWorkRoot", () => {
  it("returns the root, null when no attachments are possible, and throws on a lost worktree", async () => {
    const mount = tempDir("host");
    const store = storeOf(tempDir("data"), workspaceAt(mount));

    expect(await attachmentWorkRoot(sessionOf(), store)).toBe(mount);
    expect(await attachmentWorkRoot(sessionOf({ workspaceId: undefined }), store)).toBeNull();
    expect(await attachmentWorkRoot(sessionOf({ workspaceId: "ws-gone" }), store)).toBeNull();
    await expect(
      attachmentWorkRoot(sessionOf({ worktreeId: "wt_removed" }), store),
    ).rejects.toMatchObject({ statusCode: 409 });
  });

  it("creates the control directory an attachment write needs", async () => {
    const dataDir = tempDir("data");
    const root = await attachmentWorkRoot(
      sessionOf({ workspaceId: undefined, serverDurable: { role: "control" } }),
      storeOf(dataDir),
    );
    expect(root).toBe(join(dataDir, "control-conversation", "cwd"));
    expect(lstatSync(root as string).isDirectory()).toBe(true);
  });
});
