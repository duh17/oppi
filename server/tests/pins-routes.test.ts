import { chmodSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createPinRoutes } from "../src/routes/pins.js";
import type { RouteContext } from "../src/routes/types.js";
import type { PinAddResponse, PinsResponse } from "../src/types.js";
import { PINS_HTTP_SNAPSHOT_FILE, serializePinsHttpFixture } from "./pins-fixtures.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";
import { makeTempDir } from "./harness/temp-dir.js";

const homeFolder = (path: string | null) => ({ kind: "files", origin: "host", path });
const homeFile = (path: string) => ({ kind: "file", origin: "host", path, line: null });
const workspaceFolder = (workspace: string, path: string | null) => ({
  kind: "files",
  workspace,
  path,
});

function makeServer() {
  const dataDir = makeTempDir("oppi-pins-data-");
  const home = makeTempDir("oppi-pins-home-");
  const checkout = makeTempDir("oppi-pins-ws-");
  mkdirSync(join(home, "notebook"));
  writeFileSync(join(home, "book.epub"), "epub");
  mkdirSync(join(checkout, "reports"));
  const workspaces = new Map([["ws-1", { id: "ws-1", hostMount: checkout, runtime: "host" }]]);
  const sessions = new Set(["sess-release", "sess-review"]);
  // The games the Godot service knows, by project id, with their names.
  const games = new Map([["sword-lab-3fa9c2b1", "Sword Lab"]]);
  const events: number[] = [];

  function start() {
    const ctx = {
      storage: {
        getDataDir: () => dataDir,
        getWorkspace: (id: string) => workspaces.get(id),
        getSession: (id: string) => (sessions.has(id) ? { id } : undefined),
      },
      godot: {
        detail: async (id: string) => {
          const name = games.get(id);
          return name === undefined ? undefined : { id, name };
        },
      },
      appEvents: { emitPinsChanged: (revision: number) => events.push(revision) },
    } as unknown as RouteContext;
    const route = createPinRoutes(ctx, createRouteHelpers(), { homeDir: home });
    return async function call<T = Record<string, unknown>>(method: string, body?: unknown) {
      const res = makeResponse();
      const handled = await route({
        method,
        path: "/pins",
        url: new URL("http://localhost/pins"),
        req: makeRequest(body),
        res: res as never,
      });
      expect(handled).toBe(true);
      return { status: res.statusCode, json: JSON.parse(res.body) as T };
    };
  }

  /** Writes `pins.json` as an older server left it. */
  function writeRecord(record: unknown) {
    mkdirSync(join(dataDir, "settings"), { recursive: true });
    writeFileSync(join(dataDir, "settings", "pins.json"), JSON.stringify(record));
  }

  return { dataDir, home, checkout, workspaces, sessions, games, events, start, writeRecord };
}

