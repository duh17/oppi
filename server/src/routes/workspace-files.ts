import type { IncomingMessage, ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { stat, realpath } from "node:fs/promises";
import { join, extname } from "node:path";

import { resolveSdkSessionCwd } from "../sdk-backend.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

/**
 * Safety valve — not a real bandwidth constraint.
 *
 * We stream with `createReadStream` (no memory buffering), and this is
 * single-user self-hosted, so there's no multi-tenant concern. 50 MB
 * covers high-res screenshots and complex renders while still catching
 * accidental multi-GB file references.
 */
const MAX_FILE_SIZE = 50 * 1024 * 1024; // 50 MB

/** Extension allowlist — images only for the initial release. */
// periphery:ignore - exported for tests
export const ALLOWED_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]);

const CONTENT_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
};

/**
 * Resolve and validate a workspace-relative file path.
 *
 * Returns the canonical absolute path if it is valid and accessible, or
 * `null` if the path does not exist or escapes the workspace root via symlinks
 * or `..` traversal.
 */
// periphery:ignore - exported for tests
export async function resolveWorkspaceFilePath(
  workspaceRoot: string,
  requestedPath: string,
): Promise<string | null> {
  const joined = join(workspaceRoot, requestedPath);

  // Resolve symlinks on the requested path — this is what we serve.
  let realFile: string;
  try {
    realFile = await realpath(joined);
  } catch {
    return null;
  }

  // Resolve symlinks on the workspace root separately to get the canonical root.
  let realRoot: string;
  try {
    realRoot = await realpath(workspaceRoot);
  } catch {
    realRoot = workspaceRoot;
  }

  // Ensure the resolved file is strictly under the workspace root.
  const normalizedRoot = realRoot.endsWith("/") ? realRoot : realRoot + "/";
  if (realFile !== realRoot && !realFile.startsWith(normalizedRoot)) {
    return null;
  }

  return realFile;
}

export function createWorkspaceFileRoutes(
  ctx: RouteContext,
  helpers: RouteHelpers,
): RouteDispatcher {
  async function handleGetFile(
    wsId: string,
    requestedPath: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(wsId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    const ext = extname(requestedPath).toLowerCase();
    if (!ALLOWED_EXTENSIONS.has(ext)) {
      helpers.error(res, 403, "File type not allowed");
      return;
    }

    const workspaceRoot = resolveSdkSessionCwd(workspace);
    const realFile = await resolveWorkspaceFilePath(workspaceRoot, requestedPath);

    if (!realFile) {
      helpers.error(res, 404, "File not found");
      return;
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
    try {
      fileStat = await stat(realFile);
    } catch {
      helpers.error(res, 404, "File not found");
      return;
    }

    if (!fileStat.isFile()) {
      helpers.error(res, 404, "Not a file");
      return;
    }

    if (fileStat.size > MAX_FILE_SIZE) {
      helpers.error(res, 413, "File too large (max 50MB)");
      return;
    }

    const contentType = CONTENT_TYPES[ext] ?? "application/octet-stream";
    res.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": fileStat.size.toString(),
      "Cache-Control": "private, max-age=60",
    });
    createReadStream(realFile).pipe(res as NodeJS.WritableStream);
  }

  return async ({
    method,
    path,
    res,
  }: {
    method: string;
    path: string;
    url: URL;
    req: IncomingMessage;
    res: ServerResponse;
  }) => {
    const match = path.match(/^\/workspaces\/([^/]+)\/files\/(.+)$/);
    if (match && method === "GET") {
      await handleGetFile(match[1], match[2], res);
      return true;
    }
    return false;
  };
}
