import { createHash, createPublicKey, generateKeyPairSync, sign as cryptoSign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Loggers read the level when their module loads; the commit hook runs tests at `error`.
const previousLogLevel = vi.hoisted(() => {
  const previous = process.env.OPPI_LOG_LEVEL;
  process.env.OPPI_LOG_LEVEL = "info";
  return previous;
});
afterAll(() => {
  if (previousLogLevel === undefined) delete process.env.OPPI_LOG_LEVEL;
  else process.env.OPPI_LOG_LEVEL = previousLogLevel;
});

import { AuthModule } from "../src/auth-module.js";
import {
  DevicePairing,
  PAIRING_APPROVAL_CLAIM_MS,
  PAIRING_APPROVAL_TTL_MS,
  type PairingApprovalEvents,
} from "../src/device-pairing.js";
import { pushCollapseId, PushSender } from "../src/push/push-sender.js";
import type { RequestPrincipal } from "../src/request-principal.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { markLocalRequest } from "../src/request-trust.js";
import { REFRESH_AUDIENCE } from "../src/storage/device-auth.js";
import { Storage } from "../src/storage.js";
import type { DevicePublicKey, PendingPairingApproval } from "../src/types.js";
import { openPushEnvelopeForTest } from "./helpers/push-envelope-open.js";
import { makeRawRequest, makeRequest, makeResponse } from "./harness/route-test-helpers.js";

type DeviceKey = { publicKey: DevicePublicKey; sign: (data: Buffer | string) => string };

function makeDeviceKey(): DeviceKey {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return {
    publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    sign: (data) =>
      cryptoSign("sha256", Buffer.from(data), {
        key: privateKey,
        dsaEncoding: "ieee-p1363",
      }).toString("base64url"),
  };
}

/** RFC 7638 section 3.2: required EC members in lexicographic order, no whitespace. */
function rfc7638Thumbprint(key: DevicePublicKey): string {
  return createHash("sha256")
    .update(`{"crv":"${key.crv}","kty":"${key.kty}","x":"${key.x}","y":"${key.y}"}`)
    .digest("base64url");
}

function approvalSignature(
  key: DeviceKey,
  approval: { id: string; keyThumbprint: string },
): string {
  return key.sign(`oppi:pair-approve:v1.${approval.id}.${approval.keyThumbprint}`);
}

let dataDir: string;
let storage: Storage;
let pairing: DevicePairing;
let clock: number;
let events: Array<Parameters<PairingApprovalEvents["emitPairingApprovalRequested"]>[0] | object>;
let dispatch: ReturnType<typeof createIdentityRoutes>;

/** One route instance per pairing service, like the server: limiters persist across calls. */
function createPairing(extra: Partial<ConstructorParameters<typeof DevicePairing>[0]> = {}): void {
  pairing?.dispose();
  pairing = new DevicePairing({
    storage,
    events: {
      emitPairingApprovalRequested: (approval) => events.push({ requested: approval }),
      emitPairingApprovalSettled: (approvalId, outcome) => events.push({ approvalId, outcome }),
    },
    now: () => clock,
    ...extra,
  });
  dispatch = createIdentityRoutes(
    { storage, pairing } as unknown as RouteContext,
    createRouteHelpers(),
  );
}

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-pairing-approval-"));
  storage = new Storage(dataDir);
  storage.ensurePaired();
  clock = Date.now();
  events = [];
  createPairing();
});

afterEach(() => {
  pairing.dispose();
  vi.restoreAllMocks();
  rmSync(dataDir, { recursive: true, force: true });
});

async function call(
  method: string,
  path: string,
  options: {
    body?: unknown;
    rawBody?: string;
    principal?: RequestPrincipal;
    ip?: string;
    local?: boolean;
  } = {},
): Promise<{ status: number; body: Record<string, unknown> }> {
  const req =
    options.rawBody === undefined ? makeRequest(options.body) : makeRawRequest(options.rawBody);
  (req.socket as { remoteAddress?: string }).remoteAddress = options.ip ?? "100.64.0.7";
  if (options.local) markLocalRequest(req);
  const res = makeResponse();
  const handled = await dispatch({
    method,
    path,
    url: new URL(`https://paired.example${path}`),
    req,
    res: res as never,
    principal: options.principal,
  });
  expect(handled).toBe(true);
  return { status: res.statusCode, body: res.body ? JSON.parse(res.body) : {} };
}