describe("pins routes", () => {
  it("adds, dedupes, reorders and removes, with one app event per change, and keeps them across a restart", async () => {
    const server = makeServer();
    const call = server.start();

    const first = await call<PinAddResponse>("POST", { target: homeFolder("~/notebook/") });
    expect(first.status).toBe(200);
    expect(first.json.revision).toBe(1);
    expect(first.json.pins).toMatchObject([{ target: homeFolder("~/notebook"), status: "ok" }]);
    const notebookId = first.json.pinId;

    // The same route with its fields in another order is the same pin.
    const again = await call<PinAddResponse>("POST", {
      target: { path: "~/notebook", origin: "host", kind: "files" },
    });
    expect(again.json).toMatchObject({ revision: 1, pinId: notebookId });
    expect(again.json.pins).toHaveLength(1);

    const book = await call<PinAddResponse>("POST", {
      target: homeFile("~/book.epub"),
      label: "  My\tbook ",
    });
    const reports = await call<PinAddResponse>("POST", {
      target: workspaceFolder("ws-1", "reports"),
    });
    expect(reports.json.revision).toBe(3);
    expect(reports.json.pins.map((pin) => [pin.target.kind, pin.label])).toEqual([
      ["files", undefined],
      ["file", "My book"],
      ["files", undefined],
    ]);
    expect(server.events).toEqual([1, 2, 3]);

    // New order and label; the book is left out, so it goes.
    const reordered = await call<PinsResponse>("PUT", {
      baseRevision: 3,
      pins: [{ id: reports.json.pinId, label: "Reports" }, { id: notebookId }],
    });
    expect(reordered.status).toBe(200);
    expect(reordered.json.revision).toBe(4);
    expect(reordered.json.pins.map((pin) => pin.label ?? pin.id)).toEqual(["Reports", notebookId]);
    expect(reordered.json.pins.some((pin) => pin.id === book.json.pinId)).toBe(false);
    expect(server.events).toEqual([1, 2, 3, 4]);

    // The same order again is no change: no new revision, no event.
    const same = await call<PinsResponse>("PUT", {
      baseRevision: 4,
      pins: [{ id: reports.json.pinId, label: "Reports" }, { id: notebookId }],
    });
    expect(same.json.revision).toBe(4);
    expect(server.events).toEqual([1, 2, 3, 4]);

    const restarted = await server.start()<PinsResponse>("GET");
    expect(restarted.json).toEqual(reordered.json);
  });

  it("answers a stale PUT with 409 and the current list, and changes nothing", async () => {
    const server = makeServer();
    const call = server.start();
    const added = await call<PinAddResponse>("POST", { target: homeFolder("~/notebook") });
    const stale = await call<{ code: string; current: PinsResponse }>("PUT", {
      baseRevision: 0,
      pins: [],
    });
    expect(stale.status).toBe(409);
    expect(stale.json.code).toBe("revision_conflict");
    expect(stale.json.current.pins.map((pin) => pin.id)).toEqual([added.json.pinId]);
    expect((await call<PinsResponse>("GET")).json.revision).toBe(1);
    expect(server.events).toEqual([1]);
  });

  it("refuses an unknown id, the 51st pin, and a label over 40 characters", async () => {
    const server = makeServer();
    const call = server.start();
    const added = await call<PinAddResponse>("POST", { target: homeFolder("~/notebook") });

    const unknown = await call("PUT", { baseRevision: 1, pins: [{ id: "pin_NotSaved0000" }] });
    expect(unknown.status).toBe(400);
    const long = await call("POST", { target: homeFile("~/book.epub"), label: "x".repeat(41) });
    expect(long.status).toBe(400);
    const longRename = await call("PUT", {
      baseRevision: 1,
      pins: [{ id: added.json.pinId, label: "x".repeat(41) }],
    });
    expect(longRename.status).toBe(400);

    for (let index = 1; index < 50; index++) {
      const each = await call("POST", {
        target: { kind: "browser", url: `https://example.com/${index}` },
      });
      expect(each.status).toBe(200);
    }
    const over = await call("POST", { target: { kind: "browser", url: "https://example.com/51" } });
    expect(over.status).toBe(400);
    expect((await call<PinsResponse>("GET")).json.pins).toHaveLength(50);
  });

  it("refuses a route that leaves its root, breaks a link's rules, or misses a field", async () => {
    const server = makeServer();
    const call = server.start();
    const outside = makeTempDir("oppi-pins-outside-");
    for (const target of [
      homeFolder(outside),
      homeFolder("~/notebook/../.."),
      homeFolder("~/../etc"),
      homeFolder("~root/notebook"),
      homeFolder("notebook"),
      homeFile("~"),
      workspaceFolder("ws-1", "../outside"),
      workspaceFolder("ws-1", "/etc"),
      workspaceFolder("ws-1", "~/notebook"),
      { kind: "files", workspace: "ws-1" },
      { kind: "file", origin: "workspace", workspace: "ws-1", path: "reports/a.md", line: null },
      { kind: "file", origin: "session", session: "sess-release", path: "../x", line: null },
      { kind: "file", origin: "workspace", workspace: "ws-1", worktree: null, path: "a", line: 0 },
      { kind: "session", id: "" },
      { kind: "session", id: "sess\nrelease" },
      { kind: "session", id: "x".repeat(257) },
      { kind: "session", id: "sess-release", path: "~/notebook" },
      { kind: "git", workspace: "ws-1", worktree: null },
      { kind: "commit", workspace: "ws-1", sha: "9f86d08" },
      { kind: "browser", url: "ftp://example.com/" },
      { kind: "browser", url: "http://localhost:5173/" },
      { kind: "browser", url: "https://user:secret@example.com/" },
      { kind: "browser", url: `https://example.com/${"a".repeat(2048)}` },
      { kind: "godot", project: "../sword-lab" },
      { kind: "local", token: "outline" },
      { origin: "host", path: "~/notebook" },
    ]) {
      expect((await call("POST", { target })).status, JSON.stringify(target)).toBe(400);
    }
    const nothing = await call("POST", { target: homeFolder("~/not-here") });
    expect(nothing.status).toBe(404);
    const fileAsFolder = await call("POST", { target: homeFolder("~/book.epub") });
    expect(fileAsFolder.status).toBe(404);
    const noWorkspace = await call("POST", { target: workspaceFolder("ws-gone", null) });
    expect(noWorkspace.status).toBe(404);
    expect((await call<PinsResponse>("GET")).json.pins).toEqual([]);
    expect(server.events).toEqual([]);
  });

  it("reports a deleted folder as missing, a locked one as unreadable, and a deleted workspace as workspaceMissing", async () => {
    const server = makeServer();
    const call = server.start();
    const locked = join(server.home, "locked");
    mkdirSync(locked);
    await call("POST", { target: homeFolder("~/locked") });
    await call("POST", { target: homeFolder("~/notebook") });
    await call("POST", { target: workspaceFolder("ws-1", "reports") });
    await call("POST", { target: workspaceFolder("ws-1", null) });
    await call("POST", { target: { kind: "sessions", workspace: "ws-1" } });

    rmSync(join(server.home, "notebook"), { recursive: true });
    // A file where the pinned folder was is not the pinned folder.
    writeFileSync(join(server.home, "notebook"), "not a folder");
    server.workspaces.delete("ws-1");
    chmodSync(locked, 0o000);

    const list = await call<PinsResponse>("GET");
    chmodSync(locked, 0o700);
    expect(list.json.pins.map((pin) => pin.status)).toEqual([
      "unreadable",
      "missing",
      "workspaceMissing",
      "workspaceMissing",
      "workspaceMissing",
    ]);
  });
});

