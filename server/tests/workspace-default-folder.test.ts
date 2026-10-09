/**
 * Every workspace has a stored folder. A host workspace created with an empty folder gets
 * `<dataDir>/workspaces/<slug>`, created and stored at that moment; older records get the same
 * folder once, on load.
 */
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import { hostMountValidationError } from "../src/host.js";
import { ensureOwnerOnlyRealDirectory } from "../src/owner-directory.js";
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
import { defaultHostWorkspaceFolder } from "../src/workspace-folder.js";

import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

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

    expect(
      () =>
        new WorkspaceStore(configStore, undefined, {
          faultInjector(phase) {
            if (phase === faultPhase) throw new Error(`injected ${phase}`);
          },
        }),
    ).toThrow(`injected ${faultPhase}`);
    expect(readFileSync(recordPath(id), "utf-8")).toBe(original);
    // The folder made for the failed write is not left behind to look taken.
    expect(existsSync(join(workspacesDir(), "atomic-host"))).toBe(false);
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

describe("a folder is only ever one Oppi made for this workspace", () => {
  it("never adopts a symlink planted at the slug path", () => {
    const elsewhere = mkdtempSync(join(tmpdir(), "oppi-elsewhere-"));
    try {
      symlinkSync(elsewhere, join(workspacesDir(), "planted"));

      const ws = storage.createWorkspace({ name: "Planted" });

      expect(ws.hostMount).toBe(join(workspacesDir(), `planted-${ws.id}`));
      expect(lstatSync(ws.hostMount).isDirectory()).toBe(true);
      expect(readdirSync(elsewhere)).toEqual([]);
    } finally {
      rmSync(elsewhere, { recursive: true, force: true });
    }
  });

  it("never adopts a symlink planted at the slug path during migration", () => {
    const elsewhere = mkdtempSync(join(tmpdir(), "oppi-elsewhere-"));
    try {
      const ws = storage.createWorkspace({ name: "Legacy Planted" });
      rmSync(ws.hostMount, { recursive: true });
      symlinkSync(elsewhere, ws.hostMount);
      writeLegacyRecord(ws.id, (raw) => delete raw.hostMount);

      const loaded = new Storage(dataDir).getWorkspace(ws.id);

      expect(loaded?.hostMount).toBe(join(workspacesDir(), `legacy-planted-${ws.id}`));
      expect(readdirSync(elsewhere)).toEqual([]);
    } finally {
      rmSync(elsewhere, { recursive: true, force: true });
    }
  });

  it("refuses a symlink or a file where the folder should be", () => {
    const target = mkdtempSync(join(tmpdir(), "oppi-target-"));
    try {
      const link = join(dataDir, "link");
      symlinkSync(target, link);
      expect(() => ensureOwnerOnlyRealDirectory(link, "not a real directory")).toThrow(
        "not a real directory",
      );
      const file = join(dataDir, "file");
      writeFileSync(file, "x");
      expect(() => ensureOwnerOnlyRealDirectory(file, "not a real directory")).toThrow(
        "not a real directory",
      );
      const real = join(dataDir, "real");
      ensureOwnerOnlyRealDirectory(real, "unused");
      expect(statSync(real).mode & 0o777).toBe(0o700);
    } finally {
      rmSync(target, { recursive: true, force: true });
    }
  });

  it("fails instead of sharing a directory when the plain and the suffixed folder are taken", () => {
    const workspace = { id: "abc12345", name: "Busy" };
    expect(() => defaultHostWorkspaceFolder("/data/workspaces", workspace, () => true)).toThrow(
      "No free default folder",
    );
    const plainTaken = (path: string) => path === "/data/workspaces/busy";
    expect(defaultHostWorkspaceFolder("/data/workspaces", workspace, plainTaken)).toBe(
      "/data/workspaces/busy-abc12345",
    );
  });

  it("does not hand a deleted workspace's leftover folder to the next same-named workspace", () => {
    const first = storage.createWorkspace({ name: "Gone" });
    writeFileSync(join(first.hostMount, "agent-output.txt"), "precious");
    storage.deleteWorkspace(first.id);

    const second = storage.createWorkspace({ name: "Gone" });

    expect(second.hostMount).toBe(join(workspacesDir(), `gone-${second.id}`));
    expect(readdirSync(second.hostMount)).toEqual([]);
    expect(readFileSync(join(first.hostMount, "agent-output.txt"), "utf-8")).toBe("precious");
  });

  it("lets an update that clears the folder keep the default folder the workspace already has", () => {
    const ws = storage.createWorkspace({ name: "Keeps" });
    writeFileSync(join(ws.hostMount, "work.txt"), "work");

    const cleared = storage.updateWorkspace(ws.id, { hostMount: null });

    expect(cleared?.hostMount).toBe(ws.hostMount);
    expect(readFileSync(join(ws.hostMount, "work.txt"), "utf-8")).toBe("work");
  });
});

