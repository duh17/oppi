import { randomUUID } from "node:crypto";
import { existsSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { createServer, type Server as NetServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";

import { afterEach, describe, expect, it } from "vitest";

import { desktopCompanionOwnerSocketPath } from "../src/desktop-companion-still-client.js";
import {
  DesktopCompanionViewSessionClient,
  DesktopCompanionViewSessionError,
  type DesktopCompanionViewSessionErrorCode,
} from "../src/desktop-companion-view-session-client.js";

const VIEW_CAPTION = "View session\u2014not live delivery";
const PNG_1X1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);

describe("desktop companion owner-socket view session client", () => {
  const tempDirs: string[] = [];
  const companions: FakeCompanion[] = [];

  afterEach(async () => {
    await Promise.all(companions.splice(0).map((companion) => companion.close()));
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not create a socket at construction", () => {
    const runtimeRoot = makeTempDir();
    const client = new DesktopCompanionViewSessionClient({ runtimeRoot });
    expect(client.socketPath).toBe(join(runtimeRoot, "run", "companion.sock"));
    expect(existsSync(client.socketPath)).toBe(false);
  });

  it("binds by forwarding device headers and returns JSON metadata", async () => {
    const companion = await listenCompanion();
    companion.grant = makeGrant();
    const client = new DesktopCompanionViewSessionClient({ runtimeRoot: companion.runtimeRoot });

    const session = await client.fetchViewSession({
      deviceId: "phone-1",
      deviceName: "Chen iPhone",
    });

    expect(session.capability).toBe("view");
    expect(session.deviceId).toBe("phone-1");
    expect(session.caption).toBe(VIEW_CAPTION);
    expect(session.grantId).toBe(companion.grant?.grantId);
    expect(companion.requests).toEqual([
      expect.objectContaining({
        method: "GET",
        url: "/view/session",
        deviceId: "phone-1",
        deviceName: "Chen iPhone",
      }),
    ]);

    companion.grant = makeGrant();
    await client.fetchViewSession({
      deviceId: "phone-1",
      deviceName: "Chen \u{1F4F1}",
    });
    expect(companion.requests[1]).toEqual(
      expect.objectContaining({
        deviceId: "phone-1",
        deviceName: undefined,
      }),
    );

    companion.grant = makeGrant();
    const cafe = await client.fetchViewSession({
      deviceId: "phone-1",
      deviceName: "Caf\u00e9",
    });
    expect(cafe.deviceId).toBe("phone-1");
    expect(companion.requests[2]).toEqual(
      expect.objectContaining({
        deviceId: "phone-1",
        deviceName: undefined,
      }),
    );
  });

  it("maps missing device id, unavailable, and not-bound", async () => {
    const companion = await listenCompanion();
    const client = new DesktopCompanionViewSessionClient({ runtimeRoot: companion.runtimeRoot });

    await expectError(client.fetchViewSession({ deviceId: "   " }), "missing_device_id");
    expect(companion.requests).toEqual([]);

    companion.grant = undefined;
    await expectError(client.fetchViewSession({ deviceId: "phone-1" }), "unavailable");

    companion.grant = makeGrant({ deviceId: "phone-1" });
    await expectError(client.fetchViewSession({ deviceId: "phone-2" }), "not_bound");
    expect(companion.requests.every((request) => request.deviceId !== undefined)).toBe(true);
  });

  it("rejects PNG bodies without treating them as a still", async () => {
    const companion = await listenCompanion();
    companion.overrideBody = PNG_1X1;
    companion.overrideContentType = "image/png";
    companion.grant = makeGrant({ deviceId: "phone-1" });
    const client = new DesktopCompanionViewSessionClient({ runtimeRoot: companion.runtimeRoot });

    await expectError(client.fetchViewSession({ deviceId: "phone-1" }), "malformed_session");
  });

  it("keeps the sibling fence in source", () => {
    const source = readFileSync(
      fileURLToPath(new URL("../src/desktop-companion-view-session-client.ts", import.meta.url)),
      "utf8",
    );
    expect(source).toContain("/view/session");
    expect(source).toContain("X-Oppi-Device-ID");
    expect(source).toContain("application/json");
    expect(source).not.toContain("image/png");
    expect(source).not.toContain("inspectPng");
    expect(source).not.toContain("captureOnce");
    expect(source).not.toContain("Authorization");
    expect(source).not.toContain("oppi.sock");
  });

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dc-view-"));
    tempDirs.push(dir);
    return dir;
  }

  async function listenCompanion(): Promise<FakeCompanion> {
    const runtimeRoot = makeTempDir();
    const companion = new FakeCompanion(runtimeRoot);
    companions.push(companion);
    await companion.listen();
    return companion;
  }
});

class FakeCompanion {
  requests: Array<{
    method?: string;
    url?: string;
    deviceId?: string;
    deviceName?: string;
  }> = [];
  grant:
    | {
        grantId: string;
        deviceId?: string;
        expiresAt: string;
      }
    | undefined;
  overrideBody: Buffer | undefined;
  overrideContentType: string | undefined;
  readonly socketPath: string;
  private server: NetServer | undefined;
  private readonly sockets = new Set<Socket>();

  constructor(readonly runtimeRoot: string) {
    this.socketPath = desktopCompanionOwnerSocketPath(runtimeRoot);
  }

