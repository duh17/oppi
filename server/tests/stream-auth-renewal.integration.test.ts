/**
 * In-band access renewal (`auth_renew`) on live device streams: a fresh token of the same
 * device moves the socket's expiry close to that token's deadline; anything else is refused
 * and the socket still closes at its old deadline.
 */
import { createHash, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { readdirSync, readFileSync, rmSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket, type RawData } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { CLOCK_SKEW_MS, REFRESH_AUDIENCE } from "../src/storage/device-auth.js";
import { makeTempDir } from "./harness/temp-dir.js";

type Device = { id: string; token: string; privateKey: KeyObject };
type Frame = Record<string, unknown>;

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let sockets: WebSocket[] = [];

beforeEach(async () => {
  dataDir = makeTempDir("oppi-renew-");
  storage = new Storage(dataDir);
  storage.mutateConfig(() => ({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "self-signed" },
    // Enough for /dictation/stream to accept sockets; no take ever reaches it.
    asr: { sttEndpoint: "http://127.0.0.1:9/unused" },
  }));
  storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `https://127.0.0.1:${server.port}`;
}, 30_000);

afterEach(async () => {
  for (const ws of sockets) ws.terminate();
  sockets = [];
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 45_000);

function enroll(): Device {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  const result = storage.enrollViaPairing(storage.issuePairingToken(60_000), {
    publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    name: "Renewal test device",
  });
  if (!result) throw new Error("enrollment failed");
  return { id: result.deviceId, token: result.accessToken, privateKey };
}

/** A second access token for the device, through the real signed refresh. */
function mintToken(device: Device): string {
  const challenge = storage.issueChallenge(device.id);
  if (!challenge) throw new Error("no challenge");
  const signature = sign("sha256", Buffer.from(`${REFRESH_AUDIENCE}.${challenge.nonce}`), {
    key: device.privateKey,
    dsaEncoding: "ieee-p1363",
  }).toString("base64url");
  const result = storage.refresh({ deviceId: device.id, nonce: challenge.nonce, signature });
  if (!result.ok) throw new Error(`refresh failed: ${result.code}`);
  return result.accessToken;
}

/** Make `token` expire so its socket deadline (expiry + skew) lands `deadlineInMs` from now. */
function setDeadline(token: string, deadlineInMs: number): number {
  const hash = `sha256:${createHash("sha256").update(token, "utf8").digest("hex")}`;
  const expiresAt = Date.now() - CLOCK_SKEW_MS + deadlineInMs;
  storage.mutateConfig((config) => ({
    authAccessTokens: (config.authAccessTokens ?? []).map((record) =>
      record.tokenHash === hash ? { ...record, expiresAt } : record,
    ),
  }));
  return expiresAt;
}

class Probe {
  readonly frames: Frame[] = [];
  readonly closed: Promise<{ code: number; at: number }>;

  constructor(readonly ws: WebSocket) {
    this.closed = new Promise((resolve) => {
      ws.once("close", (code) => resolve({ code, at: Date.now() }));
    });
    ws.on("message", (data: RawData, isBinary) => {
      if (!isBinary) this.frames.push(JSON.parse(String(data)) as Frame);
    });
  }

  async next(type: string, timeoutMs = 10_000): Promise<Frame> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.frames.findIndex((frame) => frame["type"] === type);
      if (index >= 0) return this.frames.splice(index, 1)[0] as Frame;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`timed out waiting for ${type}`);
  }

  async renew(token: string): Promise<Frame> {
    this.ws.send(JSON.stringify({ type: "auth_renew", token }));
    return this.next("auth_renew_result");
  }
}

