import type { IncomingMessage, ServerResponse } from "node:http";

import { ICON_ASSET_MAX_BYTES, IconAssetStoreError } from "../storage/icon-asset-store.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createIconAssetRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  return async ({ method, path, req, res }) => {
    if (path === "/icon-assets" && method === "POST") {
      try {
        const bytes = await readBoundedBody(req);
        const contentType = headerValue(req.headers["content-type"]);
        const record = ctx.storage.putIconAsset(bytes, contentType);
        helpers.json(res, { asset: record }, 201);
      } catch (error) {
        handleAssetError(error, res, helpers);
      }
      return true;
    }

    const match = path.match(/^\/icon-assets\/([^/]+)$/);
    if (match && (method === "GET" || method === "HEAD")) {
      try {
        const assetId = decodeAssetId(match[1]);
        const { record, bytes } = ctx.storage.getIconAssetStore().read(assetId);
        res.writeHead(200, {
          "Content-Type": record.contentType,
          "Content-Length": String(record.sizeBytes),
          ETag: `"sha256-${record.sha256}"`,
          "Cache-Control": "private, max-age=31536000, immutable",
          "X-Content-Type-Options": "nosniff",
        });
        res.end(method === "HEAD" ? undefined : bytes);
      } catch (error) {
        handleAssetError(error, res, helpers);
      }
      return true;
    }

    return false;
  };
}

function decodeAssetId(encoded: string): string {
  try {
    return decodeURIComponent(encoded);
  } catch {
    throw new IconAssetStoreError("invalid_id", "Invalid icon asset ID", 400);
  }
}

function readBoundedBody(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const declaredLength = Number(headerValue(req.headers["content-length"]));
    if (Number.isFinite(declaredLength) && declaredLength > ICON_ASSET_MAX_BYTES) {
      reject(new IconAssetStoreError("oversized", "Icon asset exceeds the 2 MiB maximum", 413));
      return;
    }

    const chunks: Buffer[] = [];
    let size = 0;
    let settled = false;
    req.on("data", (chunk: Buffer | string) => {
      if (settled) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > ICON_ASSET_MAX_BYTES) {
        settled = true;
        reject(new IconAssetStoreError("oversized", "Icon asset exceeds the 2 MiB maximum", 413));
        return;
      }
      chunks.push(buffer);
    });
    req.on("end", () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on("error", (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    });
  });
}

function handleAssetError(error: unknown, res: ServerResponse, helpers: RouteHelpers): void {
  if (error instanceof IconAssetStoreError) {
    helpers.error(res, error.status, error.message);
    return;
  }
  helpers.error(res, 500, "Icon asset operation failed");
}

function headerValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}
