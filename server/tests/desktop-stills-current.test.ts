import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import {
  DesktopCompanionStillError,
  type DesktopCompanionStill,
} from "../src/desktop-companion-still-client.js";
import { RouteHandler } from "../src/routes/index.js";
import type { RouteContext } from "../src/routes/types.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { makeRequest } from "./harness/route-test-helpers.js";

type RequestPrincipal =
  | { kind: "owner" }
  | { kind: "device"; deviceId: string; tokenClass: "at_"; expiresAt?: number };

const STILL_CAPTION = "Still\u2014not live";
const PNG_1X1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);

const devicePrincipal: RequestPrincipal = {
  kind: "device",
  deviceId: "dev-paired-1",
  tokenClass: "at_",
};

const ownerPrincipal: RequestPrincipal = { kind: "owner" };

describe("GET /desktop/stills/current", () => {
  it("returns the companion current still for a device at_ principal", async () => {
    const still = makeStill();
    const fetchCurrentStill = vi.fn(async () => still);
    const { statusCode, headers, body } = await dispatchCurrent({
      principal: devicePrincipal,
      fetchCurrentStill,
    });

    expect(statusCode).toBe(200);
    expect(headers["Content-Type"]).toBe("image/png");
    expect(headers["Cache-Control"]).toBe("no-store");
    expect(headers["X-Oppi-Capture-ID"]).toBe(still.captureId);
    expect(headers["X-Oppi-Surface-Window-ID"]).toBe("91");
    expect(headerUtf8(headers["X-Oppi-Surface-Title"])).toBe("Notes");
    expect(headers["X-Oppi-Captured-At"]).toBe(still.capturedAt);
    expect(headers["X-Oppi-Width"]).toBe("1");
    expect(headers["X-Oppi-Height"]).toBe("1");
    expect(headerUtf8(headers["X-Oppi-Caption"])).toBe(STILL_CAPTION);
    expect(body.equals(PNG_1X1)).toBe(true);
    expect(fetchCurrentStill).toHaveBeenCalledTimes(1);
  });

  it("maps remote-off to 403 and missing current to 404", async () => {
    const remoteOff = await dispatchCurrent({
      principal: devicePrincipal,
      fetchCurrentStill: async () => {
        throw new DesktopCompanionStillError(
          "Desktop still sharing is disabled",
          "sharing_disabled",
        );
      },
    });
    expect(remoteOff.statusCode).toBe(403);
    expect(remoteOff.body.toString("utf8")).toContain("disabled");

    const missing = await dispatchCurrent({
      principal: devicePrincipal,
      fetchCurrentStill: async () => {
        throw new DesktopCompanionStillError("Desktop still is not available", "stale_capture");
      },
    });
    expect(missing.statusCode).toBe(404);
  });

  it("does not fetch current for owner principals and missing principals", async () => {
    const fetchCurrentStill = vi.fn(async () => makeStill());

    const owner = await dispatchCurrent({ principal: ownerPrincipal, fetchCurrentStill });
    expect(owner.statusCode).toBe(404);
    expect(fetchCurrentStill).not.toHaveBeenCalled();

    const missing = await dispatchCurrent({ principal: undefined, fetchCurrentStill });
    expect(missing.statusCode).toBe(404);
    expect(fetchCurrentStill).not.toHaveBeenCalled();
  });

  it("maps companion down without recapturing", async () => {
    const fetchCurrentStill = vi.fn(async () => {
      throw new DesktopCompanionStillError(
        "Desktop companion is unavailable",
        "companion_unavailable",
      );
    });
    const response = await dispatchCurrent({ principal: devicePrincipal, fetchCurrentStill });
    expect(response.statusCode).toBe(502);
    expect(fetchCurrentStill).toHaveBeenCalledTimes(1);
  });

  it("never writes the still to disk or attachments", async () => {
    const source = readRouteSource();
    expect(source).toContain("/desktop/stills/current");
    expect(source).not.toContain("writeFile");
    expect(source).not.toContain("attachments");
    expect(source).not.toContain("createSessionAttachment");
    expect(source).not.toContain("captureOnce");
  });
});

