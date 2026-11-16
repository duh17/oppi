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

function makeServer() {
  const dataDir = makeTempDir("oppi-pins-data-");
  const home = makeTempDir("oppi-pins-home-");
  const checkout = makeTempDir("oppi-pins-ws-");
  mkdirSync(join(home, "notebook"));
  writeFileSync(join(home, "book.epub"), "epub");
  mkdirSync(join(checkout, "reports"));
  const workspaces = new Map([["ws-1", { id: "ws-1", hostMount: checkout, runtime: "host" }]]);
  const sessions = new Set(["sess-release", "sess-review"]);
  const events: number[] = [];

  function start() {
    const ctx = {
      storage: {
        getDataDir: () => dataDir,
        getWorkspace: (id: string) => workspaces.get(id),
        getSession: (id: string) => (sessions.has(id) ? { id } : undefined),
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

  return { dataDir, home, checkout, workspaces, sessions, events, start };
}

describe("pins routes", () => {
  it("adds, dedupes, reorders and removes, with one app event per change, and keeps them across a restart", async () => {
    const server = makeServer();
    const call = server.start();

    const first = await call<PinAddResponse>("POST", {
      target: { origin: "host", path: "~/notebook/" },
    });
    expect(first.status).toBe(200);
    expect(first.json.revision).toBe(1);
    expect(first.json.pins).toMatchObject([
      { target: { origin: "host", path: "~/notebook" }, kind: "directory", status: "ok" },
    ]);
    const notebookId = first.json.pinId;

    const again = await call<PinAddResponse>("POST", {
      target: { origin: "host", path: "~/notebook" },
    });
    expect(again.json).toMatchObject({ revision: 1, pinId: notebookId });
    expect(again.json.pins).toHaveLength(1);

    const book = await call<PinAddResponse>("POST", {
      target: { origin: "host", path: "~/book.epub" },
      label: "  My\tbook ",
    });
    const reports = await call<PinAddResponse>("POST", {
      target: { origin: "workspace", workspaceId: "ws-1", path: "reports" },
    });
    expect(reports.json.revision).toBe(3);
    expect(reports.json.pins.map((pin) => [pin.kind, pin.label])).toEqual([
      ["directory", undefined],
      ["file", "My book"],
      ["directory", undefined],
    ]);
    expect(server.events).toEqual([1, 2, 3]);

    // New order and label; the book is left out, so it goes.
    const reordered = await call<PinsResponse>("PUT", {
      baseRevision: 3,
      pins: [{ id: reports.json.pinId, label: "Reports" }, { id: notebookId }],
    });
    expect(reordered.status).toBe(200);
    expect(reordered.json.revision).toBe(4);
    expect(reordered.json.pins.map((pin) => pin.label ?? pin.target.path)).toEqual([
      "Reports",
      "~/notebook",
    ]);
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
    const added = await call<PinAddResponse>("POST", {
      target: { origin: "host", path: "~/notebook" },
    });
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
    const added = await call<PinAddResponse>("POST", {
      target: { origin: "host", path: "~/notebook" },
    });

    const unknown = await call("PUT", { baseRevision: 1, pins: [{ id: "pin_NotSaved0000" }] });
    expect(unknown.status).toBe(400);
    const long = await call("POST", {
      target: { origin: "host", path: "~/book.epub" },
      label: "x".repeat(41),
    });
    expect(long.status).toBe(400);
    const longRename = await call("PUT", {
      baseRevision: 1,
      pins: [{ id: added.json.pinId, label: "x".repeat(41) }],
    });
    expect(longRename.status).toBe(400);

    for (let index = 1; index < 50; index++) {
      mkdirSync(join(server.home, `folder-${index}`));
      const each = await call("POST", { target: { origin: "host", path: `~/folder-${index}` } });
      expect(each.status).toBe(200);
    }
    mkdirSync(join(server.home, "one-too-many"));
    const over = await call("POST", { target: { origin: "host", path: "~/one-too-many" } });
    expect(over.status).toBe(400);
    expect((await call<PinsResponse>("GET")).json.pins).toHaveLength(50);
  });

  it("refuses a target the File Browser could not open", async () => {
    const server = makeServer();
    const call = server.start();
    const outside = makeTempDir("oppi-pins-outside-");
    for (const target of [
      { origin: "host", path: outside },
      { origin: "host", path: "~/notebook/../.." },
      { origin: "host", path: "~/../etc" },
      { origin: "host", path: "~root/notebook" },
      { origin: "host", path: "notebook" },
      { origin: "workspace", workspaceId: "ws-1", path: "../outside" },
      { origin: "workspace", workspaceId: "ws-1", path: "/etc" },
      { origin: "workspace", workspaceId: "ws-1", path: "~/notebook" },
    ]) {
      expect((await call("POST", { target })).status, JSON.stringify(target)).toBe(400);
    }
    const nothing = await call("POST", { target: { origin: "host", path: "~/not-here" } });
    expect(nothing.status).toBe(404);
    const noWorkspace = await call("POST", {
      target: { origin: "workspace", workspaceId: "ws-gone", path: "" },
    });
    expect(noWorkspace.status).toBe(404);
    expect((await call<PinsResponse>("GET")).json.pins).toEqual([]);
    expect(server.events).toEqual([]);
  });

  it("reports a deleted folder as missing, a locked one as unreadable, and a deleted workspace as workspaceMissing", async () => {
    const server = makeServer();
    const call = server.start();
    const locked = join(server.home, "locked");
    mkdirSync(locked);
    await call("POST", { target: { origin: "host", path: "~/locked" } });
    await call("POST", { target: { origin: "host", path: "~/notebook" } });
    await call("POST", { target: { origin: "workspace", workspaceId: "ws-1", path: "reports" } });
    await call("POST", { target: { origin: "workspace", workspaceId: "ws-1", path: "" } });

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
    ]);
  });
});

describe("session pins", () => {
  it("pins a session once, reorders it among places, and reads missing once the session is deleted", async () => {
    const server = makeServer();
    const call = server.start();

    const folder = await call<PinAddResponse>("POST", {
      target: { origin: "host", path: "~/notebook" },
    });
    const release = await call<PinAddResponse>("POST", {
      target: { origin: "session", sessionId: "sess-release" },
    });
    expect(release.status).toBe(200);
    expect(release.json.pins.at(-1)).toMatchObject({
      id: release.json.pinId,
      target: { origin: "session", sessionId: "sess-release" },
      kind: "session",
      status: "ok",
    });
    const again = await call<PinAddResponse>("POST", {
      target: { origin: "session", sessionId: "sess-release" },
    });
    expect(again.json).toMatchObject({ revision: 2, pinId: release.json.pinId });
    const review = await call<PinAddResponse>("POST", {
      target: { origin: "session", sessionId: "sess-review" },
    });
    expect(server.events).toEqual([1, 2, 3]);

    const reordered = await call<PinsResponse>("PUT", {
      baseRevision: 3,
      pins: [{ id: review.json.pinId }, { id: release.json.pinId }, { id: folder.json.pinId }],
    });
    expect(reordered.json.pins.map((pin) => pin.id)).toEqual([
      review.json.pinId,
      release.json.pinId,
      folder.json.pinId,
    ]);

    server.sessions.delete("sess-release");
    const list = await server.start()<PinsResponse>("GET");
    expect(list.json.pins.map((pin) => [pin.id, pin.status])).toEqual([
      [review.json.pinId, "ok"],
      [release.json.pinId, "missing"],
      [folder.json.pinId, "ok"],
    ]);
    // A status is read, not a change: no new revision and no event.
    expect(list.json.revision).toBe(4);
    expect(server.events).toEqual([1, 2, 3, 4]);
  });

  it("refuses a session that does not exist and a malformed session target", async () => {
    const server = makeServer();
    const call = server.start();
    const gone = await call<{ error: string }>("POST", {
      target: { origin: "session", sessionId: "sess-gone" },
    });
    expect(gone.status).toBe(404);
    expect(gone.json.error).toBe("Session not found");
    for (const target of [
      { origin: "session" },
      { origin: "session", sessionId: "" },
      { origin: "session", sessionId: 7 },
      { origin: "session", sessionId: "sess\nrelease" },
      { origin: "session", sessionId: "x".repeat(257) },
      { origin: "session", sessionId: "sess-release", path: "~/notebook" },
    ]) {
      expect((await call("POST", { target })).status, JSON.stringify(target)).toBe(400);
    }
    expect((await call<PinsResponse>("GET")).json.pins).toEqual([]);
    expect(server.events).toEqual([]);
  });

  it("refuses a stored file whose session pin is not of kind session", async () => {
    const server = makeServer();
    mkdirSync(join(server.dataDir, "settings"), { recursive: true });
    writeFileSync(
      join(server.dataDir, "settings", "pins.json"),
      JSON.stringify({
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
      }),
    );
    expect((await server.start()("GET")).status).toBe(503);
  });
});

describe("pins protocol fixture", () => {
  it("matches the committed protocol/pins-http.json", () => {
    // Never writes: a deliberate regeneration runs `npm run protocol:fixtures:update`.
    expect(serializePinsHttpFixture()).toBe(readFileSync(PINS_HTTP_SNAPSHOT_FILE, "utf8"));
  });
});
