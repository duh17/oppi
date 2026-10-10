/**
 * Cloudflare adapter: a Worker in front of the relay core, one SQLite-backed Durable Object
 * per registration (atomic quotas, counters, and revocation), and one per outstanding
 * challenge (single use). APNs is reached with `fetch`.
 *
 * Secrets (`wrangler secret put`): APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID.
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
import { createRelayHandler } from "../core/relay.js";
import {
  applyAddPermission,
  applyAssertionCounter,
  applyAuthorizePush,
  applyDeletePermission,
  type AddPermissionResult,
  type PermissionRecord,
  type PushAuthorization,
  type RegistrationRecord,
  type RelayStore,
} from "../core/store.js";

export interface Env {
  REGISTRATIONS: DurableObjectNamespace<RegistrationObject>;
  CHALLENGES: DurableObjectNamespace<ChallengeObject>;
  APP_ID: string;
  BUNDLE_ID: string;
  APNS_KEY_P8: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
}

const RECORD_KEY = "registration";

export class RegistrationObject extends DurableObject<Env> {
  private async read(): Promise<RegistrationRecord | null> {
    return (await this.ctx.storage.get<RegistrationRecord>(RECORD_KEY)) ?? null;
  }

  async load(): Promise<RegistrationRecord | null> {
    return this.read();
  }

  async create(record: RegistrationRecord): Promise<void> {
    await this.ctx.storage.put(RECORD_KEY, record);
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
    if (!record) return;
    applyDeletePermission(record, permissionId);
    await this.ctx.storage.put(RECORD_KEY, record);
  }

  async authorizePush(
    permissionId: string,
    secretHash: string,
    now: number,
  ): Promise<PushAuthorization> {
    const record = await this.read();
    if (!record) return { ok: false, reason: "gone" };
    const result = applyAuthorizePush(record, permissionId, secretHash, now);
    await this.ctx.storage.put(RECORD_KEY, record);
    return result;
  }
}

export class ChallengeObject extends DurableObject<Env> {
  async put(expiresAt: number): Promise<void> {
    await this.ctx.storage.put("expiresAt", expiresAt);
    // Unused challenges delete themselves.
    await this.ctx.storage.setAlarm(expiresAt);
  }

  async consume(now: number): Promise<boolean> {
    const expiresAt = await this.ctx.storage.get<number>("expiresAt");
    await this.ctx.storage.deleteAll();
    return expiresAt !== undefined && expiresAt >= now;
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

class DurableObjectRelayStore implements RelayStore {
  /** Bindings of the request being served. */
  constructor(private readonly env: () => Env) {}

  private registration(id: string) {
    const { REGISTRATIONS } = this.env();
    return REGISTRATIONS.get(REGISTRATIONS.idFromName(id));
  }

  private challenge(challenge: string) {
    const { CHALLENGES } = this.env();
    return CHALLENGES.get(CHALLENGES.idFromName(challenge));
  }

  putChallenge(challenge: string, expiresAt: number): Promise<void> {
    return this.challenge(challenge).put(expiresAt);
  }

  consumeChallenge(challenge: string, now: number): Promise<boolean> {
    return this.challenge(challenge).consume(now);
  }

  createRegistration(record: RegistrationRecord): Promise<void> {
    return this.registration(record.id).create(record);
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
}

class FetchApnsSender implements ApnsSender {
  constructor(private readonly providerToken: ApnsProviderToken) {}

  async send(request: ApnsRequest): Promise<ApnsResult> {
    const response = await fetch(
      `${APNS_ORIGINS[request.environment]}/3/device/${request.deviceToken}`,
      {
        method: "POST",
        headers: {
          authorization: `bearer ${await this.providerToken.get()}`,
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
    return reason === undefined ? { status: response.status } : { status: response.status, reason };
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
        config: { appId: env.APP_ID, bundleId: env.BUNDLE_ID },
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
