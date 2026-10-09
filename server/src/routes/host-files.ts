import type { IncomingMessage, ServerResponse } from "node:http";
import { homedir } from "node:os";
import { isAbsolute } from "node:path";

import { isControlRouteSession } from "../control-session.js";
import {
  listTimedTextSidecars,
  resolveCurrentFilePath,
  resolvedPathHeaders,
  resolveWorkspaceFileRoot,
  sendExactFileBytes,
  sendFileBytes,
  statServableFile,
  type CurrentFileOrigin,
  type ResolvedCurrentFile,
} from "../current-file.js";
import { listDirectoryEntries } from "../directory-listing.js";
import { decodeWorkspaceRoutePath } from "../file-serving-policy.js";
import { createLogger, type Logger } from "../logger.js";
import { resolveSdkSessionCwd, resolveSdkSessionCwdAsync } from "../sdk-backend.js";
import type { DirectoryListingResponse } from "../types.js";
import {
  evaluateIfMatch,
  inspectWorkspaceFileForEdit,
  putWorkspaceFile,
  readBoundedRequestBody,
  WORKSPACE_FILE_EDIT_MAX_BYTES,
} from "../workspace-file-edit.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export interface HostFileRouteOptions {
  logger?: Logger;
  homeDir?: string;
}

const defaultLog = createLogger({ base: { component: "host_files" } });

/** Query keys accepted by `/files/current`; anything else fails closed. */
const CURRENT_FILE_QUERY_KEYS = new Set([
  "path",
  "origin",
  "workspaceId",
  "worktreeId",
  "sessionId",
]);

type CurrentFileRequest =
  | { kind: "ok"; origin: CurrentFileOrigin; path: string; originKind: string }
  | { kind: "error"; status: number; message: string };

