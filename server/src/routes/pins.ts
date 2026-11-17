import { open, opendir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import { isRecord } from "../json-shape.js";
import { resolveContainedPath } from "../directory-listing.js";
import { isRevision } from "../settings/revision.js";
import { validateSetting } from "../settings/registry.js";
import { workspaceMountRoot } from "../session-work-root.js";
import { PinsError, PinsStore, validatePinLabel, validatePinRoute } from "../storage/pins-store.js";
import type {
  Pin,
  PinAddResponse,
  PinRoute,
  PinStatus,
  PinsResponse,
  PinWithStatus,
} from "../types.js";
import { answerStatusError } from "./http.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export interface PinRouteOptions {
  homeDir?: string;
  /** How long one target's check may take before it reads `unknown`. */
  statusTimeoutMs?: number;
}

/** Where a folder or file lives on disk, or why it has no place. */
type Located =
  | { kind: "path"; path: string; confineTo?: string }
  | { kind: "workspaceMissing" }
  | { kind: "missing" };

/** What a list read found at a target, and a game's name. */
interface Checked {
  status: PinStatus;
  name?: string;
}

function errorCode(error: unknown): string | undefined {
  return isRecord(error) && typeof error.code === "string" ? error.code : undefined;
}

/**
 * Throws EACCES or EPERM unless `path` reads: a folder yields its first entry, a file opens.
 * Opening alone is not enough: Bun's `opendir` defers the open to the first read, so a
 * locked folder would pass there and fail on Node.
 */
async function canRead(path: string, folder: boolean): Promise<void> {
  if (folder) {
    const dir = await opendir(path);
    try {
      await dir.read();
    } finally {
      await dir.close();
    }
  } else {
    await (await open(path, "r")).close();
  }
}

/**
 * What is at `path` now, read the way the File Browser reads it: symlinks are followed (only a
 * sandbox root confines them), a folder must list and a file must read. A file where the pin
 * names a folder, or the other way round, is `missing`.
 */
async function probe(located: Located, folder: boolean): Promise<PinStatus> {
  if (located.kind !== "path") return located.kind;
  try {
    // A sandbox root confines symlinks as its file routes do.
    if (
      located.confineTo &&
      !(await resolveContainedPath(located.confineTo, located.path, { confineSymlinks: true }))
    ) {
      return "missing";
    }
    const info = await stat(located.path);
    if (folder ? !info.isDirectory() : !info.isFile()) return "missing";
    await canRead(located.path, folder);
    return "ok";
  } catch (error) {
    const code = errorCode(error);
    return code === "EACCES" || code === "EPERM" ? "unreadable" : "missing";
  }
}

/**
 * `GET /pins`, `POST /pins`, `PUT /pins`. A pin grants nothing: it is a pane route the app opens
 * as it opens that route's link, through the same routes and locks. Adding a pin checks what the
 * server can: a session (or a thread's or panel's session) exists; a folder or file in the home
 * folder or a workspace's main checkout opens the way the File Browser would open it; a workspace
 * exists; the Godot service knows a game (whatever the Godot Pane switch says). A web page, a
 * worktree's file, and a session copy's file are kept as they are. Git and commit routes are
 * refused. Changes send `pins_changed`.
 */
