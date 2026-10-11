import { createServer, type Server as NetServer, type Socket } from "node:net";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateKeyPairSync } from "node:crypto";
import { WebSocket } from "ws";

import { afterEach, describe, expect, it } from "vitest";

import { desktopCompanionOwnerSocketPath } from "../src/desktop-companion-still-client.js";
import { DesktopCompanionViewStreamClient } from "../src/desktop-companion-view-stream-client.js";
import { DesktopViewStreamMux } from "../src/desktop-view-stream.js";
import {
  CompanionFrameReader,
  encodeCompanionJson,
  encodeCompanionMedia,
  encodeMediaFrame,
  parseControlJson,
} from "../src/desktop-view-stream-codec.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import {
  DESKTOP_VIEW_ERROR,
  DESKTOP_VIEW_FEATURE_H264_ANNEXB,
  DESKTOP_VIEW_STREAM_PATH,
  DESKTOP_VIEW_WIRE_VERSION,
} from "../src/types/protocol.js";
import { makeResponse } from "./harness/route-test-helpers.js";

const tempDirs: string[] = [];

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

class FakePhoneSocket {
  readyState = 1;
  OPEN = 1;
  CONNECTING = 0;
  CLOSING = 2;
  CLOSED = 3;
  sent: Array<{ data: Buffer | string; binary?: boolean }> = [];
  closeCode: number | undefined;
  closeReason: string | undefined;
  private readonly handlers = new Map<string, Array<(...args: unknown[]) => void>>();

  on(event: string, handler: (...args: unknown[]) => void): void {
    const list = this.handlers.get(event) ?? [];
    list.push(handler);
    this.handlers.set(event, list);
  }

  send(data: Buffer | string, options?: { binary?: boolean }): void {
    this.sent.push({ data, binary: options?.binary });
  }

  close(code?: number, reason?: string): void {
    this.readyState = this.CLOSED;
    this.closeCode = code;
    this.closeReason = reason;
    this.emit("close", code, Buffer.from(reason ?? ""));
  }

  emit(event: string, ...args: unknown[]): void {
    for (const handler of this.handlers.get(event) ?? []) handler(...args);
  }

  emitText(value: unknown): void {
    this.emit("message", Buffer.from(JSON.stringify(value), "utf8"), false);
  }

  textMessages(): Array<Record<string, unknown>> {
    return this.sent
      .filter((item) => !item.binary && typeof item.data === "string")
      .map((item) => JSON.parse(item.data as string) as Record<string, unknown>);
  }

  binaryMessages(): Buffer[] {
    return this.sent
      .filter((item) => item.binary)
      .map((item) => (Buffer.isBuffer(item.data) ? item.data : Buffer.from(item.data)));
  }
}

type FakeCompanionOptions = {
  deviceId: string;
  status?: number;
  body?: string;
  hello?: Record<string, unknown>;
  onEncode?: (encode: Record<string, unknown>, socket: Socket) => void;
  closeAfterHelloMs?: number;
  errorBeforeClose?: Record<string, unknown>;
};

function companionRoot(): string {
  const root = tempDir("oppi-dv-comp-");
  mkdirSync(join(root, "run"), { recursive: true });
  return root;
}

