/**
 * Cloudflare adapter: a Worker in front of the relay core, one SQLite-backed Durable Object
 * per registration (atomic quotas, counters, revocation, and its idle-expiry alarm) and one
 * per APNs token naming that phone's current registration. Challenges need no storage
 * (core/challenge.ts). APNs is reached with `fetch`.
 *
 * Secrets (`wrangler secret put`): APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID. APNS_KEY_P8 also
 * keys the challenges, through HKDF with its own label.
 * Vars (wrangler.toml): APP_ID, BUNDLE_ID.
 */

import { DurableObject } from "cloudflare:workers";
import {
  APNS_ORIGINS,
  ApnsProviderToken,
  type ApnsRequest,
  type ApnsResult,
  type ApnsSender,
} from "../core/apns.js";
import { utf8 } from "../core/bytes.js";
import { createRelayHandler } from "../core/relay.js";
import {
  applyAddPermission,
  applyAssertionCounter,
  applyAuthorizeLiveActivity,
  applyAuthorizePush,
  applyClearLiveActivityToken,
  applyDeletePermission,
  applySetLiveActivity,
  registrationExpiresAt,
  type AddPermissionResult,
  type LiveActivityAuthorization,
  type LiveActivityEvent,
  type LiveActivityTarget,
  type LiveActivityUpdate,
  type PermissionRecord,
  type PushAuthorization,
  type RegistrationRecord,
  type RelayStore,
  type SetLiveActivityResult,
} from "../core/store.js";

export interface Env {
  REGISTRATIONS: DurableObjectNamespace<RegistrationObject>;
  APNS_TOKENS: DurableObjectNamespace<ApnsTokenObject>;
  APP_ID: string;
  BUNDLE_ID: string;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
}

const RECORD_KEY = "registration";

export class RegistrationObject extends DurableObject<Env> {
  private expiryAlarmChecked = false;

  private async read(): Promise<RegistrationRecord | null> {
    return (await this.ctx.storage.get<RegistrationRecord>(RECORD_KEY)) ?? null;
  }

  /**
   * Registrations created before idle expiry existed have no alarm. The first push after this
   * object starts checks once (a read) and sets one only then; pushes never set alarms.
   */
  private async ensureExpiryAlarm(record: RegistrationRecord): Promise<void> {
    if (this.expiryAlarmChecked) return;
    this.expiryAlarmChecked = true;
    if ((await this.ctx.storage.getAlarm()) === null) {
      await this.ctx.storage.setAlarm(registrationExpiresAt(record));
    }
  }

  async load(): Promise<RegistrationRecord | null> {
    return this.read();
  }

  async create(record: RegistrationRecord): Promise<void> {
    await this.ctx.storage.put(RECORD_KEY, record);
    // One alarm for the registration's life: it fires when the registration could first have
    // gone idle and moves itself to the last push + 90 days, so a push writes no alarm.
    await this.ctx.storage.setAlarm(registrationExpiresAt(record));
    this.expiryAlarmChecked = true;
  }

  async alarm(): Promise<void> {
    const record = await this.read();
    // Deleted already; `deleteAll` also drops the alarm on this compatibility date.
    if (!record) return;
    const expiresAt = registrationExpiresAt(record);
    if (Date.now() < expiresAt) {
      await this.ctx.storage.setAlarm(expiresAt);
      return;
    }
    await this.ctx.storage.deleteAll();
    // A binding left behind if this throws is harmless: it names a registration that is gone.
    const { APNS_TOKENS } = this.env;
    await APNS_TOKENS.get(APNS_TOKENS.idFromName(record.apnsToken)).unbind(record.id);
  }

  async remove(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }

  async advanceAssertionCounter(counter: number): Promise<boolean> {
    const record = await this.read();
    if (!record || !applyAssertionCounter(record, counter)) return false;
    await this.ctx.storage.put(RECORD_KEY, record);
    return true;
  }

  async addPermission(permission: PermissionRecord): Promise<AddPermissionResult> {
    const record = await this.read();
    if (!record) return "gone";
    const result = applyAddPermission(record, permission);
    if (result === "ok") await this.ctx.storage.put(RECORD_KEY, record);
    return result;
  }

