import type { IncomingHttpHeaders, IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createIconAssetRoutes } from "../src/routes/icon-assets.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { apiRouteSpecs } from "../src/routes/registry.js";
import type { RouteContext } from "../src/routes/types.js";
import { Storage } from "../src/storage.js";
import { structuralHeifFixture } from "./harness/heic-fixture.js";
import { makeRawRequest, makeResponse } from "./harness/route-test-helpers.js";

function sample(): Buffer {
  return structuralHeifFixture();
}

function request(bytes: Buffer, headers: IncomingHttpHeaders = {}) {
  const req = makeRawRequest(bytes) as IncomingMessage & { headers: IncomingHttpHeaders };
  req.headers = headers;
  return req;
}

function binaryResponse(): ServerResponse & { statusCode: number; headers: Record<string, string>; body: Buffer } {
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
  it("registers upload, GET, and HEAD as owner-authenticated routes", () => {
    const routes = apiRouteSpecs.filter((route) => route.path.startsWith("/icon-assets"));
    expect(routes.map(({ method, auth }) => ({ method, auth }))).toEqual([
      { method: "POST", auth: "owner" },
      { method: "GET", auth: "owner" },
      { method: "HEAD", auth: "owner" },
    ]);
  });

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
      req: request(sample(), { "content-type": "image/png" }),
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
