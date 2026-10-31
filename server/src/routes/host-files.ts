import type { IncomingMessage, ServerResponse } from "node:http";
import { homedir } from "node:os";
import { basename, extname, isAbsolute } from "node:path";

import { getAgentDir } from "@earendil-works/pi-coding-agent";

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
import { decodeWorkspaceRoutePath, getContentType } from "../file-serving-policy.js";
import { createLogger, type Logger } from "../logger.js";
import { readAudioMediaInfo } from "../media-info.js";
import { piAgentCreatesIn, piAgentEditablePath } from "../pi-agent-files.js";
import { sessionWorkRoot, type SessionWorkRoot } from "../session-work-root.js";
import type { DirectoryListingResponse } from "../types.js";
import {
  ServerResourceNotFoundError,
  ServerResourceReadOnlyError,
} from "../server-resource-service.js";
import {
  FILE_EDIT_CREATABLE_HEADER,
  type FileEditTarget,
  inspectFileForEdit,
  putEditedFileFromRequest,
} from "../workspace-file-edit.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export interface HostFileRouteOptions {
  logger?: Logger;
  homeDir?: string;
  /** Pi's agent directory, the root of `origin=pi` (defaults to Pi's own). */
  piAgentDir?: string;
}

const defaultLog = createLogger({ base: { component: "host_files" } });

/** Query keys accepted by `/files/current`; anything else fails closed. */
const CURRENT_FILE_QUERY_KEYS = new Set([
  "path",
  "origin",
  "workspaceId",
  "worktreeId",
  "sessionId",
  "skillId",
]);

const SESSION_ROOT_ERRORS: Record<Exclude<SessionWorkRoot["kind"], "ok">, string> = {
  "no-workspace": "Workspace not found",
  "workspace-missing": "Workspace not found",
  "root-missing": "Workspace root not found",
  "worktree-unavailable": "Session root not found",
  "invalid-root": "Session root not found",
};

type CurrentFileRequest =
  | { kind: "ok"; origin: CurrentFileOrigin; path: string; originKind: string }
  | { kind: "error"; status: number; message: string };

/**
 * The file the editor reads and writes for a query origin, or null. Only the
 * `workspace`, `skill`, and `pi` query origins edit; a session read that
 * resolves into a workspace stays read-only.
 */
function editTargetFor(request: {
  originKind: string;
  origin: CurrentFileOrigin;
  path: string;
}): FileEditTarget | null {
  if (request.originKind === "workspace" && request.origin.kind === "workspace") {
    return {
      workspace: request.origin.workspace,
      root: request.origin.root,
      requestedPath: request.path,
    };
  }
  if (request.originKind === "skill" && request.origin.kind === "skill") {
    return { root: request.origin.root, requestedPath: request.path };
  }
  if (request.originKind === "pi" && request.origin.kind === "pi") {
    return {
      root: request.origin.agentDir,
      requestedPath: request.path,
      // The allowlist again, on the path after symlinks: a link inside the
      // agent directory must not reach a file the list does not name. This is
      // also where a *linked* Pi file stays read-only — `inspectFileForEdit`
      // refuses a final-component symlink and the canonical recheck refuses a
      // link that leads elsewhere — so whether a linked SYSTEM.md may be edited
      // is decided here and in that one refusal, and nowhere else.
      allowsCanonical: (relativeToRealRoot) => piAgentEditablePath(relativeToRealRoot) !== null,
      // A missing file the editor may create: the same allowlist, plus the one
      // directory it may appear in. `inspectFileForEdit` still proves that
      // directory is the real one and refuses a link, so a `prompts` symlink
      // creates nothing.
      createsIn: (parentRelativeToRealRoot) => piAgentCreatesIn(parentRelativeToRealRoot),
    };
  }
  return null;
}

