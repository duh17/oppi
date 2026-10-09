/**
 * Every workspace has a stored folder. A host workspace created with an empty folder gets
 * `<dataDir>/workspaces/<slug>`, created and stored at that moment; older records get the same
 * folder once, on load.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import { Storage } from "../src/storage.js";
import { ConfigStore } from "../src/storage/config-store.js";
import {
  WorkspaceStore,
  type WorkspaceMigrationFaultPhase,
} from "../src/storage/workspace-store.js";
import { loadWorkspacePromptTemplates } from "../src/workspace-quick-action-session.js";

import { makeResponse } from "./harness/route-test-helpers.js";

let dataDir: string;
let storage: Storage;

const workspacesDir = () => join(dataDir, "workspaces");
const recordPath = (id: string) => join(workspacesDir(), `${id}.json`);
const readRecord = (id: string) =>
  JSON.parse(readFileSync(recordPath(id), "utf-8")) as Record<string, unknown>;

/** Rewrites a stored record the way an older Oppi left it. */
function writeLegacyRecord(id: string, edit: (raw: Record<string, unknown>) => void): string {
  const raw = readRecord(id);
  edit(raw);
  const text = JSON.stringify(raw, null, 2);
  writeFileSync(recordPath(id), text, { mode: 0o600 });
  return text;
}

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-default-folder-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

describe("host workspace created with an empty folder", () => {
  it.each([undefined, "", "   "])("stores and creates <workspaces>/<slug> for %j", (hostMount) => {
    const ws = storage.createWorkspace({ name: "My Project", hostMount });

    const folder = join(workspacesDir(), "my-project");
    expect(ws.hostMount).toBe(folder);
    expect(ws.runtime).toBe("host");
    expect(statSync(folder).isDirectory()).toBe(true);
    expect(readRecord(ws.id)).toMatchObject({ hostMount: folder, runtime: "host" });
    expect(storage.getWorkspace(ws.id)?.hostMount).toBe(folder);
  });

  it("never claims the home folder", () => {
    const created = storage.createWorkspace({ name: "", hostMount: "" });
    const cleared = storage.updateWorkspace(created.id, { hostMount: null });

    for (const ws of [created, cleared]) {
      expect(ws?.hostMount).not.toBe("~");
      expect(ws?.hostMount).not.toBe(homedir());
      expect(ws?.hostMount.startsWith(workspacesDir())).toBe(true);
    }
  });

  it("keeps a chosen folder untouched", () => {
    const chosen = mkdtempSync(join(tmpdir(), "oppi-chosen-"));
    try {
      const ws = storage.createWorkspace({ name: "Chosen", hostMount: chosen });
      expect(ws.hostMount).toBe(chosen);
      expect(existsSync(join(workspacesDir(), "chosen"))).toBe(false);
    } finally {
      rmSync(chosen, { recursive: true, force: true });
    }
  });

  it("adds the workspace id when another workspace already owns the folder", () => {
    const first = storage.createWorkspace({ name: "Same Name" });
    const second = storage.createWorkspace({ name: "Same Name" });
    const third = storage.createWorkspace({ name: "same name" });

    expect(first.hostMount).toBe(join(workspacesDir(), "same-name"));
    expect(second.hostMount).toBe(join(workspacesDir(), `same-name-${second.id}`));
    expect(third.hostMount).toBe(join(workspacesDir(), `same-name-${third.id}`));
    for (const ws of [first, second, third])
      expect(statSync(ws.hostMount).isDirectory()).toBe(true);
  });

  it("keeps the folder across a rename, and across deleting the workspace", () => {
    const ws = storage.createWorkspace({ name: "Original" });
    writeFileSync(join(ws.hostMount, "keep.txt"), "work");

    const renamed = storage.updateWorkspace(ws.id, { name: "Renamed" });
    expect(renamed?.hostMount).toBe(ws.hostMount);

    expect(storage.deleteWorkspace(ws.id)).toBe(true);
    expect(readFileSync(join(ws.hostMount, "keep.txt"), "utf-8")).toBe("work");
  });

  it("restores the default folder when an update clears it", () => {
    const chosen = mkdtempSync(join(tmpdir(), "oppi-chosen-"));
    try {
      const ws = storage.createWorkspace({ name: "Clearing", hostMount: chosen });
      const cleared = storage.updateWorkspace(ws.id, { hostMount: "" });
      expect(cleared?.hostMount).toBe(join(workspacesDir(), "clearing"));
      expect(existsSync(join(workspacesDir(), "clearing"))).toBe(true);
    } finally {
      rmSync(chosen, { recursive: true, force: true });
    }
  });

  it("leaves the workspace list reading only its records", () => {
    const ids = ["Alpha", "Beta", "Alpha.json"].map((name) => storage.createWorkspace({ name }).id);

    expect(
      storage
        .listWorkspaces()
        .map((ws) => ws.id)
        .sort(),
    ).toEqual([...ids].sort());
    // A folder can never be mistaken for a record: the slug alphabet has no ".".
    expect(readdirSync(workspacesDir()).filter((file) => file.endsWith(".json")).length).toBe(3);
  });
});