  async listen(): Promise<void> {
    mkdirSync(dirname(this.socketPath), { recursive: true, mode: 0o700 });
    const server = createServer((socket) => {
      this.sockets.add(socket);
      socket.on("close", () => this.sockets.delete(socket));
      socket.on("error", () => {});
      void this.handle(socket);
    });
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => reject(error);
      server.once("error", onError);
      server.listen(this.socketPath, () => {
        server.off("error", onError);
        resolve();
      });
    });
  }

  async close(): Promise<void> {
    for (const socket of this.sockets) socket.destroy();
    this.sockets.clear();
    const server = this.server;
    this.server = undefined;
    if (!server?.listening) return;
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  }

  private async handle(socket: Socket): Promise<void> {
    const request = await readRequest(socket);
    if (!request) {
      socket.end();
      return;
    }
    this.requests.push({
      method: request.method,
      url: request.url,
      deviceId: request.headers["x-oppi-device-id"],
      deviceName: request.headers["x-oppi-device-name"],
    });

    if (request.method !== "GET" || request.url !== "/view/session") {
      writeHttp(socket, 404, "Not Found", { "Content-Type": "text/plain; charset=utf-8" }, Buffer.from("not found\n"));
      socket.end();
      return;
    }

    const deviceId = request.headers["x-oppi-device-id"]?.trim();
    if (!deviceId) {
      writeHttp(
        socket,
        400,
        "Bad Request",
        { "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("missing device id\n"),
      );
      socket.end();
      return;
    }

    if (!this.grant) {
      writeHttp(
        socket,
        403,
        "Forbidden",
        { "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("view grant unavailable\n"),
      );
      socket.end();
      return;
    }

    if (this.grant.deviceId && this.grant.deviceId !== deviceId) {
      writeHttp(
        socket,
        403,
        "Forbidden",
        { "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("view session not granted\n"),
      );
      socket.end();
      return;
    }

    this.grant = { ...this.grant, deviceId };
    if (this.overrideBody) {
      writeHttp(
        socket,
        200,
        "OK",
        {
          "Content-Type": this.overrideContentType ?? "application/json",
          "Cache-Control": "no-store",
        },
        this.overrideBody,
      );
      socket.end();
      return;
    }

    const body = Buffer.from(
      JSON.stringify({
        grantId: this.grant.grantId,
        capability: "view",
        deviceId,
        expiresAt: this.grant.expiresAt,
        caption: VIEW_CAPTION,
      }),
      "utf8",
    );
    writeHttp(
      socket,
      200,
      "OK",
      {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
      body,
    );
    socket.end();
  }
}

function makeGrant(
  overrides: { grantId?: string; deviceId?: string; expiresAt?: string } = {},
): {
  grantId: string;
  deviceId?: string;
  expiresAt: string;
} {
  return {
    grantId: overrides.grantId ?? randomUUID(),
    deviceId: overrides.deviceId,
    expiresAt: overrides.expiresAt ?? "2026-09-12T03:15:40.123Z",
  };
}

function writeHttp(
  socket: Socket,
  status: number,
  reason: string,
  headers: Record<string, string>,
  body: Buffer,
): void {
  const all = { ...headers, "Content-Length": String(body.length), Connection: "close" };
  let head = `HTTP/1.1 ${status} ${reason}\r\n`;
  for (const key of Object.keys(all).sort()) {
    head += `${key}: ${all[key] ?? ""}\r\n`;
  }
  head += "\r\n";
  socket.write(Buffer.concat([Buffer.from(head, "utf8"), body]));
}

async function readRequest(
  socket: Socket,
): Promise<{ method: string; url: string; headers: Record<string, string> } | undefined> {
  const headerBytes = await readUntil(socket, Buffer.from("\r\n\r\n"), 65_536);
  if (!headerBytes) return undefined;
  const lines = headerBytes.toString("utf8").split("\r\n");
  const requestLine = lines[0];
  if (!requestLine) return undefined;
  const parts = requestLine.split(" ");
  if (parts.length < 2) return undefined;
  const headers: Record<string, string> = {};
  for (const line of lines.slice(1)) {
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
  }
  return { method: parts[0] ?? "", url: parts[1] ?? "", headers };
}

function readUntil(socket: Socket, separator: Buffer, maxBytes: number): Promise<Buffer | undefined> {
  return new Promise((resolve) => {
    let buffer = Buffer.alloc(0);
    const onData = (chunk: Buffer): void => {
      buffer = Buffer.concat([buffer, chunk]);
      const index = buffer.indexOf(separator);
      if (index >= 0) {
        cleanup();
        resolve(buffer.subarray(0, index));
        return;
      }
      if (buffer.length > maxBytes) {
        cleanup();
        resolve(undefined);
      }
    };
    const onDone = (): void => {
      cleanup();
      resolve(undefined);
    };
    const cleanup = (): void => {
      socket.off("data", onData);
      socket.off("end", onDone);
      socket.off("error", onDone);
      socket.off("close", onDone);
    };
    socket.on("data", onData);
    socket.once("end", onDone);
    socket.once("error", onDone);
    socket.once("close", onDone);
  });
}

async function expectError(
  promise: Promise<unknown>,
  code: DesktopCompanionViewSessionErrorCode,
): Promise<void> {
  const error = await promise.then(
    (value) => value,
    (caught: unknown) => caught,
  );
  expect(error).toBeInstanceOf(DesktopCompanionViewSessionError);
  expect((error as DesktopCompanionViewSessionError).code).toBe(code);
}