describe("migration stops at the first failure and never shares a lock holder's work", () => {
  function legacyHost(name: string, createdAt: number): string {
    const ws = storage.createWorkspace({ name });
    rmSync(ws.hostMount, { recursive: true, force: true });
    writeLegacyRecord(ws.id, (raw) => {
      delete raw.hostMount;
      delete raw.runtime;
      raw.createdAt = createdAt;
    });
    return ws.id;
  }

  it("assigns no younger sibling after the oldest record fails, then splits correctly on retry", () => {
    const older = legacyHost("Twin", 1_000);
    const younger = legacyHost("Twin", 2_000);
    const olderBytes = readFileSync(recordPath(older), "utf-8");
    const youngerBytes = readFileSync(recordPath(younger), "utf-8");
    const configStore = new ConfigStore(dataDir);

    expect(
      () =>
        new WorkspaceStore(configStore, undefined, {
          faultInjector(phase) {
            if (phase === "before_rename") throw new Error("disk full");
          },
        }),
    ).toThrow("disk full");
    expect(readFileSync(recordPath(older), "utf-8")).toBe(olderBytes);
    expect(readFileSync(recordPath(younger), "utf-8")).toBe(youngerBytes);
    expect(existsSync(join(workspacesDir(), "twin"))).toBe(false);
    expect(existsSync(join(workspacesDir(), ".host-folder-migration.lock"))).toBe(false);

    const recovered = new WorkspaceStore(configStore);
    expect(recovered.getWorkspace(older)?.hostMount).toBe(join(workspacesDir(), "twin"));
    expect(recovered.getWorkspace(younger)?.hostMount).toBe(
      join(workspacesDir(), `twin-${younger}`),
    );
  });

  it("lets a failed migration surface from list and from the stale record, not from other records", () => {
    const healthy = storage.createWorkspace({ name: "Healthy" });
    const configStore = new ConfigStore(dataDir);
    let failWrites = false;
    const store = new WorkspaceStore(configStore, undefined, {
      faultInjector(phase) {
        if (failWrites && phase === "after_temp_write") throw new Error("disk full");
      },
    });
    const stale = legacyHost("Arrives Later", 3_000);
    failWrites = true;

    expect(() => store.listWorkspaces()).toThrow("disk full");
    expect(() => store.getWorkspace(stale)).toThrow("disk full");
    expect(store.getWorkspace(healthy.id)?.hostMount).toBe(healthy.hostMount);

    failWrites = false;
    expect(store.listWorkspaces().map((ws) => ws.id)).toContain(stale);
  });

  it("waits for another process's migration lock, then fails clearly", () => {
    legacyHost("Locked", 1_000);
    const lock = join(workspacesDir(), ".host-folder-migration.lock");
    mkdirSync(lock);

    expect(
      () => new WorkspaceStore(new ConfigStore(dataDir), undefined, { lockTimeoutMs: 80 }),
    ).toThrow("locked by another process");
    expect(existsSync(lock)).toBe(true);
  });

  it("takes over a lock a crashed process left behind", () => {
    const id = legacyHost("Crashed Holder", 1_000);
    const lock = join(workspacesDir(), ".host-folder-migration.lock");
    mkdirSync(lock);
    const longAgo = new Date(Date.now() - 10 * 60_000);
    utimesSync(lock, longAgo, longAgo);

    const store = new WorkspaceStore(new ConfigStore(dataDir));

    expect(store.getWorkspace(id)?.hostMount).toBe(join(workspacesDir(), "crashed-holder"));
    expect(existsSync(lock)).toBe(false);
  });

  it.skipIf(process.getuid?.() === 0)(
    "names the host-folder migration when its original cannot be restored",
    () => {
      legacyHost("Unrestorable", 1_000);
      const configStore = new ConfigStore(dataDir);
      try {
        expect(
          () =>
            new WorkspaceStore(configStore, undefined, {
              faultInjector(phase) {
                if (phase === "after_rename") {
                  chmodSync(workspacesDir(), 0o500);
                  throw new Error("injected after_rename");
                }
              },
            }),
        ).toThrow("Workspace host-folder migration failed and its original could not be restored");
      } finally {
        chmodSync(workspacesDir(), 0o700);
      }
    },
  );
});

