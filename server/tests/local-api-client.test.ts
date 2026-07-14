import { execFileSync } from "node:child_process";
import { X509Certificate } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer as createHttpsServer, type Server as HttpsServer } from "node:https";
import { networkInterfaces, tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import type { TLSSocket } from "node:tls";
import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import type { ServerConfig } from "../src/types.js";

const distinctReachableIPv4 = Object.values(networkInterfaces())
  .flatMap((entries) => entries ?? [])
  .find(
    (entry) => entry.family === "IPv4" && !entry.internal && entry.address !== "127.0.0.1",
  )?.address;

let hasOpenSSL = true;
try {
  execFileSync("openssl", ["version"], { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

function generateFixtureCertificate(
  dir: string,
  options: { dnsSan?: string; ipSan?: string } = {},
): { caPath: string; certPath: string; keyPath: string } {
  const caPath = join(dir, "ca.crt");
  const caKeyPath = join(dir, "ca.key");
  const certPath = join(dir, "server.crt");
  const keyPath = join(dir, "server.key");
  const csrPath = join(dir, "server.csr");
  const extPath = join(dir, "leaf.cnf");

  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      caKeyPath,
      "-out",
      caPath,
      "-days",
      "30",
      "-subj",
      "/CN=Oppi local API test CA",
    ],
    { stdio: "ignore" },
  );
  execFileSync(
    "openssl",
    [
      "req",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      keyPath,
      "-out",
      csrPath,
      "-subj",
      `/CN=${options.dnsSan ?? "no-san.tail00000.ts.net"}`,
    ],
    { stdio: "ignore" },
  );

  const signArgs = [
    "x509",
    "-req",
    "-in",
    csrPath,
    "-CA",
    caPath,
    "-CAkey",
    caKeyPath,
    "-CAcreateserial",
    "-out",
    certPath,
    "-days",
    "30",
    "-sha256",
  ];
  const subjectAltNames = [
    ...(options.dnsSan ? [`DNS:${options.dnsSan}`] : []),
    ...(options.ipSan ? [`IP:${options.ipSan}`] : []),
  ];
  if (subjectAltNames.length > 0) {
    writeFileSync(extPath, `[leaf]\nsubjectAltName=${subjectAltNames.join(",")}\n`);
    signArgs.push("-extfile", extPath, "-extensions", "leaf");
  }
  execFileSync("openssl", signArgs, { stdio: "ignore" });

  return { caPath, certPath, keyPath };
}

function makeConnection(config: ServerConfig, token = "owner-secret"): LocalApiConnection {
  return {
    getConfig: () => config,
    getToken: () => token,
    getDataDir: () => config.dataDir,
  };
}

async function listen(
  server: HttpsServer | ReturnType<typeof createHttpServer>,
  host = "127.0.0.1",
): Promise<number> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, host, () => {
      server.off("error", reject);
      resolve();
    });
  });
  return (server.address() as AddressInfo).port;
}

async function close(server: HttpsServer | ReturnType<typeof createHttpServer>): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

