import type { IncomingMessage, ServerResponse } from "node:http";
import { gzipSync } from "node:zlib";

import type { ApiError } from "../types.js";
import type { RouteHelpers } from "./types.js";

async function parseBody<T>(req: IncomingMessage): Promise<T> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk: Buffer) => (body += chunk));
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error("Invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

function json(res: ServerResponse, data: unknown, status = 200): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

/**
 * Send JSON with gzip compression when the client supports it.
 *
 * Falls back to uncompressed JSON for clients that don't send
 * `Accept-Encoding: gzip`. Only compresses bodies >= 1KB to avoid
 * overhead on small payloads.
 */
function compressedJson(
  req: IncomingMessage,
  res: ServerResponse,
  data: unknown,
  status = 200,
): void {
  const body = JSON.stringify(data);
  const acceptEncoding = req.headers?.["accept-encoding"];
  const supportsGzip = typeof acceptEncoding === "string" && acceptEncoding.includes("gzip");

  if (supportsGzip && body.length >= 1024) {
    const compressed = gzipSync(body, { level: 1 });
    res.writeHead(status, {
      "Content-Type": "application/json",
      "Content-Encoding": "gzip",
      "Content-Length": compressed.length.toString(),
    });
    res.end(compressed);
  } else {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(body);
  }
}

function error(res: ServerResponse, status: number, message: string): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: message } as ApiError));
}

export function createRouteHelpers(): RouteHelpers {
  return {
    parseBody,
    json,
    compressedJson,
    error,
  };
}
