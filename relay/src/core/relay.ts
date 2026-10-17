/**
 * Relay API v1 (protocol/push/spec.md §3), adapter-agnostic: a WHATWG `Request` in, a
 * `Response` out. The relay checks envelope size and version and never opens one; it holds
 * no decryption code.
 */

import { APPLE_APP_ATTESTATION_ROOT_CA_PEM } from "./apple-app-attestation-root.js";
import { verifyAssertion, verifyAttestation } from "./app-attest.js";
import { buildApnsRequest, isRetiredToken, type ApnsSender } from "./apns.js";
import {
  base64Decode,
  base64urlDecode,
  base64urlEncode,
  hashesEqual,
  randomBytes,
  randomId,
  secretHash,
  sha256,
  utf8,
} from "./bytes.js";
import {
  DEFAULT_QUOTA_LIMITS,
  emptyQuota,
  type ApnsEnvironment,
  type RegistrationRecord,
  type RelayStore,
} from "./store.js";
import { parseCertificate, pemToDer, type Certificate } from "./x509.js";

export const ENVELOPE_BYTES = 641;
export const ENVELOPE_BASE64URL_LENGTH = 855;
const ENVELOPE_VERSION = 0x01;
const MAX_BODY_BYTES = 8 * 1024;
const MAX_TTL_SECONDS = 3600;
const CHALLENGE_TTL_MS = 300_000;

const REGISTRATION_ID = /^r_[A-Za-z0-9_-]{22}$/;
const PERMISSION_ID = /^p_[A-Za-z0-9_-]{22}$/;
const SECRET = /^[A-Za-z0-9_-]{43}$/;
const APNS_TOKEN = /^[0-9a-f]{64,200}$/;
const COLLAPSE_ID = /^[A-Za-z0-9_-]{22}$/;

export interface RelayConfig {
  /** `<Team ID>.<bundle ID>`, the App Attest RP ID. */
  appId: string;
  /** APNs topic. */
  bundleId: string;
  /** App Attest trust root; Apple's App Attestation Root CA unless a test replaces it. */
  trustRootPem?: string;
}

export type RelayLog = (event: string, fields?: Record<string, string | number | boolean>) => void;

export interface RelayDeps {
  store: RelayStore;
  apns: ApnsSender;
  config: RelayConfig;
  now?: () => number;
  /** Event names and status codes only: never bodies, headers, tokens, or addresses. */
  log?: RelayLog;
}

/** In-memory fixed-window counter per client address. Nothing is persisted. */
class AddressLimiter {
  private readonly hits = new Map<string, { windowStart: number; count: number }>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
  ) {}

  allow(address: string | null, now: number): boolean {
    const key = address ?? "unknown";
    if (this.hits.size > 10_000) {
      for (const [entryKey, entry] of this.hits) {
        if (now - entry.windowStart >= this.windowMs) this.hits.delete(entryKey);
      }
    }
    const entry = this.hits.get(key);
    if (!entry || now - entry.windowStart >= this.windowMs) {
      this.hits.set(key, { windowStart: now, count: 1 });
      return true;
    }
    if (entry.count >= this.max) return false;
    entry.count += 1;
    return true;
  }
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(code);
  }
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
  });
}

function noContent(): Response {
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

async function readBody(request: Request): Promise<Uint8Array> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError(413, "body_too_large");
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length > MAX_BODY_BYTES) throw new HttpError(413, "body_too_large");
  return bytes;
}

function parseObject(bytes: Uint8Array, allowed: readonly string[]): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new HttpError(400, "bad_request");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new HttpError(400, "bad_request");
  }
  for (const key of Object.keys(parsed)) {
    if (!allowed.includes(key)) throw new HttpError(400, "unknown_field");
  }
  return parsed as Record<string, unknown>;
}

function bearer(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([^\s]+)$/.exec(header);
  if (!match?.[1]) throw new HttpError(401, "unauthorized");
  return match[1];
}

interface SendToken {
  registrationId: string;
  permissionId: string;
  secret: string;
}

function parseSendToken(token: string): SendToken {
  const [prefix, registrationId, permissionId, secret, ...rest] = token.split(".");
  if (
    prefix !== "osp1" ||
    rest.length > 0 ||
    !registrationId ||
    !permissionId ||
    !secret ||
    !REGISTRATION_ID.test(registrationId) ||
    !PERMISSION_ID.test(permissionId) ||
    !SECRET.test(secret)
  ) {
    throw new HttpError(401, "unauthorized");
  }
  return { registrationId, permissionId, secret };
}

