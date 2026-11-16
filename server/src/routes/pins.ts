import { open, opendir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import { isRecord } from "../json-shape.js";
import { resolveContainedPath } from "../directory-listing.js";
import { isRevision } from "../settings/revision.js";
import { validateSetting } from "../settings/registry.js";
import { workspaceMountRoot } from "../session-work-root.js";
import {
  PinsError,
  PinsStore,
  validatePinLabel,
  validatePinTarget,
} from "../storage/pins-store.js";
import type {
  Pin,
  PinAddResponse,
  PinStatus,
  PinTarget,
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

/** Where a target lives on disk, or why it has no place. */
type Located =
  | { kind: "path"; path: string; confineTo?: string }
  | { kind: "workspaceMissing" }
  | { kind: "missing" };

function errorCode(error: unknown): string | undefined {
  return isRecord(error) && typeof error.code === "string" ? error.code : undefined;
}

/**
 * Throws EACCES or EPERM unless `path` reads: a folder yields its first entry, a file opens.
 * Opening alone is not enough: Bun's `opendir` defers the open to the first read, so a
 * locked folder would pass there and fail on Node.
 */
async function canRead(path: string, kind: Pin["kind"]): Promise<void> {
  if (kind === "directory") {
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
 * sandbox root confines them), a folder must list and a file must read.
 */
async function probe(
  located: Located,
  kind: Pin["kind"] | undefined,
): Promise<{
  status: PinStatus;
  kind?: Pin["kind"];
}> {
  if (located.kind !== "path") return { status: located.kind };
  try {
    // A sandbox root confines symlinks as its file routes do.
    if (
      located.confineTo &&
      !(await resolveContainedPath(located.confineTo, located.path, { confineSymlinks: true }))
    ) {
      return { status: "missing" };
    }
    const info = await stat(located.path);
    const found: Pin["kind"] | undefined = info.isDirectory()
      ? "directory"
      : info.isFile()
        ? "file"
        : undefined;
    if (!found || (kind && found !== kind)) return { status: "missing" };
    await canRead(located.path, found);
    return { status: "ok", kind: found };
  } catch (error) {
    const code = errorCode(error);
    return { status: code === "EACCES" || code === "EPERM" ? "unreadable" : "missing" };
  }
}

/**
 * `GET /pins`, `POST /pins`, `PUT /pins`. A pin grants nothing: adding one checks the target the
 * way the File Browser would open it (inside the home folder or the workspace, with today's
 * symlink rules), and every open still goes through the file routes. A session pin needs only that
 * the session exists; its chat opens through the session routes. Changes send `pins_changed`.
 */
export function createPinRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
  options: PinRouteOptions = {},
): RouteDispatcher {
  const timeoutMs = options.statusTimeoutMs ?? 500;

  /** A place's target (a folder or file) on disk, or why it has no place. */
  function locate(target: Exclude<PinTarget, { origin: "session" }>): Located {
    if (target.origin === "host") {
      const home = options.homeDir ?? homedir();
      return { kind: "path", path: target.path === "~" ? home : join(home, target.path.slice(2)) };
    }
    const workspace = ctx.storage.getWorkspace(target.workspaceId);
    if (!workspace) return { kind: "workspaceMissing" };
    let root: string;
    try {
      root = workspaceMountRoot(workspace, { create: false });
    } catch {
      return { kind: "missing" };
    }
    const path = target.path ? join(root, target.path) : root;
    return { kind: "path", path, ...(workspace.runtime === "sandbox" ? { confineTo: root } : {}) };
  }

  /** What is at a pin's target now: a session is there or deleted; a place is probed on disk. */
  async function check(
    target: PinTarget,
    kind: Pin["kind"] | undefined,
  ): Promise<{ status: PinStatus; kind?: Pin["kind"] }> {
    if (target.origin === "session") {
      return ctx.storage.getSession(target.sessionId)
        ? { status: "ok", kind: "session" }
        : { status: "missing" };
    }
    return probe(locate(target), kind === "session" ? undefined : kind);
  }

  /** Each pin with its status, checked in parallel; a slow check reads `unknown`. */
  async function withStatus(list: { revision: number; pins: Pin[] }): Promise<PinsResponse> {
    const pins = await Promise.all(
      list.pins.map(async (pin): Promise<PinWithStatus> => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const timeout = new Promise<PinStatus>((resolve) => {
          timer = setTimeout(() => resolve("unknown"), timeoutMs);
        });
        const found = check(pin.target, pin.kind).then((result) => result.status);
        const status = await Promise.race([found, timeout]);
        clearTimeout(timer);
        return { ...pin, status };
      }),
    );
    return { revision: list.revision, pins };
  }

  async function add(store: PinsStore, body: unknown): Promise<PinAddResponse> {
    if (!isRecord(body) || Object.keys(body).some((key) => key !== "target" && key !== "label")) {
      throw new PinsError(400, "Expected target and an optional label");
    }
    const target = validatePinTarget(body.target);
    const label = validatePinLabel(body.label);
    if (target.origin !== "session" && locate(target).kind === "workspaceMissing") {
      throw new PinsError(404, "Workspace not found");
    }
    const found = await check(target, undefined);
    if (!found.kind) {
      throw new PinsError(
        404,
        target.origin === "session" ? "Session not found" : "Nothing to pin at that path",
      );
    }
    const result = store.add(target, found.kind, label);
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