  async deletePermission(permissionId: string): Promise<void> {
    const record = await this.read();
    if (record && applyDeletePermission(record, permissionId)) {
      await this.ctx.storage.put(RECORD_KEY, record);
    }
  }

  async authorizePush(
    permissionId: string,
    secretHash: string,
    now: number,
  ): Promise<PushAuthorization> {
    const record = await this.read();
    if (!record) return { ok: false, reason: "gone" };
    const result = applyAuthorizePush(record, permissionId, secretHash, now);
    // A refused push changes no count worth keeping; skipping the write saves free-plan rows.
    if (result.ok) {
      await this.ctx.storage.put(RECORD_KEY, record);
      await this.ensureExpiryAlarm(record);
    }
    return result;
  }

  async setLiveActivity(
    update: LiveActivityUpdate,
    assertionCounter: number | null,
    now: number,
  ): Promise<SetLiveActivityResult> {
    const record = await this.read();
    if (!record) return "gone";
    if (!applySetLiveActivity(record, update, assertionCounter, now)) return "stale";
    await this.ctx.storage.put(RECORD_KEY, record);
    return "ok";
  }

  async authorizeLiveActivity(
    permissionId: string,
    secretHash: string,
    event: LiveActivityEvent,
    now: number,
  ): Promise<LiveActivityAuthorization> {
    const record = await this.read();
    if (!record) return { ok: false, reason: "gone" };
    const { authorization, changed } = applyAuthorizeLiveActivity(
      record,
      permissionId,
      secretHash,
      event,
      now,
    );
    // A refused push writes nothing unless it ended a dismissal; skipping saves free-plan rows.
    if (changed) {
      await this.ctx.storage.put(RECORD_KEY, record);
      await this.ensureExpiryAlarm(record);
    }
    return authorization;
  }

  async clearLiveActivityToken(target: LiveActivityTarget, token: string): Promise<void> {
    const record = await this.read();
    if (record && applyClearLiveActivityToken(record, target, token)) {
      await this.ctx.storage.put(RECORD_KEY, record);
    }
  }
}

/**
 * Addressed by the APNs token; holds only the id of that phone's current registration, so
 * the token itself is stored once, in the registration.
 */
export class ApnsTokenObject extends DurableObject<Env> {
  async bind(registrationId: string): Promise<string | null> {
    const previous = (await this.ctx.storage.get<string>("registrationId")) ?? null;
    if (previous === registrationId) return null;
    await this.ctx.storage.put("registrationId", registrationId);
    return previous;
  }

  async current(): Promise<string | null> {
    return (await this.ctx.storage.get<string>("registrationId")) ?? null;
  }

  async unbind(registrationId: string): Promise<void> {
    if ((await this.ctx.storage.get<string>("registrationId")) === registrationId) {
      await this.ctx.storage.deleteAll();
    }
  }
}

class DurableObjectRelayStore implements RelayStore {
  /** Bindings of the request being served. */
  constructor(private readonly env: () => Env) {}

  private registration(id: string) {
    const { REGISTRATIONS } = this.env();
    return REGISTRATIONS.get(REGISTRATIONS.idFromName(id));
  }

  private apnsToken(apnsToken: string) {
    const { APNS_TOKENS } = this.env();
    return APNS_TOKENS.get(APNS_TOKENS.idFromName(apnsToken));
  }

  createRegistration(record: RegistrationRecord): Promise<void> {
    return this.registration(record.id).create(record);
  }

  bindApnsToken(apnsToken: string, registrationId: string): Promise<string | null> {
    return this.apnsToken(apnsToken).bind(registrationId);
  }

  apnsTokenRegistration(apnsToken: string): Promise<string | null> {
    return this.apnsToken(apnsToken).current();
  }

  unbindApnsToken(apnsToken: string, registrationId: string): Promise<void> {
    return this.apnsToken(apnsToken).unbind(registrationId);
  }