describe("session and game pins", () => {
  it("pins a session once and reads missing once the session is deleted, with its thread and panel", async () => {
    const server = makeServer();
    const call = server.start();

    const release = await call<PinAddResponse>("POST", {
      target: { kind: "session", id: "sess-release" },
    });
    expect(release.status).toBe(200);
    const again = await call<PinAddResponse>("POST", {
      target: { kind: "session", id: "sess-release" },
    });
    expect(again.json).toMatchObject({ revision: 1, pinId: release.json.pinId });
    await call("POST", { target: { kind: "thread", id: "sess-release" } });
    await call("POST", { target: { kind: "panel", session: "sess-release", id: "subagents" } });
    await call("POST", { target: { kind: "session", id: "sess-review" } });
    expect(server.events).toEqual([1, 2, 3, 4]);

    server.sessions.delete("sess-release");
    const list = await server.start()<PinsResponse>("GET");
    expect(list.json.pins.map((pin) => [pin.target.kind, pin.status])).toEqual([
      ["session", "missing"],
      ["thread", "missing"],
      ["panel", "missing"],
      ["session", "ok"],
    ]);
    // A status is read, not a change: no new revision and no event.
    expect(list.json.revision).toBe(4);
    expect(server.events).toEqual([1, 2, 3, 4]);

    const gone = await call<{ error: string }>("POST", {
      target: { kind: "session", id: "sess-gone" },
    });
    expect(gone.status).toBe(404);
    expect(gone.json.error).toBe("Session not found");
  });

  it("pins a game with its name, follows a renamed game, and reads missing once it is gone", async () => {
    const server = makeServer();
    const call = server.start();
    const target = { kind: "godot", project: "sword-lab-3fa9c2b1" };
    const game = await call<PinAddResponse>("POST", { target });
    expect(game.json.pins).toEqual([
      expect.objectContaining({ id: game.json.pinId, target, status: "ok", name: "Sword Lab" }),
    ]);

    // The name is read with the status, so a renamed game shows its new name.
    server.games.set("sword-lab-3fa9c2b1", "Sword Lab II");
    expect((await call<PinsResponse>("GET")).json.pins[0]).toMatchObject({ name: "Sword Lab II" });

    server.games.delete("sword-lab-3fa9c2b1");
    const [gone] = (await call<PinsResponse>("GET")).json.pins;
    expect(gone).toMatchObject({ status: "missing" });
    expect(gone).not.toHaveProperty("name");

    const unknown = await call<{ error: string }>("POST", {
      target: { kind: "godot", project: "tide-7c01d2e4" },
    });
    expect(unknown.status).toBe(404);
    expect(unknown.json.error).toBe("Game not found");
  });

  it("keeps a web page and a worktree's file as they are", async () => {
    const server = makeServer();
    const call = server.start();
    for (const target of [
      { kind: "browser", url: "https://docs.godotengine.org/en/stable/" },
      {
        kind: "file",
        origin: "workspace",
        workspace: "ws-1",
        worktree: "wt-1",
        path: "src/a.ts",
        line: 12,
      },
    ]) {
      expect((await call("POST", { target })).status, JSON.stringify(target)).toBe(200);
    }
    const list = await call<PinsResponse>("GET");
    expect(list.json.pins.map((pin) => pin.status)).toEqual(["ok", "ok"]);
  });
});