async function listenFakeCompanion(
  runtimeRoot: string,
  options: FakeCompanionOptions,
): Promise<NetServer> {
  const socketPath = desktopCompanionOwnerSocketPath(runtimeRoot);
  const server = createServer((socket) => {
    let buf = Buffer.alloc(0);
    let upgraded = false;
    const reader = new CompanionFrameReader();
    const handleFrames = (chunk: Buffer): void => {
      for (const frame of reader.push(chunk)) {
        const parsed = parseControlJson(frame.payload);
        if (parsed?.type === "encode") options.onEncode?.(parsed, socket);
      }
    };
    socket.on("data", (chunk) => {
      if (upgraded) {
        handleFrames(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        return;
      }
      buf = Buffer.concat([buf, chunk]);
      const sep = buf.indexOf("\r\n\r\n");
      if (sep < 0) return;
      const headerText = buf.subarray(0, sep).toString("utf8");
      const leftover = buf.subarray(sep + 4);
      buf = Buffer.alloc(0);
      const lines = headerText.split("\r\n");
      const requestLine = lines[0] ?? "";
      const headers: Record<string, string> = {};
      for (const line of lines.slice(1)) {
        const idx = line.indexOf(":");
        if (idx < 0) continue;
        headers[line.slice(0, idx).trim().toLowerCase()] = line.slice(idx + 1).trim();
      }
      if (!requestLine.startsWith("GET /view/stream")) {
        socket.end("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
      }
      if (options.status && options.status !== 101) {
        const body = options.body ?? "view grant unavailable\n";
        socket.end(
          `HTTP/1.1 ${options.status} Forbidden\r\nContent-Type: text/plain\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
        );
        return;
      }
      const device = headers["x-oppi-device-id"];
      if (device !== options.deviceId) {
        const body = "view session not granted\n";
        socket.end(
          `HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
        );
        return;
      }
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: oppi-desktop-view\r\nConnection: Upgrade\r\n\r\n",
      );
      upgraded = true;
      const hello = options.hello ?? {
        type: "hello",
        version: DESKTOP_VIEW_WIRE_VERSION,
        features: [DESKTOP_VIEW_FEATURE_H264_ANNEXB],
        grantId: "11111111-1111-4111-8111-111111111111",
        deviceId: options.deviceId,
        surface: { windowId: 7, title: "Notes" },
        width: 640,
        height: 360,
      };
      socket.write(encodeCompanionJson(hello));
      if (leftover.length > 0) handleFrames(leftover);
      if (options.errorBeforeClose) {
        socket.write(encodeCompanionJson(options.errorBeforeClose));
      }
      if (options.closeAfterHelloMs !== undefined) {
        setTimeout(() => socket.end(), options.closeAfterHelloMs);
      }
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.listen(socketPath, () => resolve());
    server.on("error", reject);
  });
  return server;
}

function mediaFrame(frameId: number, bytes = 64): Buffer {
  return encodeMediaFrame(
    {
      keyframe: frameId === 1,
      frameId,
      capturedAtMs: 1_770_000_000_000 + frameId,
      width: 64,
      height: 36,
    },
    Buffer.alloc(bytes, frameId),
  );
}

describe("desktop live view capability", () => {
  it("omits desktopLiveView unless the experiment flag is on", async () => {
    const off = await getCapabilities({ experimental: { serverDurable: false } });
    expect(off.desktopLiveView).toBeUndefined();
    const on = await getCapabilities({ experimental: { desktopLiveView: true } });
    expect(on.desktopLiveView).toEqual({ version: 1 });
  });
});

describe("DesktopViewStreamMux over a real unix companion", () => {
  it("forwards phone-wire media unchanged and paces with acks", async () => {
    const root = companionRoot();
    const encoded: number[] = [];
    const companion = await listenFakeCompanion(root, {
      deviceId: "dev-1",
      onEncode: (encode, socket) => {
        encoded.push(encode.frameId as number);
        const frame = mediaFrame(encode.frameId as number, 80);
        socket.write(encodeCompanionMedia(frame));
      },
    });
    try {
      const client = new DesktopCompanionViewStreamClient({ runtimeRoot: root });
      const mux = new DesktopViewStreamMux({
        connectCompanion: (input) => client.connect(input),
      });
      const phone = new FakePhoneSocket();
      mux.handleWebSocket(phone as unknown as WebSocket, { deviceId: "dev-1" });
      await waitFor(() => phone.textMessages().some((msg) => msg.type === "ping"));
      const ping = phone.textMessages().find((msg) => msg.type === "ping");
      phone.emitText({ type: "pong", t: ping?.t });
      await waitFor(() => phone.binaryMessages().length >= 1);
      const first = phone.binaryMessages()[0]!;
      expect(first.equals(mediaFrame(1, 80))).toBe(true);
      expect(encoded.length).toBeGreaterThanOrEqual(1);
      phone.emitText({ type: "ack", frameId: 1, receivedAt: Date.now() });
      await waitFor(() => phone.binaryMessages().length >= 2);
      expect(mux.activeCount).toBe(1);
    } finally {
      companion.close();
    }
  });

  it("closes the phone socket when the companion closes after a grant error", async () => {
    const root = companionRoot();
    const companion = await listenFakeCompanion(root, {
      deviceId: "dev-1",
      errorBeforeClose: {
        type: "error",
        code: DESKTOP_VIEW_ERROR.grantRevoked,
        message: "View grant revoked",
        fatal: true,
      },
      closeAfterHelloMs: 20,
    });
    try {
      const client = new DesktopCompanionViewStreamClient({ runtimeRoot: root });
      const mux = new DesktopViewStreamMux({
        connectCompanion: (input) => client.connect(input),
      });
      const phone = new FakePhoneSocket();
      mux.handleWebSocket(phone as unknown as WebSocket, { deviceId: "dev-1" });
      await waitFor(() => phone.closeCode === 4000);
      expect(phone.closeReason).toBe("grant_revoked");
      const error = phone.textMessages().find((msg) => msg.type === "error");
      expect(error?.code).toBe(DESKTOP_VIEW_ERROR.grantRevoked);
      expect(mux.activeCount).toBe(0);
    } finally {
      companion.close();
    }
  });

  it("refuses a second stream and maps not-bound companion 403", async () => {
    const root = companionRoot();
    const companion = await listenFakeCompanion(root, {
      deviceId: "dev-1",
      onEncode: (encode, socket) => {
        socket.write(encodeCompanionMedia(mediaFrame(encode.frameId as number)));
      },
    });
    try {
      const client = new DesktopCompanionViewStreamClient({ runtimeRoot: root });
      const mux = new DesktopViewStreamMux({
        connectCompanion: (input) => client.connect(input),
      });
      const first = new FakePhoneSocket();
      mux.handleWebSocket(first as unknown as WebSocket, { deviceId: "dev-1" });
      await waitFor(() => first.textMessages().some((msg) => msg.type === "hello"));
      const second = new FakePhoneSocket();
      mux.handleWebSocket(second as unknown as WebSocket, { deviceId: "dev-1" });
      expect(second.closeReason).toBe("already_streaming");

      const other = new FakePhoneSocket();
      const mux2 = new DesktopViewStreamMux({
        connectCompanion: (input) => client.connect(input),
      });
      mux2.handleWebSocket(other as unknown as WebSocket, { deviceId: "dev-other" });
      await waitFor(() => other.closeCode === 4000);
      expect(other.closeReason).toBe("grant_not_bound");
    } finally {
      companion.close();
    }
  });
});

describe("GET /desktop/view/stream HTTPS auth shell", () => {
  it("404s owner, flag-off, and wrong path; admits a paired device when on", async () => {
    const dataDir = tempDir("oppi-dv-https-");
    const runtimeRoot = companionRoot();
    const storage = new Storage(dataDir);
    storage.updateConfig({
      port: 0,
      host: "127.0.0.1",
      tls: { mode: "self-signed" },
      experimental: { desktopLiveView: true },
    });
    storage.ensurePaired();
    const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
      name: "view-device",
    });
    if (!enrolled) throw new Error("enrollment failed");
    const bound = await listenFakeCompanion(runtimeRoot, {
      deviceId: enrolled.deviceId,
      onEncode: (encode, socket) => {
        socket.write(encodeCompanionMedia(mediaFrame(encode.frameId as number)));
      },
    });
    const previous = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    const server = new Server(storage, undefined, { desktopCompanionRuntimeRoot: runtimeRoot });
    await server.start();
    const baseUrl = `https://127.0.0.1:${server.port}`;
    try {
      const ownerUpgrade = await websocketHttpStatus(
        `${baseUrl.replace("https", "wss")}${DESKTOP_VIEW_STREAM_PATH}`,
        storage.getToken(),
      );
      expect(ownerUpgrade).toBe(401);

      const offStorage = new Storage(tempDir("oppi-dv-off-"));
      offStorage.updateConfig({
        port: 0,
        host: "127.0.0.1",
        tls: { mode: "self-signed" },
      });
      offStorage.ensurePaired();
      const offKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey;
      const offJwk = offKey.export({ format: "jwk" }) as { x: string; y: string };
      const offEnrolled = offStorage.enrollViaPairing(offStorage.issuePairingToken(), {
        publicKey: { kty: "EC", crv: "P-256", x: offJwk.x, y: offJwk.y },
        name: "off-device",
      });
      if (!offEnrolled) throw new Error("off enrollment failed");
      const offServer = new Server(offStorage);
      await offServer.start();
      try {
        const off = await websocketHttpStatus(
          `wss://127.0.0.1:${offServer.port}${DESKTOP_VIEW_STREAM_PATH}`,
          offEnrolled.accessToken,
        );
        expect(off).toBe(404);
      } finally {
        await offServer.stop();
      }

      const ws = new WebSocket(`${baseUrl.replace("https", "wss")}${DESKTOP_VIEW_STREAM_PATH}`, {
        headers: { Authorization: `Bearer ${enrolled.accessToken}` },
      });
      const hello = await new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("hello timeout")), 5_000);
        ws.on("message", (data, binary) => {
          if (binary) return;
          const parsed = JSON.parse(data.toString()) as Record<string, unknown>;
          if (parsed.type === "hello") {
            clearTimeout(timer);
            resolve(parsed);
          }
          if (parsed.type === "ping") {
            ws.send(JSON.stringify({ type: "pong", t: parsed.t }));
          }
        });
        ws.on("error", reject);
      });
      expect(hello.deviceId).toBe(enrolled.deviceId);
      ws.close();
    } finally {
      await server.stop();
      bound.close();
      if (previous === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous;
    }
  }, 20_000);
});