function enrollExisting(): { deviceId: string; key: DeviceKey; principal: RequestPrincipal } {
  const key = makeDeviceKey();
  const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
    publicKey: key.publicKey,
    name: "iPhone",
  });
  if (!enrolled) throw new Error("enrollment failed");
  return {
    deviceId: enrolled.deviceId,
    key,
    principal: { kind: "device", deviceId: enrolled.deviceId, tokenClass: "at_" },
  };
}

async function pairWithInvite(ttlMs: number, key: DeviceKey = makeDeviceKey()) {
  const pairingToken = storage.issuePairingToken(ttlMs);
  const response = await call("POST", "/pair", {
    body: { pairingToken, devicePublicKey: key.publicKey, deviceName: "iPad" },
  });
  return { ...response, pairingToken, key };
}

async function requestApproval(key: DeviceKey = makeDeviceKey()) {
  const pending = await pairWithInvite(14 * 86_400_000, key);
  expect(pending.status).toBe(202);
  const approvalId = pending.body.approvalId as string;
  const pendingToken = pending.body.pendingToken as string;
  const listed = await call("GET", "/auth/pairing-approvals");
  const approval = (listed.body.approvals as PendingPairingApproval[]).find(
    (item) => item.id === approvalId,
  );
  if (!approval) throw new Error("approval not listed");
  return { approvalId, pendingToken, approval, key };
}

function poll(approvalId: string, pendingToken: string, ip?: string) {
  return call("POST", "/pair/approval-status", {
    body: { approvalId, pendingToken },
    ...(ip ? { ip } : {}),
  });
}

describe("pairing approval policy", () => {
  it("enrolls the first device without approval, whatever the invite TTL", async () => {
    const paired = await pairWithInvite(14 * 86_400_000);
    expect(paired.status).toBe(200);
    expect(paired.body).toMatchObject({ deviceId: expect.stringMatching(/^dev_/) });
    expect(storage.listDevices()[0]?.pairing).toEqual({ method: "invite", source: "100.64.0.7" });
  });

  it("enrolls the first device from a Tailscale invite without approval", async () => {
    const pairingToken = storage.issuePairingToken(90_000, {
      method: "tailscale",
      source: "chen@example.com",
    });
    const paired = await call("POST", "/pair", {
      body: { pairingToken, devicePublicKey: makeDeviceKey().publicKey, deviceName: "iPad" },
    });
    expect(paired.status).toBe(200);
    expect(storage.listDevices()[0]?.pairing).toEqual({
      method: "tailscale",
      source: "chen@example.com",
    });
  });

  it("needs no approval for a 90 s invite while another device is paired", async () => {
    enrollExisting();
    const paired = await pairWithInvite(90_000);
    expect(paired.status).toBe(200);
    expect(paired.body.accessToken).toMatch(/^at_/);
  });

  it("holds an invite over 90 s for approval and consumes it", async () => {
    enrollExisting();
    const pending = await pairWithInvite(90_001);
    expect(pending.status).toBe(202);
    expect(pending.body).toEqual({
      status: "approval_required",
      approvalId: expect.stringMatching(/^pa_/),
      pendingToken: expect.stringMatching(/^pw_/),
      expiresAt: clock + PAIRING_APPROVAL_TTL_MS,
    });
    expect(storage.listDevices()).toHaveLength(1);
    expect(storage.getConfig().pairingToken).toBeUndefined();

    const replay = await call("POST", "/pair", {
      body: { pairingToken: pending.pairingToken, devicePublicKey: makeDeviceKey().publicKey },
    });
    expect(replay.status).toBe(401);
  });

  it("holds a Tailscale invite for approval while another device is paired", async () => {
    enrollExisting();
    const pairingToken = storage.issuePairingToken(90_000, {
      method: "tailscale",
      source: "chen@example.com",
    });
    const pending = await call("POST", "/pair", {
      body: { pairingToken, devicePublicKey: makeDeviceKey().publicKey, deviceName: "Mac" },
    });
    expect(pending.status).toBe(202);
    const listed = await call("GET", "/auth/pairing-approvals");
    expect(listed.body.approvals).toEqual([
      expect.objectContaining({
        method: "tailscale",
        source: "chen@example.com",
        deviceName: "Mac",
      }),
    ]);
  });

  it("treats a pairing as first-device when every other device is revoked", async () => {
    const existing = enrollExisting();
    storage.revokeDevice(existing.deviceId);
    expect((await pairWithInvite(14 * 86_400_000)).status).toBe(200);
  });

  it("answers 429 with eight approvals pending and leaves the long invite usable", async () => {
    const existing = enrollExisting();
    const pendingIds: string[] = [];
    for (let index = 0; index < 8; index += 1) {
      const pending = await pairWithInvite(600_000);
      expect(pending.status).toBe(202);
      pendingIds.push(pending.body.approvalId as string);
    }
    const pairingToken = storage.issuePairingToken(600_000);
    const request = {
      body: { pairingToken, devicePublicKey: makeDeviceKey().publicKey, deviceName: "iPad" },
    };
    expect(await call("POST", "/pair", request)).toEqual({
      status: 429,
      body: { error: "Too many pending pairing approvals" },
    });
    expect(storage.getConfig().pairingToken).toBe(pairingToken);

    await call("POST", `/auth/pairing-approvals/${pendingIds[0]}/deny`, {
      principal: existing.principal,
    });
    expect((await call("POST", "/pair", request)).status).toBe(202);
  });

  it("still enrolls from a 90 s invite while the approval queue is full", async () => {
    enrollExisting();
    for (let index = 0; index < 8; index += 1) {
      expect((await pairWithInvite(600_000)).status).toBe(202);
    }
    expect((await pairWithInvite(90_000)).status).toBe(200);
  });
});

