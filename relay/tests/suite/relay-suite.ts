/**
 * Relay API v1 behavior shared by every adapter (protocol/push/spec.md §3). Each adapter's
 * test file supplies a harness; adapter-only cases (clock control, a test App Attest root)
 * live next to the harness.
 */

import { randomBytes } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DEFAULT_QUOTA_LIMITS } from "../../src/core/store.js";

export interface CapturedApnsRequest {
  host: string;
  path: string;
  headers: Record<string, string>;
  payload: string;
}

export interface RelayHarness {
  url: string;
  apnsRequests: CapturedApnsRequest[];
  /** How the mock APNs answers; 200 by default. */
  respondApns(handler: (request: CapturedApnsRequest) => { status: number; reason?: string }): void;
  /** Everything the relay persisted, as text: what its operator could read. */
  storageText(): Promise<string>;
  logs: string[];
  close(): Promise<void>;
}

export const APP_ID = "TESTTEAM01.dev.chenda.Oppi";
export const BUNDLE_ID = "dev.chenda.Oppi";

let addressCounter = 0;
/** A distinct client address per call keeps the per-address limits out of unrelated tests. */
export function nextAddress(): string {
  addressCounter += 1;
  return `198.51.100.${addressCounter % 250}:${addressCounter}`;
}

export async function call(
  harness: RelayHarness,
  method: string,
  path: string,
  options: { body?: unknown; rawBody?: string; bearer?: string; headers?: Record<string, string>; address?: string } = {},
): Promise<{ status: number; json: Record<string, unknown>; headers: Headers }> {
  const address = options.address ?? nextAddress();
  const response = await fetch(`${harness.url}${path}`, {
    method,
    headers: {
      "x-forwarded-for": address,
      "cf-connecting-ip": address,
      ...(options.bearer ? { authorization: `Bearer ${options.bearer}` } : {}),
      ...(options.body !== undefined || options.rawBody !== undefined
        ? { "content-type": "application/json" }
        : {}),
      ...options.headers,
    },
    ...(options.rawBody !== undefined
      ? { body: options.rawBody }
      : options.body !== undefined
        ? { body: JSON.stringify(options.body) }
        : {}),
  });
  const text = await response.text();
  return {
    status: response.status,
    json: text ? (JSON.parse(text) as Record<string, unknown>) : {},
    headers: response.headers,
  };
}

export function fakeEnvelope(version = 0x01, length = 641): string {
  const bytes = randomBytes(length);
  bytes[0] = version;
  return bytes.toString("base64url");
}

export const APNS_TOKEN = "a".repeat(64);

export async function registerUnattested(
  harness: RelayHarness,
  environment: "sandbox" | "production" = "sandbox",
  apnsToken = APNS_TOKEN,
): Promise<{ registrationId: string; registrationSecret: string }> {
  const address = nextAddress();
  const challenge = await call(harness, "POST", "/v1/challenge", { address });
  const registration = await call(harness, "POST", "/v1/registrations", {
    address,
    body: { challenge: challenge.json.challenge, apnsToken, environment, attestation: null },
  });
  expect(registration.status).toBe(201);
  return registration.json as { registrationId: string; registrationSecret: string };
}

export async function mintSendToken(
  harness: RelayHarness,
  registration: { registrationId: string; registrationSecret: string },
): Promise<string> {
  const response = await call(harness, "POST", `/v1/registrations/${registration.registrationId}/permissions`, {
    bearer: registration.registrationSecret,
    body: {},
  });
  expect(response.status).toBe(201);
  return response.json.sendToken as string;
}

