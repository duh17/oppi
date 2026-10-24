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

/**
 * One server's card, as the phone last listed it. Only the send token of `permissionId` may
 * start, update, or end it; the phone names that permission, so a permission it does not
 * list (an older one, or one whose card the person turned off) drives nothing.
 */
export interface LiveActivityRecord {
  permissionId: string;
  /** The phone's random name for the card (22 base64url characters), never the server's. */
  slot: string;
  /** Lowercase hex ActivityKit update token of the live card; absent while there is none. */
  token?: string;
  /** When the relay first saw `token` for this slot: the card's start, near enough. */
  tokenAt?: number;
  /**
   * The person dismissed the card. `start` stays refused until a server sends `end` (its
   * counts reached zero), which sets `ended`. It lasts while the phone keeps listing the card
   * as dismissed, so a stale listing cannot dismiss it again.
   */
  dismissal?: { ended: boolean };
}

/** The phone's Live Activity state. */
export interface LiveActivityState {
  /** ActivityKit push-to-start token, lowercase hex. */
  startToken?: string;
  activities: LiveActivityRecord[];
}

/**
 * One kind of push's counts: alerts or Live Activity. The day's limit covers both kinds
 * together (their two counts for today, summed); each kind keeps its own minute.
 */
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
  /** Alert pushes. */
  quota: QuotaState;
  /** Absent until the phone first sends its Live Activity tokens. */
  liveActivity?: LiveActivityState;
  /** Live Activity pushes. Absent until the first one. */
  liveActivityQuota?: QuotaState;
  /**
   * Unix seconds of the last Live Activity event (`aps.timestamp`). Each event goes out
   * later, so a start right after an end is the newer one: ActivityKit ignores an event no
   * newer than the one before. One clock for all of the phone's cards, so turning a card off
   * and on keeps it; the per-minute quota keeps it within seconds of the real time.
   */
  liveActivityTimestamp?: number;
}

export interface QuotaLimits {
  /** Pushes per registration and UTC day, alerts and Live Activity together. */
  attestedPerDay: number;
  unattestedPerDay: number;
  /**
   * Of the day's pushes, the last ones are kept for alerts: a Live Activity `start` or
   * `update` is refused once the day's count reaches the limit minus this reserve.
   */
  attestedAlertReserve: number;
  unattestedAlertReserve: number;
  /** Alerts per registration and minute. */
  perMinute: number;
  /** Live Activity pushes per registration and minute. */
  liveActivityPerMinute: number;
  /**
   * Live Activity `end`s allowed beyond the daily limit. A full daily quota must not leave a
   * card showing finished work, but an end the relay counted and APNs failed keeps its token,
   * so the server may repeat it: the overdraft bounds that loop.
   */
  liveActivityEndOverdraft: number;
}

/**
 * Sized for normal use within the Workers Free plan (100,000 Worker requests, Durable Object
 * requests, and rows written a day each). An alert or Live Activity update costs one of each;
 * a Live Activity `start` that replaces a card's token and a delivered `end` cost two Durable
 * Object requests and two rows; each phone Live Activity upload two requests and one row. One
 * daily pool covers alerts and Live Activity, so a phone that sends few alerts gives its Live
 * Activity the rest;
 * alerts keep the last 30. A phone at the cap (100 pushes, a few card starts and ends, 10
 * uploads) is about 130 Durable Object requests a day, so about 750 such phones fill the plan;
 * the pushes alone would allow about 1,000. The quotas are per phone and shared by every
 * server it is paired with. Unattested registrations exist only in sandbox (development
 * builds, Simulator, and health probes), so they get just enough for testing.
 */
export const DEFAULT_QUOTA_LIMITS: QuotaLimits = {
  attestedPerDay: 100,
  unattestedPerDay: 20,
  attestedAlertReserve: 30,
  unattestedAlertReserve: 6,
  perMinute: 10,
  // A server sends at most one Live Activity push a minute per phone, plus a restart.
  liveActivityPerMinute: 3,
  liveActivityEndOverdraft: 8,
};

export const MAX_PERMISSIONS_PER_REGISTRATION = 16;
/** A registration that carries no push for this long is deleted (spec §3.4). */
export const REGISTRATION_IDLE_MS = 90 * 86_400_000;

/**
 * When an idle registration is deleted: 90 days after it was created or last carried a push
 * (alert or Live Activity), whichever is later. Reads only times the record already keeps:
 * each counted push sets its quota's `minuteStart` in the write it already makes, so tracking
 * this adds no field and no write.
 */
export function registrationExpiresAt(record: RegistrationRecord): number {
  return (
    Math.max(record.createdAt, record.quota.minuteStart, record.liveActivityQuota?.minuteStart ?? 0) +
    REGISTRATION_IDLE_MS
  );
}
/** Apple ends a Live Activity after 8 hours; its update token is useless after that. */
export const LIVE_ACTIVITY_MAX_AGE_MS = 8 * 60 * 60 * 1000;

export type LiveActivityEvent = "start" | "update" | "end";