describe("approving a waiting device", () => {
  it("enrolls on the first poll after a signed approval, once", async () => {
    const existing = enrollExisting();
    const newKey = makeDeviceKey();
    const { approvalId, pendingToken, approval } = await requestApproval(newKey);
    expect(approval).toEqual({
      id: approvalId,
      deviceName: "iPad",
      method: "invite",
      source: "100.64.0.7",
      requestedAt: clock,
      expiresAt: clock + PAIRING_APPROVAL_TTL_MS,
      keyThumbprint: rfc7638Thumbprint(newKey.publicKey),
    });

    expect(await poll(approvalId, pendingToken)).toEqual({
      status: 202,
      body: { status: "pending", expiresAt: clock + PAIRING_APPROVAL_TTL_MS },
    });

    const approved = await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
      principal: existing.principal,
      body: { signature: approvalSignature(existing.key, approval) },
    });
    expect(approved).toEqual({ status: 200, body: { ok: true } });
    expect((await call("GET", "/auth/pairing-approvals")).body.approvals).toEqual([]);

    const enrolled = await poll(approvalId, pendingToken);
    expect(enrolled.status).toBe(200);
    const deviceId = enrolled.body.deviceId as string;
    expect(storage.validateAccessToken(enrolled.body.accessToken as string)).toMatchObject({
      ok: true,
      deviceId,
    });
    // The enrolled device signs refreshes with the key it offered while waiting.
    const challenge = enrolled.body.refreshChallenge as { nonce: string };
    expect(
      storage.refresh({
        deviceId,
        nonce: challenge.nonce,
        signature: newKey.sign(`${REFRESH_AUDIENCE}.${challenge.nonce}`),
      }).ok,
    ).toBe(true);
    expect(storage.listDevices().find((device) => device.id === deviceId)?.pairing).toEqual({
      method: "invite",
      source: "100.64.0.7",
      approvedByDeviceId: existing.deviceId,
    });

    expect((await poll(approvalId, pendingToken)).status).toBe(404);
    expect(events).toEqual([{ requested: approval }, { approvalId, outcome: "approved" }]);

    const devices = await call("GET", "/auth/devices");
    expect(devices.body.devices).toContainEqual(
      expect.objectContaining({
        id: deviceId,
        pairingMethod: "invite",
        pairingSource: "100.64.0.7",
        approvedByDeviceId: existing.deviceId,
      }),
    );
  });

  it("does not enroll when the approving device is revoked before the claim", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken, approval } = await requestApproval();
    await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
      principal: existing.principal,
      body: { signature: approvalSignature(existing.key, approval) },
    });
    storage.revokeDevice(existing.deviceId);

    expect(await poll(approvalId, pendingToken)).toEqual({
      status: 410,
      body: { error: "pairing_expired" },
    });
    expect(storage.listDevices().map((device) => device.id)).toEqual([existing.deviceId]);
    expect((await poll(approvalId, pendingToken)).status).toBe(410);
  });

  it("answers 400 to an approval with an unreadable body", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken } = await requestApproval();
    expect(
      await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
        principal: existing.principal,
        rawBody: "{not json",
      }),
    ).toEqual({ status: 400, body: { error: "Invalid JSON" } });
    expect((await poll(approvalId, pendingToken)).status).toBe(202);
  });

  it("rejects signatures from another key, for another approval, or for another device key", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken, approval } = await requestApproval();
    const approve = (signature: unknown) =>
      call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
        principal: existing.principal,
        body: { signature },
      });

    const forged = [
      approvalSignature(makeDeviceKey(), approval),
      approvalSignature(existing.key, { ...approval, id: "pa_other" }),
      approvalSignature(existing.key, {
        ...approval,
        keyThumbprint: rfc7638Thumbprint(makeDeviceKey().publicKey),
      }),
      "not-a-signature",
      undefined,
    ];
    for (const signature of forged) {
      expect(await approve(signature)).toEqual({ status: 401, body: { error: "bad_signature" } });
    }
    expect((await poll(approvalId, pendingToken)).status).toBe(202);

    expect((await approve(approvalSignature(existing.key, approval))).status).toBe(200);
    // Single use: a second approval of the same request finds nothing pending.
    expect((await approve(approvalSignature(existing.key, approval))).status).toBe(404);
  });

  it("refuses approval and denial from the owner socket or without a device credential", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken, approval } = await requestApproval();
    const signature = approvalSignature(existing.key, approval);
    for (const action of ["approve", "deny"]) {
      for (const principal of [{ kind: "owner" } as const, undefined]) {
        const response = await call("POST", `/auth/pairing-approvals/${approvalId}/${action}`, {
          principal,
          local: principal?.kind === "owner",
          body: { signature },
        });
        expect(response.status).toBe(403);
      }
    }
    expect((await poll(approvalId, pendingToken)).status).toBe(202);
  });

  it("fails closed after a denial", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken, approval } = await requestApproval();
    expect(
      await call("POST", `/auth/pairing-approvals/${approvalId}/deny`, {
        principal: existing.principal,
      }),
    ).toEqual({ status: 200, body: { ok: true } });
    expect(await poll(approvalId, pendingToken)).toEqual({
      status: 403,
      body: { error: "pairing_denied" },
    });
    const late = await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
      principal: existing.principal,
      body: { signature: approvalSignature(existing.key, approval) },
    });
    expect(late.status).toBe(404);
    expect(storage.listDevices()).toHaveLength(1);
    expect(events.at(-1)).toEqual({ approvalId, outcome: "denied" });
  });

  it("expires an unanswered request after 120 s", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken, approval } = await requestApproval();
    clock += PAIRING_APPROVAL_TTL_MS;
    expect(await poll(approvalId, pendingToken)).toEqual({
      status: 410,
      body: { error: "pairing_expired" },
    });
    expect(events.at(-1)).toEqual({ approvalId, outcome: "expired" });
    expect((await call("GET", "/auth/pairing-approvals")).body.approvals).toEqual([]);
    const late = await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
      principal: existing.principal,
      body: { signature: approvalSignature(existing.key, approval) },
    });
    expect(late.status).toBe(404);
  });

  it("lapses an approval the new device does not collect within 60 s", async () => {
    const existing = enrollExisting();
    const { approvalId, pendingToken, approval } = await requestApproval();
    await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
      principal: existing.principal,
      body: { signature: approvalSignature(existing.key, approval) },
    });
    clock += PAIRING_APPROVAL_CLAIM_MS;
    expect((await poll(approvalId, pendingToken)).status).toBe(410);
    expect(storage.listDevices()).toHaveLength(1);
  });

  it("answers 404 for a wrong pending token and rate-limits the source", async () => {
    enrollExisting();
    const { approvalId, pendingToken } = await requestApproval();
    for (let attempt = 0; attempt < 5; attempt += 1) {
      expect(await poll(approvalId, `pw_wrong${attempt}`, "198.51.100.9")).toEqual({
        status: 404,
        body: { error: "unknown_approval" },
      });
    }
    expect((await poll(approvalId, pendingToken, "198.51.100.9")).status).toBe(429);
    expect((await poll(approvalId, pendingToken)).status).toBe(202);
  });
});

