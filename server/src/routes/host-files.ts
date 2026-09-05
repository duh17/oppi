import type { IncomingMessage, ServerResponse } from "node:http";
import { createReadStream, constants } from "node:fs";
import { access, realpath, stat } from "node:fs/promises";
import { extname } from "node:path";

import {
  getContentType,
  isBrowseMediaContentType,
  isStreamingMediaContentType,
  MAX_BROWSE_IMAGE_FILE_SIZE,
  MAX_BROWSE_TEXT_FILE_SIZE,
} from "../file-serving-policy.js";
import { encodeHostResolvedPathHeader, expandExactHostPath } from "../host-file-path.js";
import { logRejectedByteRange, parseByteRangeHeader } from "../http-range.js";
import { createLogger, type Logger } from "../logger.js";
import type { RouteDispatcher, RouteHelpers } from "./types.js";

export interface HostFileRouteOptions {
  logger?: Logger;
  homeDir?: string;
}

const defaultLog = createLogger({ base: { component: "host_files" } });

function pipeFileStream(
  filePath: string,
  res: ServerResponse,
  range?: { start: number; end: number },
): void {
  const stream = range
    ? createReadStream(filePath, { start: range.start, end: range.end })
    : createReadStream(filePath);

  stream.on("error", (error) => {
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Failed to read file" }));
      return;
    }
    res.destroy(error);
  });
  stream.pipe(res as NodeJS.WritableStream);
}

export function createHostFileRoutes(
  _ctx: unknown,
  helpers: RouteHelpers,
  options: HostFileRouteOptions = {},
): RouteDispatcher {
  const log = options.logger ?? defaultLog;
  const homeDir = options.homeDir;

  return async ({ method, path, url, req, res }) => {
    if (path !== "/files/raw") return false;

    const normalizedMethod = method.toUpperCase();
    if (normalizedMethod !== "GET" && normalizedMethod !== "HEAD") {
      return false;
    }

    await handleHostRawFile(normalizedMethod, url, req, res, helpers, log, homeDir);
    return true;
  };
}

async function handleHostRawFile(
  method: string,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
  helpers: RouteHelpers,
  log: Logger,
  homeDir: string | undefined,
): Promise<void> {
  let status = 404;
  let resolvedPath: string | null = null;
  let size: number | null = null;

  const finish = (nextStatus: number): void => {
    status = nextStatus;
  };

  try {
    const requestedPath = url.searchParams.get("path") ?? "";
    const expanded = expandExactHostPath(requestedPath, { homeDir });
    if (!expanded) {
      helpers.error(res, 404, "File not found");
      finish(404);
      return;
    }

    try {
      resolvedPath = await realpath(expanded);
    } catch {
      helpers.error(res, 404, "File not found");
      finish(404);
      return;
    }

    let fileStat: Awaited<ReturnType<typeof stat>>;
    try {
      fileStat = await stat(resolvedPath);
    } catch {
      helpers.error(res, 404, "File not found");
      finish(404);
      return;
    }

    if (!fileStat.isFile()) {
      helpers.error(res, 404, "File not found");
      finish(404);
      return;
    }

    try {
      await access(resolvedPath, constants.R_OK);
    } catch {
      helpers.error(res, 404, "File not found");
      finish(404);
      return;
    }

    size = fileStat.size;
    const filename = resolvedPath.split("/").pop() ?? resolvedPath;
    const contentType = getContentType(extname(resolvedPath), filename);

    if (!isStreamingMediaContentType(contentType)) {
      const isMedia = isBrowseMediaContentType(contentType);
      const maxSize = isMedia ? MAX_BROWSE_IMAGE_FILE_SIZE : MAX_BROWSE_TEXT_FILE_SIZE;
      if (fileStat.size > maxSize) {
        const limitMB = Math.round(maxSize / (1024 * 1024));
        helpers.error(res, 413, `File too large (max ${limitMB}MB)`);
        finish(413);
        return;
      }
    }

    const commonHeaders = {
      "Content-Type": contentType,
      "Cache-Control": "private, no-cache",
      "Accept-Ranges": "bytes",
      // Authenticated clients need the canonical path for tap-time
      // disclosure and the viewer title. Audit logs already use it.
      // Percent-encode so Node writeHead accepts non-ASCII realpaths.
      // HostRawFileHeaders decodes the same wire form.
      "X-Oppi-Resolved-Path": encodeHostResolvedPathHeader(resolvedPath),
    };
    const range = parseByteRangeHeader(req.headers?.range, fileStat.size);
    const isHeadRequest = method === "HEAD";

    if (range.kind === "invalid" || range.kind === "unsatisfiable") {
      logRejectedByteRange("host-raw", req.headers?.range, range.kind, fileStat.size);
      res.writeHead(416, {
        ...commonHeaders,
        "Content-Range": `bytes */${fileStat.size}`,
        "Content-Length": "0",
      });
      res.end();
      finish(416);
      return;
    }

    if (range.kind === "valid") {
      const contentLength = range.end - range.start + 1;
      res.writeHead(206, {
        ...commonHeaders,
        "Content-Range": `bytes ${range.start}-${range.end}/${fileStat.size}`,
        "Content-Length": contentLength.toString(),
      });
      finish(206);
      if (isHeadRequest) {
        res.end();
        return;
      }
      pipeFileStream(resolvedPath, res, range);
      return;
    }

    res.writeHead(200, {
      ...commonHeaders,
      "Content-Length": fileStat.size.toString(),
    });
    finish(200);
    if (isHeadRequest) {
      res.end();
      return;
    }
    pipeFileStream(resolvedPath, res);
  } finally {
    log.info("hostfile.read", {
      method,
      size,
      status,
    });
    log.debug("hostfile.read.path", {
      method,
      realpath: resolvedPath,
      size,
      status,
    });
  }
}
