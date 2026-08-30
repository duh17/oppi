import { createConnection } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";
import { WebSocket, type RawData } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";

describe("owner-socket WebSocket upgrades", () => {
  let dataDir = "";
  let server: Server | undefined;
  let originalTlsRejectUnauthorized: string | undefined;

  afterEach(async () => {
    await server?.stop().catch(() => {});
    server = undefined;
    if (dataDir) {
      rmSync(dataDir, { recursive: true, force: true });
      dataDir = "";
    }
    if (originalTlsRejectUnauthorized === undefined) {
      delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    } else {
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = originalTlsRejectUnauthorized;
    }
    originalTlsRejectUnauthorized = undefined;
  });

  it("accepts an owner-authenticated app-event stream on the Unix socket", async () => {
    const ctx = await startLocalServer();
    const ws = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: "/app/events/stream",
      headers: { Authorization: `Bearer ${ctx.token}` },
    });
    const firstFrame = waitForJsonFrame(ws);

    try {
      await waitForOpen(ws);
      const frame = await firstFrame;
      expect(frame["type"]).toBe("app_events_connected");
      expect(frame["snapshotRequired"]).toBe(true);
    } finally {
      await closeQuietly(ws);
    }
  }, 20_000);

  it("rejects missing and wrong owner bearers on local live upgrades", async () => {
    const ctx = await startLocalServer();

    const missing = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: "/app/events/stream",
    });
    await expect(waitForUpgradeRejection(missing)).resolves.toMatchObject({ statusCode: 401 });

    const wrong = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: "/app/events/stream",
      headers: { Authorization: "Bearer sk_wrong_owner_token" },
    });
    await expect(waitForUpgradeRejection(wrong)).resolves.toMatchObject({ statusCode: 401 });
  });

  it("rejects unknown local upgrade paths with 404", async () => {
    const ctx = await startLocalServer();
    const ws = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: "/not-a-stream",
      headers: { Authorization: `Bearer ${ctx.token}` },
    });
    await expect(waitForUpgradeRejection(ws)).resolves.toMatchObject({ statusCode: 404 });
  });

  it("keeps the local mirror bridge bearer-free", async () => {
    const ctx = await startLocalServer();
    const ws = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: "/mirror/v1/bridge",
    });
    try {
      await waitForOpen(ws);
    } finally {
      await closeQuietly(ws);
    }
  });

  it("closes focused local upgrades that fail workspace scope checks", async () => {
    const ctx = await startLocalServer();
    const { workspace, session } = createStoredSession(ctx.storage);

    const missing = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: `/workspaces/${workspace.id}/sessions/missing-session/stream`,
      headers: { Authorization: `Bearer ${ctx.token}` },
    });
    await expect(waitForClose(missing)).resolves.toMatchObject({ code: 1008 });

    const wrongWorkspace = connectUnixWebSocket({
      socketPath: ctx.socketPath,
      path: `/workspaces/other-workspace/sessions/${session.id}/stream`,
      headers: { Authorization: `Bearer ${ctx.token}` },
    });
    await expect(waitForClose(wrongWorkspace)).resolves.toMatchObject({ code: 1008 });
  });

  it("rejects owner sk_ on the network live listener", async () => {
    const ctx = await startNetworkedServer();
    const ws = new WebSocket(`${ctx.baseUrl.replace(/^https:/, "wss:")}/app/events/stream`, {
      headers: { Authorization: `Bearer ${ctx.token}` },
      rejectUnauthorized: false,
    });
    await expect(waitForUpgradeRejection(ws)).resolves.toMatchObject({ statusCode: 401 });
  });

  it("rejects the mirror bridge on the network listener", async () => {
    const ctx = await startNetworkedServer();
    const ws = new WebSocket(`${ctx.baseUrl.replace(/^https:/, "wss:")}/mirror/v1/bridge`, {
      headers: { Authorization: `Bearer ${ctx.token}` },
      rejectUnauthorized: false,
    });
    await expect(waitForUpgradeRejection(ws)).resolves.toMatchObject({ statusCode: 404 });
  });

  async function startLocalServer(): Promise<{
    storage: Storage;
    token: string;
    socketPath: string;
  }> {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-local-ws-"));
    const storage = new Storage(dataDir);
    const token = storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "tailscale" },
    });
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    server = new Server(storage);
    try {
      await server.start();
    } finally {
      process.env.PATH = originalPath;
    }
    return { storage, token, socketPath: server.socketPath };
  }

  async function startNetworkedServer(): Promise<{
    token: string;
    baseUrl: string;
  }> {
    originalTlsRejectUnauthorized = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    dataDir = mkdtempSync(join(tmpdir(), "oppi-network-ws-"));
    const storage = new Storage(dataDir);
    const token = storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "self-signed" },
    });
    server = new Server(storage);
    await server.start();
    return { token, baseUrl: `https://127.0.0.1:${server.port}` };
  }
});

