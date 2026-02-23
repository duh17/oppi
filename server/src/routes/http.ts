import type { IncomingMessage, ServerResponse } from "node:http";

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

function error(res: ServerResponse, status: number, message: string): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: message } as ApiError));
}

export function createRouteHelpers(): RouteHelpers {
  return {
    parseBody,
    json,
    error,
  };
}
