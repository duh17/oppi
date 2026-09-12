import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { createServer, type Server as NetServer, type Socket } from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, describe, expect, it } from "vitest";

import {
  DesktopCompanionStillClient,
  DesktopCompanionStillError,
  desktopCompanionOwnerSocketPath,
  type DesktopCompanionStillErrorCode,
} from "../src/desktop-companion-still-client.js";

const STILL_CAPTION = "Still\u2014not live";
const PNG_1X1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);

describe("desktop companion owner-socket still client", () => {
  const tempDirs: string[] = [];
  const companions: FakeCompanion[] = [];

  afterEach(async () => {
    await Promise.all(companions.splice(0).map((companion) => companion.close()));
    for (const dir of tempDirs.splice(0)) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  describe("socket path", () => {
    it("resolves companion.sock under Application Support and never oppi.sock", () => {
      const uid = process.getuid?.() ?? "user";
      const preferred = join(
        homedir(),
        "Library",
        "Application Support",
        "OppiDesktopCompanion",
        "run",
        "companion.sock",
      );
      const fallback = join("/tmp", `oppi-desktop-${uid}`, "companion.sock");
      const socketPath = desktopCompanionOwnerSocketPath();

      expect(socketPath === preferred || socketPath === fallback).toBe(true);
      expect(socketPath.endsWith("/companion.sock")).toBe(true);
      expect(socketPath.includes("oppi.sock")).toBe(false);
      expect(Buffer.byteLength(socketPath)).toBeLessThanOrEqual(100);

      const runtimeRoot = makeTempDir();
      const fromRoot = desktopCompanionOwnerSocketPath(runtimeRoot);
      expect(fromRoot).toBe(join(runtimeRoot, "run", "companion.sock"));
      expect(fromRoot.endsWith("companion.sock")).toBe(true);
      expect(fromRoot.endsWith("oppi.sock")).toBe(false);
    });

    it("falls back to /tmp/oppi-desktop-<uid>/companion.sock when the preferred path is too long", () => {
      const uid = process.getuid?.() ?? "user";
      const longRoot = join("/tmp", "a".repeat(120));
      expect(desktopCompanionOwnerSocketPath(longRoot)).toBe(
        join("/tmp", `oppi-desktop-${uid}`, "companion.sock"),
      );
    });
  });

  it("does not start the companion or create a socket at construction", () => {
    const runtimeRoot = makeTempDir();
    const client = new DesktopCompanionStillClient({ runtimeRoot });
    expect(client.socketPath).toBe(join(runtimeRoot, "run", "companion.sock"));
    expect(existsSync(client.socketPath)).toBe(false);
    expect(existsSync(join(runtimeRoot, "run"))).toBe(false);
  });

  it("fetches the shared still for a matching capture ID", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });

    const fetched = await client.fetchStill(still.captureId);

    expect(fetched.captureId.toLowerCase()).toBe(still.captureId.toLowerCase());
    expect(fetched.surface).toEqual({ windowId: 91, title: "Notes" });
    expect(fetched.capturedAt).toBe(still.capturedAt);
    expect(fetched.width).toBe(1);
    expect(fetched.height).toBe(1);
    expect(fetched.caption).toBe(STILL_CAPTION);
    expect(fetched.png.equals(PNG_1X1)).toBe(true);
    expect(companion.captureCount).toBe(0);
    expect(companion.requests).toEqual([
      expect.objectContaining({
        method: "GET",
        url: `/still/${still.captureId}`,
        authorization: undefined,
      }),
    ]);
    expect(pngFiles(companion.runtimeRoot)).toEqual([]);
  });

  it("rejects default-off and revoked sharing with 403", async () => {
    const companion = await listenCompanion();
    const still = companion.captureWithoutSharing();
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });

    await expectStillError(client.fetchStill(still.captureId), "sharing_disabled");
    expect(companion.captureCount).toBe(0);

    companion.share(still);
    await expect(client.fetchStill(still.captureId)).resolves.toMatchObject({
      captureId: still.captureId,
    });

    companion.revoke();
    await expectStillError(client.fetchStill(still.captureId), "sharing_disabled");
    expect(companion.captureCount).toBe(0);
    expect(companion.requests.every((request) => request.method === "GET")).toBe(true);
  });

  it("rejects a stale capture ID with 404", async () => {
    const companion = await listenCompanion();
    const first = companion.share({ captureId: randomUUID(), windowId: 92, title: "Code" });
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });
    await expect(client.fetchStill(first.captureId)).resolves.toMatchObject({
      captureId: first.captureId,
    });

    const second = companion.share({ captureId: randomUUID(), windowId: 93, title: "Preview" });
    await expectStillError(client.fetchStill(first.captureId), "stale_capture");
    await expect(client.fetchStill(second.captureId)).resolves.toMatchObject({
      captureId: second.captureId,
      surface: { windowId: 93, title: "Preview" },
    });
    expect(companion.captureCount).toBe(0);
  });

  it("rejects a malformed still", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });

    companion.override = (_request, socket) => {
      writeStill(socket, still, { caption: "Live preview" });
      return true;
    };
    await expectStillError(client.fetchStill(still.captureId), "malformed_still");

    companion.override = (_request, socket) => {
      writeStill(socket, still, { png: Buffer.from("not-a-png") });
      return true;
    };
    await expectStillError(client.fetchStill(still.captureId), "malformed_still");

    companion.override = (_request, socket) => {
      writeStill(socket, still, { cacheControl: "public" });
      return true;
    };
    await expectStillError(client.fetchStill(still.captureId), "malformed_still");

    companion.override = (_request, socket) => {
      writeStill(socket, still, { width: 9 });
      return true;
    };
    await expectStillError(client.fetchStill(still.captureId), "malformed_still");
    expect(companion.captureCount).toBe(0);
  });

  it("rejects an oversized still without waiting for the body", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    companion.override = (_request, socket) => {
      writeHttp(socket, 200, "OK", stillHeaders(still, { contentLength: 8_000_000 }));
      return true;
    };
    const client = new DesktopCompanionStillClient({
      runtimeRoot: companion.runtimeRoot,
      maxBytes: 64,
      timeoutMs: 400,
    });

    await expectStillError(client.fetchStill(still.captureId), "oversized_still");
    expect(companion.captureCount).toBe(0);
  });

  it("rejects a truncated still", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    companion.override = (_request, socket) => {
      writeHttp(
        socket,
        200,
        "OK",
        stillHeaders(still, { contentLength: PNG_1X1.length }),
        PNG_1X1.subarray(0, 24),
        { setContentLengthFromBody: false },
      );
      socket.end();
      return true;
    };
    const client = new DesktopCompanionStillClient({
      runtimeRoot: companion.runtimeRoot,
      timeoutMs: 400,
    });

    await expectStillError(client.fetchStill(still.captureId), "truncated_still");
    expect(companion.captureCount).toBe(0);
  });

  it("cancels an in-flight fetch via AbortSignal", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    let resolveHold!: () => void;
    const hold = new Promise<void>((resolve) => {
      resolveHold = resolve;
    });
    companion.override = async (_request, socket) => {
      await hold;
      if (!socket.destroyed) writeStill(socket, still);
      return true;
    };
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });
    const controller = new AbortController();
    const pending = client.fetchStill(still.captureId, { signal: controller.signal });
    await companion.waitForRequest();
    controller.abort();

    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    resolveHold();
    expect(companion.captureCount).toBe(0);
  });

  it("maps a down companion to unavailable", async () => {
    const runtimeRoot = makeTempDir();
    const client = new DesktopCompanionStillClient({ runtimeRoot, timeoutMs: 200 });
    await expectStillError(client.fetchStill(randomUUID()), "companion_unavailable");
    expect(existsSync(client.socketPath)).toBe(false);
  });

  it("rejects an invalid capture ID before connecting", async () => {
    const companion = await listenCompanion();
    companion.share();
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });

    await expectStillError(client.fetchStill("not-a-uuid"), "invalid_capture_id");
    await expectStillError(client.fetchStill("../oppi.sock"), "invalid_capture_id");
    await expectStillError(
      client.fetchStill(`http://127.0.0.1/still/${randomUUID()}`),
      "invalid_capture_id",
    );
    expect(companion.requests).toEqual([]);
    expect(companion.captureCount).toBe(0);
  });

  it("bounds concurrent companion fetches", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    let resolveHold!: () => void;
    const hold = new Promise<void>((resolve) => {
      resolveHold = resolve;
    });
    companion.override = async (_request, socket) => {
      await hold;
      writeStill(socket, still);
      return true;
    };
    const client = new DesktopCompanionStillClient({
      runtimeRoot: companion.runtimeRoot,
      maxConcurrent: 1,
      timeoutMs: 1_000,
    });
    const pending = client.fetchStill(still.captureId);
    await companion.waitForRequest();

    await expectStillError(client.fetchStill(still.captureId), "companion_unavailable");
    expect(companion.requests).toHaveLength(1);

    resolveHold();
    await expect(pending).resolves.toMatchObject({ captureId: still.captureId });
    expect(companion.captureCount).toBe(0);
  });

  it("GET /still does not recapture", async () => {
    const companion = await listenCompanion();
    const still = companion.share();
    companion.captureCount = 1;
    const client = new DesktopCompanionStillClient({ runtimeRoot: companion.runtimeRoot });

    await client.fetchStill(still.captureId);
    await client.fetchStill(still.captureId);

    expect(companion.captureCount).toBe(1);
    expect(companion.requests.map((request) => request.method)).toEqual(["GET", "GET"]);
    expect(companion.requests.every((request) => request.url === `/still/${still.captureId}`)).toBe(
      true,
    );
  });

  it("keeps the owner-socket fence in source", () => {
    const source = readFileSync(
      fileURLToPath(new URL("../src/desktop-companion-still-client.ts", import.meta.url)),
      "utf8",
    );
    expect(source).toContain("companion.sock");
    expect(source).toContain("agent: false");
    expect(source).toContain('method: "GET"');
    expect(source).toContain("socketPath");
    expect(source).not.toContain("oppi.sock");
    expect(source).not.toContain("Authorization");
    expect(source).not.toContain("Bearer");
    expect(source).not.toContain("https://");
    expect(source).not.toContain("writeFile");
    expect(source).not.toContain("captureOnce");
    expect(source).not.toContain("ScreenCaptureKit");
    expect(source).not.toContain("spawn");
  });

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "oppi-dc-still-"));
    tempDirs.push(dir);
    return dir;
  }

  async function listenCompanion(): Promise<FakeCompanion> {
    const runtimeRoot = makeTempDir();
    const companion = new FakeCompanion(runtimeRoot);
    companions.push(companion);
    await companion.listen();
    expect(statSync(companion.socketPath).isSocket()).toBe(true);
    return companion;
  }
});