describe("Git and commit pins an earlier server saved", () => {
  it("leaves them out of the list and drops them on disk with the next change", async () => {
    const server = makeServer();
    server.writeRecord({
      version: 2,
      revision: 5,
      pins: [
        {
          id: "pin_Git000000001",
          target: { kind: "git", workspace: "ws-1", worktree: null },
          createdAt: 1,
        },
        { id: "pin_Notebook0002", target: homeFolder("~/notebook"), createdAt: 2 },
        {
          id: "pin_Commit000003",
          target: { kind: "commit", workspace: "ws-1", sha: "9f86d08" },
          createdAt: 3,
        },
      ],
    });
    const call = server.start();
    const list = await call<PinsResponse>("GET");
    expect(list.status).toBe(200);
    expect(list.json.revision).toBe(5);
    expect(list.json.pins.map((pin) => pin.id)).toEqual(["pin_Notebook0002"]);

    const saved = await call<PinsResponse>("PUT", {
      baseRevision: 5,
      pins: [{ id: "pin_Notebook0002", label: "Notes" }],
    });
    expect(saved.json.revision).toBe(6);
    const file = join(server.dataDir, "settings", "pins.json");
    expect(
      JSON.parse(readFileSync(file, "utf8")).pins.map((pin: { id: string }) => pin.id),
    ).toEqual(["pin_Notebook0002"]);
  });
});

