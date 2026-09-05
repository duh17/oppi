import { mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { request as httpRequest } from "node:http";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { parseHttpRequestTarget } from "../src/request-trust.js";

let dataDir: string;
let server: Server;
let port: number;
const rejections: unknown[] = [];
const exceptions: unknown[] = [];

function onUnhandledRejection(reason: unknown): void {
  rejections.push(reason);
}

function onUncaughtException(error: unknown): void {
  exceptions.push(error);
}

function rawRequest(request: string): Promise<{ statusLine: string; body: string }> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: "127.0.0.1", port }, () => {
      socket.write(request);
    });
    let data = "";
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("raw request timed out"));
    }, 3_000);
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      data += chunk;
    });
    socket.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    socket.on("end", () => {
      clearTimeout(timer);
      const headerEnd = data.indexOf("\r\n");
      resolve({
        statusLine: headerEnd === -1 ? data : data.slice(0, headerEnd),
        body: data,
      });
    });
  });
}

function healthRequest(): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path: "/health" }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode ?? 0));
    });
    req.on("error", reject);
    req.end();
  });
}

describe("malformed Host and request-target isolation", { timeout: 30_000 }, () => {
  beforeAll(async () => {
    process.on("unhandledRejection", onUnhandledRejection);
    process.on("uncaughtException", onUncaughtException);
    dataDir = mkdtempSync(join(tmpdir(), "oppi-malformed-host-"));
    const storage = new Storage(dataDir);
    storage.updateConfig({
      port: 0,
      host: "127.0.0.1",
      tls: { mode: "disabled" },
    });
    storage.ensurePaired();
    server = new Server(storage);
    await server.start();
    port = server.port;
  }, 30_000);

  afterAll(async () => {
    process.off("unhandledRejection", onUnhandledRejection);
    process.off("uncaughtException", onUncaughtException);
    await server.stop().catch(() => {});
    rmSync(dataDir, { recursive: true, force: true });
  }, 45_000);

  it("parses request targets against a constant local base", () => {
    expect(parseHttpRequestTarget("/health")?.pathname).toBe("/health");
    expect(parseHttpRequestTarget("http://[")).toBeNull();
    expect(parseHttpRequestTarget("//[")).toBeNull();
  });

  it("does not throw or shut down when Host is syntactically invalid", async () => {
    const first = await rawRequest("GET /health HTTP/1.1\r\nHost: [\r\nConnection: close\r\n\r\n");
    expect(first.statusLine).toMatch(/^HTTP\/1\.1 (200|400)/);
    expect(await healthRequest()).toBe(200);
    expect(rejections).toEqual([]);
    expect(exceptions).toEqual([]);
  });

  it("returns 400 for a malformed request-target without killing the listener", async () => {
    const response = await rawRequest(
      "GET http://[ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    expect(response.statusLine).toBe("HTTP/1.1 400 Bad Request");
    expect(await healthRequest()).toBe(200);
    expect(rejections).toEqual([]);
    expect(exceptions).toEqual([]);
  });

  it("closes a malformed WebSocket upgrade without an unhandled exception", async () => {
    const response = await rawRequest(
      [
        "GET http://[ HTTP/1.1",
        "Host: 127.0.0.1",
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "",
        "",
      ].join("\r\n"),
    );
    expect(response.statusLine).toBe("HTTP/1.1 400 Bad Request");
    expect(await healthRequest()).toBe(200);
    expect(rejections).toEqual([]);
    expect(exceptions).toEqual([]);
  });
});
