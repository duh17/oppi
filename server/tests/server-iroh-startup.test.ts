import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer as createNetServer, type Socket } from "node:net";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { mockStartIrohPairingServer } = vi.hoisted(() => ({
  mockStartIrohPairingServer: vi.fn(),
}));

vi.mock("../src/iroh-pairing-server.js", () => ({
  startIrohPairingServer: mockStartIrohPairingServer,
}));

import { readIrohInviteState, writeIrohInviteState } from "../src/iroh-invite-state.js";
import type { IrohTunnelTarget } from "../src/iroh-pairing-server.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

let originalIrohPairing: string | undefined;
let originalIrohTransport: string | undefined;
let originalIrohInviteMode: string | undefined;
let dataDir: string;
let storage: Storage;

beforeEach(() => {
  originalIrohPairing = process.env.OPPI_IROH_PAIRING;
  originalIrohTransport = process.env.OPPI_IROH_TRANSPORT;
  originalIrohInviteMode = process.env.OPPI_IROH_INVITE_MODE;
  delete process.env.OPPI_IROH_PAIRING;
  delete process.env.OPPI_IROH_TRANSPORT;
  delete process.env.OPPI_IROH_INVITE_MODE;
  mockStartIrohPairingServer.mockReset();

  dataDir = mkdtempSync(join(tmpdir(), "oppi-server-iroh-startup-"));
  storage = new Storage(dataDir);
  storage.updateConfig({ host: "127.0.0.1", port: 0, tls: { mode: "disabled" } });
});

