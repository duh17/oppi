import { realpath } from "node:fs/promises";
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
import {
  FILE_EDIT_ORIGIN_HEADER,
  FILE_EDIT_REFUSAL_HEADER,
  FILE_EDIT_RESOLVE_HEADER,
  fileEditOriginQuery,
  fileEditTargetForOwner,
  type FileEditOwnerResult,
  type FileEditOwnerSources,
  hostFileEditTarget,
  piFileEditTarget,
  protectedRoots,
  resolveFileEditOwner,
  workspaceFileEditTarget,
} from "../file-edit-owner.js";
import { decodeWorkspaceRoutePath, getContentType } from "../file-serving-policy.js";
import { expandExactHostPath } from "../host-file-path.js";
import { createLogger, type Logger } from "../logger.js";
import { readAudioMediaInfo } from "../media-info.js";
import { piAgentEditablePath } from "../pi-agent-files.js";
import { isDeviceAccessPrincipal, type RequestPrincipal } from "../request-principal.js";
import { sessionWorkRoot, type SessionWorkRoot } from "../session-work-root.js";
import type { DirectoryListingResponse } from "../types.js";
import {
  ServerResourceNotFoundError,
  ServerResourceReadOnlyError,
} from "../server-resource-service.js";
import {
  FILE_EDIT_CREATABLE_HEADER,
  type FileEditInspection,
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
 * The file the editor reads and writes for a query origin that names its own
 * root, or null. The `workspace`, `skill`, and `pi` origins edit by path under
 * that root; `origin=host` edits too, but only once `resolveFileEditOwner`
 * proves the file has no narrower owner (see `handleCurrentFilePut`). A
 * session read names its file's owner through `X-Oppi-Edit-Origin` instead.
 */
function editTargetFor(request: {
  originKind: string;
  origin: CurrentFileOrigin;
  path: string;
}): FileEditTarget | null {
  if (request.originKind === "workspace" && request.origin.kind === "workspace") {
    return workspaceFileEditTarget(request.origin.workspace, request.origin.root, request.path);
  }
  if (request.originKind === "skill" && request.origin.kind === "skill") {
    return { root: request.origin.root, requestedPath: request.path };
  }
  if (request.originKind === "pi" && request.origin.kind === "pi") {
    return piFileEditTarget(request.origin.agentDir, request.path);
  }
  return null;
}

/** A read asked for its file's edit origin: the client sends `X-Oppi-Edit-Resolve: 1`. */
function asksForEditOrigin(req: IncomingMessage): boolean {
  return req.headers[FILE_EDIT_RESOLVE_HEADER] === "1" && !req.headers.range;
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

  /** What `resolveFileEditOwner` reads: this server's workspaces, Skills, Pi, and home. */
  function ownerSources(): FileEditOwnerSources {
    return {
      workspaces: () => ctx.storage.listWorkspaces(),
      dataDir: ctx.storage.getDataDir(),
      agentDir: () => {
        const dir = piAgentDir();
        return isAbsolute(dir) ? dir : null;
      },
      homeDir,
      hostFilesEnabled: () => ctx.storage.getConfig().fileEditing?.hostFiles !== false,
      skillContaining: async (realPath) => {
        try {
          return await ctx.serverResources.skillContaining(realPath);
        } catch (error: unknown) {
          // No Skill catalog means no Skill owner; the file falls to the next one.
          log.warn("currentfile.skill_owner_failed", {
            error: error instanceof Error ? error.message : String(error),
          });
          return null;
        }
      },
    };
  }

  /**
   * `X-Oppi-Edit-Origin` (the query that edits this file) or
   * `X-Oppi-Edit-Refusal` (why it has no editor) for a read that resolved to
   * `realPath`, and the owner's eligible inspection when there is one. A read
   * through a sandbox workspace, directly or as a sandbox session, is confined
   * to that workspace.
   */
  async function editOriginAnswer(
    request: Extract<CurrentFileRequest, { kind: "ok" }>,
    realPath: string,
    lexicalPath: string,
  ): Promise<{
    headers: Record<string, string>;
    inspection: Extract<FileEditInspection, { kind: "eligible" }> | null;
  }> {
    const confinement =
      request.origin.kind === "workspace" && request.origin.workspace.runtime === "sandbox"
        ? { workspace: request.origin.workspace, root: request.origin.root }
        : undefined;
    const sources = ownerSources();
    const result: FileEditOwnerResult = await resolveFileEditOwner({
      realPath,
      lexicalPath,
      sources,
      confinement,
    });
    if (result.kind === "refused") {
      return { headers: { [FILE_EDIT_REFUSAL_HEADER]: result.reason }, inspection: null };
    }
    const target = fileEditTargetForOwner(result.owner, protectedRoots(sources) ?? undefined);
    const inspection = target ? await inspectFileForEdit(target) : null;
    // The owner's own read must land on the file this read served; anything
    // else (a swap in between, a size or encoding refusal) has no editor.
    if (inspection?.kind !== "eligible" || inspection.realPath !== realPath) {
      return { headers: { [FILE_EDIT_REFUSAL_HEADER]: "ineligible" }, inspection: null };
    }
    return {
      headers: { [FILE_EDIT_ORIGIN_HEADER]: fileEditOriginQuery(result.owner) },
      inspection,
    };
  }

  /**
   * The editor target of a `PUT ?origin=host`: a file under the home whose
   * owner is the host itself. A file a narrower owner holds (a workspace, a
   * Skill, Pi) is written through that owner, so the same file never has two
   * write paths with different rules; a protected file is never written.
   */
  async function hostWriteTarget(
    path: string,
    principal: RequestPrincipal | undefined,
  ): Promise<
    | { kind: "ok"; target: FileEditTarget; realPath: string }
    | { kind: "error"; status: number; message: string }
  > {
    // The owner, locally, or one of the owner's paired devices: the two
    // principals that may already run agents on this host. Stated here, not
    // only in the route's auth, so a narrower credential added later does not
    // inherit writes anywhere in the home.
    if (principal?.kind !== "owner" && !isDeviceAccessPrincipal(principal)) {
      return { kind: "error", status: 403, message: "File is not editable" };
    }
    const lexical = expandExactHostPath(path, { homeDir });
    if (!lexical) return { kind: "error", status: 404, message: "File not found" };
    let real: string;
    try {
      real = await realpath(lexical);
    } catch {
      // Host files are never created through the editor.
      return { kind: "error", status: 404, message: "File not found" };
    }
    const sources = ownerSources();
    const result = await resolveFileEditOwner({ realPath: real, lexicalPath: lexical, sources });
    if (result.kind === "refused") {
      return { kind: "error", status: 403, message: "File is not editable" };
    }
    if (result.owner.kind !== "host") {
      return {
        kind: "error",
        status: 409,
        message: `Edit this file through origin=${result.owner.kind}`,
      };
    }
    const roots = protectedRoots(sources);
    const target = roots ? hostFileEditTarget(roots, lexical) : null;
    if (!target) return { kind: "error", status: 403, message: "File is not editable" };
    return { kind: "ok", target, realPath: real };
  }

  /**
   * Parse the unified current-file origin. Origin selects path resolution; it
   * never falls back to a less restrictive origin.
   *
   * - `origin=host`: absolute, `~`, or local `file://` owner-host paths. A
   *   write needs a file under the home that no narrower origin owns and the
   *   refusal list allows (`file-edit-owner.ts`).
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
          {
            [FILE_EDIT_CREATABLE_HEADER]: "1",
            // A missing file has no canonical path: the origin that offers to
            // create it (Pi's own files, a checkout's pane layouts) is the one
            // that writes it.
            ...(asksForEditOrigin(req) && request.origin.kind === "pi"
              ? {
                  [FILE_EDIT_ORIGIN_HEADER]: fileEditOriginQuery({
                    kind: "pi",
                    agentDir: request.origin.agentDir,
                    path: request.path,
                  }),
                }
              : {}),
          },
        );
        return;
      }
      const resolved = await resolveRequestFile(request, res);
      if ("status" in resolved) {
        status = resolved.status;
        return;
      }
      const servable = await statServableFile(resolved.file.realPath, resolved.file.lexicalPath, {
        wholeRead: method === "GET" && req.headers.range === undefined,
      });
      switch (servable.kind) {
        case "ok": {
          let extraHeaders = resolvedPathHeaders(resolved.file);
          // The tag: an editing origin's own inspection (what older clients
          // read), or — when the reader asked — the inspection of the origin that
          // owns the file however it was reached. The tag is the bytes' hash,
          // so it is the same whichever origin answers it.
          let tagged = inspection?.kind === "eligible" ? inspection : null;
          if (asksForEditOrigin(req)) {
            const answer = await editOriginAnswer(
              request,
              resolved.file.realPath,
              resolved.file.lexicalPath,
            );
            extraHeaders = { ...extraHeaders, ...answer.headers };
            tagged ??= answer.inspection;
          }
          if (tagged) {
            status = sendExactFileBytes(
              res,
              method,
              { bytes: tagged.bytes, contentType: servable.file.contentType },
              { ...extraHeaders, ETag: tagged.etag },
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
    principal: RequestPrincipal | undefined,
  ): Promise<void> {
    let status = 404;
    let originKind: string | undefined;
    let workspaceId: string | undefined;
    let skillId: string | undefined;
    let relativePath: string | undefined;
    // A host write's audit: the file it resolved to and the device that sent it.
    let realPath: string | undefined;
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
      let target = editTargetFor(request);
      if (request.originKind === "host") {
        const host = await hostWriteTarget(request.path, principal);
        if (host.kind === "error") {
          status = host.status;
          helpers.error(res, host.status, host.message);
          return;
        }
        target = host.target;
        realPath = host.realPath;
      }
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
      // Paths and sizes only, never the bytes.
      log.info("currentfile.write", {
        origin: originKind,
        workspaceId,
        skillId,
        path: relativePath,
        ...(realPath !== undefined && realPath !== relativePath ? { realPath } : {}),
        ...(originKind === "host" && principal?.kind === "device"
          ? { device: principal.deviceId }
          : {}),
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
      const read = await readAudioMediaInfo(servable.file.filePath);
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

  return async ({ method, path, url, req, res, principal }) => {
    const normalizedMethod = method.toUpperCase();
    const readsBytes = normalizedMethod === "GET" || normalizedMethod === "HEAD";

    if (path === "/files/current") {
      if (normalizedMethod === "PUT") {
        await handleCurrentFilePut(url, req, res, principal);
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