/** The phone's whole Live Activity state, as `PUT .../live-activity` sends it. */
export interface LiveActivityUpdate {
  startToken: string | null;
  /** One per server whose card is on. A dismissed card has no token. */
  activities: Array<{ permissionId: string; slot: string; token: string | null; dismissed: boolean }>;
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
      /** `aps.timestamp` for this event. */
      timestamp: number;
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

export type SetLiveActivityResult = "ok" | "stale" | "gone";

/**
 * Each store also deletes a registration once `registrationExpiresAt` passes, in its own way:
 * Cloudflare with one Durable Object alarm per registration, Node with a sweep.
 */
export interface RelayStore {
  createRegistration(record: RegistrationRecord): Promise<void>;
  /**
   * Make `registrationId` the only registration for `apnsToken` and return the one it
   * replaces, if any. One phone holds one registration, so it holds one quota.
   */
  bindApnsToken(apnsToken: string, registrationId: string): Promise<string | null>;
  /** The registration that holds `apnsToken` now, if any. */
  apnsTokenRegistration(apnsToken: string): Promise<string | null>;
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
  /**
   * Replace the phone's Live Activity tokens. For an attested registration, in the same
   * atomic step, `assertionCounter` must exceed the stored App Attest counter and becomes it;
   * otherwise nothing changes (`stale`), so an older upload never replaces a newer one.
   */
  setLiveActivity(
    id: string,
    update: LiveActivityUpdate,
    assertionCounter: number | null,
    now: number,
  ): Promise<SetLiveActivityResult>;
  /**
   * Check the permission's secret and that the phone lists it for a card, find the token the
   * event goes to, charge one Live Activity push, and stamp the event's time. An `end` also
   * ends the card's dismissal, even when there is no token.
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

/** False when the registration held no such permission: nothing to write. */
export function applyDeletePermission(record: RegistrationRecord, permissionId: string): boolean {
  const kept = record.permissions.filter((entry) => entry.id !== permissionId);
  if (kept.length === record.permissions.length) return false;
  record.permissions = kept;
  return true;
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
  const charged = chargeQuota(
    record.quota,
    record.liveActivityQuota,
    now,
    record.attested ? limits.attestedPerDay : limits.unattestedPerDay,
    limits.perMinute,
  );
  if (!charged.ok) return charged;
  return { ok: true, apnsToken: record.apnsToken, environment: record.environment };
}

/**
 * Count one push against `quota`, or say when the next one fits. The day's count is this
 * kind's and `otherKind`'s together; `perDay` is where this push is refused: the limit, less
 * the alert reserve for a Live Activity start or update, plus the overdraft for an end.
 */
function chargeQuota(
  quota: QuotaState,
  otherKind: QuotaState | undefined,
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
  const usedToday = quota.dayCount + (otherKind?.day === day ? otherKind.dayCount : 0);
  if (usedToday >= perDay) {
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

/** False, changing nothing, for an attested registration whose counter is not newer. */
export function applySetLiveActivity(
  record: RegistrationRecord,
  update: LiveActivityUpdate,
  assertionCounter: number | null,
  now: number,
): boolean {
  if (record.attested && (assertionCounter === null || !applyAssertionCounter(record, assertionCounter))) {
    return false;
  }
  const previous = record.liveActivity?.activities ?? [];
  record.liveActivity = {
    ...(update.startToken ? { startToken: update.startToken } : {}),
    activities: update.activities.map(({ permissionId, slot, token, dismissed }) => {
      const held = previous.find((entry) => entry.slot === slot);
      const tokenAt = held?.token === token ? held?.tokenAt : undefined;
      return {
        permissionId,
        slot,
        ...(token ? { token, tokenAt: tokenAt ?? now } : {}),
        ...(dismissed ? { dismissal: held?.dismissal ?? { ended: false } } : {}),
      };
    }),
  };
  return true;
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
  const state = record.liveActivity;
  // The phone names the permission that may drive each card; any other drives none.
  const activity = state?.activities.find((entry) => entry.permissionId === permissionId);
  if (!state || !activity) {
    return { authorization: { ok: false, reason: "no_activity" }, changed: false };
  }
  const { slot, dismissal } = activity;

  // The work the dismissed card counted is over; the next work may show a card again.
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
    replacedToken = activity.token;
  } else {
    // Apple has ended an activity this old; an update would land nowhere. An `end` still
    // goes, to take the ended card off the Lock Screen.
    if (
      activity.token &&
      (event === "end" || now - (activity.tokenAt ?? now) < LIVE_ACTIVITY_MAX_AGE_MS)
    ) {
      token = activity.token;
    }
    target = { kind: "activity", slot };
  }
  if (!token) return { authorization: { ok: false, reason: "no_activity" }, changed };

  record.liveActivityQuota ??= emptyQuota();
  const perDay = record.attested ? limits.attestedPerDay : limits.unattestedPerDay;
  const reserve = record.attested ? limits.attestedAlertReserve : limits.unattestedAlertReserve;
  const charged = chargeQuota(
    record.liveActivityQuota,
    record.quota,
    now,
    // A start or update leaves the alert reserve. An `end` is never refused for the day's
    // limit, so a full quota cannot leave a card showing finished work; its overdraft on top
    // (108 for 100, 28 for 20) bounds a failing-end loop.
    event === "end" ? perDay + limits.liveActivityEndOverdraft : perDay - reserve,
    limits.liveActivityPerMinute,
  );
  if (!charged.ok) return { authorization: charged, changed };
  const timestamp = Math.max(Math.floor(now / 1000), (record.liveActivityTimestamp ?? 0) + 1);
  record.liveActivityTimestamp = timestamp;
  return {
    authorization: {
      ok: true,
      token,
      target,
      slot,
      environment: record.environment,
      timestamp,
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
  const activity = state.activities.find(
    (entry) => entry.slot === target.slot && entry.token === token,
  );
  if (!activity) return false;
  delete activity.token;
  delete activity.tokenAt;
  return true;
}
