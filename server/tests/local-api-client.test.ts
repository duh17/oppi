import { mkdtempSync, rmSync } from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import type { ServerConfig } from "../src/types.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

describe("local API Unix socket client", () => {
  const tempDirs: string[] = [];
  const servers: HttpServer[] = [];

  afterEach(async () => {
    await Promise.all(servers.splice(0).map((server) => close(server)));
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("sends bearer-authenticated HTTP through the data-directory socket", async () => {
    const dataDir = makeDataDir();
    let observed:
      | { authorization?: string; method?: string; url?: string; body: string }
      | undefined;
    const server = createHttpServer((req, res) => {
      let body = "";
      req.setEncoding("utf8");
      req.on("data", (chunk) => {
        body += String(chunk);
      });
      req.on("end", () => {
        observed = {
          authorization: req.headers.authorization,
          method: req.method,
          url: req.url,
          body,
        };
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      });
    });
    servers.push(server);
    await listenOnLocalApiFixture(server, dataDir);

    await expect(
      localApiRequest(makeConnection(dataDir), "/sessions?limit=2", {
        method: "POST",
        body: { prompt: "hello" },
      }),
    ).resolves.toEqual({ ok: true });
    expect(observed).toEqual({
      authorization: "Bearer owner-secret",
      method: "POST",
      url: "/sessions?limit=2",
      body: JSON.stringify({ prompt: "hello" }),
    });
  });

  it("does not inspect network or TLS configuration", async () => {
    const dataDir = makeDataDir();
    const getConfig = vi.fn(() => {
      throw new Error("network config must not be read");
    });
    const server = createHttpServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ transport: "unix" }));
    });
    servers.push(server);
    await listenOnLocalApiFixture(server, dataDir);

    const connection = makeConnection(dataDir, { getConfig });
    await expect(localApiRequest(connection, "/me")).resolves.toEqual({ transport: "unix" });
    expect(getConfig).not.toHaveBeenCalled();
  });

  it("requires the owner token before opening a socket", async () => {
    const dataDir = makeDataDir();
    const connection = makeConnection(dataDir, { getToken: () => undefined });

    await expect(localApiRequest(connection, "/me")).rejects.toThrow(
      "No owner bearer token configured",
    );
  });

  it("preserves HTTP status and API error messages", async () => {
    const dataDir = makeDataDir();
    const server = createHttpServer((_req, res) => {
      res.writeHead(409, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "conflict" }));
    });
    servers.push(server);
    await listenOnLocalApiFixture(server, dataDir);

    const error = await localApiRequest(makeConnection(dataDir), "/resource").catch(
      (caught: unknown) => caught,
    );
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toBe("conflict");
    expect((error as Error & { status?: number }).status).toBe(409);
  });

  it("rejects invalid JSON from a successful response", async () => {
    const dataDir = makeDataDir();
    const server = createHttpServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("not json");
    });
    servers.push(server);
    await listenOnLocalApiFixture(server, dataDir);

    await expect(localApiRequest(makeConnection(dataDir), "/me")).rejects.toThrow(
      "Invalid JSON response from local API",
    );
  });

  function makeDataDir(): string {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-client-"));
    tempDirs.push(dataDir);
    return dataDir;
  }
});

function makeConnection(
  dataDir: string,
  overrides: Partial<LocalApiConnection> = {},
): LocalApiConnection {
  const unusedConfig = {} as ServerConfig;
  return {
    getConfig: () => unusedConfig,
    getToken: () => "owner-secret",
    getDataDir: () => dataDir,
    ...overrides,
  };
}

async function close(server: HttpServer): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