describe("new-device alerts", () => {
  const PRIMARY = "https://primary.example.test";
  const vectors = JSON.parse(
    readFileSync(
      new URL("../../protocol/push/vectors/cryptokit-hpke.json", import.meta.url),
      "utf8",
    ),
  ) as Record<"recipient" | "other", { privateKey: string; publicKey: string; keyId: string }>;
  const signing = generateKeyPairSync("ed25519");

  function relayCapture() {
    const calls: Array<{ authorization: string | null; envelope: string; collapseId?: string }> =
      [];
    const fetchImpl = vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as { envelope: string; collapseId?: string };
      calls.push({ authorization: new Headers(init?.headers).get("authorization"), ...body });
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    return { calls, fetchImpl: fetchImpl as unknown as typeof fetch };
  }

  function registerPush(deviceId: string, which: "recipient" | "other", sendToken: string): void {
    storage.setPushRegistration({
      deviceId,
      keyId: vectors[which].keyId,
      publicKey: vectors[which].publicKey,
      sendToken,
    });
  }

  function open(envelope: string, which: "recipient" | "other") {
    return openPushEnvelopeForTest(envelope, {
      recipientPrivateKey: Buffer.from(vectors[which].privateKey, "base64url"),
      serverPublicKey: createPublicKey(signing.privateKey),
    });
  }

  it("pushes the approval request and the enrollment to every other registered device and logs it", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    const phone = enrollExisting();
    const mac = enrollExisting();
    const revoked = enrollExisting();
    registerPush(phone.deviceId, "recipient", "osp1.r.p.phone");
    registerPush(mac.deviceId, "other", "osp1.r.p.mac");
    storage.revokeDevice(revoked.deviceId);
    const { calls, fetchImpl } = relayCapture();
    createPairing({
      push: new PushSender(storage, { signingKey: signing.privateKey, fetch: fetchImpl }),
    });
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

    const { approvalId, pendingToken, approval } = await requestApproval();
    await vi.waitFor(() => expect(calls).toHaveLength(2));
    const requested = calls.map((relayCall) =>
      relayCall.authorization === "Bearer osp1.r.p.phone"
        ? open(relayCall.envelope, "recipient")
        : open(relayCall.envelope, "other"),
    );
    for (const plaintext of requested) {
      expect(plaintext).toEqual({
        v: 1,
        ts: expect.any(Number),
        event: "pairing_approval",
        approvalId,
        title: "Approve New Device?",
        body: "iPad wants to pair (invite, 100.64.0.7).",
      });
    }
    expect(calls.find((c) => c.authorization === "Bearer osp1.r.p.phone")?.collapseId).toBe(
      pushCollapseId("osp1.r.p.phone", `pairing:${approvalId}`),
    );

    await call("POST", `/auth/pairing-approvals/${approvalId}/approve`, {
      principal: phone.principal,
      body: { signature: approvalSignature(phone.key, approval) },
    });
    const enrolled = await poll(approvalId, pendingToken);
    const deviceId = enrolled.body.deviceId as string;
    await vi.waitFor(() => expect(calls).toHaveLength(4));
    const alerts = calls.slice(2);
    expect(alerts.map((c) => c.authorization).sort()).toEqual([
      "Bearer osp1.r.p.mac",
      "Bearer osp1.r.p.phone",
    ]);
    const phoneAlert = alerts.find((c) => c.authorization === "Bearer osp1.r.p.phone");
    expect(open(phoneAlert?.envelope ?? "", "recipient")).toEqual({
      v: 1,
      ts: expect.any(Number),
      event: "device_enrolled",
      deviceId,
      title: "New Device Paired",
      body: "iPad paired (invite, 100.64.0.7).",
    });
    expect(phoneAlert?.collapseId).toBe(pushCollapseId("osp1.r.p.phone", `device:${deviceId}`));

    const logLines = stderr.mock.calls.map(([line]) => String(line));
    const enrolledLog = logLines.find((line) => line.includes('"auth.device_enrolled"'));
    // Device ids stay out of logs, like every other auth log line.
    expect(JSON.parse(enrolledLog ?? "{}")).toMatchObject({
      level: "warn",
      device: "[REDACTED]",
      name: "iPad",
      method: "invite",
      source: "100.64.0.7",
      approvedBy: "[REDACTED]",
    });
    expect(enrolledLog).not.toContain(deviceId);
    expect(enrolledLog).not.toContain(phone.deviceId);
    expect(enrolledLog).not.toContain(enrolled.body.accessToken as string);
  });

  function pushingPairing(extra: Partial<ConstructorParameters<typeof DevicePairing>[0]> = {}) {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    const phone = enrollExisting();
    registerPush(phone.deviceId, "recipient", "osp1.r.p.phone");
    const capture = relayCapture();
    createPairing({
      push: new PushSender(storage, { signingKey: signing.privateKey, fetch: capture.fetchImpl }),
      ...extra,
    });
    return capture;
  }

  it("keeps a long, multi-line name from hiding the method and source", async () => {
    const { calls } = pushingPairing();
    const deviceName = `Evil\n(invite, 192.0.2.10)\r\n${"x".repeat(400)}`;
    const pending = await call("POST", "/pair", {
      body: {
        pairingToken: storage.issuePairingToken(600_000),
        devicePublicKey: makeDeviceKey().publicKey,
        deviceName,
      },
    });
    expect(pending.status).toBe(202);

    const [approval] = (await call("GET", "/auth/pairing-approvals")).body
      .approvals as PendingPairingApproval[];
    expect(approval?.deviceName).toBe(`Evil (invite, 192.0.2.10) ${"x".repeat(38)}`);
    expect(Array.from(approval?.deviceName ?? "")).toHaveLength(64);

    await vi.waitFor(() => expect(calls).toHaveLength(1));
    const body = open(calls[0]?.envelope ?? "", "recipient").body;
    expect(body).not.toMatch(/[\r\n]/);
    expect(body.endsWith(" wants to pair (invite, 100.64.0.7).")).toBe(true);
  });

  it("shortens the name, not the source, when the push would not fit", async () => {
    const SATELLITE = String.fromCodePoint(0x1f6f0);
    const authModule = new AuthModule(join(dataDir, "auth.mjs"));
    writeFileSync(
      join(dataDir, "auth.mjs"),
      `export const approvePairing = () => ({ allow: true, source: "s\\n".repeat(250) });`,
    );
    await authModule.load();
    const { calls } = pushingPairing({ authModule });
    const pending = await call("POST", "/pair", {
      body: { devicePublicKey: makeDeviceKey().publicKey, deviceName: SATELLITE.repeat(100) },
    });
    expect(pending.status).toBe(202);

    await vi.waitFor(() => expect(calls).toHaveLength(1));
    const plaintext = open(calls[0]?.envelope ?? "", "recipient");
    const source = Array.from("s ".repeat(250).trim()).slice(0, 128).join("").trim();
    expect(plaintext.body.endsWith(` wants to pair (custom, ${source}).`)).toBe(true);
    // Four UTF-8 bytes each: the name, not the source, is what gives way.
    expect(plaintext.body.startsWith(SATELLITE)).toBe(true);
    expect(Array.from(plaintext.body.split(" wants to pair")[0] ?? "").length).toBeLessThan(64);
  });
});