describe("loading records from before every workspace had a folder", () => {
  function legacyHostWorkspace(name: string, createdAt?: number): string {
    const ws = storage.createWorkspace({ name });
    rmSync(ws.hostMount, { recursive: true, force: true });
    writeLegacyRecord(ws.id, (raw) => {
      delete raw.hostMount;
      delete raw.runtime;
      raw.futureField = { nested: true };
      if (createdAt !== undefined) raw.createdAt = createdAt;
    });
    return ws.id;
  }

  it("fills hostMount and runtime once, keeping every other raw field", () => {
    const id = legacyHostWorkspace("Legacy Host");
    const before = readRecord(id);

    const loaded = storage.getWorkspace(id);

    const folder = join(workspacesDir(), "legacy-host");
    expect(loaded).toMatchObject({ hostMount: folder, runtime: "host" });
    expect(statSync(folder).isDirectory()).toBe(true);
    expect(readRecord(id)).toEqual({ ...before, hostMount: folder, runtime: "host" });

    const written = readFileSync(recordPath(id), "utf-8");
    expect(storage.getWorkspace(id)?.hostMount).toBe(folder);
    expect(storage.listWorkspaces().find((ws) => ws.id === id)?.hostMount).toBe(folder);
    expect(readFileSync(recordPath(id), "utf-8")).toBe(written);
  });

  it("migrates at startup, oldest first, so same-named workspaces split the same way", () => {
    const newer = legacyHostWorkspace("Twin", 2_000);
    const older = legacyHostWorkspace("Twin", 1_000);

    const reopened = new Storage(dataDir);

    expect(reopened.getWorkspace(older)?.hostMount).toBe(join(workspacesDir(), "twin"));
    expect(reopened.getWorkspace(newer)?.hostMount).toBe(join(workspacesDir(), `twin-${newer}`));
    expect(readRecord(older).hostMount).toBe(join(workspacesDir(), "twin"));
  });

  it("gives a record with no runtime but a folder only the runtime", () => {
    const chosen = mkdtempSync(join(tmpdir(), "oppi-chosen-"));
    try {
      const ws = storage.createWorkspace({ name: "Has Folder", hostMount: chosen });
      writeLegacyRecord(ws.id, (raw) => delete raw.runtime);

      expect(storage.getWorkspace(ws.id)).toMatchObject({ hostMount: chosen, runtime: "host" });
      expect(readRecord(ws.id)).toMatchObject({ hostMount: chosen, runtime: "host" });
      expect(existsSync(join(workspacesDir(), "has-folder"))).toBe(false);
    } finally {
      rmSync(chosen, { recursive: true, force: true });
    }
  });

  it.each<WorkspaceMigrationFaultPhase>([
    "after_temp_write",
    "after_temp_fsync",
    "before_rename",
    "after_rename",
  ])("keeps the original record when the write fails at %s", (faultPhase) => {
    const id = legacyHostWorkspace("Atomic Host");
    const original = readFileSync(recordPath(id), "utf-8");
    const configStore = new ConfigStore(dataDir);
    const faulty = new WorkspaceStore(configStore, undefined, {
      faultInjector(phase) {
        if (phase === faultPhase) throw new Error(`injected ${phase}`);
      },
    });

    expect(() => faulty.getWorkspace(id)).toThrow(`injected ${faultPhase}`);
    expect(readFileSync(recordPath(id), "utf-8")).toBe(original);
    expect(readdirSync(workspacesDir()).filter((file) => file.endsWith(".tmp"))).toEqual([]);

    const recovered = new WorkspaceStore(configStore);
    expect(recovered.getWorkspace(id)?.hostMount).toBe(join(workspacesDir(), "atomic-host"));
    expect(readRecord(id)).toMatchObject({
      hostMount: join(workspacesDir(), "atomic-host"),
      runtime: "host",
      futureField: { nested: true },
    });
  });
});

describe("what an empty-created host workspace now takes part in", () => {
  it("claims legacy sessions whose Pi cwd is inside its folder, and nothing under home", () => {
    const ws = storage.createWorkspace({ name: "Claims" });
    const inside = storage.createSession("inside");
    const outside = storage.createSession("outside");
    const files = [
      [inside, join(ws.hostMount, "sub")],
      [outside, homedir()],
    ] as const;
    for (const [session, cwd] of files) {
      const file = join(dataDir, `${session.id}.jsonl`);
      writeFileSync(file, `${JSON.stringify({ type: "session", id: session.id, cwd })}\n`);
      session.piSessionFile = file;
      storage.saveSession(session);
    }

    const reopened = new Storage(dataDir);

    expect(reopened.getSession(inside.id)?.workspaceId).toBe(ws.id);
    expect(reopened.getSession(outside.id)?.workspaceId).toBeUndefined();
  });

  it("reports a Git summary once its folder becomes a repository", async () => {
    const ws = storage.createWorkspace({ name: "Becomes Repo" });
    execFileSync("git", ["init", "--initial-branch=main"], { cwd: ws.hostMount });
    writeFileSync(join(ws.hostMount, "a.txt"), "a\n");
    const dispatch = createWorkspaceRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const res = makeResponse();

    await dispatch({
      method: "GET",
      path: `/workspaces/${ws.id}/git/summary`,
      url: new URL(`http://localhost/workspaces/${ws.id}/git/summary`),
      req: {} as never,
      res: res as never,
    });

    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ isGitRepo: true, changedCount: 1 });
  });

  it("loads quick-action prompt templates from its folder", async () => {
    const ws = storage.createWorkspace({ name: "Quick Actions" });
    mkdirSync(join(ws.hostMount, ".pi", "prompts"), { recursive: true });
    writeFileSync(
      join(ws.hostMount, ".pi", "prompts", "tidy-up.md"),
      "---\ndescription: Tidy\n---\nTidy $ARGUMENTS\n",
    );

    const templates = await loadWorkspacePromptTemplates(ws);

    expect(templates.map((template) => template.name)).toContain("tidy-up");
  });
});