function createStoredSession(storage: Storage): { workspace: { id: string }; session: Session } {
  const workspace = storage.createWorkspace({
    name: "local-ws-scope",
    hostMount: storage.getDataDir(),
  });
  const created = storage.createSession("Scoped session");
  const session: Session = {
    ...created,
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    status: "stopped",
  };
  storage.saveSession(session);
  return { workspace, session };
}

function connectUnixWebSocket(opts: {
  socketPath: string;
  path: string;
  headers?: Record<string, string>;
}): WebSocket {
  return new WebSocket(`ws://localhost${opts.path}`, {
    headers: opts.headers,
    createConnection: () => createConnection(opts.socketPath),
  });
}

function waitForOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      ws.terminate();
      reject(new Error("Timed out waiting for WebSocket open after 15000ms"));
    }, 15_000);
    const cleanup = (): void => {
      clearTimeout(timer);
      ws.off("open", onOpen);
      ws.off("unexpected-response", onUnexpected);
      ws.off("error", onError);
    };
    const onOpen = (): void => {
      cleanup();
      resolve();
    };
    const onUnexpected = (
      _request: unknown,
      response: { statusCode?: number },
    ): void => {
      cleanup();
      reject(new Error(`WS upgrade failed with HTTP ${response.statusCode ?? "unknown"}`));
    };
    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };
    ws.once("open", onOpen);
    ws.once("unexpected-response", onUnexpected);
    ws.once("error", onError);
  });
}

function waitForJsonFrame(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("Timed out waiting for WebSocket JSON frame after 15000ms"));
    }, 15_000);
    const cleanup = (): void => {
      clearTimeout(timer);
      ws.off("message", onMessage);
      ws.off("close", onClose);
      ws.off("error", onError);
    };
    const onMessage = (data: RawData): void => {
      cleanup();
      resolve(JSON.parse(rawDataToString(data)) as Record<string, unknown>);
    };
    const onClose = (code: number, reason: Buffer): void => {
      cleanup();
      reject(new Error(`WebSocket closed before JSON frame (${code} ${reason.toString()})`));
    };
    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };
    ws.once("message", onMessage);
    ws.once("close", onClose);
    ws.once("error", onError);
  });
}

function waitForClose(ws: WebSocket): Promise<{ code: number }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      ws.terminate();
      reject(new Error("Timed out waiting for WebSocket close after 15000ms"));
    }, 15_000);
    const cleanup = (): void => {
      clearTimeout(timer);
      ws.off("close", onClose);
      ws.off("unexpected-response", onUnexpected);
      ws.off("error", onError);
    };
    const onClose = (code: number): void => {
      cleanup();
      resolve({ code });
    };
    const onUnexpected = (
      _request: unknown,
      response: { statusCode?: number },
    ): void => {
      cleanup();
      reject(new Error(`WS upgrade failed with HTTP ${response.statusCode ?? "unknown"}`));
    };
    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };
    ws.once("close", onClose);
    ws.once("unexpected-response", onUnexpected);
    ws.once("error", onError);
  });
}

function waitForUpgradeRejection(ws: WebSocket): Promise<{ statusCode: number }> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      ws.terminate();
      reject(new Error("Timed out waiting for WebSocket upgrade rejection after 15000ms"));
    }, 15_000);
    const cleanup = (): void => {
      clearTimeout(timer);
      ws.off("unexpected-response", onUnexpected);
      ws.off("open", onOpen);
      ws.off("error", onError);
    };
    const onUnexpected = (
      _request: unknown,
      response: { statusCode?: number; resume(): void },
    ): void => {
      cleanup();
      response.resume();
      resolve({ statusCode: response.statusCode ?? 0 });
    };
    const onOpen = (): void => {
      cleanup();
      ws.close();
      reject(new Error("Expected upgrade rejection but connection opened"));
    };
    const onError = (error: Error): void => {
      cleanup();
      reject(error);
    };
    ws.once("unexpected-response", onUnexpected);
    ws.once("open", onOpen);
    ws.once("error", onError);
  });
}

async function closeQuietly(ws: WebSocket): Promise<void> {
  if (ws.readyState === WebSocket.CLOSED) return;
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      ws.terminate();
      resolve();
    }, 2_000);
    ws.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
    if (ws.readyState !== WebSocket.CLOSING) {
      ws.close();
    }
  });
}

function rawDataToString(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}