  getRegistration(id: string): Promise<RegistrationRecord | null> {
    return this.registration(id).load();
  }

  deleteRegistration(id: string): Promise<void> {
    return this.registration(id).remove();
  }

  advanceAssertionCounter(id: string, counter: number): Promise<boolean> {
    return this.registration(id).advanceAssertionCounter(counter);
  }

  addPermission(id: string, permission: PermissionRecord): Promise<AddPermissionResult> {
    return this.registration(id).addPermission(permission);
  }

  deletePermission(id: string, permissionId: string): Promise<void> {
    return this.registration(id).deletePermission(permissionId);
  }

  authorizePush(
    id: string,
    permissionId: string,
    secretHash: string,
    now: number,
  ): Promise<PushAuthorization> {
    return this.registration(id).authorizePush(permissionId, secretHash, now);
  }

  setLiveActivity(
    id: string,
    update: LiveActivityUpdate,
    assertionCounter: number | null,
    now: number,
  ): Promise<SetLiveActivityResult> {
    return this.registration(id).setLiveActivity(update, assertionCounter, now);
  }

  authorizeLiveActivity(
    id: string,
    permissionId: string,
    secretHash: string,
    event: LiveActivityEvent,
    now: number,
  ): Promise<LiveActivityAuthorization> {
    return this.registration(id).authorizeLiveActivity(permissionId, secretHash, event, now);
  }

  clearLiveActivityToken(id: string, target: LiveActivityTarget, token: string): Promise<void> {
    return this.registration(id).clearLiveActivityToken(target, token);
  }
}

class FetchApnsSender implements ApnsSender {
  constructor(private readonly providerToken: ApnsProviderToken) {}

  async send(request: ApnsRequest): Promise<ApnsResult> {
    const token = await this.providerToken.get();
    const response = await fetch(
      `${APNS_ORIGINS[request.environment]}/3/device/${request.deviceToken}`,
      {
        method: "POST",
        headers: {
          authorization: `bearer ${token}`,
          "content-type": "application/json",
          ...request.headers,
        },
        body: request.payload,
      },
    );
    let reason: string | undefined;
    try {
      const parsed = (await response.json()) as { reason?: unknown };
      if (typeof parsed.reason === "string") reason = parsed.reason;
    } catch {
      // An empty body is a success.
    }
    const result = reason === undefined ? { status: response.status } : { status: response.status, reason };
    this.providerToken.forgetIfRefused(token, result);
    return result;
  }
}

/**
 * One handler per isolate and configuration, so the APNs provider token and in-memory rate
 * limits survive across requests even if the runtime hands each request a new `env` object.
 * Re-minting the provider token per request would trip APNs `TooManyProviderTokenUpdates`.
 */
let cached: { key: string; handle: ReturnType<typeof createRelayHandler> } | null = null;
let currentEnv: Env | null = null;

function handlerFor(env: Env): ReturnType<typeof createRelayHandler> {
  currentEnv = env;
  const key = [env.APP_ID, env.BUNDLE_ID, env.APNS_KEY_ID, env.APNS_TEAM_ID, env.APNS_KEY_P8].join("\n");
  if (cached?.key !== key) {
    const providerToken = new ApnsProviderToken({
      keyP8: env.APNS_KEY_P8,
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
    });
    cached = {
      key,
      handle: createRelayHandler({
        store: new DurableObjectRelayStore(() => {
          if (!currentEnv) throw new Error("no bindings");
          return currentEnv;
        }),
        apns: new FetchApnsSender(providerToken),
        // Throws without APNS_KEY_P8, so the relay answers nothing rather than run unkeyed.
        config: {
          appId: env.APP_ID,
          bundleId: env.BUNDLE_ID,
          challengeSecret: utf8(env.APNS_KEY_P8 ?? ""),
        },
        // Event names and status codes only. Workers Logs are off in wrangler.toml.
        log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
      }),
    };
  }
  return cached.handle;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // The address feeds in-memory rate limits only; it is never stored or logged.
    return handlerFor(env)(request, request.headers.get("cf-connecting-ip"));
  },
};
