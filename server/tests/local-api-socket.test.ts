import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { describe, expect, it } from "vitest";

import { localApiRequest } from "../src/cli/local-api-client.js";
import {
  listenOnLocalApiSocket,
  localApiSocketPath,
  type LocalApiSocketBinding,
} from "../src/local-api-socket.js";
import { rememberValidatedPairingAdvertiseHost } from "../src/cli/pairing-host.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

describe("Unix-socket local API", () => {
  it("keeps the authenticated local API available without Tailscale or certificate material", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-poc-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "0.0.0.0",
      port: 0,
      tls: { mode: "tailscale" },
    });

    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    const server = new Server(storage);
    try {
      await server.start();
      process.env.PATH = originalPath;

      expect(server.remoteAvailable).toBe(false);
      expect(existsSync(server.socketPath)).toBe(true);
      expect(statSync(server.socketPath).mode & 0o777).toBe(0o600);
      expect(statSync(dirname(server.socketPath)).mode & 0o777).toBe(0o700);

      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      process.env.PATH = originalPath;
      await server.stop().catch(() => {});
      expect(existsSync(server.socketPath)).toBe(false);
      expect(existsSync(`${server.socketPath}.lock`)).toBe(false);
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("retries Tailscale TLS preparation when Tailscale becomes available", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-tls-retry-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "tailscale" },
    });

    const previousRetryMs = process.env.OPPI_REMOTE_BIND_RETRY_MS;
    process.env.OPPI_REMOTE_BIND_RETRY_MS = "80";
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    const server = new Server(storage);
    try {
      await server.start();
      expect(server.remoteAvailable).toBe(false);
      expect(existsSync(server.socketPath)).toBe(true);

      writeFileSync(
        join(dataDir, "tailscale"),
        `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
case "\$cmd" in
  status)
    if [[ "\${2:-}" == "--json" ]]; then
      echo '{"Self":{"DNSName":"my-server.tail00000.ts.net."}}'
      exit 0
    fi
    ;;
  cert)
    cert_file=""; key_file=""; host=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --cert-file) cert_file="\$2"; shift 2 ;;
        --key-file) key_file="\$2"; shift 2 ;;
        --min-validity) shift 2 ;;
        *) host="\$1"; shift ;;
      esac
    done
    mkdir -p "\$(dirname "\$cert_file")" "\$(dirname "\$key_file")"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \\
      -keyout "\$key_file" -out "\$cert_file" -subj "/CN=\$host" \\
      -addext "subjectAltName=DNS:\$host" -days 1 >/dev/null 2>&1
    exit 0
    ;;
esac
exit 1
`,
        { mode: 0o755 },
      );
      chmodSync(join(dataDir, "tailscale"), 0o755);
      process.env.PATH = `${dataDir}:${originalPath}`;

      await waitFor(() => server.remoteAvailable, 8_000);
      expect(server.remoteAvailable).toBe(true);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      process.env.PATH = originalPath;
      if (previousRetryMs === undefined) delete process.env.OPPI_REMOTE_BIND_RETRY_MS;
      else process.env.OPPI_REMOTE_BIND_RETRY_MS = previousRetryMs;
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("persists serve --host only after remote TLS listener recovery", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-pairhost-ready-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "tailscale" },
    });

    const previousRetryMs = process.env.OPPI_REMOTE_BIND_RETRY_MS;
    process.env.OPPI_REMOTE_BIND_RETRY_MS = "80";
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    const server = new Server(storage);
    const pairHost = "my-server.tail00000.ts.net";
    try {
      await server.start();
      expect(server.hasPublicHttpListener).toBe(false);
      expect(() => rememberValidatedPairingAdvertiseHost(storage, pairHost)).toThrow(
        /certificate not found/,
      );
      expect(storage.getConfig().pairHost).toBeUndefined();

      server.onRemoteListenerReady(() => {
        rememberValidatedPairingAdvertiseHost(storage, pairHost);
      });

      writeFileSync(
        join(dataDir, "tailscale"),
        `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
case "\$cmd" in
  status)
    if [[ "\${2:-}" == "--json" ]]; then
      echo '{"Self":{"DNSName":"my-server.tail00000.ts.net."}}'
      exit 0
    fi
    ;;
  cert)
    cert_file=""; key_file=""; host=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --cert-file) cert_file="\$2"; shift 2 ;;
        --key-file) key_file="\$2"; shift 2 ;;
        --min-validity) shift 2 ;;
        *) host="\$1"; shift ;;
      esac
    done
    mkdir -p "\$(dirname "\$cert_file")" "\$(dirname "\$key_file")"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \\
      -keyout "\$key_file" -out "\$cert_file" -subj "/CN=\$host" \\
      -addext "subjectAltName=DNS:\$host" -days 1 >/dev/null 2>&1
    exit 0
    ;;
esac
exit 1
`,
        { mode: 0o755 },
      );
      chmodSync(join(dataDir, "tailscale"), 0o755);
      process.env.PATH = `${dataDir}:${originalPath}`;

      await waitFor(() => server.hasPublicHttpListener && storage.getConfig().pairHost === pairHost, 8_000);
      expect(server.remoteAvailable).toBe(true);
      expect(storage.getConfig().pairHost).toBe(pairHost);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      process.env.PATH = originalPath;
      if (previousRetryMs === undefined) delete process.env.OPPI_REMOTE_BIND_RETRY_MS;
      else process.env.OPPI_REMOTE_BIND_RETRY_MS = previousRetryMs;
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("rebuilds Tailscale TLS material on each remote-listener retry", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-tls-rebuild-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "192.0.2.1",
      port: 0,
      tls: { mode: "tailscale" },
    });

    const certCallsPath = join(dataDir, "cert-calls");
    writeFileSync(certCallsPath, "0\n");
    writeFileSync(
      join(dataDir, "tailscale"),
      `#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
case "\$cmd" in
  status)
    if [[ "\${2:-}" == "--json" ]]; then
      echo '{"Self":{"DNSName":"my-server.tail00000.ts.net."}}'
      exit 0
    fi
    ;;
  cert)
    echo $(( $(cat "${certCallsPath}") + 1 )) > "${certCallsPath}"
    cert_file=""; key_file=""; host=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --cert-file) cert_file="\$2"; shift 2 ;;
        --key-file) key_file="\$2"; shift 2 ;;
        --min-validity) shift 2 ;;
        *) host="\$1"; shift ;;
      esac
    done
    mkdir -p "\$(dirname "\$cert_file")" "\$(dirname "\$key_file")"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \\
      -keyout "\$key_file" -out "\$cert_file" -subj "/CN=\$host" \\
      -addext "subjectAltName=DNS:\$host" -days 1 >/dev/null 2>&1
    exit 0
    ;;
esac
exit 1
`,
      { mode: 0o755 },
    );
    chmodSync(join(dataDir, "tailscale"), 0o755);

    const previousRetryMs = process.env.OPPI_REMOTE_BIND_RETRY_MS;
    process.env.OPPI_REMOTE_BIND_RETRY_MS = "80";
    const originalPath = process.env.PATH;
    process.env.PATH = `${dataDir}:${originalPath}`;
    const server = new Server(storage);
    try {
      await server.start();
      expect(server.remoteAvailable).toBe(false);
      const afterStart = Number(readFileSync(certCallsPath, "utf8"));
      expect(afterStart).toBeGreaterThanOrEqual(1);

      // A leftover httpServer from the first EADDRNOTAVAIL must not skip TLS prep.
      await waitFor(() => Number(readFileSync(certCallsPath, "utf8")) > afterStart, 8_000);
      expect(server.remoteAvailable).toBe(false);

      storage.updateConfig({ host: "127.0.0.1" });
      await waitFor(() => server.remoteAvailable, 8_000);
      expect(server.remoteAvailable).toBe(true);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      process.env.PATH = originalPath;
      if (previousRetryMs === undefined) delete process.env.OPPI_REMOTE_BIND_RETRY_MS;
      else process.env.OPPI_REMOTE_BIND_RETRY_MS = previousRetryMs;
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("retries the remote listener when the configured bind address returns", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-bind-retry-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "192.0.2.1",
      port: 0,
      tls: { mode: "disabled", allowInsecureNetworkHttp: true },
    });

    const previousRetryMs = process.env.OPPI_REMOTE_BIND_RETRY_MS;
    process.env.OPPI_REMOTE_BIND_RETRY_MS = "40";
    const server = new Server(storage);
    try {
      await server.start();
      expect(server.remoteAvailable).toBe(false);
      expect(existsSync(server.socketPath)).toBe(true);

      storage.updateConfig({ host: "127.0.0.1" });
      await waitFor(() => server.remoteAvailable, 3_000);
      expect(server.remoteAvailable).toBe(true);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      if (previousRetryMs === undefined) delete process.env.OPPI_REMOTE_BIND_RETRY_MS;
      else process.env.OPPI_REMOTE_BIND_RETRY_MS = previousRetryMs;
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("keeps retrying the remote listener after a transient EADDRINUSE", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-eaddrinuse-retry-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    const port = await getFreePort();
    storage.updateConfig({
      host: "192.0.2.1",
      port,
      tls: { mode: "disabled", allowInsecureNetworkHttp: true },
    });

    const occupant = createHttpServer();
    const previousRetryMs = process.env.OPPI_REMOTE_BIND_RETRY_MS;
    process.env.OPPI_REMOTE_BIND_RETRY_MS = "40";
    const server = new Server(storage);
    try {
      await listenOnPort(occupant, port);
      await server.start();
      expect(server.remoteAvailable).toBe(false);
      expect(existsSync(server.socketPath)).toBe(true);

      storage.updateConfig({ host: "127.0.0.1" });
      await new Promise((resolve) => setTimeout(resolve, 120));
      expect(server.remoteAvailable).toBe(false);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );

      await close(occupant);
      await waitFor(() => server.remoteAvailable, 3_000);
      expect(server.remoteAvailable).toBe(true);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      if (previousRetryMs === undefined) delete process.env.OPPI_REMOTE_BIND_RETRY_MS;
      else process.env.OPPI_REMOTE_BIND_RETRY_MS = previousRetryMs;
      await close(occupant);
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("keeps the local API when the configured bind address is missing", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-eaddrnotavail-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "192.0.2.1",
      port: 0,
      tls: { mode: "disabled", allowInsecureNetworkHttp: true },
    });

    const server = new Server(storage);
    try {
      await server.start();
      expect(server.remoteAvailable).toBe(false);
      expect(existsSync(server.socketPath)).toBe(true);
      await expect(localApiRequest<Record<string, unknown>>(storage, "/me")).resolves.toEqual(
        expect.objectContaining({}),
      );
    } finally {
      await server.stop().catch(() => {});
      expect(existsSync(server.socketPath)).toBe(false);
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 30_000);

  it("serves local requests while slow Tailscale preparation is still running", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-slow-remote-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "tailscale" },
    });
    writeFileSync(join(dataDir, "tailscale"), "#!/bin/sh\n/bin/sleep 3\nexit 1\n", {
      mode: 0o755,
    });

    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    const server = new Server(storage);
    let startSettled = false;
    const start = server.start().finally(() => {
      startSettled = true;
    });
    try {
      await waitFor(() => existsSync(server.socketPath));
      await expect(
        Promise.race([
          localApiRequest<Record<string, unknown>>(storage, "/workspaces"),
          new Promise((_, reject) =>
            setTimeout(() => reject(new Error("local API was blocked by TLS preparation")), 2_000),
          ),
        ]),
      ).resolves.toEqual(expect.objectContaining({ workspaces: [] }));
      expect(startSettled).toBe(false);

      await start;
      process.env.PATH = originalPath;
      expect(server.remoteAvailable).toBe(false);
    } finally {
      process.env.PATH = originalPath;
      await start.catch(() => {});
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  }, 10_000);

  it("keeps unexpected TLS preparation errors fatal and cleans up the local socket", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-tls-error-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: {
        mode: "manual",
        certPath: join(dataDir, "missing.crt"),
        keyPath: join(dataDir, "missing.key"),
      },
    });
    const server = new Server(storage);
    try {
      await expect(server.start()).rejects.toThrow("TLS cert not found");
      expect(existsSync(server.socketPath)).toBe(false);
      expect(existsSync(`${server.socketPath}.lock`)).toBe(false);
    } finally {
      await server.stop().catch(() => {});
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("creates a private runtime directory and releases only its socket binding", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-mode-"));
    const socketPath = localApiSocketPath(dataDir);
    const server = createHttpServer();
    let binding: LocalApiSocketBinding | undefined;
    try {
      binding = await listenOnLocalApiSocket(server, socketPath);
      expect(statSync(dirname(socketPath)).mode & 0o777).toBe(0o700);
      expect(statSync(socketPath).mode & 0o777).toBe(0o600);
      expect(statSync(`${socketPath}.lock`).mode & 0o777).toBe(0o600);
    } finally {
      await close(server);
      binding?.release();
      expect(existsSync(socketPath)).toBe(false);
      expect(existsSync(`${socketPath}.lock`)).toBe(false);
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("refuses a second concurrent server for the same data directory", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-lock-"));
    const socketPath = localApiSocketPath(dataDir);
    const first = createHttpServer();
    const second = createHttpServer();
    const binding = await listenOnLocalApiSocket(first, socketPath);
    try {
      await expect(listenOnLocalApiSocket(second, socketPath)).rejects.toThrow(
        /startup is already owned/,
      );
    } finally {
      await close(first);
      await close(second);
      binding.release();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("reclaims a lock left by an earlier process instance with the same PID", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-pid-reuse-"));
    const socketPath = localApiSocketPath(dataDir);
    mkdirSync(dirname(socketPath), { recursive: true, mode: 0o700 });
    writeFileSync(
      `${socketPath}.lock`,
      `${JSON.stringify({
        pid: process.pid,
        token: "previous-lock",
        processInstanceToken: "previous-process-instance",
      })}\n`,
      { mode: 0o600 },
    );
    const server = createHttpServer();
    let binding: LocalApiSocketBinding | undefined;
    try {
      binding = await listenOnLocalApiSocket(server, socketPath);
      expect(existsSync(socketPath)).toBe(true);
    } finally {
      await close(server);
      binding?.release();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("refuses to replace a non-socket path", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-local-socket-file-"));
    const socketPath = localApiSocketPath(dataDir);
    mkdirSync(dirname(socketPath), { recursive: true, mode: 0o700 });
    writeFileSync(socketPath, "not a socket", { mode: 0o600 });
    const server = createHttpServer();
    try {
      await expect(listenOnLocalApiSocket(server, socketPath)).rejects.toThrow(
        /Refusing to replace non-socket/,
      );
      expect(existsSync(socketPath)).toBe(true);
      expect(existsSync(`${socketPath}.lock`)).toBe(false);
    } finally {
      await close(server);
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("uses a bounded deterministic fallback for deep custom data directories", () => {
    const dataDir = join(tmpdir(), "oppi-deep-data", "x".repeat(180));
    const first = localApiSocketPath(dataDir);
    const second = localApiSocketPath(dataDir);
    expect(first).toBe(second);
    expect(Buffer.byteLength(first)).toBeLessThanOrEqual(100);
    expect(first).not.toContain("x".repeat(100));
  });
});

async function close(server: HttpServer): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve) => server.close(() => resolve()));
}

function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createHttpServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("Failed to allocate test port")));
        return;
      }
      const { port } = address;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
  });
}

function listenOnPort(server: HttpServer, port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => resolve());
  });
}

async function waitFor(condition: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for local API socket");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
