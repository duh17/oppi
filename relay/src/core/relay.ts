/**
 * Relay API v1 (protocol/push/spec.md §3), adapter-agnostic: a WHATWG `Request` in, a
 * `Response` out. The relay checks envelope size and version and never opens one; it holds
 * no decryption code. Live Activity pushes (spec §3.6) carry two validated counts in a fixed
 * template and nothing else.
 */

import { APPLE_APP_ATTESTATION_ROOT_CA_PEM } from "./apple-app-attestation-root.js";
import { verifyAssertion, verifyAttestation } from "./app-attest.js";
import {
  buildApnsRequest,
  buildLiveActivityRequest,
  isRetiredToken,
  type ApnsSender,
} from "./apns.js";
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
  MAX_PERMISSIONS_PER_REGISTRATION,
  type ApnsEnvironment,
  type LiveActivityEvent,
  type LiveActivityUpdate,
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
/** Pushes one client address may send a minute, before any send token is looked up. */
export const PUSHES_PER_ADDRESS_PER_MINUTE = 60;

const REGISTRATION_ID = /^r_[A-Za-z0-9_-]{22}$/;
const PERMISSION_ID = /^p_[A-Za-z0-9_-]{22}$/;
const SECRET = /^[A-Za-z0-9_-]{43}$/;
const APNS_TOKEN = /^[0-9a-f]{64,200}$/;
const COLLAPSE_ID = /^[A-Za-z0-9_-]{22}$/;
const LIVE_ACTIVITY_SLOT = /^[A-Za-z0-9_-]{22}$/;
/** Live Activity counts are top-level sessions; more than this shows as this. */
export const LIVE_ACTIVITY_MAX_COUNT = 99;

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

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const IPV6_GROUP = /^[0-9a-f]{1,4}$/i;

function parseIpv4(text: string): number[] | null {
  const match = IPV4.exec(text);
  if (!match) return null;
  const octets = match.slice(1).map(Number);
  return octets.every((octet) => octet <= 255) ? octets : null;
}