async function letBackgroundStartupTasksRun(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function mockedTunnelTarget(): IrohTunnelTarget {
  const call = mockStartIrohPairingServer.mock.calls.at(-1) as
    | [Storage, { tunnelTarget: IrohTunnelTarget }]
    | undefined;
  if (!call) throw new Error("Iroh pairing server was not started");
  return call[1].tunnelTarget;
}

async function exchangeRawHttp(
  target: IrohTunnelTarget,
  context: { clientNodeId: string; bearerToken: string },
  request: string,
  stopWhen?: (response: string) => boolean,
): Promise<string> {
  const socket = (await target.open(context)) as Socket;
  let response = "";
  return await new Promise<string>((resolve, reject) => {
    const finish = (): void => resolve(response);
    socket.on("data", (chunk: Buffer) => {
      response += chunk.toString("utf8");
      if (stopWhen?.(response)) socket.destroy();
    });
    socket.once("end", finish);
    socket.once("close", finish);
    socket.once("error", reject);
    socket.resume();
    socket.write(request);
  });
}

afterEach(() => {
  if (originalIrohPairing === undefined) delete process.env.OPPI_IROH_PAIRING;
  else process.env.OPPI_IROH_PAIRING = originalIrohPairing;
  if (originalIrohTransport === undefined) delete process.env.OPPI_IROH_TRANSPORT;
  else process.env.OPPI_IROH_TRANSPORT = originalIrohTransport;
  if (originalIrohInviteMode === undefined) delete process.env.OPPI_IROH_INVITE_MODE;
  else process.env.OPPI_IROH_INVITE_MODE = originalIrohInviteMode;
  rmSync(dataDir, { recursive: true, force: true });
});

describe("server Iroh pairing startup", () => {
  it("does not start Iroh when the feature flag is disabled", async () => {
    const server = new Server(storage);
    try {
      await server.start();
      expect(mockStartIrohPairingServer).not.toHaveBeenCalled();
    } finally {
      await letBackgroundStartupTasksRun();
      await server.stop();
    }
  });

  it("starts Iroh when durable config enables the transport", async () => {
    storage.updateConfig({ iroh: { enabled: true } });
    mockStartIrohPairingServer.mockResolvedValueOnce({
      nodeId: "iroh-node",
      ticket: "endpoint-ticket",
      alpns: ["oppi/pair/1", "oppi/http/1"],
      close: vi.fn(async () => {}),
    });
    const server = new Server(storage);
    try {
      await server.start();
      expect(mockStartIrohPairingServer).toHaveBeenCalledOnce();
      expect(storage.getConfig().irohInviteMode).toBe("irohPreferred");
    } finally {
      await server.stop();
    }
  });

  it("logs Iroh startup failure while preserving the HTTP fallback", async () => {
    process.env.OPPI_IROH_PAIRING = "1";
    const staleInvitePath = join(dataDir, "iroh", "invite.json");
    mkdirSync(join(dataDir, "iroh"), { recursive: true });
    writeFileSync(staleInvitePath, JSON.stringify({ stale: true }));
    mockStartIrohPairingServer.mockRejectedValueOnce(new Error("bind failed"));
    const server = new Server(storage);
    try {
      await server.start();
      expect(mockStartIrohPairingServer).toHaveBeenCalledWith(
        storage,
        expect.objectContaining({
          tunnelTarget: expect.objectContaining({
            open: expect.any(Function),
            contextFor: expect.any(Function),
            close: expect.any(Function),
          }),
        }),
      );

      const response = await fetch(`http://127.0.0.1:${server.port}/health`);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ ok: true, protocol: 2 });
      expect(server.irohFailure?.message).toBe("bind failed");
      expect(existsSync(staleInvitePath)).toBe(false);
    } finally {
      await letBackgroundStartupTasksRun();
      await server.stop();
    }
  });

  it("fails startup closed when irohOnly readiness cannot be established", async () => {
    process.env.OPPI_IROH_TRANSPORT = "1";
    process.env.OPPI_IROH_INVITE_MODE = "irohOnly";
    mockStartIrohPairingServer.mockRejectedValueOnce(new Error("relay unavailable"));

    const server = new Server(storage);
    await expect(server.start()).rejects.toThrow("relay unavailable");
    expect(mockStartIrohPairingServer).toHaveBeenCalledOnce();
  });

  it("rejects irohOnly configuration when the transport is disabled", async () => {
    process.env.OPPI_IROH_INVITE_MODE = "irohOnly";
    const server = new Server(storage);
    await expect(server.start()).rejects.toThrow(
      "Iroh-only mode requires iroh.enabled=true or OPPI_IROH_TRANSPORT=1",
    );
    expect(mockStartIrohPairingServer).not.toHaveBeenCalled();
  });

  it("rejects irohOnly pairing tokens over HTTP without consuming them", async () => {
    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });

    const server = new Server(storage);
    try {
      await server.start();

      const rejected = await fetch(`http://127.0.0.1:${server.port}/pair`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pairingToken }),
      });
      expect(rejected.status).toBe(401);
      expect(storage.getConfig().pairingToken).toBe(pairingToken);

      const irohCredential = storage.consumePairingToken(pairingToken, {
        transport: "iroh",
        irohClientNodeId: "client-node-1",
      });
      expect(irohCredential?.deviceToken).toMatch(/^dt_/);

      const httpMe = await fetch(`http://127.0.0.1:${server.port}/me`, {
        headers: { Authorization: `Bearer ${irohCredential?.deviceToken}` },
      });
      expect(httpMe.status).toBe(401);
    } finally {
      await letBackgroundStartupTasksRun();
      await server.stop();
    }
  });

  it("allows irohPreferred pairing tokens to fall back to HTTP pairing", async () => {
    const pairingToken = storage.issuePairingToken(60_000, {
      allowedTransports: ["iroh", "http"],
    });

    const server = new Server(storage);
    try {
      await server.start();

      const paired = await fetch(`http://127.0.0.1:${server.port}/pair`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pairingToken }),
      });
      expect(paired.status).toBe(200);
      const body = (await paired.json()) as { deviceToken?: string };
      expect(body.deviceToken).toMatch(/^dt_/);

      const httpMe = await fetch(`http://127.0.0.1:${server.port}/me`, {
        headers: { Authorization: `Bearer ${body.deviceToken}` },
      });
      expect(httpMe.status).toBe(200);
    } finally {
      await letBackgroundStartupTasksRun();
      await server.stop();
    }
  });

  it("rejects Iroh-only device tokens over HTTP while preserving unbound HTTP tokens", async () => {
    const unboundPairingToken = storage.issuePairingToken(60_000);
    const unboundCredential = storage.consumePairingToken(unboundPairingToken, {
      transport: "http",
    });
    const irohOnlyPairingToken = storage.issuePairingToken(60_000, {
      allowedTransports: ["iroh"],
    });
    const irohOnlyCredential = storage.consumePairingToken(irohOnlyPairingToken, {
      transport: "iroh",
      irohClientNodeId: "client-node-1",
    });
    expect(unboundCredential?.deviceToken).toMatch(/^dt_/);
    expect(irohOnlyCredential?.deviceToken).toMatch(/^dt_/);

    const server = new Server(storage);
    try {
      await server.start();

      const unbound = await fetch(`http://127.0.0.1:${server.port}/me`, {
        headers: { Authorization: `Bearer ${unboundCredential?.deviceToken}` },
      });
      expect(unbound.status).toBe(200);

      const irohOnly = await fetch(`http://127.0.0.1:${server.port}/me`, {
        headers: { Authorization: `Bearer ${irohOnlyCredential?.deviceToken}` },
      });
      expect(irohOnly.status).toBe(401);
    } finally {
      await letBackgroundStartupTasksRun();
      await server.stop();
    }
  });

  it("accepts Iroh-bound device tokens over HTTP when the binding allows HTTP", async () => {
    const pairingToken = storage.issuePairingToken(60_000, {
      allowedTransports: ["iroh", "http"],
    });
    const credential = storage.consumePairingToken(pairingToken, {
      transport: "iroh",
      irohClientNodeId: "client-node-1",
    });
    expect(credential?.deviceToken).toMatch(/^dt_/);

    const server = new Server(storage);
    try {
      await server.start();

      const response = await fetch(`http://127.0.0.1:${server.port}/me`, {
        headers: { Authorization: `Bearer ${credential?.deviceToken}` },
      });
      expect(response.status).toBe(200);
    } finally {
      await letBackgroundStartupTasksRun();
      await server.stop();
    }
  });

  it("starts Iroh-only with an occupied configured port and unusable TLS", async () => {
    process.env.OPPI_IROH_TRANSPORT = "1";
    process.env.OPPI_IROH_INVITE_MODE = "irohOnly";
    const blocker = createNetServer();
    await new Promise<void>((resolve, reject) => {
      blocker.once("error", reject);
      blocker.listen(0, "127.0.0.1", resolve);
    });
    const address = blocker.address();
    if (!address || typeof address === "string") throw new Error("missing blocker port");
    storage.updateConfig({
      host: "not-a-bindable-public-host.invalid",
      port: address.port,
      tls: {
        mode: "manual",
        certPath: join(dataDir, "missing.crt"),
        keyPath: join(dataDir, "missing.key"),
      },
    });
    mockStartIrohPairingServer.mockResolvedValueOnce({
      nodeId: "iroh-node",
      ticket: "endpoint-ticket",
      alpns: ["oppi/pair/1", "oppi/http/1"],
      close: vi.fn(async () => {}),
    });
    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });
    const credential = storage.consumePairingToken(pairingToken, {
      transport: "iroh",
      irohClientNodeId: "client-node",
    });
    if (!credential) throw new Error("failed to issue Iroh token");
    const deviceToken = credential.deviceToken;

    const server = new Server(storage);
    try {
      await server.start();
      expect(server.hasPublicHttpListener).toBe(false);
      const response = await exchangeRawHttp(
        mockedTunnelTarget(),
        { clientNodeId: "client-node", bearerToken: deviceToken },
        `GET /me HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nConnection: close\r\n\r\n`,
      );
      expect(response).toContain("HTTP/1.1 200 OK");
      expect(response).toContain('"user":"owner"');
    } finally {
      await server.stop();
      await new Promise<void>((resolve) => blocker.close(() => resolve()));
    }
  });

  it("requires the tunnel bearer on every raw HTTP request and WebSocket upgrade", async () => {
    process.env.OPPI_IROH_TRANSPORT = "1";
    process.env.OPPI_IROH_INVITE_MODE = "irohOnly";
    mockStartIrohPairingServer.mockResolvedValueOnce({
      nodeId: "iroh-node",
      ticket: "endpoint-ticket",
      alpns: ["oppi/pair/1", "oppi/http/1"],
      close: vi.fn(async () => {}),
    });
    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });
    const credential = storage.consumePairingToken(pairingToken, {
      transport: "iroh",
      irohClientNodeId: "client-node",
    });
    if (!credential) throw new Error("failed to issue Iroh token");
    const deviceToken = credential.deviceToken;

    const server = new Server(storage);
    try {
      await server.start();
      const target = mockedTunnelTarget();
      const context = { clientNodeId: "client-node", bearerToken: deviceToken };
      const missing = await exchangeRawHttp(
        target,
        context,
        "GET /health HTTP/1.1\r\nHost: iroh.internal\r\nConnection: close\r\n\r\n",
      );
      expect(missing).toContain("HTTP/1.1 401 Unauthorized");

      const wrong = await exchangeRawHttp(
        target,
        context,
        "GET /health HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer dt_wrong\r\nConnection: close\r\n\r\n",
      );
      expect(wrong).toContain("HTTP/1.1 401 Unauthorized");

      const correct = await exchangeRawHttp(
        target,
        context,
        `GET /health HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nConnection: close\r\n\r\n`,
      );
      expect(correct).toContain("HTTP/1.1 200 OK");

      const keepAlive = await exchangeRawHttp(
        target,
        context,
        `GET /health HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nConnection: keep-alive\r\n\r\nGET /health HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer dt_wrong\r\nConnection: close\r\n\r\n`,
      );
      expect(keepAlive.match(/HTTP\/1\.1 200 OK/g)).toHaveLength(1);
      expect(keepAlive.match(/HTTP\/1\.1 401 Unauthorized/g)).toHaveLength(1);

      const upgrade = await exchangeRawHttp(
        target,
        context,
        `GET /app/events/stream HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`,
        (response) => response.includes("HTTP/1.1 101 Switching Protocols"),
      );
      expect(upgrade).toContain("HTTP/1.1 101 Switching Protocols");
    } finally {
      await server.stop();
    }
  });

  it("bounds Server.stop with active REST, keep-alive, and WebSocket tunnels", async () => {
    process.env.OPPI_IROH_TRANSPORT = "1";
    process.env.OPPI_IROH_INVITE_MODE = "irohOnly";
    mockStartIrohPairingServer.mockResolvedValueOnce({
      nodeId: "iroh-node",
      ticket: "endpoint-ticket",
      alpns: ["oppi/pair/1", "oppi/http/1"],
      close: vi.fn(async () => {}),
    });
    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });
    const credential = storage.consumePairingToken(pairingToken, {
      transport: "iroh",
      irohClientNodeId: "client-node",
    });
    if (!credential) throw new Error("failed to issue Iroh token");
    const deviceToken = credential.deviceToken;
    const context = { clientNodeId: "client-node", bearerToken: deviceToken };

    const server = new Server(storage);
    await server.start();
    const target = mockedTunnelTarget();
    const rest = (await target.open(context)) as Socket;
    const keepAlive = (await target.open(context)) as Socket;
    const webSocket = (await target.open(context)) as Socket;
    for (const socket of [rest, keepAlive, webSocket]) socket.resume();
    rest.write(
      `POST /workspaces HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nContent-Type: application/json\r\nContent-Length: 100\r\nConnection: keep-alive\r\n\r\n{`,
    );
    keepAlive.write(
      `GET /health HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nConnection: keep-alive\r\n\r\n`,
    );
    webSocket.write(
      `GET /app/events/stream HTTP/1.1\r\nHost: iroh.internal\r\nAuthorization: Bearer ${deviceToken}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`,
    );
    await new Promise((resolve) => setTimeout(resolve, 20));

    const startedAt = Date.now();
    await server.stop();
    expect(Date.now() - startedAt).toBeLessThan(500);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(rest.destroyed).toBe(true);
    expect(keepAlive.destroyed).toBe(true);
    expect(webSocket.destroyed).toBe(true);
  });

  it("clears readiness and exposes terminal Iroh-only failure to the server callback", async () => {
    process.env.OPPI_IROH_TRANSPORT = "1";
    process.env.OPPI_IROH_INVITE_MODE = "irohOnly";
    let failTransport: ((error: Error) => void) | undefined;
    mockStartIrohPairingServer.mockImplementationOnce(
      async (_storage: Storage, options: { onFailure: (error: Error) => void }) => {
        failTransport = options.onFailure;
        return {
          nodeId: "iroh-node",
          ticket: "endpoint-ticket",
          alpns: ["oppi/pair/1", "oppi/http/1"],
          close: vi.fn(async () => {}),
        };
      },
    );
    const observed: Error[] = [];
    const server = new Server(storage, undefined, {
      onIrohTransportFailure: (error) => observed.push(error),
    });
    try {
      await server.start();
      const readinessId = storage.getConfig().irohInviteReadinessId;
      if (!readinessId) throw new Error("missing readiness id");
      writeIrohInviteState(dataDir, {
        version: 2,
        nodeId: "iroh-node",
        alpns: ["oppi/pair/1", "oppi/http/1"],
        addressMode: "ticket",
        ticket: "endpoint-ticket",
        readinessId,
        processId: process.pid,
      });

      failTransport?.(new Error("accept loop exploded"));

      expect(readIrohInviteState(dataDir)).toBeUndefined();
      expect(server.irohFailure?.message).toBe("accept loop exploded");
      expect(observed.map((error) => error.message)).toEqual(["accept loop exploded"]);
    } finally {
      await server.stop();
    }
  });

  it("closes the Iroh listener during server shutdown", async () => {
    process.env.OPPI_IROH_TRANSPORT = "1";
    const close = vi.fn(async () => {});
    mockStartIrohPairingServer.mockResolvedValueOnce({
      nodeId: "iroh-node",
      ticket: "endpoint-ticket",
      alpns: ["oppi/pair/1"],
      close,
    });

    const server = new Server(storage);
    await server.start();
    await letBackgroundStartupTasksRun();
    await server.stop();

    expect(close).toHaveBeenCalledOnce();
  });
});
