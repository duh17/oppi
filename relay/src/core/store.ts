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
  /**
   * The phone's random name for this server's Live Activity (22 base64url characters). It
   * names the activity a `start` creates and keys its update token, and survives the phone
   * minting a new permission for the same server.
   */
  liveActivitySlot?: string;
}

/** Update token of one live activity on the phone. */
export interface LiveActivityTokenRecord {
  slot: string;
  /** Lowercase hex ActivityKit push token. */
  token: string;
  /** When the relay first saw this token for this slot: the activity's start, near enough. */
  tokenAt: number;
}

/**
 * A slot whose card the person dismissed. `start` stays refused for it until a server sends
 * `end` for the slot (its counts reached zero), which sets `ended`. The entry lasts while the
 * phone keeps listing the slot, so a stale listing cannot dismiss it again.
 */
export interface LiveActivityDismissalRecord {
  slot: string;
  ended: boolean;
}

/** The phone's Live Activity tokens. */
export interface LiveActivityState {
  /** ActivityKit push-to-start token, lowercase hex. */
  startToken?: string;
  activities: LiveActivityTokenRecord[];
  /** Absent when no card is dismissed. */
  dismissed?: LiveActivityDismissalRecord[];
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
  /** Absent until the phone first sends its Live Activity tokens. */
  liveActivity?: LiveActivityState;
  /** Live Activity pushes, counted apart from alerts. Absent until the first one. */
  liveActivityQuota?: QuotaState;
}

export interface QuotaLimits {
  attestedPerDay: number;
  unattestedPerDay: number;
  perMinute: number;
  /** Live Activity pushes per registration and UTC day, separate from alerts. */
  liveActivityAttestedPerDay: number;
  liveActivityUnattestedPerDay: number;
  liveActivityPerMinute: number;
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
  // A server sends at most one Live Activity push a minute per phone, plus a restart.
  liveActivityAttestedPerDay: 40,
  liveActivityUnattestedPerDay: 20,
  liveActivityPerMinute: 3,
};

export const MAX_PERMISSIONS_PER_REGISTRATION = 16;
/** Apple ends a Live Activity after 8 hours; its update token is useless after that. */
export const LIVE_ACTIVITY_MAX_AGE_MS = 8 * 60 * 60 * 1000;

export type LiveActivityEvent = "start" | "update" | "end";

/** The phone's whole Live Activity state, as `PUT .../live-activity` sends it. */
export interface LiveActivityUpdate {
  startToken: string | null;
  activities: Array<{ slot: string; token: string }>;
  /** Slots whose card the person dismissed and that have no card since. */
  dismissed: string[];
}

/** Which token a Live Activity push goes to: the phone's start token or one slot's activity. */
export type LiveActivityTarget = { kind: "start" } | { kind: "activity"; slot: string };

export type LiveActivityAuthorization =
  | {
      ok: true;
      token: string;
      target: LiveActivityTarget;
      slot: string;
      environment: ApnsEnvironment;
      /**
       * For `start`: the slot's update token when it was authorized. The relay forgets it only
       * once APNs accepts the start, and only while it is still this token.
       */
      replacedToken?: string;
    }
  | { ok: false; reason: "gone" }
  | { ok: false; reason: "no_activity" }
  | { ok: false; reason: "quota"; retryAfterSeconds: number };

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
  /** Replace the phone's Live Activity tokens. False when the registration is gone. */
  setLiveActivity(
    id: string,
    update: LiveActivityUpdate,
    now: number,
  ): Promise<boolean>;
  /**
   * Check the permission's secret, find the token the event goes to, and charge one Live
   * Activity push. An `end` also ends the slot's dismissal, even when there is no token.
   */
  authorizeLiveActivity(
    id: string,
    permissionId: string,
    secretHash: string,
    event: LiveActivityEvent,
    now: number,
  ): Promise<LiveActivityAuthorization>;
  /** Forget a Live Activity token, only while it is still `token`. */
  clearLiveActivityToken(id: string, target: LiveActivityTarget, token: string): Promise<void>;
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
  const dailyLimit = record.attested ? limits.attestedPerDay : limits.unattestedPerDay;
  const charged = chargeQuota(record.quota, now, dailyLimit, limits.perMinute);
  if (!charged.ok) return charged;
  return { ok: true, apnsToken: record.apnsToken, environment: record.environment };
}