describe("GET /desktop/stills/current HTTPS auth shell", () => {
  let dataDir: string;
  let storage: Storage;
  let server: Server;
  let baseUrl: string;
  let deviceToken: string;
  let originalTlsRejectUnauthorized: string | undefined;
  const fetchCurrentStill = vi.fn(async () => makeStill());

  beforeAll(async () => {
    originalTlsRejectUnauthorized = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    dataDir = mkdtempSync(join(tmpdir(), "oppi-desktop-stills-"));
    storage = new Storage(dataDir);
    storage.updateConfig({
      port: 0,
      host: "127.0.0.1",
      tls: { mode: "self-signed" },
    });
    storage.ensurePaired();
    const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
      name: "still-device",
    });
    if (!enrolled) throw new Error("enrollment failed");
    deviceToken = enrolled.accessToken;
    fetchCurrentStill.mockImplementation(async () => makeStill());
    server = new Server(storage, undefined, {
      desktopCompanionStillClient: { fetchCurrentStill },
    });
    await server.start();
    baseUrl = `https://127.0.0.1:${server.port}`;
  }, 30_000);

  afterAll(async () => {
    await server?.stop().catch(() => {});
    if (dataDir) rmSync(dataDir, { recursive: true, force: true });
    if (originalTlsRejectUnauthorized === undefined) {
      delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    } else {
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = originalTlsRejectUnauthorized;
    }
  }, 45_000);

  it("lets a paired device fetch current and rejects owner sk_ on the network listener", async () => {
    fetchCurrentStill.mockClear();
    const device = await fetch(`${baseUrl}/desktop/stills/current`, {
      headers: { Authorization: `Bearer ${deviceToken}` },
    });
    expect(device.status).toBe(200);
    expect(device.headers.get("content-type")).toBe("image/png");
    expect(device.headers.get("cache-control")).toBe("no-store");
    expect(headerUtf8(device.headers.get("x-oppi-caption"))).toBe(STILL_CAPTION);
    expect(Buffer.from(await device.arrayBuffer()).equals(PNG_1X1)).toBe(true);
    expect(fetchCurrentStill).toHaveBeenCalledTimes(1);

    fetchCurrentStill.mockClear();
    const owner = await fetch(`${baseUrl}/desktop/stills/current`, {
      headers: { Authorization: `Bearer ${storage.getToken()}` },
    });
    expect(owner.status).toBe(401);
    expect(fetchCurrentStill).not.toHaveBeenCalled();
  });
});

function makeStill(): DesktopCompanionStill {
  return {
    captureId: randomUUID(),
    surface: { windowId: 91, title: "Notes" },
    capturedAt: "2026-09-12T03:00:40.123Z",
    width: 1,
    height: 1,
    caption: STILL_CAPTION,
    png: PNG_1X1,
  };
}

async function dispatchCurrent(options: {
  principal: RequestPrincipal | undefined;
  fetchCurrentStill: () => Promise<DesktopCompanionStill>;
}): Promise<{ statusCode: number; headers: Record<string, string>; body: Buffer }> {
  const routes = new RouteHandler({
    desktopCompanionStillClient: { fetchCurrentStill: options.fetchCurrentStill },
  } as unknown as RouteContext);
  const response = makeBinaryResponse();
  const url = new URL("http://localhost/desktop/stills/current");
  await routes.dispatch(
    "GET",
    url.pathname,
    url,
    makeRequest() as IncomingMessage,
    response as never,
    options.principal,
  );
  return response;
}

function makeBinaryResponse(): {
  statusCode: number;
  headers: Record<string, string>;
  body: Buffer;
  writeHead: (status: number, headers: Record<string, string>) => unknown;
  end: (payload?: string | Buffer) => void;
} {
  return {
    statusCode: 0,
    headers: {},
    body: Buffer.alloc(0),
    writeHead(status: number, headers: Record<string, string>) {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: string | Buffer) {
      if (payload === undefined) {
        this.body = Buffer.alloc(0);
        return;
      }
      this.body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
    },
  };
}

function headerUtf8(value: string | null | undefined): string | undefined {
  if (value == null) return undefined;
  return Buffer.from(value, "latin1").toString("utf8");
}

function readRouteSource(): string {
  return readFileSync(
    fileURLToPath(new URL("../src/routes/desktop-stills.ts", import.meta.url)),
    "utf8",
  );
}
