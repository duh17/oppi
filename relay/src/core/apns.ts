/**
 * The only APNs request the relay makes (protocol/push/spec.md §3.5): a fixed alert template
 * around the sealed envelope. Callers choose no APNs headers or payload fields.
 */

import { base64urlEncode, utf8 } from "./bytes.js";
import type { ApnsEnvironment } from "./store.js";

export const APNS_ORIGINS: Record<ApnsEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

/** Shown when the phone cannot decrypt; the Notification Service Extension uses the same text. */
export const FALLBACK_ALERT = { title: "Oppi", body: "You have a new notification." } as const;

export interface ApnsRequest {
  environment: ApnsEnvironment;
  deviceToken: string;
  /** `apns-*` headers; the sender adds authorization. */
  headers: Record<string, string>;
  payload: string;
}

export interface ApnsResult {
  status: number;
  reason?: string;
}

/** Sends one request. Throws on network failure. */
export interface ApnsSender {
  send(request: ApnsRequest): Promise<ApnsResult>;
}

export function buildApnsRequest(input: {
  environment: ApnsEnvironment;
  deviceToken: string;
  bundleId: string;
  envelope: string;
  collapseId?: string;
  ttlSeconds: number;
  now: number;
}): ApnsRequest {
  const headers: Record<string, string> = {
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-topic": input.bundleId,
    "apns-expiration": String(Math.floor(input.now / 1000) + input.ttlSeconds),
  };
  if (input.collapseId) headers["apns-collapse-id"] = input.collapseId;
  const payload = JSON.stringify({
    aps: { alert: FALLBACK_ALERT, "mutable-content": 1 },
    e: input.envelope,
  });
  return { environment: input.environment, deviceToken: input.deviceToken, headers, payload };
}

// ─── Live Activity (spec §3.6) ───

/** The app's `ActivityAttributes` type; ActivityKit decodes `attributes` with it. */
export const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "OppiActivityAttributes";
/** Apple requires an alert to start a Live Activity by push. Fixed text, like the fallback. */
export const LIVE_ACTIVITY_START_ALERT = { title: "Oppi", body: "Agents are working." } as const;
/** An ended card leaves the Lock Screen this long after the event's timestamp. */
export const LIVE_ACTIVITY_DISMISSAL_SECONDS = 30;
const LIVE_ACTIVITY_TTL_SECONDS = 3600;

/**
 * The only Live Activity request the relay makes: two validated counts in a fixed template.
 * Routine updates go at priority 5 so they do not spend the phone's ActivityKit budget;
 * start and end go at 10.
 */
export function buildLiveActivityRequest(input: {
  environment: ApnsEnvironment;
  token: string;
  bundleId: string;
  event: "start" | "update" | "end";
  running: number;
  needsYou: number;
  /** Unix seconds, later than the slot's previous event (`applyAuthorizeLiveActivity`). */
  timestamp: number;
  slot: string;
  now: number;
}): ApnsRequest {
  const headers: Record<string, string> = {
    "apns-push-type": "liveactivity",
    "apns-priority": input.event === "update" ? "5" : "10",
    "apns-topic": `${input.bundleId}.push-type.liveactivity`,
    "apns-expiration": String(Math.floor(input.now / 1000) + LIVE_ACTIVITY_TTL_SECONDS),
  };
  const contentState = { running: input.running, needsYou: input.needsYou };
  let aps: Record<string, unknown>;
  switch (input.event) {
    case "start":
      aps = {
        timestamp: input.timestamp,
        event: "start",
        "content-state": contentState,
        "attributes-type": LIVE_ACTIVITY_ATTRIBUTES_TYPE,
        attributes: { slot: input.slot },
        // Ask iOS for the new activity's update token (iOS 18 and later).
        "input-push-token": 1,
        alert: LIVE_ACTIVITY_START_ALERT,
      };
      break;
    case "update":
      aps = { timestamp: input.timestamp, event: "update", "content-state": contentState };
      break;
    case "end":
      aps = {
        timestamp: input.timestamp,
        event: "end",
        "content-state": contentState,
        "dismissal-date": input.timestamp + LIVE_ACTIVITY_DISMISSAL_SECONDS,
      };
      break;
  }
  return {
    environment: input.environment,
    deviceToken: input.token,
    headers,
    payload: JSON.stringify({ aps }),
  };
}

/** APNs answers that mean the token will never work again: the relay forgets it. */
export function isRetiredToken(result: ApnsResult): boolean {
  if (result.status === 410) return true;
  return (
    result.status === 400 &&
    (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic")
  );
}

// ─── Provider token (ES256 JWT) ───

/** APNs accepts a provider token for an hour; refreshing at 50 minutes stays inside it. */
const PROVIDER_TOKEN_REFRESH_MS = 50 * 60 * 1000;

export interface ApnsCredentials {
  /** Contents of the `.p8` key file (PKCS #8 PEM). */
  keyP8: string;
  keyId: string;
  teamId: string;
}

interface CachedProviderToken {
  token: Promise<string>;
  issuedAt: number;
  /** Set once signed. */
  value?: string;
}

/** APNs `403` reasons a newly signed provider token can cure. */
const REFUSED_PROVIDER_TOKEN = new Set(["ExpiredProviderToken", "InvalidProviderToken"]);

export class ApnsProviderToken {
  /**
   * The token being signed or signed already. Holding the promise, not the result, makes
   * concurrent misses share one signature: APNs refuses provider tokens that change too often
   * (`TooManyProviderTokenUpdates`).
   */
  private cached: CachedProviderToken | null = null;
  private keyPromise: Promise<CryptoKey> | null = null;

  constructor(
    private readonly credentials: ApnsCredentials,
    private readonly now: () => number = Date.now,
  ) {}

  get(): Promise<string> {
    const now = this.now();
    if (this.cached && now - this.cached.issuedAt < PROVIDER_TOKEN_REFRESH_MS) {
      return this.cached.token;
    }
    const entry: CachedProviderToken = { token: this.sign(now), issuedAt: now };
    this.cached = entry;
    entry.token.then(
      (value) => {
        entry.value = value;
      },
      () => {
        if (this.cached === entry) this.cached = null;
      },
    );
    return entry.token;
  }

  /**
   * After APNs answered a request signed with `token`: an expired or invalid provider token is
   * dropped so the next request signs a new one. Only while it is still the current token, so
   * a late answer to an older one keeps a newer token.
   */
  forgetIfRefused(token: string, result: ApnsResult): void {
    if (result.status !== 403 || !REFUSED_PROVIDER_TOKEN.has(result.reason ?? "")) return;
    if (this.cached?.value === token) this.cached = null;
  }

  private async sign(now: number): Promise<string> {
    this.keyPromise ??= importP8(this.credentials.keyP8);
    const key = await this.keyPromise;
    const header = base64urlEncode(utf8(JSON.stringify({ alg: "ES256", kid: this.credentials.keyId })));
    const claims = base64urlEncode(
      utf8(JSON.stringify({ iss: this.credentials.teamId, iat: Math.floor(now / 1000) })),
    );
    const signingInput = `${header}.${claims}`;
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        utf8(signingInput) as BufferSource,
      ),
    );
    return `${signingInput}.${base64urlEncode(signature)}`;
  }
}

async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) der[index] = binary.charCodeAt(index);
  return crypto.subtle.importKey(
    "pkcs8",
    der as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}