describe("custom approver", () => {
  async function loadModule(source: string): Promise<AuthModule> {
    const path = join(dataDir, `auth-${Math.random().toString(36).slice(2)}.mjs`);
    writeFileSync(path, source);
    const authModule = new AuthModule(path);
    await authModule.load();
    return authModule;
  }

  function pairCustom(credential: unknown) {
    return call("POST", "/pair", {
      body: { devicePublicKey: makeDeviceKey().publicKey, deviceName: "Kiosk", credential },
    });
  }

  it("enrolls when the module allows, with its source", async () => {
    createPairing({
      authModule: await loadModule(
        `export function approvePairing(req) {
           return req.credential === "letmein" && req.method === "custom" && req.keyThumbprint
             ? { allow: true, source: "sso:chen" } : { allow: false, reason: "bad credential" };
         }`,
      ),
    });
    expect((await pairCustom("letmein")).status).toBe(200);
    expect(storage.listDevices()[0]?.pairing).toEqual({ method: "custom", source: "sso:chen" });

    expect(await pairCustom("wrong")).toEqual({ status: 403, body: { error: "bad credential" } });
  });

  it("answers 429 with a full queue without asking the module", async () => {
    enrollExisting();
    createPairing({
      authModule: await loadModule(
        `export function approvePairing() { globalThis.__oppiCustomCalls = (globalThis.__oppiCustomCalls ?? 0) + 1; return { allow: true }; }`,
      ),
    });
    for (let index = 0; index < 8; index += 1) {
      expect((await pairCustom("x")).status).toBe(202);
    }
    const calls = (globalThis as { __oppiCustomCalls?: number }).__oppiCustomCalls;
    expect(await pairCustom("x")).toEqual({
      status: 429,
      body: { error: "Too many pending pairing approvals" },
    });
    expect((globalThis as { __oppiCustomCalls?: number }).__oppiCustomCalls).toBe(calls);
  });

  it("holds the last queue slot for one of two concurrent custom pairings", async () => {
    enrollExisting();
    createPairing({
      authModule: await loadModule(
        `export async function approvePairing() {
           await new Promise((resolve) => setTimeout(resolve, 50));
           return { allow: true };
         }`,
      ),
    });
    for (let index = 0; index < 7; index += 1) {
      expect((await pairCustom("x")).status).toBe(202);
    }
    const racing = await Promise.all([pairCustom("x"), pairCustom("x")]);
    expect(racing.map((response) => response.status).sort()).toEqual([202, 429]);
    expect((await call("GET", "/auth/pairing-approvals")).body.approvals).toHaveLength(8);
  });

  it("denies when the module throws", async () => {
    createPairing({
      authModule: await loadModule(
        `export async function approvePairing() { throw new Error("boom"); }`,
      ),
    });
    expect(await pairCustom("x")).toEqual({ status: 403, body: { error: "pairing_denied" } });
    expect(storage.listDevices()).toHaveLength(0);
  });

  it("requires approval for a custom pairing once another device is paired", async () => {
    enrollExisting();
    createPairing({
      authModule: await loadModule(`export const approvePairing = async () => ({ allow: true });`),
    });
    const pending = await pairCustom("x");
    expect(pending.status).toBe(202);
    expect((await call("GET", "/auth/pairing-approvals")).body.approvals).toEqual([
      expect.objectContaining({ method: "custom", source: "100.64.0.7", deviceName: "Kiosk" }),
    ]);
  });

  it("still requires pairingToken without a module approver", async () => {
    createPairing({ authModule: await loadModule(`export const gate = () => ({ allow: true });`) });
    expect(await pairCustom("x")).toEqual({
      status: 400,
      body: { error: "pairingToken required" },
    });
  });
});

describe("challenge flood", () => {
  it("does not block a device's refresh from another source", async () => {
    const existing = enrollExisting();
    // An unauthenticated caller who knows the device id floods challenges from one source.
    for (let attempt = 0; attempt < 20; attempt += 1) {
      await call("POST", "/auth/challenge", {
        body: { deviceId: existing.deviceId },
        ip: "203.0.113.66",
      });
    }
    const challenge = await call("POST", "/auth/challenge", {
      body: { deviceId: existing.deviceId },
      ip: "100.64.0.8",
    });
    expect(challenge.status).toBe(200);
    const nonce = challenge.body.nonce as string;
    const refreshed = await call("POST", "/auth/refresh", {
      body: {
        deviceId: existing.deviceId,
        nonce,
        signature: existing.key.sign(`${REFRESH_AUDIENCE}.${nonce}`),
      },
      ip: "100.64.0.8",
    });
    expect(refreshed.status).toBe(200);
    expect(refreshed.body.accessToken).toMatch(/^at_/);
  });
});
