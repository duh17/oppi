/**
 * `GET /health?identity=1` names the answering process only to a direct
 * loopback caller (install.sh's readiness check). Everyone else, including
 * clients behind a reverse proxy on the same host, gets the readiness body
 * the iOS probes match.
 */
import { request as httpRequest } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

let dataDir = "";
let server: Server | undefined;

afterEach(async () => {
  await server?.stop().catch(() => {});
  server = undefined;
  if (dataDir) rmSync(dataDir, { recursive: true, force: true });
  dataDir = "";
});

async function start(trustedPeers: string[] = []): Promise<void> {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-health-identity-"));
  const storage = new Storage(dataDir);
  storage.ensurePaired();
  storage.updateConfig({
    host: "127.0.0.1",
    port: 0,
    tls: { mode: "disabled" },
    ...(trustedPeers.length > 0
      ? { publicUrl: "https://oppi.example.com", proxy: { trustedPeers } }
      : {}),
  });
  server = new Server(storage);
  await server.start();
}

function getHealth(path: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(`http://127.0.0.1:${server!.port}${path}`, (res) => {
      let data = "";
      res.on("data", (chunk: Buffer) => (data += chunk.toString("utf8")));
      res.on("end", () => resolve(JSON.parse(data || "null")));
    });
    req.on("error", reject);
    req.end();
  });
}

describe("GET /health?identity=1", () => {
  it("tells a direct loopback caller the answering server's version and pid", async () => {
    await start();
    expect(await getHealth("/health?identity=1")).toEqual({
      ok: true,
      protocol: 2,
      version: Server.VERSION,
      pid: process.pid,
    });
    expect(await getHealth("/health")).toEqual({ ok: true, protocol: 2 });
  });

  it("gives a loopback reverse proxy (a trusted peer) only the readiness body", async () => {
    await start(["127.0.0.1/32"]);
    expect(await getHealth("/health?identity=1")).toEqual({ ok: true, protocol: 2 });
  });
});
