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

export class ApnsProviderToken {
  private cached: { token: string; issuedAt: number } | null = null;
  private keyPromise: Promise<CryptoKey> | null = null;

  constructor(
    private readonly credentials: ApnsCredentials,
    private readonly now: () => number = Date.now,
  ) {}

  async get(): Promise<string> {
    const now = this.now();
    if (this.cached && now - this.cached.issuedAt < PROVIDER_TOKEN_REFRESH_MS) {
      return this.cached.token;
    }
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
    const token = `${signingInput}.${base64urlEncode(signature)}`;
    this.cached = { token, issuedAt: now };
    return token;
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
