/**
 * What the relay stores (protocol/push/spec.md §3.4) and the atomic operations adapters
 * provide. Node keeps records in memory; Cloudflare keeps one Durable Object per
 * registration. Every method is atomic for its registration.
 */

import { hashesEqual } from "./bytes.js";

export type ApnsEnvironment = "sandbox" | "production";

export interface PermissionRecord {
  id: string;
  /** base64url SHA-256 of the send token's secret part. */
  secretHash: string;
}

export interface QuotaState {
  /** UTC day `YYYY-MM-DD` the daily count belongs to. */
  day: string;
  dayCount: number;
  /** Start (ms) of the current one-minute window. */
  minuteStart: number;
  minuteCount: number;
}

export interface RegistrationRecord {
  id: string;
  secretHash: string;
  apnsToken: string;
  environment: ApnsEnvironment;
  attested: boolean;
  /** base64url DER SubjectPublicKeyInfo of the App Attest key, when attested. */
  appAttestPublicKey?: string;
  appAttestCounter?: number;
  createdAt: number;
  permissions: PermissionRecord[];
  quota: QuotaState;
}

export interface QuotaLimits {
  attestedPerDay: number;
  unattestedPerDay: number;
  perMinute: number;
}

/**
 * Sized for normal use within the Workers Free plan: each push costs one Worker request, one
 * Durable Object request, and one row written (100,000 a day each). 1,000 phones at the daily
 * cap use them all; normal use is a few dozen a day. An Oppi server keeps its own per-device
 * budget at or below these. Unattested registrations exist only in sandbox (development builds,
 * Simulator, and health probes), so they get just enough for testing.
 */
export const DEFAULT_QUOTA_LIMITS: QuotaLimits = {
  attestedPerDay: 100,
  unattestedPerDay: 20,
  perMinute: 10,
};

export const MAX_PERMISSIONS_PER_REGISTRATION = 16;

export type PushAuthorization =
  | { ok: true; apnsToken: string; environment: ApnsEnvironment }
  | { ok: false; reason: "gone" }
  | { ok: false; reason: "quota"; retryAfterSeconds: number };

export type AddPermissionResult = "ok" | "limit" | "gone";

export interface RelayStore {
  putChallenge(challenge: string, expiresAt: number): Promise<void>;
  /** True only the first time, before expiry; the challenge is gone afterwards. */
  consumeChallenge(challenge: string, now: number): Promise<boolean>;
  createRegistration(record: RegistrationRecord): Promise<void>;
  /**
   * Make `registrationId` the only registration for `apnsToken` and return the one it
   * replaces, if any. One phone holds one registration, so it holds one quota.
   */
  bindApnsToken(apnsToken: string, registrationId: string): Promise<string | null>;
  /** Forget the token's binding when it still names `registrationId`. */
  unbindApnsToken(apnsToken: string, registrationId: string): Promise<void>;
  getRegistration(id: string): Promise<RegistrationRecord | null>;
  deleteRegistration(id: string): Promise<void>;
  /** Store `counter` only when it exceeds the stored App Attest counter. */
  advanceAssertionCounter(id: string, counter: number): Promise<boolean>;
  addPermission(id: string, permission: PermissionRecord): Promise<AddPermissionResult>;
  deletePermission(id: string, permissionId: string): Promise<void>;
  /** Check the permission's secret and charge one push to the registration's quota. */
  authorizePush(
    id: string,
    permissionId: string,
    secretHash: string,
    now: number,
  ): Promise<PushAuthorization>;
}

export function emptyQuota(): QuotaState {
  return { day: "", dayCount: 0, minuteStart: 0, minuteCount: 0 };
}

// ─── Pure rules both stores apply inside their atomic sections ───

export function applyAssertionCounter(record: RegistrationRecord, counter: number): boolean {
  if (!record.attested || counter <= (record.appAttestCounter ?? 0)) return false;
  record.appAttestCounter = counter;
  return true;
}

export function applyAddPermission(
  record: RegistrationRecord,
  permission: PermissionRecord,
): AddPermissionResult {
  if (record.permissions.length >= MAX_PERMISSIONS_PER_REGISTRATION) return "limit";
  record.permissions.push(permission);
  return "ok";
}

export function applyDeletePermission(record: RegistrationRecord, permissionId: string): void {
  record.permissions = record.permissions.filter((entry) => entry.id !== permissionId);
}

export function applyAuthorizePush(
  record: RegistrationRecord,
  permissionId: string,
  secretHash: string,
  now: number,
  limits: QuotaLimits = DEFAULT_QUOTA_LIMITS,
): PushAuthorization {
  const permission = record.permissions.find((entry) => entry.id === permissionId);
  if (!permission || !hashesEqual(permission.secretHash, secretHash)) {
    return { ok: false, reason: "gone" };
  }
  const day = new Date(now).toISOString().slice(0, 10);
  const quota = record.quota;
  if (quota.day !== day) {
    quota.day = day;
    quota.dayCount = 0;
  }
  if (now - quota.minuteStart >= 60_000) {
    quota.minuteStart = now;
    quota.minuteCount = 0;
  }
  const dailyLimit = record.attested ? limits.attestedPerDay : limits.unattestedPerDay;
  if (quota.dayCount >= dailyLimit) {
    const nextDay = Date.parse(`${day}T00:00:00Z`) + 86_400_000;
    return { ok: false, reason: "quota", retryAfterSeconds: Math.ceil((nextDay - now) / 1000) };
  }
  if (quota.minuteCount >= limits.perMinute) {
    return {
      ok: false,
      reason: "quota",
      retryAfterSeconds: Math.max(1, Math.ceil((quota.minuteStart + 60_000 - now) / 1000)),
    };
  }
  quota.dayCount += 1;
  quota.minuteCount += 1;
  return { ok: true, apnsToken: record.apnsToken, environment: record.environment };
}