describe.skipIf(!hasOpenSSL)("local API Tailscale TLS", () => {
  const tempDirs: string[] = [];
  const servers: Array<HttpsServer | ReturnType<typeof createHttpServer>> = [];
  const originalPath = process.env.PATH;

  afterEach(async () => {
    process.env.PATH = originalPath;
    vi.useRealTimers();
    await Promise.all(servers.splice(0).map((server) => close(server)));
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("authenticates a Tailnet DNS SAN while dialing loopback with Tailscale stopped", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-tailnet-"));
    tempDirs.push(dataDir);
    const tailnetHost = "node.tail00000.ts.net";
    const tls = generateFixtureCertificate(dataDir, { dnsSan: tailnetHost });
    let authorization: string | undefined;
    let servername: string | false | undefined;
    const server = createHttpsServer(
      { cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) },
      (req, res) => {
        authorization = req.headers.authorization;
        servername = (req.socket as TLSSocket).servername;
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
      },
    );
    servers.push(server);
    const port = await listen(server);
    process.env.PATH = dataDir;

    const config: ServerConfig = {
      host: "0.0.0.0",
      port,
      dataDir,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      tls: { mode: "tailscale", ...tls },
    };

    await expect(localApiRequest(makeConnection(config), "/me")).resolves.toEqual({ ok: true });
    expect(authorization).toBe("Bearer owner-secret");
    expect(servername).toBe(tailnetHost);
  });

  it.each([
    ["IPv6 wildcard", "::", "::1"],
    ["IPv6 loopback", "::1", "::1"],
    ["explicit hostname", "localhost", "localhost"],
  ])(
    "keeps Tailnet TLS identity while routing an %s bind through %s",
    async (_label, bindHost, listenHost) => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-routing-"));
      tempDirs.push(dataDir);
      const tailnetHost = "routing.tail00000.ts.net";
      const tls = generateFixtureCertificate(dataDir, { dnsSan: tailnetHost });
      let servername: string | false | undefined;
      const server = createHttpsServer(
        { cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) },
        (req, res) => {
          expect(req.headers.host).toBe(`${tailnetHost}:${(server.address() as AddressInfo).port}`);
          servername = (req.socket as TLSSocket).servername;
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ routed: true }));
        },
      );
      servers.push(server);
      const port = await listen(server, listenHost);
      const config: ServerConfig = {
        host: bindHost,
        port,
        dataDir,
        sessionIdleTimeoutMs: 600_000,
        workspaceIdleTimeoutMs: 1_800_000,
        maxSessionsPerWorkspace: 3,
        maxSessionsGlobal: 5,
        tls: { mode: "tailscale", ...tls },
      };

      await expect(localApiRequest(makeConnection(config), "/me")).resolves.toEqual({
        routed: true,
      });
      expect(servername).toBe(tailnetHost);
    },
  );

  it.skipIf(!distinctReachableIPv4)(
    "dials a distinct explicit IPv4 bind while preserving Tailnet Host and SNI",
    async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-explicit-ip-"));
      tempDirs.push(dataDir);
      const tailnetHost = "explicit.tail00000.ts.net";
      const tls = generateFixtureCertificate(dataDir, { dnsSan: tailnetHost });
      let servername: string | false | undefined;
      const server = createHttpsServer(
        { cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) },
        (req, res) => {
          expect(req.headers.host).toBe(`${tailnetHost}:${(server.address() as AddressInfo).port}`);
          servername = (req.socket as TLSSocket).servername;
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ routed: distinctReachableIPv4 }));
        },
      );
      servers.push(server);
      const port = await listen(server, distinctReachableIPv4);
      const config: ServerConfig = {
        host: distinctReachableIPv4!,
        port,
        dataDir,
        sessionIdleTimeoutMs: 600_000,
        workspaceIdleTimeoutMs: 1_800_000,
        maxSessionsPerWorkspace: 3,
        maxSessionsGlobal: 5,
        tls: { mode: "tailscale", ...tls },
      };

      await expect(localApiRequest(makeConnection(config), "/me")).resolves.toEqual({
        routed: distinctReachableIPv4,
      });
      expect(servername).toBe(tailnetHost);
    },
  );

  it("rejects a leaf without a Tailnet DNS SAN before reading or sending authorization", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-no-san-"));
    tempDirs.push(dataDir);
    const tls = generateFixtureCertificate(dataDir);
    let requestCount = 0;
    const server = createHttpsServer(
      { cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) },
      (_req, res) => {
        requestCount += 1;
        res.end("{}");
      },
    );
    servers.push(server);
    const port = await listen(server);
    const getToken = vi.fn(() => "must-not-be-read");
    const config: ServerConfig = {
      host: "0.0.0.0",
      port,
      dataDir,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      tls: { mode: "tailscale", ...tls },
    };
    const connection: LocalApiConnection = {
      getConfig: () => config,
      getToken,
      getDataDir: () => dataDir,
    };

    await expect(localApiRequest(connection, "/me")).rejects.toThrow(
      "Tailscale TLS certificate has no valid Tailnet DNS SAN",
    );
    expect(getToken).not.toHaveBeenCalled();
    expect(requestCount).toBe(0);
  });

  it("rejects malformed, expired, and not-yet-valid leaves before reading the token", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-invalid-leaf-"));
    tempDirs.push(dataDir);
    const tls = generateFixtureCertificate(dataDir, { dnsSan: "invalid.tail00000.ts.net" });
    const getToken = vi.fn(() => "must-not-be-read");
    const config: ServerConfig = {
      host: "0.0.0.0",
      port: 443,
      dataDir,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      tls: { mode: "tailscale", ...tls },
    };
    const connection: LocalApiConnection = {
      getConfig: () => config,
      getToken,
      getDataDir: () => dataDir,
    };
    writeFileSync(tls.certPath, "not a certificate");
    await expect(localApiRequest(connection, "/me")).rejects.toThrow(/certificate is malformed/);

    generateFixtureCertificate(dataDir, { dnsSan: "invalid.tail00000.ts.net" });
    const cert = new X509Certificate(readFileSync(tls.certPath));
    vi.useFakeTimers();
    vi.setSystemTime(Date.parse(cert.validTo) + 1);
    await expect(localApiRequest(connection, "/me")).rejects.toThrow(/certificate is expired/);

    vi.setSystemTime(Date.parse(cert.validFrom) - 1);
    await expect(localApiRequest(connection, "/me")).rejects.toThrow(/not yet valid/);
    expect(getToken).not.toHaveBeenCalled();
  });

  it("preserves non-Tailscale HTTPS routing and CA verification", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-self-signed-"));
    tempDirs.push(dataDir);
    const tls = generateFixtureCertificate(dataDir, { ipSan: "127.0.0.1" });
    const server = createHttpsServer(
      { cert: readFileSync(tls.certPath), key: readFileSync(tls.keyPath) },
      (req, res) => {
        expect(req.headers.authorization).toBe("Bearer owner-secret");
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ transport: "https" }));
      },
    );
    servers.push(server);
    const port = await listen(server);
    const config: ServerConfig = {
      host: "127.0.0.1",
      port,
      dataDir,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      tls: { mode: "self-signed", ...tls },
    };

    await expect(localApiRequest(makeConnection(config), "/me")).resolves.toEqual({
      transport: "https",
    });
  });

  it("preserves plain HTTP local API behavior", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-api-http-"));
    tempDirs.push(dataDir);
    const server = createHttpServer((req, res) => {
      expect(req.headers.authorization).toBe("Bearer owner-secret");
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ transport: "http" }));
    });
    servers.push(server);
    const port = await listen(server);
    const config: ServerConfig = {
      host: "0.0.0.0",
      port,
      dataDir,
      sessionIdleTimeoutMs: 600_000,
      workspaceIdleTimeoutMs: 1_800_000,
      maxSessionsPerWorkspace: 3,
      maxSessionsGlobal: 5,
      tls: { mode: "disabled" },
    };

    await expect(localApiRequest(makeConnection(config), "/me")).resolves.toEqual({
      transport: "http",
    });
  });
});