export function defineRelaySuite(name: string, start: () => Promise<RelayHarness>): void {
  describe(`relay API v1 (${name})`, () => {
    let harness: RelayHarness;

    beforeEach(async () => {
      harness = await start();
    });
    afterEach(async () => {
      await harness.close();
    });

    it("reports its API version", async () => {
      expect(await call(harness, "GET", "/v1/version")).toMatchObject({ status: 200, json: { api: 1 } });
    });

    it("accepts each challenge once and rejects unknown ones", async () => {
      const address = nextAddress();
      const challenge = (await call(harness, "POST", "/v1/challenge", { address })).json.challenge;
      expect(challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
      const body = { challenge, apnsToken: APNS_TOKEN, environment: "sandbox", attestation: null };
      expect((await call(harness, "POST", "/v1/registrations", { body, address })).status).toBe(201);
      expect(await call(harness, "POST", "/v1/registrations", { body })).toMatchObject({
        status: 400,
        json: { error: "challenge_invalid" },
      });
      expect(
        (await call(harness, "POST", "/v1/registrations", { body: { ...body, challenge: "x".repeat(43) } }))
          .json.error,
      ).toBe("challenge_invalid");
    });

    it("registers a device without App Attest with the lower daily limit", async () => {
      const address = nextAddress();
      const challenge = (await call(harness, "POST", "/v1/challenge", { address })).json.challenge;
      const response = await call(harness, "POST", "/v1/registrations", {
        address,
        body: { challenge, apnsToken: APNS_TOKEN, environment: "production", attestation: null },
      });
      expect(response.status).toBe(201);
      expect(response.json).toMatchObject({
        attested: false,
        limits: { pushesPerDay: DEFAULT_QUOTA_LIMITS.unattestedPerDay },
      });
      expect(response.json.registrationId).toMatch(/^r_[A-Za-z0-9_-]{22}$/);
      expect(response.json.registrationSecret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    });

    it("rejects unknown fields, malformed tokens, and oversized bodies", async () => {
      const challenge = (await call(harness, "POST", "/v1/challenge")).json.challenge;
      const base = { challenge, apnsToken: APNS_TOKEN, environment: "sandbox", attestation: null };
      expect((await call(harness, "POST", "/v1/registrations", { body: { ...base, extra: 1 } })).json.error).toBe(
        "unknown_field",
      );
      expect(
        (await call(harness, "POST", "/v1/registrations", { body: { ...base, apnsToken: "XYZ" } })).json.error,
      ).toBe("bad_request");
      expect(
        (await call(harness, "POST", "/v1/registrations", { rawBody: JSON.stringify({ ...base, pad: "x".repeat(9000) }) }))
          .status,
      ).toBe(413);
    });

    it("mints send permissions only with the registration secret, up to 16", async () => {
      const registration = await registerUnattested(harness);
      const path = `/v1/registrations/${registration.registrationId}/permissions`;
      expect((await call(harness, "POST", path, { body: {} })).status).toBe(401);
      expect((await call(harness, "POST", path, { body: {}, bearer: "wrong" })).status).toBe(401);
      expect(
        (await call(harness, "POST", `/v1/registrations/r_${"A".repeat(22)}/permissions`, { body: {}, bearer: "x" }))
          .status,
      ).toBe(410);

      const tokens = [];
      for (let index = 0; index < 16; index += 1) tokens.push(await mintSendToken(harness, registration));
      expect(new Set(tokens).size).toBe(16);
      expect(tokens[0]).toMatch(
        new RegExp(`^osp1\\.${registration.registrationId}\\.p_[A-Za-z0-9_-]{22}\\.[A-Za-z0-9_-]{43}$`),
      );
      expect(await call(harness, "POST", path, { body: {}, bearer: registration.registrationSecret })).toMatchObject({
        status: 409,
        json: { error: "too_many_permissions" },
      });
    });

    it("sends the fixed APNs template around the envelope", async () => {
      const registration = await registerUnattested(harness, "production");
      const sendToken = await mintSendToken(harness, registration);
      const envelope = fakeEnvelope();
      const before = Math.floor(Date.now() / 1000);
      const response = await call(harness, "POST", "/v1/push", {
        bearer: sendToken,
        body: { envelope, collapseId: "c".repeat(22), ttl: 600 },
      });

      expect(response).toMatchObject({ status: 200, json: { ok: true } });
      expect(harness.apnsRequests).toHaveLength(1);
      const [sent] = harness.apnsRequests;
      expect(sent?.host).toBe("api.push.apple.com");
      expect(sent?.path).toBe(`/3/device/${APNS_TOKEN}`);
      expect(sent?.headers).toMatchObject({
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": BUNDLE_ID,
        "apns-collapse-id": "c".repeat(22),
      });
      const expiration = Number(sent?.headers["apns-expiration"]);
      expect(expiration).toBeGreaterThanOrEqual(before + 600);
      expect(expiration).toBeLessThanOrEqual(before + 602);
      expect(JSON.parse(sent?.payload ?? "{}")).toEqual({
        aps: { alert: { title: "Oppi", body: "You have a new notification." }, "mutable-content": 1 },
        e: envelope,
      });
    });

    it("routes sandbox registrations to the sandbox host with the default TTL", async () => {
      const registration = await registerUnattested(harness, "sandbox");
      const sendToken = await mintSendToken(harness, registration);
      expect((await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } })).status).toBe(200);
      const [sent] = harness.apnsRequests;
      expect(sent?.host).toBe("api.sandbox.push.apple.com");
      expect(sent?.headers).not.toHaveProperty("apns-collapse-id");
      expect(Number(sent?.headers["apns-expiration"])).toBeGreaterThanOrEqual(Math.floor(Date.now() / 1000) + 3590);
    });

    it("accepts only exact v1 envelopes and known fields", async () => {
      const sendToken = await mintSendToken(harness, await registerUnattested(harness));
      const push = (body: unknown) => call(harness, "POST", "/v1/push", { bearer: sendToken, body });
      expect((await push({ envelope: fakeEnvelope(0x01, 642) })).json.error).toBe("envelope_size");
      expect((await push({ envelope: fakeEnvelope(0x01, 640) })).json.error).toBe("envelope_size");
      expect((await push({ envelope: fakeEnvelope(0x02) })).json.error).toBe("bad_envelope");
      expect((await push({ envelope: `+${fakeEnvelope().slice(1)}` })).json.error).toBe("bad_envelope");
      expect((await push({ envelope: fakeEnvelope(), title: "plaintext" })).json.error).toBe("unknown_field");
      expect((await push({ envelope: fakeEnvelope(), ttl: 3601 })).status).toBe(400);
      expect((await push({ envelope: fakeEnvelope(), collapseId: "session-1" })).status).toBe(400);
      expect(harness.apnsRequests).toHaveLength(0);
    });

    it("answers 401 for a missing or malformed send token and 410 for an unknown one", async () => {
      const body = { envelope: fakeEnvelope() };
      expect((await call(harness, "POST", "/v1/push", { body })).status).toBe(401);
      expect((await call(harness, "POST", "/v1/push", { body, bearer: "osp1.nope" })).status).toBe(401);
      const unknown = `osp1.r_${"A".repeat(22)}.p_${"B".repeat(22)}.${"C".repeat(43)}`;
      expect(await call(harness, "POST", "/v1/push", { body, bearer: unknown })).toMatchObject({
        status: 410,
        json: { error: "gone" },
      });
      const registration = await registerUnattested(harness);
      const real = await mintSendToken(harness, registration);
      const wrongSecret = `${real.slice(0, real.lastIndexOf("."))}.${"D".repeat(43)}`;
      expect((await call(harness, "POST", "/v1/push", { body, bearer: wrongSecret })).status).toBe(410);
    });

    it.each([
      [410, "Unregistered"],
      [400, "BadDeviceToken"],
      [400, "DeviceTokenNotForTopic"],
    ])("forgets the registration when APNs answers %i %s", async (status, reason) => {
      const registration = await registerUnattested(harness);
      const sendToken = await mintSendToken(harness, registration);
      harness.respondApns(() => ({ status, reason }));
      expect(await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } })).toMatchObject({
        status: 410,
        json: { error: "gone" },
      });
      harness.respondApns(() => ({ status: 200 }));
      expect((await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } })).status).toBe(410);
      expect(
        (await call(harness, "POST", `/v1/registrations/${registration.registrationId}/permissions`, {
          bearer: registration.registrationSecret,
          body: {},
        })).status,
      ).toBe(410);
    });

    it.each([
      [500, "InternalServerError"],
      [429, "TooManyRequests"],
      [403, "InvalidProviderToken"],
    ])("answers 502 and keeps the registration when APNs answers %i", async (status, reason) => {
      const sendToken = await mintSendToken(harness, await registerUnattested(harness));
      harness.respondApns(() => ({ status, reason }));
      const push = () => call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } });
      expect(await push()).toMatchObject({ status: 502, json: { error: "apns_unavailable" } });
      harness.respondApns(() => ({ status: 200 }));
      expect((await push()).status).toBe(200);
    });

    it("limits a registration's pushes per minute with Retry-After", async () => {
      const perMinute = DEFAULT_QUOTA_LIMITS.perMinute;
      const sendToken = await mintSendToken(harness, await registerUnattested(harness));
      for (let index = 0; index < perMinute; index += 1) {
        expect((await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } })).status).toBe(200);
      }
      const limited = await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } });
      expect(limited).toMatchObject({ status: 429, json: { error: "quota_exceeded" } });
      const retryAfter = Number(limited.headers.get("retry-after"));
      expect(retryAfter).toBeGreaterThanOrEqual(1);
      expect(retryAfter).toBeLessThanOrEqual(60);
      expect(harness.apnsRequests).toHaveLength(perMinute);
    });

    it("lets a server release its own permission, idempotently", async () => {
      const registration = await registerUnattested(harness);
      const kept = await mintSendToken(harness, registration);
      const released = await mintSendToken(harness, registration);
      expect((await call(harness, "DELETE", "/v1/permission", { bearer: released })).status).toBe(204);
      expect((await call(harness, "DELETE", "/v1/permission", { bearer: released })).status).toBe(204);
      expect((await call(harness, "POST", "/v1/push", { bearer: released, body: { envelope: fakeEnvelope() } })).status).toBe(410);
      expect((await call(harness, "POST", "/v1/push", { bearer: kept, body: { envelope: fakeEnvelope() } })).status).toBe(200);
    });

    it("lets the app revoke one permission or the whole registration", async () => {
      const registration = await registerUnattested(harness);
      const first = await mintSendToken(harness, registration);
      const second = await mintSendToken(harness, registration);
      const permissionId = first.split(".")[2];
      expect(
        (await call(harness, "DELETE", `/v1/registrations/${registration.registrationId}/permissions/${permissionId}`, {
          bearer: registration.registrationSecret,
        })).status,
      ).toBe(204);
      expect((await call(harness, "POST", "/v1/push", { bearer: first, body: { envelope: fakeEnvelope() } })).status).toBe(410);
      expect((await call(harness, "POST", "/v1/push", { bearer: second, body: { envelope: fakeEnvelope() } })).status).toBe(200);

      expect(
        (await call(harness, "DELETE", `/v1/registrations/${registration.registrationId}`, { bearer: "wrong" })).status,
      ).toBe(401);
      expect(
        (await call(harness, "DELETE", `/v1/registrations/${registration.registrationId}`, {
          bearer: registration.registrationSecret,
        })).status,
      ).toBe(204);
      expect((await call(harness, "POST", "/v1/push", { bearer: second, body: { envelope: fakeEnvelope() } })).status).toBe(410);
    });

    it("stores and logs no envelope, send token, or client address", async () => {
      const address = "203.0.113.77";
      const registration = await registerUnattested(harness);
      const sendToken = await mintSendToken(harness, registration);
      const envelope = fakeEnvelope();
      expect((await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope }, address })).status).toBe(200);

      const stored = await harness.storageText();
      const logged = harness.logs.join("\n");
      expect(stored).toContain(registration.registrationId);
      for (const secret of [envelope, envelope.slice(100, 140), sendToken.split(".")[3] ?? "", registration.registrationSecret, address]) {
        expect(stored).not.toContain(secret);
        expect(logged).not.toContain(secret);
      }
    });
  });
}
