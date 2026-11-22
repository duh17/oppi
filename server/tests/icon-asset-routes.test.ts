import type { IncomingHttpHeaders, IncomingMessage, ServerResponse } from "node:http";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createIconAssetRoutes } from "../src/routes/icon-assets.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { Storage } from "../src/storage.js";
import { structuralHeifFixture } from "./harness/heic-fixture.js";
import { gifFixture, pngFixture } from "./harness/image-fixtures.js";
import { makeRawRequest, makeResponse } from "./harness/route-test-helpers.js";

function sample(): Buffer {
  return structuralHeifFixture();
}

function request(bytes: Buffer, headers: IncomingHttpHeaders = {}) {
  const req = makeRawRequest(bytes) as IncomingMessage & { headers: IncomingHttpHeaders };
  req.headers = headers;
  return req;
}

function binaryResponse(): ServerResponse & {
  statusCode: number;
  headers: Record<string, string>;
  body: Buffer;
} {
  const response = {
    statusCode: 0,
    headers: {} as Record<string, string>,
    body: Buffer.alloc(0),
    writeHead(status: number, headers: Record<string, string>) {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: Buffer | string) {
      this.body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload ?? "");
    },
  };
  return response as unknown as ServerResponse & typeof response;
}

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-icon-asset-routes-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

describe("icon asset routes", () => {
  it("uploads and serves identical bytes through the route dispatcher", async () => {
    const dispatch = createIconAssetRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const upload = makeResponse();
    await dispatch({
      method: "POST",
      path: "/icon-assets",
      url: new URL("http://localhost/icon-assets"),
      req: request(sample(), { "content-type": "image/heic" }),
      res: upload as unknown as ServerResponse,
    });
    expect(upload.statusCode).toBe(201);
    const assetId = JSON.parse(upload.body).asset.assetId as string;

    const get = binaryResponse();
    await dispatch({
      method: "GET",
      path: `/icon-assets/${assetId}`,
      url: new URL(`http://localhost/icon-assets/${assetId}`),
      req: request(Buffer.alloc(0)),
      res: get,
    });
    expect(get.statusCode).toBe(200);
    expect(get.headers["Content-Type"]).toBe("image/heic");
    expect(get.body).toEqual(sample());

    const head = binaryResponse();
    await dispatch({
      method: "HEAD",
      path: `/icon-assets/${assetId}`,
      url: new URL(`http://localhost/icon-assets/${assetId}`),
      req: request(Buffer.alloc(0)),
      res: head,
    });
    expect(head.statusCode).toBe(200);
    expect(head.headers["Content-Length"]).toBe(String(sample().length));
    expect(head.body).toHaveLength(0);
  });

  it("types an upload by its bytes, not its declared Content-Type", async () => {
    const dispatch = createIconAssetRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const png = pngFixture();
    const upload = makeResponse();
    await dispatch({
      method: "POST",
      path: "/icon-assets",
      url: new URL("http://localhost/icon-assets"),
      req: request(png, { "content-type": "image/heic" }),
      res: upload as unknown as ServerResponse,
    });
    expect(upload.statusCode).toBe(201);
    const { asset } = JSON.parse(upload.body) as {
      asset: { assetId: string; contentType: string };
    };
    expect(asset.contentType).toBe("image/png");

    const get = binaryResponse();
    await dispatch({
      method: "GET",
      path: `/icon-assets/${asset.assetId}`,
      url: new URL(`http://localhost/icon-assets/${asset.assetId}`),
      req: request(Buffer.alloc(0)),
      res: get,
    });
    expect(get.headers["Content-Type"]).toBe("image/png");
    expect(get.body).toEqual(png);
  });

  it("refuses a GIF upload with a message naming WebP", async () => {
    const dispatch = createIconAssetRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const refused = makeResponse();
    await dispatch({
      method: "POST",
      path: "/icon-assets",
      url: new URL("http://localhost/icon-assets"),
      req: request(gifFixture(), { "content-type": "image/gif" }),
      res: refused as unknown as ServerResponse,
    });
    expect(refused.statusCode).toBe(415);
    expect(refused.body).toContain("use WebP for an animated icon");
  });

  it("serves a GIF stored before WebP was the only animated icon", async () => {
    const dispatch = createIconAssetRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const bytes = gifFixture({ width: 3, height: 3 });
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const assetId = `ia_${Buffer.from(sha256, "hex").toString("base64url")}`;
    const blobs = join(dataDir, "icon-assets", "blobs");
    const metadata = join(dataDir, "icon-assets", "metadata");
    mkdirSync(blobs, { recursive: true });
    mkdirSync(metadata, { recursive: true });
    writeFileSync(join(blobs, `${assetId}.heic`), bytes);
    writeFileSync(
      join(metadata, `${assetId}.json`),
      JSON.stringify({
        assetId,
        sha256,
        sizeBytes: bytes.length,
        contentType: "image/gif",
        createdAt: 1_000,
        lastUploadedAt: 1_000,
      }),
    );

    const get = binaryResponse();
    await dispatch({
      method: "GET",
      path: `/icon-assets/${assetId}`,
      url: new URL(`http://localhost/icon-assets/${assetId}`),
      req: request(Buffer.alloc(0)),
      res: get,
    });
    expect(get.statusCode).toBe(200);
    expect(get.headers["Content-Type"]).toBe("image/gif");
    expect(get.body).toEqual(bytes);
  });

  it("returns deterministic errors for unsupported, missing, and traversal input", async () => {
    const dispatch = createIconAssetRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );

    const unsupported = makeResponse();
    await dispatch({
      method: "POST",
      path: "/icon-assets",
      url: new URL("http://localhost/icon-assets"),
      req: request(Buffer.from("plain text, not an image"), { "content-type": "image/png" }),
      res: unsupported as unknown as ServerResponse,
    });
    expect(unsupported.statusCode).toBe(415);

    for (const [assetId, status] of [
      [`ia_${"z".repeat(43)}`, 404],
      ["..%2F..%2Fetc", 400],
      ["%E0%A4%A", 400],
    ] as const) {
      const response = makeResponse();
      await dispatch({
        method: "GET",
        path: `/icon-assets/${assetId}`,
        url: new URL(`http://localhost/icon-assets/${assetId}`),
        req: request(Buffer.alloc(0)),
        res: response as unknown as ServerResponse,
      });
      expect(response.statusCode).toBe(status);
    }
  });
});