/** The eight 16-bit groups of an IPv6 address (zone id dropped), or null. */
function parseIpv6(text: string): number[] | null {
  let address = text.split("%")[0] ?? "";
  if (!address.includes(":")) return null;
  // A dotted IPv4 tail (`::ffff:192.0.2.1`) is the last two groups.
  const lastColon = address.lastIndexOf(":");
  const tail = address.slice(lastColon + 1);
  if (tail.includes(".")) {
    const octets = parseIpv4(tail);
    if (!octets) return null;
    const [a = 0, b = 0, c = 0, d = 0] = octets;
    address = `${address.slice(0, lastColon + 1)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const halves = address.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return null;
  const groups = [...head, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...rest];
  if (!groups.every((group) => IPV6_GROUP.test(group))) return null;
  return groups.map((group) => parseInt(group, 16));
}

/**
 * What a client address counts as for rate limits. An IPv6 address counts as its /64: one
 * subscriber usually holds a whole /64, so keying on the full address would let it pick a
 * new address per request. IPv4 (also IPv4-mapped IPv6) counts as itself; anything else
 * unparsed, as its text.
 */
export function addressLimitKey(address: string | null): string {
  if (!address) return "unknown";
  const groups = parseIpv6(address);
  if (!groups) return address;
  if (groups.slice(0, 5).every((group) => group === 0) && groups[5] === 0xffff) {
    const [high = 0, low = 0] = groups.slice(6);
    return `${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`;
  }
  return `${groups.slice(0, 4).map((group) => group.toString(16)).join(":")}::/64`;
}

/** In-memory fixed-window counter per client address (`addressLimitKey`). Nothing is persisted. */
class AddressLimiter {
  private readonly hits = new Map<string, { windowStart: number; count: number }>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
  ) {}

  allow(address: string | null, now: number): boolean {
    const key = addressLimitKey(address);
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

/**
 * Cloudflare's Workers Free plan refuses Durable Object work for the rest of the UTC day once
 * the account has used one of its daily allowances (requests, rows read, rows written,
 * duration), throwing these messages from the stub or storage call. Only these mean "until
 * 00:00 UTC"; any other storage error (the 5 GB storage cap included) is not a daily limit.
 */
const DAILY_LIMIT_ERROR =
  /Exceeded allowed (?:volume of requests|rows read|rows written|duration) in Durable Objects free tier/;

function isDailyLimitError(error: unknown): boolean {
  return DAILY_LIMIT_ERROR.test(error instanceof Error ? error.message : String(error));
}

function secondsToNextUtcDay(now: number): number {
  const nextDay = Math.floor(now / 86_400_000) * 86_400_000 + 86_400_000;
  return Math.max(1, Math.ceil((nextDay - now) / 1000));
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

/** A nested object whose keys must all be present and known. */
function parseEntry(entry: unknown, keys: readonly string[]): Record<string, unknown> {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    throw new HttpError(400, "bad_request");
  }
  for (const key of Object.keys(entry)) {
    if (!keys.includes(key)) throw new HttpError(400, "unknown_field");
  }
  const fields = entry as Record<string, unknown>;
  if (keys.some((key) => !(key in fields))) throw new HttpError(400, "bad_request");
  return fields;
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
  // Checked before the send token reaches storage, so a flood of made-up tokens from one
  // address stops costing Durable Object requests. Per isolate, so it only raises the bar;
  // a server pushing to a handful of phones stays far below it.
  const pushLimiter = new AddressLimiter(PUSHES_PER_ADDRESS_PER_MINUTE, 60_000);
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
    // Anyone who learns a phone's APNs token can register it unattested in sandbox. That must
    // not delete the phone's attested registration and cut off its pushes.
    if (!record.attested) {
      const holderId = await store.apnsTokenRegistration(apnsToken);
      if (holderId && (await store.getRegistration(holderId))?.attested) {
        log("relay.registration_refused", { reason: "attested_holder" });
        throw new HttpError(409, "registration_conflict");
      }
    }
    // Registering again replaces the phone's earlier registration and keeps its counts, so
    // a new registration never brings a fresh daily quota.
    const replacedId = await store.bindApnsToken(apnsToken, record.id);
    if (replacedId) {
      const replaced = await store.getRegistration(replacedId);
      if (replaced) {
        record.quota = replaced.quota;
        if (replaced.liveActivityQuota) record.liveActivityQuota = replaced.liveActivityQuota;
        if (replaced.liveActivityTimestamp !== undefined) {
          record.liveActivityTimestamp = replaced.liveActivityTimestamp;
        }
      }
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

  /**
   * Registration secret, plus a valid App Attest assertion for attested registrations. The
   * assertion's counter is not yet checked against the stored one: the caller does that in
   * the same storage call as its write.
   */
  async function verifyRegistration(
    request: Request,
    registrationId: string,
    path: string,
    body: Uint8Array,
  ): Promise<{ record: RegistrationRecord; counter: number | null }> {
    const secret = bearer(request);
    const record = await store.getRegistration(registrationId);
    if (!record) throw new HttpError(410, "gone");
    if (!hashesEqual(record.secretHash, await secretHash(secret))) {
      throw new HttpError(401, "unauthorized");
    }
    if (!record.attested) return { record, counter: null };

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
    if (!verified.ok) {
      log("relay.assertion_rejected", { reason: verified.reason });
      throw new HttpError(401, "assertion_invalid");
    }
    return { record, counter: verified.counter };
  }

  /** `verifyRegistration`, and the assertion's counter exceeds every earlier one. */
  async function authenticateRegistration(
    request: Request,
    registrationId: string,
    path: string,
    body: Uint8Array,
  ): Promise<RegistrationRecord> {
    const { record, counter } = await verifyRegistration(request, registrationId, path, body);
    if (counter !== null && !(await store.advanceAssertionCounter(record.id, counter))) {
      log("relay.assertion_rejected", { reason: "counter" });
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

  async function postPush(
    request: Request,
    body: Uint8Array,
    clientAddress: string | null,
  ): Promise<Response> {
    if (!pushLimiter.allow(clientAddress, now())) {
      throw new HttpError(429, "rate_limited", { "retry-after": "60" });
    }
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

  /**
   * The phone's whole Live Activity state; replaces what the relay held. Each entry names the
   * permission that may drive that server's card, so the phone alone decides which servers
   * can: a server it leaves out gets `409 no_activity`. On an attested registration the
   * assertion counter is checked in the write itself, so an older upload that arrives after
   * a newer one is refused instead of replacing it.
   */
  async function putLiveActivity(
    request: Request,
    registrationId: string,
    path: string,
    body: Uint8Array,
  ): Promise<Response> {
    const { startToken, activities } = parseObject(body, ["startToken", "activities"]);
    if (
      (startToken !== null && (typeof startToken !== "string" || !APNS_TOKEN.test(startToken))) ||
      !Array.isArray(activities) ||
      activities.length > MAX_PERMISSIONS_PER_REGISTRATION
    ) {
      throw new HttpError(400, "bad_request");
    }
    const parsed: LiveActivityUpdate["activities"] = [];
    for (const entry of activities as unknown[]) {
      const { permissionId, slot, token, dismissed } = parseEntry(entry, [
        "permissionId",
        "slot",
        "token",
        "dismissed",
      ]);
      if (
        typeof permissionId !== "string" ||
        !PERMISSION_ID.test(permissionId) ||
        typeof slot !== "string" ||
        !LIVE_ACTIVITY_SLOT.test(slot) ||
        (token !== null && (typeof token !== "string" || !APNS_TOKEN.test(token))) ||
        typeof dismissed !== "boolean" ||
        // A dismissed card is gone from the phone, so it has no update token.
        (dismissed && token !== null) ||
        parsed.some((item) => item.slot === slot || item.permissionId === permissionId)
      ) {
        throw new HttpError(400, "bad_request");
      }
      parsed.push({ permissionId, slot, token, dismissed });
    }
    const { record, counter } = await verifyRegistration(request, registrationId, path, body);
    const update = { startToken, activities: parsed };
    const result = await store.setLiveActivity(record.id, update, counter, now());
    if (result === "gone") throw new HttpError(410, "gone");
    if (result === "stale") {
      log("relay.assertion_rejected", { reason: "counter" });
      throw new HttpError(401, "assertion_invalid");
    }
    return noContent();
  }

  /** A server's Live Activity push: the fixed schema below, nothing caller-written reaches APNs. */
  async function postLiveActivity(
    request: Request,
    body: Uint8Array,
    clientAddress: string | null,
  ): Promise<Response> {
    // Shares the push limit: both look up a send token, so both feed a junk-token flood.
    if (!pushLimiter.allow(clientAddress, now())) {
      throw new HttpError(429, "rate_limited", { "retry-after": "60" });
    }
    const token = parseSendToken(bearer(request));
    const { event, running, needsYou } = parseObject(body, ["event", "running", "needsYou"]);
    const isCount = (value: unknown): value is number =>
      typeof value === "number" &&
      Number.isInteger(value) &&
      value >= 0 &&
      value <= LIVE_ACTIVITY_MAX_COUNT;
    if (
      (event !== "start" && event !== "update" && event !== "end") ||
      !isCount(running) ||
      !isCount(needsYou) ||
      // Nothing running or waiting is an end, and an end shows nothing running or waiting.
      (event === "end") !== (running + needsYou === 0)
    ) {
      throw new HttpError(400, "bad_request");
    }

    const authorization = await store.authorizeLiveActivity(
      token.registrationId,
      token.permissionId,
      await secretHash(token.secret),
      event as LiveActivityEvent,
      now(),
    );
    if (!authorization.ok) {
      if (authorization.reason === "gone") throw new HttpError(410, "gone");
      if (authorization.reason === "no_activity") throw new HttpError(409, "no_activity");
      throw new HttpError(429, "quota_exceeded", {
        "retry-after": String(authorization.retryAfterSeconds),
      });
    }

    const apnsRequest = buildLiveActivityRequest({
      environment: authorization.environment,
      token: authorization.token,
      bundleId: deps.config.bundleId,
      event: event as LiveActivityEvent,
      running,
      needsYou,
      timestamp: authorization.timestamp,
      slot: authorization.slot,
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
      // The ended activity takes no more updates.
      if (event === "end") {
        await store.clearLiveActivityToken(token.registrationId, authorization.target, authorization.token);
      }
      // The new card brings its own update token; the one held before belongs to the card the
      // server just ended. Until APNs accepts the start, that card can still be ended.
      if (event === "start" && authorization.replacedToken) {
        await store.clearLiveActivityToken(
          token.registrationId,
          { kind: "activity", slot: authorization.slot },
          authorization.replacedToken,
        );
      }
      log("relay.live_activity_delivered", { event: event as string });
      return json(200, { ok: true });
    }
    log("relay.apns_rejected", { status: result.status, reason: result.reason ?? "" });
    if (isRetiredToken(result)) {
      // Only this Live Activity token is dead; the phone's alert registration still works.
      await store.clearLiveActivityToken(token.registrationId, authorization.target, authorization.token);
      throw new HttpError(409, "no_activity");
    }
    throw new HttpError(502, "apns_unavailable");
  }

  async function deletePermissionBySendToken(
    request: Request,
    clientAddress: string | null,
  ): Promise<Response> {
    // Looks up a send token too, so it shares the push limit.
    if (!pushLimiter.allow(clientAddress, now())) {
      throw new HttpError(429, "rate_limited", { "retry-after": "60" });
    }
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
    if (path === "/v1/push" && method === "POST") {
      return postPush(request, await readBody(request), clientAddress);
    }
    if (path === "/v1/live-activity" && method === "POST") {
      return postLiveActivity(request, await readBody(request), clientAddress);
    }
    if (path === "/v1/permission" && method === "DELETE") {
      return deletePermissionBySendToken(request, clientAddress);
    }

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

    const liveActivityMatch = /^\/v1\/registrations\/([^/]+)\/live-activity$/.exec(path);
    if (liveActivityMatch) {
      const registrationId = liveActivityMatch[1] ?? "";
      if (!REGISTRATION_ID.test(registrationId)) throw new HttpError(410, "gone");
      if (method !== "PUT") throw new HttpError(405, "method_not_allowed");
      return putLiveActivity(request, registrationId, path, await readBody(request));
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
      // Servers pause pushes to this relay until Retry-After passes, so only a daily limit
      // that really lasts until 00:00 UTC says so.
      if (isDailyLimitError(error)) {
        log("relay.capacity_exhausted");
        return json(503, { error: "relay_capacity" }, { "retry-after": String(secondsToNextUtcDay(now())) });
      }
      log("relay.internal_error");
      return json(500, { error: "internal" });
    }
  };
}