export function registrationClientData(challenge: string, apnsToken: string, environment: string): string {
  return `oppi-relay-registration-v1\n${challenge}\n${apnsToken}\n${environment}`;
}

export async function requestClientData(method: string, path: string, body: Uint8Array): Promise<string> {
  return `oppi-relay-request-v1\n${method}\n${path}\n${base64urlEncode(await sha256(body))}`;
}

export function createRelayHandler(deps: RelayDeps): (
  request: Request,
  clientAddress: string | null,
) => Promise<Response> {
  const now = deps.now ?? Date.now;
  const log: RelayLog = deps.log ?? (() => {});
  const trustRoot: Certificate = parseCertificate(
    pemToDer(deps.config.trustRootPem ?? APPLE_APP_ATTESTATION_ROOT_CA_PEM),
  );
  const challengeLimiter = new AddressLimiter(20, 10 * 60_000);
  const unattestedLimiter = new AddressLimiter(5, 60 * 60_000);
  const { store } = deps;

  async function postChallenge(clientAddress: string | null): Promise<Response> {
    if (!challengeLimiter.allow(clientAddress, now())) throw new HttpError(429, "rate_limited");
    const challenge = base64urlEncode(randomBytes(32));
    const expiresAt = now() + CHALLENGE_TTL_MS;
    await store.putChallenge(challenge, expiresAt);
    return json(200, { challenge, expiresAt });
  }

  async function postRegistration(body: Uint8Array, clientAddress: string | null): Promise<Response> {
    const fields = parseObject(body, ["challenge", "apnsToken", "environment", "attestation"]);
    const { challenge, apnsToken, environment, attestation } = fields;
    if (
      typeof challenge !== "string" ||
      typeof apnsToken !== "string" ||
      !APNS_TOKEN.test(apnsToken) ||
      (environment !== "sandbox" && environment !== "production") ||
      attestation === undefined
    ) {
      throw new HttpError(400, "bad_request");
    }
    // Production is for App Store and TestFlight builds, which can always attest; only
    // development builds, Simulator, and probes register in sandbox without App Attest.
    if (attestation === null && environment === "production") {
      throw new HttpError(401, "attestation_required");
    }
    let attestationInput: { keyId: Uint8Array; object: Uint8Array } | null = null;
    if (attestation !== null) {
      if (typeof attestation !== "object" || Array.isArray(attestation)) {
        throw new HttpError(400, "bad_request");
      }
      const attestationFields = attestation as Record<string, unknown>;
      for (const key of Object.keys(attestationFields)) {
        if (key !== "keyId" && key !== "object") throw new HttpError(400, "unknown_field");
      }
      const keyId =
        typeof attestationFields.keyId === "string" ? base64Decode(attestationFields.keyId) : null;
      const object =
        typeof attestationFields.object === "string" ? base64Decode(attestationFields.object) : null;
      if (!keyId || keyId.length !== 32 || !object) throw new HttpError(400, "bad_request");
      attestationInput = { keyId, object };
    } else if (!unattestedLimiter.allow(clientAddress, now())) {
      throw new HttpError(429, "rate_limited");
    }

    if (!(await store.consumeChallenge(challenge, now()))) {
      throw new HttpError(400, "challenge_invalid");
    }

    let appAttestPublicKey: string | undefined;
    if (attestationInput) {
      const clientDataHash = await sha256(utf8(registrationClientData(challenge, apnsToken, environment)));
      const verified = await verifyAttestation({
        attestationObject: attestationInput.object,
        keyId: attestationInput.keyId,
        clientDataHash,
        appId: deps.config.appId,
        trustRoot,
        now: now(),
      });
      if (!verified.ok) {
        log("relay.attestation_rejected", { reason: verified.reason });
        throw new HttpError(401, "attestation_invalid");
      }
      if (verified.value.environment === "development" && environment !== "sandbox") {
        log("relay.attestation_rejected", { reason: "development_for_production" });
        throw new HttpError(401, "attestation_invalid");
      }
      appAttestPublicKey = base64urlEncode(verified.value.publicKeySpki);
    }

    const registrationSecret = base64urlEncode(randomBytes(32));
    const record: RegistrationRecord = {
      id: randomId("r_"),
      secretHash: await secretHash(registrationSecret),
      apnsToken,
      environment: environment as ApnsEnvironment,
      attested: attestationInput !== null,
      ...(appAttestPublicKey ? { appAttestPublicKey, appAttestCounter: 0 } : {}),
      createdAt: now(),
      permissions: [],
      quota: emptyQuota(),
    };
    // Registering again replaces the phone's earlier registration and keeps its counts, so
    // a new registration never brings a fresh daily quota.
    const replacedId = await store.bindApnsToken(apnsToken, record.id);
    if (replacedId) {
      const replaced = await store.getRegistration(replacedId);
      if (replaced) record.quota = replaced.quota;
      await store.deleteRegistration(replacedId);
      log("relay.registration_replaced");
    }
    await store.createRegistration(record);
    log("relay.registered", { attested: record.attested });
    return json(201, {
      registrationId: record.id,
      registrationSecret,
      attested: record.attested,
      limits: {
        pushesPerDay: record.attested
          ? DEFAULT_QUOTA_LIMITS.attestedPerDay
          : DEFAULT_QUOTA_LIMITS.unattestedPerDay,
      },
    });
  }

  /** Registration secret, plus an App Attest assertion for attested registrations. */
  async function authenticateRegistration(
    request: Request,
    registrationId: string,
    path: string,
    body: Uint8Array,
  ): Promise<RegistrationRecord> {
    const secret = bearer(request);
    const record = await store.getRegistration(registrationId);
    if (!record) throw new HttpError(410, "gone");
    if (!hashesEqual(record.secretHash, await secretHash(secret))) {
      throw new HttpError(401, "unauthorized");
    }
    if (!record.attested) return record;

    const assertionHeader = request.headers.get("x-oppi-assertion");
    const assertion = assertionHeader ? base64Decode(assertionHeader) : null;
    const publicKey = record.appAttestPublicKey ? base64urlDecode(record.appAttestPublicKey) : null;
    if (!assertion || !publicKey) throw new HttpError(401, "assertion_invalid");
    const clientDataHash = await sha256(utf8(await requestClientData(request.method, path, body)));
    const verified = await verifyAssertion({
      assertion,
      clientDataHash,
      publicKeySpki: publicKey,
      appId: deps.config.appId,
    });
    if (!verified.ok || !(await store.advanceAssertionCounter(record.id, verified.counter))) {
      log("relay.assertion_rejected", { reason: verified.ok ? "counter" : verified.reason });
      throw new HttpError(401, "assertion_invalid");
    }
    return record;
  }

  async function postPermission(request: Request, registrationId: string, path: string, body: Uint8Array) {
    parseObject(body, []);
    const record = await authenticateRegistration(request, registrationId, path, body);
    const permissionId = randomId("p_");
    const secret = base64urlEncode(randomBytes(32));
    const result = await store.addPermission(record.id, {
      id: permissionId,
      secretHash: await secretHash(secret),
    });
    if (result === "gone") throw new HttpError(410, "gone");
    if (result === "limit") throw new HttpError(409, "too_many_permissions");
    return json(201, { permissionId, sendToken: `osp1.${record.id}.${permissionId}.${secret}` });
  }

  async function postPush(request: Request, body: Uint8Array): Promise<Response> {
    const token = parseSendToken(bearer(request));
    const fields = parseObject(body, ["envelope", "collapseId", "ttl"]);
    const { envelope, collapseId, ttl } = fields;
    if (typeof envelope !== "string") throw new HttpError(400, "bad_request");
    if (collapseId !== undefined && (typeof collapseId !== "string" || !COLLAPSE_ID.test(collapseId))) {
      throw new HttpError(400, "bad_request");
    }
    if (
      ttl !== undefined &&
      (typeof ttl !== "number" || !Number.isInteger(ttl) || ttl < 0 || ttl > MAX_TTL_SECONDS)
    ) {
      throw new HttpError(400, "bad_request");
    }
    // Shape only: exact length and version byte. The relay cannot open the envelope.
    if (envelope.length !== ENVELOPE_BASE64URL_LENGTH) throw new HttpError(413, "envelope_size");
    const envelopeBytes = base64urlDecode(envelope);
    if (!envelopeBytes) throw new HttpError(400, "bad_envelope");
    if (envelopeBytes.length !== ENVELOPE_BYTES) throw new HttpError(413, "envelope_size");
    if (envelopeBytes[0] !== ENVELOPE_VERSION) throw new HttpError(400, "bad_envelope");

    const authorization = await store.authorizePush(
      token.registrationId,
      token.permissionId,
      await secretHash(token.secret),
      now(),
    );
    if (!authorization.ok) {
      if (authorization.reason === "gone") throw new HttpError(410, "gone");
      throw new HttpError(429, "quota_exceeded", {
        "retry-after": String(authorization.retryAfterSeconds),
      });
    }

    const apnsRequest = buildApnsRequest({
      environment: authorization.environment,
      deviceToken: authorization.apnsToken,
      bundleId: deps.config.bundleId,
      envelope,
      ...(typeof collapseId === "string" ? { collapseId } : {}),
      ttlSeconds: typeof ttl === "number" ? ttl : MAX_TTL_SECONDS,
      now: now(),
    });
    let result;
    try {
      result = await deps.apns.send(apnsRequest);
    } catch {
      log("relay.apns_network_error");
      throw new HttpError(502, "apns_unavailable");
    }
    if (result.status === 200) {
      log("relay.push_delivered");
      return json(200, { ok: true });
    }
    log("relay.apns_rejected", { status: result.status, reason: result.reason ?? "" });
    if (isRetiredToken(result)) {
      await store.deleteRegistration(token.registrationId);
      await store.unbindApnsToken(authorization.apnsToken, token.registrationId);
      throw new HttpError(410, "gone");
    }
    throw new HttpError(502, "apns_unavailable");
  }

  async function deletePermissionBySendToken(request: Request): Promise<Response> {
    const token = parseSendToken(bearer(request));
    const record = await store.getRegistration(token.registrationId);
    const permission = record?.permissions.find((entry) => entry.id === token.permissionId);
    if (record && permission && hashesEqual(permission.secretHash, await secretHash(token.secret))) {
      await store.deletePermission(record.id, permission.id);
    }
    return noContent();
  }

  async function route(request: Request, clientAddress: string | null): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    if (path === "/v1/version" && method === "GET") return json(200, { api: 1 });
    if (path === "/v1/challenge" && method === "POST") return postChallenge(clientAddress);
    if (path === "/v1/registrations" && method === "POST") {
      return postRegistration(await readBody(request), clientAddress);
    }
    if (path === "/v1/push" && method === "POST") return postPush(request, await readBody(request));
    if (path === "/v1/permission" && method === "DELETE") return deletePermissionBySendToken(request);

    const permissionMatch = /^\/v1\/registrations\/([^/]+)\/permissions(?:\/([^/]+))?$/.exec(path);
    if (permissionMatch) {
      const [, registrationId = "", permissionId] = permissionMatch;
      if (!REGISTRATION_ID.test(registrationId)) throw new HttpError(410, "gone");
      const body = await readBody(request);
      if (!permissionId && method === "POST") {
        return postPermission(request, registrationId, path, body);
      }
      if (permissionId && method === "DELETE") {
        await authenticateRegistration(request, registrationId, path, body);
        await store.deletePermission(registrationId, permissionId);
        return noContent();
      }
      throw new HttpError(405, "method_not_allowed");
    }

    const registrationMatch = /^\/v1\/registrations\/([^/]+)$/.exec(path);
    if (registrationMatch && method === "DELETE") {
      const registrationId = registrationMatch[1] ?? "";
      if (!REGISTRATION_ID.test(registrationId)) throw new HttpError(410, "gone");
      const record = await authenticateRegistration(
        request,
        registrationId,
        path,
        await readBody(request),
      );
      await store.deleteRegistration(registrationId);
      await store.unbindApnsToken(record.apnsToken, registrationId);
      return noContent();
    }
    throw new HttpError(404, "not_found");
  }

  return async (request, clientAddress) => {
    try {
      return await route(request, clientAddress);
    } catch (error) {
      if (error instanceof HttpError) return json(error.status, { error: error.code }, error.headers);
      log("relay.internal_error");
      return json(500, { error: "internal" });
    }
  };
}