async function open(path: string, token: string, readyFrame?: string): Promise<Probe> {
  const ws = new WebSocket(`${baseUrl.replace(/^https:/, "wss:")}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    rejectUnauthorized: false,
  });
  sockets.push(ws);
  const probe = new Probe(ws);
  await new Promise<void>((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("unexpected-response", (_req, res) => reject(new Error(`HTTP ${res.statusCode}`)));
    ws.once("error", reject);
  });
  if (readyFrame) await probe.next(readyFrame, 20_000);
  return probe;
}

function networkPost(path: string, token: string, body: unknown): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body);
    const req = httpsRequest(
      `${baseUrl}${path}`,
      {
        method: "POST",
        rejectUnauthorized: false,
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(payload),
          Authorization: `Bearer ${token}`,
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk: Buffer) => (data += chunk.toString("utf8")));
        res.on("end", () => resolve(JSON.parse(data)));
      },
    );
    req.on("error", reject);
    req.end(payload);
  });
}

function revokeAsOwner(deviceId: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        socketPath: server.socketPath,
        method: "DELETE",
        path: `/auth/devices/${encodeURIComponent(deviceId)}`,
        headers: { Authorization: `Bearer ${storage.getToken()}` },
      },
      (res) => {
        res.resume();
        res.on("end", () => resolve(res.statusCode ?? 0));
      },
    );
    req.on("error", reject);
    req.end();
  });
}

async function sessionStreamPath(device: Device): Promise<string> {
  const workspace = storage.createWorkspace({ name: "Renewal", hostMount: dataDir });
  const created = (await networkPost(`/workspaces/${workspace.id}/sessions`, device.token, {})) as {
    session: { id: string };
  };
  return `/workspaces/${workspace.id}/sessions/${created.session.id}/stream`;
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

describe("in-band stream access renewal", { timeout: 60_000 }, () => {
  const streams = [
    { name: "app events", path: async () => "/app/events/stream", ready: "app_events_connected" },
    { name: "focused session", path: sessionStreamPath, ready: "connected" },
    { name: "dictation", path: async () => "/dictation/stream", ready: undefined },
  ] as const;

  for (const stream of streams) {
    it(`moves a ${stream.name} socket's expiry close to the renewal token's deadline`, async () => {
      const device = enroll();
      const path = await stream.path(device);
      const fresh = mintToken(device);
      setDeadline(device.token, 1_500);
      const renewedExpiresAt = setDeadline(fresh, 4_500);

      const probe = await open(path, device.token, stream.ready);
      expect(await probe.renew(fresh)).toEqual({
        type: "auth_renew_result",
        ok: true,
        expiresAt: renewedExpiresAt,
      });

      // Past the token it connected with: still open.
      await sleep(2_500);
      expect(probe.ws.readyState).toBe(WebSocket.OPEN);

      // A renewed socket lasts exactly as long as the renewal token, no longer.
      const closed = await probe.closed;
      expect(closed.code).toBe(4001);
      expect(closed.at).toBeGreaterThanOrEqual(renewedExpiresAt + CLOCK_SKEW_MS - 50);
    });
  }

  it("refuses tokens that are not this device's, revoked, unknown, or expired, keeping the old deadline", async () => {
    const device = enroll();
    const other = enroll();
    const revoked = enroll();
    expect(storage.revokeDevice(revoked.id)).toBe(true);
    const expired = mintToken(device);
    const connectedAt = Date.now();
    setDeadline(device.token, 3_000);

    const probe = await open("/app/events/stream", device.token, "app_events_connected");
    const refused = async (token: string): Promise<unknown> => (await probe.renew(token))["reason"];
    expect(await refused(other.token)).toBe("wrong_device");
    expect(await refused(revoked.token)).toBe("unknown_token");
    expect(await refused("at_not_a_token")).toBe("unknown_token");
    // Expire it just before use: the next validation of any token prunes expired records,
    // after which the same token is refused as unknown.
    setDeadline(expired, -1);
    expect(await refused(expired)).toBe("expired");
    probe.ws.send(JSON.stringify({ type: "auth_renew" }));
    expect((await probe.next("auth_renew_result"))["reason"]).toBe("unknown_token");

    const closed = await probe.closed;
    expect(closed.code).toBe(4001);
    expect(closed.at - connectedAt).toBeLessThan(4_500);
  });

  it("still closes a renewed socket at once when the device is revoked", async () => {
    const device = enroll();
    const probe = await open("/app/events/stream", device.token, "app_events_connected");
    expect((await probe.renew(mintToken(device)))["ok"]).toBe(true);

    const revokedAt = Date.now();
    expect(await revokeAsOwner(device.id)).toBe(200);
    const closed = await probe.closed;
    expect(closed.code).toBe(1008);
    expect(closed.at - revokedAt).toBeLessThan(1_000);
  });

  it("records renewals and refusals in server telemetry", async () => {
    const device = enroll();
    const other = enroll();
    const probe = await open("/app/events/stream", device.token, "app_events_connected");
    expect((await probe.renew(mintToken(device)))["ok"]).toBe(true);
    expect((await probe.renew(other.token))["ok"]).toBe(false);

    await server.stop();
    const dir = join(dataDir, "diagnostics", "telemetry");
    const events = readdirSync(dir)
      .filter((name) => name.startsWith("server-events-"))
      .flatMap((name) => readFileSync(join(dir, name), "utf8").trim().split("\n"))
      .map((line) => JSON.parse(line) as { name: string; tags: Record<string, string> })
      .filter((event) => event.name === "server.ws_auth_renew")
      .map((event) => event.tags);
    expect(events).toEqual([
      { stream: "app_events", result: "renewed" },
      { stream: "app_events", result: "rejected", reason: "wrong_device" },
    ]);
  });
});