describe("pins.json version 1", () => {
  it("reads folder, file, and session pins as routes, keeps the revision, and writes version 2 on the next change", async () => {
    const server = makeServer();
    server.writeRecord({
      version: 1,
      revision: 9,
      pins: [
        {
          id: "pin_Home00000001",
          target: { origin: "host", path: "~" },
          kind: "directory",
          createdAt: 1,
        },
        {
          id: "pin_Notebook0002",
          target: { origin: "host", path: "~/notebook" },
          kind: "directory",
          label: "Notes",
          createdAt: 2,
        },
        {
          id: "pin_Book00000003",
          target: { origin: "host", path: "~/book.epub" },
          kind: "file",
          createdAt: 3,
        },
        {
          id: "pin_Root00000004",
          target: { origin: "workspace", workspaceId: "ws-1", path: "" },
          kind: "directory",
          createdAt: 4,
        },
        {
          id: "pin_Reports00005",
          target: { origin: "workspace", workspaceId: "ws-1", path: "reports" },
          kind: "directory",
          createdAt: 5,
        },
        {
          id: "pin_Readme000006",
          target: { origin: "workspace", workspaceId: "ws-1", path: "README.md" },
          kind: "file",
          createdAt: 6,
        },
        {
          id: "pin_Release00007",
          target: { origin: "session", sessionId: "sess-release" },
          kind: "session",
          createdAt: 7,
        },
      ],
    });
    const call = server.start();
    const list = await call<PinsResponse>("GET");
    expect(list.status).toBe(200);
    expect(list.json.revision).toBe(9);
    expect(list.json.pins.map((pin) => [pin.id, pin.target, pin.label])).toEqual([
      ["pin_Home00000001", homeFolder(null), undefined],
      ["pin_Notebook0002", homeFolder("~/notebook"), "Notes"],
      ["pin_Book00000003", homeFile("~/book.epub"), undefined],
      ["pin_Root00000004", workspaceFolder("ws-1", null), undefined],
      ["pin_Reports00005", workspaceFolder("ws-1", "reports"), undefined],
      [
        "pin_Readme000006",
        {
          kind: "file",
          origin: "workspace",
          workspace: "ws-1",
          worktree: null,
          path: "README.md",
          line: null,
        },
        undefined,
      ],
      ["pin_Release00007", { kind: "session", id: "sess-release" }, undefined],
    ]);
    // A read changes nothing on disk.
    const file = join(server.dataDir, "settings", "pins.json");
    expect(JSON.parse(readFileSync(file, "utf8")).version).toBe(1);

    // Re-pinning a migrated route is the migrated pin.
    const again = await call<PinAddResponse>("POST", { target: homeFolder("~/notebook") });
    expect(again.json).toMatchObject({ revision: 9, pinId: "pin_Notebook0002" });

    const kept = list.json.pins.map((pin) => ({
      id: pin.id,
      ...(pin.label ? { label: pin.label } : {}),
    }));
    const saved = await call<PinsResponse>("PUT", { baseRevision: 9, pins: kept.slice(1) });
    expect(saved.json.revision).toBe(10);
    const written = JSON.parse(readFileSync(file, "utf8"));
    expect(written.version).toBe(2);
    expect(written.pins[0]).toEqual({
      id: "pin_Notebook0002",
      target: homeFolder("~/notebook"),
      label: "Notes",
      createdAt: 2,
    });
  });

  it("refuses a version 1 file whose session pin is not of kind session", async () => {
    const server = makeServer();
    server.writeRecord({
      version: 1,
      revision: 1,
      pins: [
        {
          id: "pin_Release00007",
          target: { origin: "session", sessionId: "sess-release" },
          kind: "directory",
          createdAt: 1,
        },
      ],
    });
    expect((await server.start()("GET")).status).toBe(503);
  });

  it("refuses a version 2 file with a route outside its root", async () => {
    const server = makeServer();
    server.writeRecord({
      version: 2,
      revision: 1,
      pins: [{ id: "pin_Escape000001", target: homeFolder("~/../etc"), createdAt: 1 }],
    });
    expect((await server.start()("GET")).status).toBe(503);
  });
});

describe("pins protocol fixture", () => {
  it("matches the committed protocol/pins-http.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    expect(serializePinsHttpFixture()).toBe(readFileSync(PINS_HTTP_SNAPSHOT_FILE, "utf8"));
  });
});
