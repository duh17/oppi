import { createReadStream } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";

import { logRejectedByteRange, parseByteRangeHeader } from "../http-range.js";
import { safeErrorMessage } from "../log-utils.js";
import type { GodotProjectList } from "../types.js";
import { answerStatusError } from "./http.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const GAME = /^\/godot\/([^/]+)$/;
const PACK = /^\/godot\/([^/]+)\/packs\/([^/]+)$/;
const RELEASES = /^\/godot\/([^/]+)\/releases$/;
const COMMANDS = /^\/godot\/([^/]+)\/commands$/;
const LOGS = /^\/godot\/([^/]+)\/logs$/;
const CAPTURE = /^\/godot\/([^/]+)\/captures\/([^/]+)$/;
/** A Web build `godot_export` stored: its folder (redirected to `/`), or one file in it. */
const WEB = /^\/godot\/([^/]+)\/web\/([^/]+)(?:\/(.*))?$/;
const RELEASE_BODY_MAX_BYTES = 64 * 1024;
const COMMAND_BODY_MAX_BYTES = 256 * 1024;

/**
 * The Godot pane's HTTP side (`server/src/types/godot.ts`, `GodotService`). `WS .../link` is
 * upgraded in `server.ts`. Packs are content-addressed, so a pack answer is cacheable for good.
 */
export function createGodotRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  return async ({ method, path, url, req, res }) => {
    const games = ctx.godot;
    if (!games || !path.startsWith("/godot")) return false;
    try {
      if (path === "/godot" && method === "GET") {
        const workspaceId = url.searchParams.get("workspace") ?? undefined;
        const body: GodotProjectList = {
          projects: await games.list(workspaceId ? { workspaceId } : {}),
        };
        helpers.json(res, body);
        return true;
      }
      const game = GAME.exec(path);
      if (game && method === "GET") {
        const detail = await games.detail(game[1] ?? "");
        if (detail) helpers.json(res, detail);
        else helpers.error(res, 404, "No such game");
        return true;
      }
      const pack = PACK.exec(path);
      if (pack) {
        const [, id = "", sha256 = ""] = pack;
        if (method === "PUT") {
          const { pack: stored, existed } = await games.uploadPack(id, sha256, req);
          helpers.json(res, { pack: stored, existed }, existed ? 200 : 201);
          return true;
        }
        const found = await games.pack(id, sha256);
        if (!found) helpers.error(res, 404, "No such pack");
        else servePack(req, res, method, found.path, found.pack.size, sha256);
        return true;
      }
      const releases = RELEASES.exec(path);
      if (releases && method === "POST") {
        const body = await helpers.parseBody<unknown>(req, { maxBytes: RELEASE_BODY_MAX_BYTES });
        const wait = url.searchParams.get("wait") === "first-frame";
        helpers.json(res, await games.publish(releases[1] ?? "", body, wait), 201);
        return true;
      }
      const commands = COMMANDS.exec(path);
      if (commands && method === "POST") {
        const id = commands[1] ?? "";
        if (!games.describe(id)) {
          helpers.error(res, 404, "No such game");
          return true;
        }
        const body = await helpers.parseBody<unknown>(req, { maxBytes: COMMAND_BODY_MAX_BYTES });
        helpers.json(res, await games.command(id, body));
        return true;
      }
      const logs = LOGS.exec(path);
      if (logs && method === "GET") {
        const id = logs[1] ?? "";
        if (!games.describe(id)) {
          helpers.error(res, 404, "No such game");
          return true;
        }
        helpers.json(
          res,
          games.logs(id, {
            since: url.searchParams.get("since") ?? undefined,
            limit: url.searchParams.get("limit") ?? undefined,
            level: url.searchParams.get("level") ?? undefined,
          }),
        );
        return true;
      }
      const web = WEB.exec(path);
      if (web && (method === "GET" || method === "HEAD")) {
        const [, id = "", exportId = "", rest] = web;
        if (rest === undefined) {
          // Relative asset URLs in index.html need the folder's trailing slash.
          res.writeHead(308, { Location: `${path}/` }).end();
          return true;
        }
        let name: string;
        try {
          name = decodeURIComponent(rest || "index.html");
        } catch {
          name = "";
        }
        const found = await games.webFile(id, exportId, name);
        if (!found) {
          helpers.error(res, 404, "No such file");
          return true;
        }
        res.writeHead(200, {
          "Content-Type": found.contentType,
          "Content-Length": String(found.size),
          // The export id is a hash of the build, so its files never change.
          "Cache-Control": "private, max-age=31536000, immutable",
          "X-Content-Type-Options": "nosniff",
        });
        if (method === "HEAD") res.end();
        else
          createReadStream(found.path)
            .on("error", () => res.destroy())
            .pipe(res);
        return true;
      }
      const capture = CAPTURE.exec(path);
      if (capture) {
        const [, id = "", captureId = ""] = capture;
        if (method === "PUT") {
          helpers.json(res, await games.uploadCapture(id, captureId, req), 201);
          return true;
        }
        const found = await games.capture(id, captureId);
        if (!found) {
          helpers.error(res, 404, "No such capture");
          return true;
        }
        res.writeHead(200, {
          "Content-Type": found.mimeType,
          "Content-Length": String(found.size),
          "Cache-Control": "private, max-age=3600",
        });
        createReadStream(found.path)
          .on("error", () => res.destroy())
          .pipe(res);
        return true;
      }
      return false;
    } catch (error: unknown) {
      if (!res.headersSent && answerStatusError(helpers, res, error)) return true;
      if (!res.headersSent) helpers.error(res, 500, safeErrorMessage(error));
      else res.destroy();
      return true;
    }
  };
}

/** A pack's bytes: `ETag` is its sha256, `If-None-Match` answers 304, one byte range. */
function servePack(
  req: IncomingMessage,
  res: ServerResponse,
  method: string,
  path: string,
  size: number,
  sha256: string,
): void {
  const etag = `"${sha256}"`;
  const headers = {
    "Content-Type": "application/octet-stream",
    "Accept-Ranges": "bytes",
    ETag: etag,
    "Cache-Control": "private, max-age=31536000, immutable",
  };
  if (req.headers["if-none-match"] === etag) {
    res.writeHead(304, headers);
    res.end();
    return;
  }
  // A range against another version of the bytes is answered whole.
  const ifRange = req.headers["if-range"];
  const range =
    ifRange === undefined || ifRange === etag
      ? parseByteRangeHeader(req.headers.range, size)
      : ({ kind: "none" } as const);
  if (range.kind === "invalid" || range.kind === "unsatisfiable") {
    logRejectedByteRange("game-pack", req.headers.range, range.kind, size);
    res.writeHead(416, { ...headers, "Content-Range": `bytes */${size}`, "Content-Length": "0" });
    res.end();
    return;
  }
  const partial = range.kind === "valid";
  const start = partial ? range.start : 0;
  const end = partial ? range.end : size - 1;
  res.writeHead(partial ? 206 : 200, {
    ...headers,
    "Content-Length": String(size === 0 ? 0 : end - start + 1),
    ...(partial ? { "Content-Range": `bytes ${start}-${end}/${size}` } : {}),
  });
  if (method === "HEAD" || size === 0) {
    res.end();
    return;
  }
  createReadStream(path, { start, end })
    .on("error", () => res.destroy())
    .pipe(res);
}
