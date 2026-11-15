import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

// A web build `godot_export` stored, served by the real server: the same owner-or-paired-device
// auth as every other route, nothing public.
describe("Godot web builds over the server", () => {
  const game = "tide-0123abcd";
  const build = "0123456789abcdef";
  const html = "<!doctype html><title>Tide</title><script src=index.js></script>";
  const wasm = Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
  let dataDir = "";
  let server: Server;
  let token = "";

  beforeAll(async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-godot-web-"));
    const folder = join(dataDir, "godot", game, "web", build);
    mkdirSync(folder, { recursive: true });
    writeFileSync(join(folder, "index.html"), html);
    writeFileSync(join(folder, "index.wasm"), wasm);
    writeFileSync(join(dataDir, "godot", game, "secret.json"), "{}");
    const storage = new Storage(dataDir);
    token = storage.ensurePaired();
    storage.mutateConfig(() => ({ host: "127.0.0.1", port: 0, tls: { mode: "tailscale" } }));
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    server = new Server(storage);
    try {
      await server.start();
    } finally {
      process.env.PATH = originalPath;
    }
  });

  afterAll(async () => {
    await server?.stop().catch(() => {});
    rmSync(dataDir, { recursive: true, force: true });
  });

  function get(
    path: string,
    headers: Record<string, string> = { Authorization: `Bearer ${token}` },
  ): Promise<{ status: number; headers: Record<string, unknown>; body: Buffer }> {
    return new Promise((resolve, reject) => {
      const req = request(
        { socketPath: server.socketPath, method: "GET", path, headers },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (chunk: Buffer) => chunks.push(chunk));
          res.on("end", () =>
            resolve({
              status: res.statusCode ?? 0,
              headers: res.headers,
              body: Buffer.concat(chunks),
            }),
          );
        },
      );
      req.on("error", reject);
      req.end();
    });
  }

  const base = `/godot/${game}/web/${build}`;

  it("serves the build to a paired client: the folder as index.html, wasm as wasm", async () => {
    const redirect = await get(base);
    expect(redirect.status).toBe(308);
    expect(redirect.headers.location).toBe(`${base}/`);

    const page = await get(`${base}/`);
    expect(page.status).toBe(200);
    expect(page.headers["content-type"]).toBe("text/html; charset=utf-8");
    expect(page.body.toString()).toBe(html);

    const module = await get(`${base}/index.wasm`);
    expect(module.status).toBe(200);
    expect(module.headers["content-type"]).toBe("application/wasm");
    expect(module.body.equals(wasm)).toBe(true);
  });

  it("refuses a request without the owner's or a paired device's token", async () => {
    expect((await get(`${base}/`, {})).status).toBe(401);
    expect((await get(`${base}/index.wasm`, { Authorization: "Bearer not-a-token" })).status).toBe(
      401,
    );
  });

  it("serves nothing outside the build's folder", async () => {
    expect((await get(`${base}/..%2F..%2Fsecret.json`)).status).toBe(404);
    expect((await get(`/godot/${game}/web/..%2F${build}/index.html`)).status).toBe(404);
    expect((await get(`${base}/missing.js`)).status).toBe(404);
  });
});