export function createHostFileRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
  options: HostFileRouteOptions = {},
): RouteDispatcher {
  const log = options.logger ?? defaultLog;
  const homeDir = options.homeDir;
  // Read per request: Pi's agent directory is configuration (an env var or the
  // home it reads), not a value to freeze at route construction.
  const piAgentDir = (): string => options.piAgentDir ?? getAgentDir();

  /**
   * Parse the unified current-file origin. Origin selects path resolution; it
   * never falls back to a less restrictive origin.
   *
   * - `origin=host`: absolute, `~`, or local `file://` owner-host paths.
   * - `origin=workspace&workspaceId[&worktreeId]`: the selected checkout or mount.
   * - `origin=session&sessionId`: the session's actual cwd (worktree, sandbox
   *   mount, or control-session cwd).
   * - `origin=skill&skillId`: an editable Skill's own files, by Skill-relative
   *   path; a single-file Skill is that one file. Read-only Skills are 403.
   * - `origin=pi`: Pi's own agent files, by agent-relative path. The allowlist
   *   (`pi-agent-files.ts`) is these files only: the rest of the home stays
   *   read-only, and a path outside it is 404 for reads and writes alike.
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
    const skillId = params.get("skillId");
    const conflict = {
      kind: "error",
      status: 400,
      message: "Conflicting origin parameters",
    } as const;
    const dataDir = ctx.storage.getDataDir();

    if (originKind !== "skill" && skillId !== null) return conflict;

    switch (originKind) {
      case "host":
        if (workspaceId !== null || worktreeId !== null || sessionId !== null) return conflict;
        return { kind: "ok", origin: { kind: "host", homeDir }, path, originKind };
      case "pi": {
        if (workspaceId !== null || worktreeId !== null || sessionId !== null) return conflict;
        const editablePath = piAgentEditablePath(path);
        if (!editablePath) return { kind: "error", status: 404, message: "File not found" };
        let agentDir: string;
        try {
          agentDir = piAgentDir();
        } catch {
          log.warn("currentfile.pi_agent_dir_failed", {});
          return { kind: "error", status: 404, message: "File not found" };
        }
        if (!isAbsolute(agentDir)) return { kind: "error", status: 404, message: "File not found" };
        return { kind: "ok", origin: { kind: "pi", agentDir }, path: editablePath, originKind };
      }
      case "workspace": {
        if (!workspaceId || sessionId !== null) return conflict;
        const workspace = ctx.storage.getWorkspace(workspaceId);
        if (!workspace) return { kind: "error", status: 404, message: "Workspace not found" };
        const root = await resolveWorkspaceFileRoot(workspace, worktreeId ?? undefined, dataDir);
        if (!root) return { kind: "error", status: 404, message: "Worktree not found" };
        return {
          kind: "ok",
          origin: { kind: "workspace", workspace, root },
          path,
          originKind,
        };
      }
      case "session": {
        if (!sessionId || workspaceId !== null || worktreeId !== null) return conflict;
        const session = ctx.storage.getSession(sessionId);
        if (!session) return { kind: "error", status: 404, message: "Session not found" };
        let resolved: SessionWorkRoot;
        try {
          resolved = await sessionWorkRoot(session, ctx.storage, { create: false });
        } catch (error: unknown) {
          // Filesystem error text names host paths; keep it in the server log.
          log.warn("currentfile.session_root_failed", {
            sessionId,
            error: error instanceof Error ? error.message : String(error),
          });
          return { kind: "error", status: 500, message: "Session root not found" };
        }
        if (resolved.kind !== "ok") {
          return { kind: "error", status: 404, message: SESSION_ROOT_ERRORS[resolved.kind] };
        }
        // Workspace sessions read through their workspace (sandbox mounts stay
        // confined); control sessions have no workspace and read their
        // server-owned cwd as a host origin. Invalid control roots fail closed
        // above instead of being followed to alternate bytes.
        return {
          kind: "ok",
          origin: resolved.workspace
            ? { kind: "workspace", workspace: resolved.workspace, root: resolved.root }
            : { kind: "host", cwd: () => resolved.root, homeDir },
          path,
          originKind,
        };
      }
      case "skill": {
        if (!skillId || workspaceId !== null || worktreeId !== null || sessionId !== null) {
          return conflict;
        }
        try {
          const root = await ctx.serverResources.skillEditRoot(skillId, path);
          return { kind: "ok", origin: { kind: "skill", root }, path, originKind };
        } catch (error: unknown) {
          if (error instanceof ServerResourceReadOnlyError) {
            return { kind: "error", status: 403, message: error.message };
          }
          if (error instanceof ServerResourceNotFoundError) {
            return { kind: "error", status: 404, message: error.message };
          }
          log.warn("currentfile.skill_resolve_failed", {
            error: error instanceof Error ? error.message : String(error),
          });
          return { kind: "error", status: 500, message: "Unable to load server skills" };
        }
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
    const resolved = await resolveRequestFile(request, res);
    if ("status" in resolved) return resolved;
    return {
      file: resolved.file,
      originKind: request.originKind,
      origin: request.origin,
      path: request.path,
    };
  }

  /** Resolve a parsed request's file, answering the read's own error statuses. */
  async function resolveRequestFile(
    request: Extract<CurrentFileRequest, { kind: "ok" }>,
    res: ServerResponse,
  ): Promise<{ file: ResolvedCurrentFile } | { status: number }> {
    const resolved = await resolveCurrentFilePath(request.origin, request.path);
    switch (resolved.kind) {
      case "ok":
        return { file: resolved.file };
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
      const request = await parseCurrentFileRequest(url);
      if (request.kind === "error") {
        status = request.status;
        helpers.error(res, request.status, request.message);
        return;
      }
      originKind = request.originKind;
      // One inspection answers both the tag and the miss: an editing origin (a
      // workspace, a Skill, Pi's agent files) either tags the bytes or — where
      // the target may create — answers the empty base of a file that is not
      // there yet. Every other read resolves and serves as before.
      const editTarget = req.headers.range ? null : editTargetFor(request);
      const inspection = editTarget ? await inspectFileForEdit(editTarget) : null;
      if (inspection?.kind === "creatable") {
        status = sendExactFileBytes(
          res,
          method,
          {
            bytes: Buffer.alloc(0),
            contentType: getContentType(
              extname(request.path).toLowerCase(),
              basename(request.path),
            ),
          },
          { [FILE_EDIT_CREATABLE_HEADER]: "1" },
        );
        return;
      }
      const resolved = await resolveRequestFile(request, res);
      if ("status" in resolved) {
        status = resolved.status;
        return;
      }
      const servable = await statServableFile(resolved.file.realPath, resolved.file.lexicalPath);
      switch (servable.kind) {
        case "ok": {
          const extraHeaders = resolvedPathHeaders(resolved.file);
          // ETag only for an editing origin (workspace, skill, pi), not session→workspace.
          if (inspection?.kind === "eligible") {
            status = sendExactFileBytes(
              res,
              method,
              { bytes: inspection.bytes, contentType: servable.file.contentType },
              { ...extraHeaders, ETag: inspection.etag },
            );
            return;
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
    let skillId: string | undefined;
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
      const target = editTargetFor(request);
      if (!target) {
        status = 404;
        helpers.error(res, 404, "File not found");
        return;
      }
      workspaceId = target.workspace?.id;
      skillId =
        request.originKind === "skill" ? (url.searchParams.get("skillId") ?? undefined) : undefined;

      const result = await putEditedFileFromRequest(req, target);
      size = result.size ?? null;
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
        skillId,
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

  async function handleCurrentFileMediaInfo(url: URL, res: ServerResponse): Promise<void> {
    let status = 404;
    let originKind: string | undefined;
    let durationKnown = false;
    try {
      const resolved = await resolveCurrentFileRequest(url, res);
      if ("status" in resolved) {
        status = resolved.status;
        return;
      }
      originKind = resolved.originKind;
      const servable = await statServableFile(resolved.file.realPath, resolved.file.lexicalPath);
      if (servable.kind !== "ok") {
        helpers.error(res, 404, "File not found");
        return;
      }
      // Only audio is parsed; any other servable file has no media info.
      if (!servable.file.contentType.startsWith("audio/")) {
        status = 200;
        helpers.json(res, {});
        return;
      }
      const read = await readAudioMediaInfo(servable.file.filePath, servable.file.contentType);
      if (read.kind === "error") {
        status = read.status;
        helpers.error(
          res,
          read.status,
          read.status === 404 ? "File not found" : "Failed to read file",
        );
        return;
      }
      durationKnown = read.info.durationSeconds !== undefined;
      status = 200;
      helpers.json(res, read.info);
    } finally {
      log.info("currentfile.media_info", { origin: originKind, status, durationKnown });
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

    if (path === "/files/current/media-info") {
      if (normalizedMethod !== "GET") return false;
      await handleCurrentFileMediaInfo(url, res);
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