export function createPinRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
  options: PinRouteOptions = {},
): RouteDispatcher {
  const timeoutMs = options.statusTimeoutMs ?? 500;

  const workspaceStatus = (id: string | null): PinStatus =>
    id === null || ctx.storage.getWorkspace(id) ? "ok" : "workspaceMissing";
  const sessionStatus = (id: string): PinStatus => (ctx.storage.getSession(id) ? "ok" : "missing");

  /** A home path or a path in a workspace's main checkout on disk, or why it has no place. */
  function locate(at: { home: string } | { workspace: string; path: string }): Located {
    if ("home" in at) {
      const home = options.homeDir ?? homedir();
      return { kind: "path", path: at.home === "~" ? home : join(home, at.home.slice(2)) };
    }
    const workspace = ctx.storage.getWorkspace(at.workspace);
    if (!workspace) return { kind: "workspaceMissing" };
    let root: string;
    try {
      root = workspaceMountRoot(workspace, { create: false });
    } catch {
      return { kind: "missing" };
    }
    const path = at.path ? join(root, at.path) : root;
    return { kind: "path", path, ...(workspace.runtime === "sandbox" ? { confineTo: root } : {}) };
  }

  /** What is at a pin's route now, where the server can tell; `ok` where it does not check. */
  async function check(route: PinRoute): Promise<Checked> {
    switch (route.kind) {
      case "sessions":
        return { status: workspaceStatus(route.workspace) };
      case "session":
      case "thread":
        return { status: sessionStatus(route.id) };
      case "panel":
        return { status: sessionStatus(route.session) };
      case "file":
        if (route.origin === "host")
          return { status: await probe(locate({ home: route.path }), false) };
        if (route.origin === "session") return { status: sessionStatus(route.session) };
        // A worktree comes and goes with its work; only the main checkout is probed.
        if (route.worktree !== null) return { status: workspaceStatus(route.workspace) };
        return {
          status: await probe(locate({ workspace: route.workspace, path: route.path }), false),
        };
      case "files": {
        const at =
          "origin" in route
            ? { home: route.path ?? "~" }
            : { workspace: route.workspace, path: route.path ?? "" };
        return { status: await probe(locate(at), true) };
      }
      case "browser":
        return { status: "ok" };
      case "godot": {
        // Right after a restart the stored game stands in until discovery has walked once.
        const game = await ctx.godot?.detail(route.project);
        return game ? { status: "ok", name: game.name } : { status: "missing" };
      }
    }
  }

  /** Each pin with its status, checked in parallel; a slow check reads `unknown`. */
  async function withStatus(list: { revision: number; pins: Pin[] }): Promise<PinsResponse> {
    const pins = await Promise.all(
      list.pins.map(async (pin): Promise<PinWithStatus> => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<Checked>((resolve) => {
          timer = setTimeout(() => resolve({ status: "unknown" }), timeoutMs);
        });
        const { status, name } = await Promise.race([check(pin.target), timeout]);
        clearTimeout(timer);
        return name === undefined ? { ...pin, status } : { ...pin, status, name };
      }),
    );
    return { revision: list.revision, pins };
  }

  /** Why a route that is not there can't be pinned. */
  function notFound(route: PinRoute, status: PinStatus): string {
    if (status === "workspaceMissing") return "Workspace not found";
    switch (route.kind) {
      case "session":
      case "thread":
      case "panel":
        return "Session not found";
      case "godot":
        return "Game not found";
      case "file":
        return route.origin === "session" ? "Session not found" : "Nothing to pin at that path";
      default:
        return "Nothing to pin at that path";
    }
  }

  async function add(store: PinsStore, body: unknown): Promise<PinAddResponse> {
    if (!isRecord(body) || Object.keys(body).some((key) => key !== "target" && key !== "label")) {
      throw new PinsError(400, "Expected target and an optional label");
    }
    const target = validatePinRoute(body.target);
    const label = validatePinLabel(body.label);
    const { status } = await check(target);
    if (status !== "ok") throw new PinsError(404, notFound(target, status));
    const result = store.add(target, label);
    if (result.changed) ctx.appEvents?.emitPinsChanged(result.revision);
    return { ...(await withStatus(result)), pinId: result.pin.id };
  }

  return async ({ method, path, req, res }) => {
    if (path !== "/pins") return false;
    const store = new PinsStore(ctx.storage.getDataDir());
    try {
      if (method === "GET") {
        helpers.json(res, await withStatus(store.list()));
      } else if (method === "POST") {
        helpers.json(
          res,
          await add(store, await helpers.parseBody<unknown>(req, { maxBytes: 4096 })),
        );
      } else if (method === "PUT") {
        const body = await helpers.parseBody<unknown>(req, { maxBytes: 16_384 });
        if (
          !isRecord(body) ||
          Object.keys(body).length !== 2 ||
          !isRevision(body.baseRevision) ||
          !("pins" in body)
        ) {
          throw new PinsError(400, "Expected baseRevision and pins");
        }
        const entries = validateSetting("pins", body.pins);
        const result = store.reorder(body.baseRevision, entries);
        if ("conflict" in result) {
          const current = await withStatus(store.list());
          helpers.json(res, { error: "Pins changed", code: "revision_conflict", current }, 409);
          return true;
        }
        if (result.changed) ctx.appEvents?.emitPinsChanged(result.revision);
        helpers.json(res, await withStatus(result));
      } else {
        return false;
      }
    } catch (error) {
      if (!answerStatusError(helpers, res, error)) {
        helpers.error(res, 400, error instanceof Error ? error.message : "Invalid pins request");
      }
    }
    return true;
  };
}