/** Count one push against `quota`, or say when the next one fits. */
function chargeQuota(
  quota: QuotaState,
  now: number,
  perDay: number,
  perMinute: number,
): { ok: true } | { ok: false; reason: "quota"; retryAfterSeconds: number } {
  const day = new Date(now).toISOString().slice(0, 10);
  if (quota.day !== day) {
    quota.day = day;
    quota.dayCount = 0;
  }
  if (now - quota.minuteStart >= 60_000) {
    quota.minuteStart = now;
    quota.minuteCount = 0;
  }
  if (quota.dayCount >= perDay) {
    const nextDay = Date.parse(`${day}T00:00:00Z`) + 86_400_000;
    return { ok: false, reason: "quota", retryAfterSeconds: Math.ceil((nextDay - now) / 1000) };
  }
  if (quota.minuteCount >= perMinute) {
    return {
      ok: false,
      reason: "quota",
      retryAfterSeconds: Math.max(1, Math.ceil((quota.minuteStart + 60_000 - now) / 1000)),
    };
  }
  quota.dayCount += 1;
  quota.minuteCount += 1;
  return { ok: true };
}

export function applySetLiveActivity(
  record: RegistrationRecord,
  update: LiveActivityUpdate,
  now: number,
): void {
  const previous = record.liveActivity;
  const dismissed = update.dismissed.map(
    (slot) => previous?.dismissed?.find((entry) => entry.slot === slot) ?? { slot, ended: false },
  );
  record.liveActivity = {
    ...(update.startToken ? { startToken: update.startToken } : {}),
    activities: update.activities.map(({ slot, token }) => {
      const kept = previous?.activities.find((entry) => entry.slot === slot && entry.token === token);
      return { slot, token, tokenAt: kept?.tokenAt ?? now };
    }),
    ...(dismissed.length > 0 ? { dismissed } : {}),
  };
}

/**
 * `changed`: the record changed even though the push was refused (an `end` ended a
 * dismissal), so the store must save it.
 */
export function applyAuthorizeLiveActivity(
  record: RegistrationRecord,
  permissionId: string,
  secretHash: string,
  event: LiveActivityEvent,
  now: number,
  limits: QuotaLimits = DEFAULT_QUOTA_LIMITS,
): { authorization: LiveActivityAuthorization; changed: boolean } {
  const permission = record.permissions.find((entry) => entry.id === permissionId);
  if (!permission || !hashesEqual(permission.secretHash, secretHash)) {
    return { authorization: { ok: false, reason: "gone" }, changed: false };
  }
  const slot = permission.liveActivitySlot;
  const state = record.liveActivity;
  if (!slot || !state) return { authorization: { ok: false, reason: "no_activity" }, changed: false };

  // The work the dismissed card counted is over; the next work may show a card again.
  const dismissal = state.dismissed?.find((entry) => entry.slot === slot);
  let changed = false;
  if (event === "end" && dismissal && !dismissal.ended) {
    dismissal.ended = true;
    changed = true;
  }

  let token: string | undefined;
  let target: LiveActivityTarget;
  let replacedToken: string | undefined;
  if (event === "start") {
    // The person dismissed this server's card: no new one until its counts reach zero.
    if (!dismissal || dismissal.ended) token = state.startToken;
    target = { kind: "start" };
    replacedToken = state.activities.find((entry) => entry.slot === slot)?.token;
  } else {
    const activity = state.activities.find((entry) => entry.slot === slot);
    // Apple has ended an activity this old; an update would land nowhere. An `end` still
    // goes, to take the ended card off the Lock Screen.
    if (activity && (event === "end" || now - activity.tokenAt < LIVE_ACTIVITY_MAX_AGE_MS)) {
      token = activity.token;
    }
    target = { kind: "activity", slot };
  }
  if (!token) return { authorization: { ok: false, reason: "no_activity" }, changed };

  record.liveActivityQuota ??= emptyQuota();
  const charged = chargeQuota(
    record.liveActivityQuota,
    now,
    record.attested ? limits.liveActivityAttestedPerDay : limits.liveActivityUnattestedPerDay,
    limits.liveActivityPerMinute,
  );
  if (!charged.ok) return { authorization: charged, changed };
  return {
    authorization: {
      ok: true,
      token,
      target,
      slot,
      environment: record.environment,
      ...(replacedToken ? { replacedToken } : {}),
    },
    changed: true,
  };
}

export function applyClearLiveActivityToken(
  record: RegistrationRecord,
  target: LiveActivityTarget,
  token: string,
): boolean {
  const state = record.liveActivity;
  if (!state) return false;
  if (target.kind === "start") {
    if (state.startToken !== token) return false;
    delete state.startToken;
    return true;
  }
  const before = state.activities.length;
  state.activities = state.activities.filter(
    (entry) => entry.slot !== target.slot || entry.token !== token,
  );
  return state.activities.length !== before;
}