describe("files that are not workspace records", () => {
  const strays: Array<[string, string]> = [
    ["note.json", '{"note":1}'],
    ["list.json", '[{"id":"list","name":"Array"}]'],
    ["blank-id.json", '{"id":"","name":"Blank"}'],
    ["wrong-name.json", '{"id":"someone-else","name":"Mismatch"}'],
  ];

  it("leaves them untouched at startup, and neither get nor list returns them", () => {
    for (const [file, text] of strays) writeFileSync(join(workspacesDir(), file), text);
    const real = storage.createWorkspace({ name: "Real" });

    const reopened = new Storage(dataDir);

    for (const [file, text] of strays) {
      expect(readFileSync(join(workspacesDir(), file), "utf-8")).toBe(text);
    }
    expect(reopened.listWorkspaces().map((ws) => ws.id)).toEqual([real.id]);
    expect(reopened.getWorkspace("note")).toBeUndefined();
    expect(reopened.getWorkspace("wrong-name")).toBeUndefined();
    expect(reopened.getWorkspace("someone-else")).toBeUndefined();
  });
});

describe("a host workspace cannot be rooted at the home folder", () => {
  it("refuses ~, ~/, $HOME and a symlink to it for a host workspace only", () => {
    const home = mkdtempSync(join(tmpdir(), "oppi-home-"));
    const previousHome = process.env.HOME;
    try {
      process.env.HOME = home;
      const viaLink = join(dataDir, "home-link");
      symlinkSync(home, viaLink);
      for (const value of ["~", "~/", home, `${home}/`, viaLink]) {
        expect(hostMountValidationError(value, "host")).toContain("cannot be your home folder");
        expect(hostMountValidationError(value, "sandbox")).toBeUndefined();
      }
      mkdirSync(join(home, "project"));
      expect(hostMountValidationError("~/project", "host")).toBeUndefined();
    } finally {
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("answers 400 on create and update, and leaves a stored home folder alone", async () => {
    const home = mkdtempSync(join(tmpdir(), "oppi-home-"));
    const previousHome = process.env.HOME;
    try {
      process.env.HOME = home;
      const dispatch = createWorkspaceRoutes(
        { storage } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const send = async (method: "POST" | "PUT", path: string, body: unknown) => {
        const res = makeResponse();
        await dispatch({
          method,
          path,
          url: new URL(`http://localhost${path}`),
          req: makeRequest(body) as never,
          res: res as never,
        });
        return res;
      };

      const created = await send("POST", "/workspaces", { name: "Home", hostMount: "~" });
      expect(created.statusCode).toBe(400);
      expect(created.body).toContain("cannot be your home folder");
      expect(storage.listWorkspaces()).toEqual([]);

      const ws = storage.createWorkspace({ name: "Updatable" });
      const updated = await send("PUT", `/workspaces/${ws.id}`, { hostMount: home });
      expect(updated.statusCode).toBe(400);
      expect(storage.getWorkspace(ws.id)?.hostMount).toBe(ws.hostMount);

      // A record an older Oppi stored with the home folder still loads as it was.
      writeLegacyRecord(ws.id, (raw) => (raw.hostMount = "~"));
      expect(new Storage(dataDir).getWorkspace(ws.id)?.hostMount).toBe("~");
    } finally {
      if (previousHome === undefined) delete process.env.HOME;
      else process.env.HOME = previousHome;
      rmSync(home, { recursive: true, force: true });
    }
  });
});