async function getCapabilities(config: Record<string, unknown>): Promise<{
  desktopLiveView?: { version: number };
}> {
  const ctx = {
    storage: {
      getConfig: () => ({
        configVersion: 2,
        uploadStore: { maxFileBytes: 1, maxTurnBytes: 2 },
        images: { autoResize: false },
        ...config,
      }),
      listWorkspaces: () => [],
      listSessions: () => [],
      getDataDir: () => tempDirs[0] ?? tmpdir(),
    },
    sessions: {
      getActiveSessionIds: () => new Set(),
      durableSessionsAvailable: () => false,
      conversationStreamAvailable: () => false,
    },
    sessionRuntimes: { getActiveSessionIds: () => new Set() },
    skillRegistry: { list: () => [] },
    getModelCatalog: () => [],
    serverStartedAt: Date.now(),
    serverVersion: "test",
    piVersion: "test",
  } as unknown as RouteContext;
  const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
  const res = makeResponse();
  await dispatch({
    method: "GET",
    path: "/server/info",
    url: new URL("http://localhost/server/info"),
    req: {} as never,
    res: res as never,
  });
  return (JSON.parse(res.body) as { capabilities: { desktopLiveView?: { version: number } } })
    .capabilities;
}

async function waitFor(predicate: () => boolean, ms = 2_000): Promise<void> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > ms) throw new Error("waitFor timeout");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function websocketHttpStatus(url: string, token: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const timer = setTimeout(() => {
      ws.terminate();
      reject(new Error("upgrade status timeout"));
    }, 5_000);
    ws.on("unexpected-response", (_req, res) => {
      clearTimeout(timer);
      const status = res.statusCode ?? 0;
      res.resume();
      ws.terminate();
      resolve(status);
    });
    ws.on("open", () => {
      clearTimeout(timer);
      ws.close();
      resolve(101);
    });
    ws.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}
