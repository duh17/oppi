import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

import {
  DesktopCompanionViewSessionError,
  type DesktopCompanionViewSession,
} from "../src/desktop-companion-view-session-client.js";
import { RouteHandler } from "../src/routes/index.js";
import type { RouteContext } from "../src/routes/types.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { makeRequest } from "./harness/route-test-helpers.js";

type RequestPrincipal =
  | { kind: "owner" }
  | { kind: "device"; deviceId: string; tokenClass: "at_"; expiresAt?: number };

const VIEW_CAPTION = "View session\u2014not live delivery";

const devicePrincipal: RequestPrincipal = {
  kind: "device",
  deviceId: "dev-paired-1",
  tokenClass: "at_",
};

const ownerPrincipal: RequestPrincipal = { kind: "owner" };

describe("GET /desktop/view/session", () => {
  it("returns JSON metadata for a device at_ principal and forwards deviceId", async () => {
    const session = makeSession();
    const fetchViewSession = vi.fn(async (input: { deviceId: string; deviceName?: string }) => {
      expect(input.deviceId).toBe("dev-paired-1");
      expect(input.deviceName).toBe("Chen iPhone");
      return session;
    });
    const { statusCode, headers, body } = await dispatchViewSession({
      principal: devicePrincipal,
      fetchViewSession,
    });

    expect(statusCode).toBe(200);
    expect(headers["Content-Type"]).toBe("application/json");
    expect(headers["Cache-Control"]).toBe("no-store");
    expect(JSON.parse(body.toString("utf8"))).toEqual({
      grantId: session.grantId,
      capability: "view",
      deviceId: "dev-paired-1",
      expiresAt: session.expiresAt,
      caption: VIEW_CAPTION,
    });
    expect(fetchViewSession).toHaveBeenCalledTimes(1);
  });

  it("maps unavailable and not-bound without leaking another device id", async () => {
    const unavailable = await dispatchViewSession({
      principal: devicePrincipal,
      fetchViewSession: async () => {
        throw new DesktopCompanionViewSessionError(
          "Desktop view session is not available",
          "unavailable",
        );
      },
    });
    expect(unavailable.statusCode).toBe(403);
    expect(JSON.parse(unavailable.body.toString("utf8"))).toEqual({
      error: "Desktop view session is not available",
      code: "view_grant_unavailable",
    });
    expect(unavailable.body.toString("utf8")).not.toContain("phone-other");

    const notBound = await dispatchViewSession({
      principal: devicePrincipal,
      fetchViewSession: async () => {
        throw new DesktopCompanionViewSessionError(
          "Desktop view session is not granted to this device",
          "not_bound",
        );
      },
    });
    expect(notBound.statusCode).toBe(403);
    expect(JSON.parse(notBound.body.toString("utf8"))).toEqual({
      error: "Desktop view session is not granted to this device",
      code: "view_grant_not_bound",
    });
    expect(notBound.body.toString("utf8")).not.toContain("phone-other");
  });

  it("does not fetch for owner principals and missing principals", async () => {
    const fetchViewSession = vi.fn(async () => makeSession());

    const owner = await dispatchViewSession({ principal: ownerPrincipal, fetchViewSession });
    expect(owner.statusCode).toBe(404);
    expect(fetchViewSession).not.toHaveBeenCalled();

    const missing = await dispatchViewSession({ principal: undefined, fetchViewSession });
    expect(missing.statusCode).toBe(404);
    expect(fetchViewSession).not.toHaveBeenCalled();
  });

  it("maps companion down without recapturing", async () => {
    const fetchViewSession = vi.fn(async () => {
      throw new DesktopCompanionViewSessionError(
        "Desktop companion is unavailable",
        "companion_unavailable",
      );
    });
    const response = await dispatchViewSession({ principal: devicePrincipal, fetchViewSession });
    expect(response.statusCode).toBe(502);
    expect(fetchViewSession).toHaveBeenCalledTimes(1);
  });

  it("never writes frames, PNG, or recapture to the route", () => {
    const source = readRouteSource();
    expect(source).toContain("/desktop/view/session");
    expect(source).not.toContain("writeFile");
    expect(source).not.toContain("attachments");
    expect(source).not.toContain("createSessionAttachment");
    expect(source).not.toContain("captureOnce");
    expect(source).not.toContain("image/png");
    expect(source).not.toContain("desktop-stills");
  });
});

describe("GET /desktop/view/session HTTPS auth shell", () => {
  let dataDir: string;
  let storage: Storage;
  let server: Server;
  let baseUrl: string;
  let deviceToken: string;
  let originalTlsRejectUnauthorized: string | undefined;
  const fetchViewSession = vi.fn(async () => makeSession());

  beforeAll(async () => {
    originalTlsRejectUnauthorized = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    dataDir = mkdtempSync(join(tmpdir(), "oppi-desktop-view-session-"));
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
      name: "view-device",
    });
    if (!enrolled) throw new Error("enrollment failed");
    deviceToken = enrolled.accessToken;
    fetchViewSession.mockImplementation(async (input: { deviceId: string }) => ({
      ...makeSession(),
      deviceId: input.deviceId,
    }));
    server = new Server(storage, undefined, {
      desktopCompanionViewSessionClient: { fetchViewSession },
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

  it("lets a paired device fetch metadata and rejects owner sk_ on the network listener", async () => {
    fetchViewSession.mockClear();
    const device = await fetch(`${baseUrl}/desktop/view/session`, {
      headers: { Authorization: `Bearer ${deviceToken}` },
    });
    expect(device.status).toBe(200);
    expect(device.headers.get("content-type")).toBe("application/json");
    expect(device.headers.get("cache-control")).toBe("no-store");
    const payload = (await device.json()) as { capability: string; caption: string; deviceId: string };
    expect(payload.capability).toBe("view");
    expect(payload.caption).toBe(VIEW_CAPTION);
    expect(payload.deviceId).toBeTruthy();
    expect(fetchViewSession).toHaveBeenCalledTimes(1);

    fetchViewSession.mockClear();
    const owner = await fetch(`${baseUrl}/desktop/view/session`, {
      headers: { Authorization: `Bearer ${storage.getToken()}` },
    });
    expect(owner.status).toBe(401);
    expect(fetchViewSession).not.toHaveBeenCalled();
  });
});

function makeSession(): DesktopCompanionViewSession {
  return {
    grantId: randomUUID(),
    capability: "view",
    deviceId: "dev-paired-1",
    expiresAt: "2026-09-12T03:15:40.123Z",
    caption: VIEW_CAPTION,
  };
}

async function dispatchViewSession(options: {
  principal: RequestPrincipal | undefined;
  fetchViewSession: (input: {
    deviceId: string;
    deviceName?: string;
  }) => Promise<DesktopCompanionViewSession>;
}): Promise<{ statusCode: number; headers: Record<string, string>; body: Buffer }> {
  const routes = new RouteHandler({
    storage: {
      listDevices: () => [{ id: "dev-paired-1", name: "Chen iPhone" }],
    },
    desktopCompanionViewSessionClient: { fetchViewSession: options.fetchViewSession },
  } as unknown as RouteContext);
  const response = makeBinaryResponse();
  const url = new URL("http://localhost/desktop/view/session");
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

function readRouteSource(): string {
  return readFileSync(
    fileURLToPath(new URL("../src/routes/desktop-view-session.ts", import.meta.url)),
    "utf8",
  );
}
