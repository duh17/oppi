import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { brotliDecompressSync, gunzipSync } from "node:zlib";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { GodotWebExports } from "../src/godot/godot-web-exports.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

// Web builds `godot_export` stored, served by the real server two ways: to the owner and paired
// devices with the server's own auth, and through a signed link that opens one build and
// nothing else, with no credentials.
describe("Godot web builds over the server", () => {
  const game = "tide-0123abcd";
  const otherGame = "pong-89abcdef";
  const html = "<!doctype html><title>Tide</title><script src=index.js></script>";
  // Compressible, like an engine wasm.
  const wasm = Buffer.concat([
    Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
    Buffer.alloc(64 * 1024, "godot"),
  ]);
  let dataDir = "";
  let server: Server;
  let token = "";
  let store: GodotWebExports;
  let build = "";
  let otherBuild = "";

  beforeAll(async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-godot-web-"));
    store = new GodotWebExports(join(dataDir, "godot"));
    const exported = (files: Record<string, string | Buffer>): string => {
      const folder = mkdtempSync(join(dataDir, "export-"));
      for (const [name, bytes] of Object.entries(files)) writeFileSync(join(folder, name), bytes);
      return folder;
    };
    build = await store.adopt(game, exported({ "index.html": html, "index.wasm": wasm }));
    otherBuild = await store.adopt(game, exported({ "index.html": `${html}<!-- v2 -->` }));
    // The other game holds a build with the same id.
    mkdirSync(join(dataDir, "godot", otherGame, "web", build), { recursive: true });
    writeFileSync(join(dataDir, "godot", otherGame, "web", build, "index.html"), "other game");
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

  const owned = (): string => `/godot/${game}/web/${build}`;
  const day = 24 * 60 * 60 * 1000;

  it("serves a build to a paired client: the folder as index.html, wasm as wasm", async () => {
    const redirect = await get(owned());
    expect(redirect.status).toBe(308);
    expect(redirect.headers.location).toBe(`${owned()}/`);

    const page = await get(`${owned()}/`);
    expect(page.status).toBe(200);
    expect(page.headers["content-type"]).toBe("text/html; charset=utf-8");
    expect(page.body.toString()).toBe(html);

    const module = await get(`${owned()}/index.wasm`);
    expect(module.status).toBe(200);
    expect(module.headers["content-type"]).toBe("application/wasm");
    expect(module.headers["content-encoding"]).toBeUndefined();
    expect(module.body.equals(wasm)).toBe(true);
  });

  it("sends the stored brotli or gzip copy the client accepts, typed as the file", async () => {
    const auth = { Authorization: `Bearer ${token}` };
    const br = await get(`${owned()}/index.wasm`, { ...auth, "Accept-Encoding": "gzip, br" });
    expect(br.headers["content-encoding"]).toBe("br");
    expect(br.headers["content-type"]).toBe("application/wasm");
    expect(br.headers.vary).toBe("Accept-Encoding");
    expect(br.body.length).toBeLessThan(wasm.length / 10);
    expect(brotliDecompressSync(br.body).equals(wasm)).toBe(true);

    const gz = await get(`${owned()}/index.wasm`, { ...auth, "Accept-Encoding": "gzip, br;q=0" });
    expect(gz.headers["content-encoding"]).toBe("gzip");
    expect(gunzipSync(gz.body).equals(wasm)).toBe(true);

    // A file too small to gain goes out as it is.
    const page = await get(`${owned()}/`, { ...auth, "Accept-Encoding": "br" });
    expect(page.headers["content-encoding"]).toBeUndefined();
    expect(page.body.toString()).toBe(html);
  });

  it("refuses the owner route without the owner's or a paired device's token", async () => {
    expect((await get(`${owned()}/`, {})).status).toBe(401);
    expect(
      (await get(`${owned()}/index.wasm`, { Authorization: "Bearer not-a-token" })).status,
    ).toBe(401);
  });

  it("opens a build through its signed link with no credentials", async () => {
    const link = store.signedPath(game, build, Date.now() + day);
    const redirect = await get(link.slice(0, -1), {});
    expect(redirect.status).toBe(308);
    expect(redirect.headers.location).toBe(link);

    const page = await get(link, {});
    expect(page.status).toBe(200);
    expect(page.body.toString()).toBe(html);
    const module = await get(`${link}index.wasm`, { "Accept-Encoding": "br" });
    expect(module.status).toBe(200);
    expect(module.headers["content-type"]).toBe("application/wasm");
    expect(brotliDecompressSync(module.body).equals(wasm)).toBe(true);
  });

  it("answers the same bare 404 for an expired, tampered, other-build, or other-game link", async () => {
    const link = store.signedPath(game, build, Date.now() + day);
    const grant = link.split("/")[4] ?? "";
    const [, expires = "", mac = ""] = grant.split(".");
    const flipped = `${mac[0] === "A" ? "B" : "A"}${mac.slice(1)}`;
    const refused = [
      store.signedPath(game, build, Date.now() - 1000),
      `/godot/${game}/play/${build}.${expires}.${flipped}/`,
      `/godot/${game}/play/${build}.${Number(expires) + 3600}.${mac}/`,
      `/godot/${game}/play/${otherBuild}.${expires}.${mac}/`,
      `/godot/${otherGame}/play/${grant}/`,
      `/godot/${game}/play/not-a-grant/`,
    ];
    const answers = await Promise.all(refused.map((path) => get(path, {})));
    for (const answer of answers) {
      expect(answer.status).toBe(404);
      expect(answer.body.toString()).toBe(answers[0]?.body.toString());
    }
    // The link opens its build only: the other build of the same game stays shut.
    expect((await get(`${link}index.wasm`, {})).status).toBe(200);
  });

  it("serves nothing outside the build's folder, signed or not", async () => {
    const link = store.signedPath(game, build, Date.now() + day);
    for (const path of [
      `${owned()}/..%2F..%2Fsecret.json`,
      `/godot/${game}/web/..%2F${build}/index.html`,
      `${owned()}/missing.js`,
      `${owned()}/.br%2Findex.wasm`,
      `${link}..%2F..%2F..%2Fsecret.json`,
      `${link}.br%2Findex.wasm`,
    ]) {
      expect((await get(path)).status, path).toBe(404);
    }
  });
});