class FakeCompanion {
  captureCount = 0;
  requests: Array<{ method?: string; url?: string; authorization?: string }> = [];
  shared: SharedStill | undefined;
  sharingEnabled = false;
  override?: (request: ParsedRequest, socket: Socket) => boolean | Promise<boolean>;
  readonly socketPath: string;

  private server: NetServer | undefined;
  private readonly sockets = new Set<Socket>();
  private requestWaiters: Array<() => void> = [];

  constructor(readonly runtimeRoot: string) {
    this.socketPath = desktopCompanionOwnerSocketPath(runtimeRoot);
  }

  captureWithoutSharing(overrides: Partial<SharedStill> = {}): SharedStill {
    const still = makeStill(overrides);
    this.shared = still;
    this.sharingEnabled = false;
    return still;
  }

  share(overrides: Partial<SharedStill> = {}): SharedStill {
    const still =
      overrides.captureId || !this.shared ? makeStill(overrides) : { ...this.shared, ...overrides };
    this.shared = still;
    this.sharingEnabled = true;
    return still;
  }

  revoke(): void {
    this.sharingEnabled = false;
  }

  waitForRequest(): Promise<void> {
    if (this.requests.length > 0) return Promise.resolve();
    return new Promise<void>((resolve) => this.requestWaiters.push(resolve));
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
      authorization: request.headers.authorization,
    });
    for (const waiter of this.requestWaiters.splice(0)) waiter();

    if (request.method === "POST" && request.url === "/capture") {
      this.captureCount += 1;
      writeHttp(socket, 204, "No Content", {}, Buffer.alloc(0));
      socket.end();
      return;
    }

    if (this.override) {
      const handled = await this.override(request, socket);
      if (handled) return;
    }

    if (request.method !== "GET") {
      writeHttp(
        socket,
        405,
        "Method Not Allowed",
        { Allow: "GET", "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("method not allowed\n"),
      );
      socket.end();
      return;
    }

    const captureId = stillCaptureId(request.url);
    if (!captureId) {
      writeHttp(
        socket,
        404,
        "Not Found",
        { "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("not found\n"),
      );
      socket.end();
      return;
    }

    if (!this.sharingEnabled || !this.shared) {
      writeHttp(
        socket,
        403,
        "Forbidden",
        { "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("sharing disabled\n"),
      );
      socket.end();
      return;
    }

    if (this.shared.captureId.toLowerCase() !== captureId.toLowerCase()) {
      writeHttp(
        socket,
        404,
        "Not Found",
        { "Content-Type": "text/plain; charset=utf-8" },
        Buffer.from("stale capture\n"),
      );
      socket.end();
      return;
    }

    writeStill(socket, this.shared);
    socket.end();
  }
}

type SharedStill = {
  captureId: string;
  windowId: number;
  title: string;
  capturedAt: string;
  width: number;
  height: number;
  caption: string;
  png: Buffer;
};

type ParsedRequest = {
  method: string;
  url: string;
  headers: Record<string, string>;
};

function makeStill(overrides: Partial<SharedStill> = {}): SharedStill {
  return {
    captureId: randomUUID(),
    windowId: 91,
    title: "Notes",
    capturedAt: "2026-09-12T03:00:40.123Z",
    width: 1,
    height: 1,
    caption: STILL_CAPTION,
    png: PNG_1X1,
    ...overrides,
  };
}

function writeStill(
  socket: Socket,
  still: SharedStill,
  overrides: {
    caption?: string;
    png?: Buffer;
    cacheControl?: string;
    width?: number;
    contentLength?: number;
  } = {},
): void {
  const png = overrides.png ?? still.png;
  writeHttp(
    socket,
    200,
    "OK",
    stillHeaders(still, { ...overrides, contentLength: png.length }),
    png,
  );
  socket.end();
}

function stillHeaders(
  still: SharedStill,
  overrides: {
    caption?: string;
    cacheControl?: string;
    width?: number;
    contentLength?: number;
  } = {},
): Record<string, string> {
  return {
    "Content-Type": "image/png",
    "Content-Length": String(overrides.contentLength ?? still.png.length),
    "Cache-Control": overrides.cacheControl ?? "no-store",
    "X-Oppi-Capture-ID": still.captureId,
    "X-Oppi-Surface-Window-ID": String(still.windowId),
    "X-Oppi-Surface-Title": still.title,
    "X-Oppi-Captured-At": still.capturedAt,
    "X-Oppi-Width": String(overrides.width ?? still.width),
    "X-Oppi-Height": String(still.height),
    "X-Oppi-Caption": overrides.caption ?? still.caption,
  };
}

function writeHttp(
  socket: Socket,
  status: number,
  reason: string,
  headers: Record<string, string>,
  body: Buffer = Buffer.alloc(0),
  options: { setContentLengthFromBody?: boolean } = {},
): void {
  if (socket.destroyed) return;
  const all = { ...headers };
  if (options.setContentLengthFromBody !== false && all["Content-Length"] === undefined) {
    all["Content-Length"] = String(body.length);
  }
  all.Connection = all.Connection ?? "close";
  let head = `HTTP/1.1 ${status} ${reason}\r\n`;
  for (const key of Object.keys(all).sort()) {
    head += `${key}: ${all[key] ?? ""}\r\n`;
  }
  head += "\r\n";
  socket.write(Buffer.concat([Buffer.from(head, "utf8"), body]));
}

function stillCaptureId(url: string): string | undefined {
  const match = /^\/still\/([^/?]+)$/.exec(url);
  if (!match) return undefined;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(match[1])) {
    return undefined;
  }
  return match[1];
}

function pngFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  const matches: string[] = [];
  const visit = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.name.toLowerCase().endsWith(".png")) matches.push(path);
    }
  };
  visit(root);
  return matches;
}

async function expectStillError(
  promise: Promise<unknown>,
  code: DesktopCompanionStillErrorCode,
): Promise<void> {
  const error = await promise.then(
    (value) => value,
    (caught: unknown) => caught,
  );
  expect(error).toBeInstanceOf(DesktopCompanionStillError);
  expect((error as DesktopCompanionStillError).code).toBe(code);
}

async function readRequest(socket: Socket): Promise<ParsedRequest | undefined> {
  const headerBytes = await readUntil(socket, Buffer.from("\r\n\r\n"), 65_536);
  if (!headerBytes) return undefined;
  const headerText = headerBytes.toString("utf8");
  const lines = headerText.split("\r\n");
  const requestLine = lines[0];
  if (!requestLine) return undefined;
  const parts = requestLine.split(" ");
  if (parts.length < 2) return undefined;
  const headers: Record<string, string> = {};
  for (const line of lines.slice(1)) {
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const name = line.slice(0, colon).trim().toLowerCase();
    headers[name] = line.slice(colon + 1).trim();
  }
  return { method: parts[0] ?? "", url: parts[1] ?? "", headers };
}

function readUntil(
  socket: Socket,
  separator: Buffer,
  maxBytes: number,
): Promise<Buffer | undefined> {
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