export function createHostFileRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
  options: HostFileRouteOptions = {},
): RouteDispatcher {
  const log = options.logger ?? defaultLog;
  const homeDir = options.homeDir;

  /** Control sessions share one server-owned cwd; invalid roots fail closed. */
  function controlSessionCwd(sessionId: string | null): string | null {
    if (!sessionId) return null;
    const session = ctx.storage.getSession(sessionId);
    if (!session || !isControlRouteSession(session)) return null;
    try {
      return resolveSdkSessionCwd(undefined, session, { dataDir: ctx.storage.getDataDir() });
    } catch {
      // The runtime rejects symlinked/non-directory control roots. File reads
      // must reject the same invalid origin, not follow it to alternate bytes.
      return null;
    }
  }

  /**
   * Parse the unified current-file origin. Origin selects path resolution; it
   * never falls back to a less restrictive origin.
   *
   * - `origin=host`: absolute, `~`, or local `file://` owner-host paths.
   * - `origin=workspace&workspaceId[&worktreeId]`: the selected checkout or mount.
   * - `origin=session&sessionId`: the session's actual cwd (worktree, sandbox
   *   mount, or control-session cwd).
   */
  async function parseCurrentFileRequest(url: URL): Promise<CurrentFileRequest> {
    const params = url.searchParams;
    for (const key of new Set(params.keys())) {
      if (!CURRENT_FILE_QUERY_KEYS.has(key) || params.getAll(key).length !== 1) {
        return { kind: "error", status: 400, message: `Invalid query parameter: ${key}` };
      }
    }
    const path = params.get("path") ?? "";
    if (!path) return { kind: "error", status: 400, message: "path parameter required" };
    const originKind = params.get("origin");
    const workspaceId = params.get("workspaceId");
    const worktreeId = params.get("worktreeId");
    const sessionId = params.get("sessionId");
    const conflict = {
      kind: "error",
      status: 400,
      message: "Conflicting origin parameters",
    } as const;
    const dataDir = ctx.storage.getDataDir();

    switch (originKind) {
      case "host":
        if (workspaceId !== null || worktreeId !== null || sessionId !== null) return conflict;
        return { kind: "ok", origin: { kind: "host", homeDir }, path, originKind };
      case "workspace": {
        if (!workspaceId || sessionId !== null) return conflict;
        const workspace = ctx.storage.getWorkspace(workspaceId);
        if (!workspace) return { kind: "error", status: 404, message: "Workspace not found" };
        const root = await resolveWorkspaceFileRoot(workspace, worktreeId ?? undefined, dataDir);
        if (!root) return { kind: "error", status: 404, message: "Worktree not found" };
        return {
          kind: "ok",
          origin: { kind: "workspace", workspace, root, dataDir },
          path,
          originKind,
        };
      }
      case "session": {
        if (!sessionId || workspaceId !== null || worktreeId !== null) return conflict;
        const session = ctx.storage.getSession(sessionId);
        if (!session) return { kind: "error", status: 404, message: "Session not found" };
        if (isControlRouteSession(session)) {
          const cwd = controlSessionCwd(sessionId);
          if (!cwd) return { kind: "error", status: 404, message: "Session root not found" };
          return {
            kind: "ok",
            origin: { kind: "host", cwd: () => cwd, homeDir },
            path,
            originKind,
          };
        }
        const workspace = session.workspaceId
          ? ctx.storage.getWorkspace(session.workspaceId)
          : undefined;
        if (!workspace) return { kind: "error", status: 404, message: "Workspace not found" };
        let root: string;
        try {
          root = await resolveSdkSessionCwdAsync(workspace, session, { dataDir });
        } catch {
          return { kind: "error", status: 404, message: "Session root not found" };
        }
        return {
          kind: "ok",
          origin: { kind: "workspace", workspace, root, dataDir },
          path,
          originKind,
        };
      }
      default:
        return { kind: "error", status: 400, message: "Invalid origin" };
    }
  }

  async function resolveCurrentFileRequest(
    url: URL,
    res: ServerResponse,
  ): Promise<
    | {
        file: ResolvedCurrentFile;
        originKind: string;
        origin: CurrentFileOrigin;
        path: string;
      }
    | { status: number }
  > {
    const request = await parseCurrentFileRequest(url);
    if (request.kind === "error") {
      helpers.error(res, request.status, request.message);
      return { status: request.status };
    }
    const resolved = await resolveCurrentFilePath(request.origin, request.path);
    switch (resolved.kind) {
      case "ok":
        return {
          file: resolved.file,
          originKind: request.originKind,
          origin: request.origin,
          path: request.path,
        };
      case "outside-sandbox":
        helpers.error(res, 403, "Path outside sandbox workspace");
        return { status: 403 };
      case "root-not-found":
        helpers.error(res, 404, "Workspace root not found");
        return { status: 404 };
      case "not-found":
        helpers.error(res, 404, "File not found");
        return { status: 404 };
    }
  }

  async function handleCurrentFile(
    method: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let status = 404;
    let originKind: string | undefined;
    try {
      const resolved = await resolveCurrentFileRequest(url, res);
      if ("status" in resolved) {
        status = resolved.status;
        return;
      }
      originKind = resolved.originKind;
      const servable = await statServableFile(resolved.file.realPath, resolved.file.lexicalPath);
      switch (servable.kind) {
        case "ok": {
          const extraHeaders = resolvedPathHeaders(resolved.file);
          // ETag only when the query origin is workspace, not session→workspace.
          if (
            originKind === "workspace" &&
            resolved.origin.kind === "workspace" &&
            !req.headers.range
          ) {
            const inspection = await inspectWorkspaceFileForEdit({
              workspace: resolved.origin.workspace,
              root: resolved.origin.root,
              requestedPath: resolved.path,
              dataDir: resolved.origin.dataDir,
            });
            if (inspection.kind === "eligible") {
              status = sendExactFileBytes(
                res,
                method,
                { bytes: inspection.bytes, contentType: servable.file.contentType },
                { ...extraHeaders, ETag: inspection.etag },
              );
              return;
            }
          }
          status = await sendFileBytes(req, res, method, servable.file, {
            rangeLogTag: "current-file",
            extraHeaders,
          });
          return;
        }
        case "too-large":
          status = 413;
          helpers.error(res, 413, `File too large (max ${servable.maxSizeMegabytes}MB)`);
          return;
        case "not-file":
        case "missing":
        case "unreadable":
          helpers.error(res, 404, "File not found");
          return;
      }
    } finally {
      log.info("currentfile.read", { method, origin: originKind, status });
    }
  }

  async function handleCurrentFilePut(
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let status = 404;
    let originKind: string | undefined;
    let workspaceId: string | undefined;
    let relativePath: string | undefined;
    let size: number | null = null;
    try {
      const request = await parseCurrentFileRequest(url);
      if (request.kind === "error") {
        status = request.status;
        helpers.error(res, request.status, request.message);
        return;
      }
      originKind = request.originKind;
      relativePath = request.path;
      if (request.originKind !== "workspace" || request.origin.kind !== "workspace") {
        status = 404;
        helpers.error(res, 404, "File not found");
        return;
      }
      workspaceId = request.origin.workspace.id;

      const precondition = evaluateIfMatch(req.headers["if-match"]);
      if (precondition.kind === "missing") {
        status = 428;
        helpers.error(res, 428, "If-Match precondition required");
        return;
      }
      if (precondition.kind === "wildcard" || precondition.kind === "invalid") {
        status = 412;
        helpers.error(res, 412, "Precondition failed");
        return;
      }

      const body = await readBoundedRequestBody(req, WORKSPACE_FILE_EDIT_MAX_BYTES);
      if (body.kind === "too-large") {
        status = 413;
        helpers.error(
          res,
          413,
          `File too large (max ${Math.round(WORKSPACE_FILE_EDIT_MAX_BYTES / (1024 * 1024))}MB)`,
        );
        req.resume();
        return;
      }
      if (body.kind === "error") {
        status = 400;
        helpers.error(res, 400, "Failed to read body");
        return;
      }
      size = body.bytes.length;

      const result = await putWorkspaceFile({
        workspace: request.origin.workspace,
        root: request.origin.root,
        requestedPath: request.path,
        dataDir: request.origin.dataDir,
        ifMatch: req.headers["if-match"],
        body: body.bytes,
      });
      if (result.kind === "error") {
        status = result.status;
        helpers.error(res, result.status, result.message);
        return;
      }
      status = 200;
      helpers.json(res, result.response);
    } finally {
      log.info("currentfile.write", {
        origin: originKind,
        workspaceId,
        path: relativePath,
        status,
        ...(size !== null ? { size } : {}),
      });
    }
  }

  async function handleCurrentFileSidecars(url: URL, res: ServerResponse): Promise<void> {
    const resolved = await resolveCurrentFileRequest(url, res);
    if ("status" in resolved) return;
    const servable = await statServableFile(resolved.file.realPath, resolved.file.lexicalPath);
    if (servable.kind !== "ok" && servable.kind !== "too-large") {
      helpers.error(res, 404, "File not found");
      return;
    }
    helpers.json(res, await listTimedTextSidecars(resolved.file));
  }

  /** Legacy `/files/raw`: the host origin with optional control-session cwd; errors are 404. */
  async function handleHostRawFile(
    method: string,
    url: URL,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    let status = 404;
    let resolvedPath: string | null = null;
    let size: number | null = null;

    try {
      const resolved = await resolveCurrentFilePath(
        {
          kind: "host",
          homeDir,
          cwd: () => controlSessionCwd(url.searchParams.get("controlSessionId")),
        },
        url.searchParams.get("path") ?? "",
      );
      if (resolved.kind !== "ok") {
        helpers.error(res, 404, "File not found");
        return;
      }
      resolvedPath = resolved.file.realPath;
      const servable = await statServableFile(resolvedPath);
      if (servable.kind === "too-large") {
        status = 413;
        helpers.error(res, 413, `File too large (max ${servable.maxSizeMegabytes}MB)`);
        return;
      }
      if (servable.kind !== "ok") {
        helpers.error(res, 404, "File not found");
        return;
      }
      size = servable.file.size;
      // Authenticated clients need the canonical path for tap-time disclosure
      // and the viewer title. Audit logs already use it.
      status = await sendFileBytes(req, res, method, servable.file, {
        rangeLogTag: "host-raw",
        extraHeaders: resolvedPathHeaders(resolved.file),
      });
    } finally {
      log.info("hostfile.read", { method, size, status });
      log.debug("hostfile.read.path", { method, realpath: resolvedPath, size, status });
    }
  }

  return async ({ method, path, url, req, res }) => {
    const normalizedMethod = method.toUpperCase();
    const readsBytes = normalizedMethod === "GET" || normalizedMethod === "HEAD";

    if (path === "/files/current") {
      if (normalizedMethod === "PUT") {
        await handleCurrentFilePut(url, req, res);
        return true;
      }
      if (!readsBytes) return false;
      await handleCurrentFile(normalizedMethod, url, req, res);
      return true;
    }

    if (path === "/files/current/sidecars") {
      if (normalizedMethod !== "GET") return false;
      await handleCurrentFileSidecars(url, res);
      return true;
    }

    if (path === "/files/raw") {
      if (!readsBytes) return false;
      await handleHostRawFile(normalizedMethod, url, req, res);
      return true;
    }

    if (normalizedMethod !== "GET") return false;

    if (path === "/host/contents" || path === "/host/contents/") {
      await handleListHostDirectory("", res, helpers, homeDir);
      return true;
    }

    const contentsMatch = path.match(/^\/host\/contents\/(.*)$/);
    if (!contentsMatch) return false;

    const requestedPath = decodeWorkspaceRoutePath(contentsMatch[1]);
    if (requestedPath === null) {
      helpers.error(res, 400, "Invalid file path encoding");
      return true;
    }

    await handleListHostDirectory(requestedPath, res, helpers, homeDir);
    return true;
  };
}

async function handleListHostDirectory(
  requestedPath: string,
  res: ServerResponse,
  helpers: RouteHelpers,
  homeDir: string | undefined,
): Promise<void> {
  let home: string;
  try {
    home = homeDir ?? homedir();
  } catch {
    helpers.error(res, 404, "Directory not found");
    return;
  }
  if (!home || !isAbsolute(home)) {
    helpers.error(res, 404, "Directory not found");
    return;
  }

  const dirPath = requestedPath.endsWith("/") ? requestedPath.slice(0, -1) : requestedPath;
  const result = await listDirectoryEntries(home, dirPath || ".");
  if (!result) {
    helpers.error(res, 404, "Directory not found");
    return;
  }

  const response: DirectoryListingResponse = {
    path: requestedPath || "/",
    entries: result.entries,
    truncated: result.truncated,
  };
  helpers.json(res, response);
}
