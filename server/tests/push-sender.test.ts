import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PUSH_ENVELOPE_BYTES, type SealedPushEnvelope } from "../src/push/envelope.js";
import {
  OPPI_PUSH_RELAY,
  PUSH_DEVICE_BUDGET,
  pushCollapseId,
  PushSender,
} from "../src/push/push-sender.js";
import { RelayClient } from "../src/push/relay-client.js";
import { Storage } from "../src/storage.js";
import { openPushEnvelopeForTest } from "./helpers/push-envelope-open.js";

const vectors = JSON.parse(
  readFileSync(new URL("../../protocol/push/vectors/cryptokit-hpke.json", import.meta.url), "utf8"),
) as { recipient: { privateKey: string; publicKey: string; keyId: string } };
const recipientPrivateKey = Buffer.from(vectors.recipient.privateKey, "base64url");

const PRIMARY = "https://primary.example.test";
const STANDBY = "https://standby.example.test";

interface RelayCall {
  url: string;
  authorization: string | null;
  body: { envelope: string; collapseId?: string; ttl?: number };
}

function relayFetch(responses: Record<string, () => Response | Promise<Response>>) {
  const calls: RelayCall[] = [];
  const fetchImpl = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({
      url,
      authorization: new Headers(init?.headers).get("authorization"),
      body: JSON.parse(String(init?.body ?? "{}")) as RelayCall["body"],
    });
    const origin = new URL(url).origin;
    const respond = responses[origin];
    if (!respond) throw new TypeError("fetch failed");
    return respond();
  });
  return { fetchImpl: fetchImpl as unknown as typeof fetch, calls };
}

const ok = () => new Response(JSON.stringify({ ok: true }), { status: 200 });

describe("PushSender", () => {
  let dataDir: string;
  let storage: Storage;
  let deviceId: string;
  const signing = generateKeyPairSync("ed25519");

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-push-sender-"));
    storage = new Storage(dataDir);
    storage.ensurePaired();
    const devicePublicKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({
      format: "jwk",
    }) as { x: string; y: string };
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: devicePublicKey.x, y: devicePublicKey.y },
    });
    if (!enrolled) throw new Error("enrollment failed");
    deviceId = enrolled.deviceId;
    storage.setPushRegistration({
      deviceId,
      keyId: vectors.recipient.keyId,
      publicKey: vectors.recipient.publicKey,
      sendToken: "osp1.r_a.p_a.secret-a",
      events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
    });
  });

  afterEach(() => rmSync(dataDir, { recursive: true, force: true }));

  function sender(fetchImpl: typeof fetch): PushSender {
    return new PushSender(storage, { signingKey: signing.privateKey, fetch: fetchImpl });
  }

  const notification = {
    event: "blocked" as const,
    kind: "permission" as const,
    sessionId: "s1",
    workspaceId: "w1",
    title: "Needs Approval",
    subtitle: "Deploy",
    body: "Waiting for your approval.",
  };

  it("sends nothing while push is off, even to a registered device", async () => {
    storage.updateConfig({ push: { mode: "off" } });
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    const push = sender(fetchImpl);

    expect(push.registrations()).toEqual([]);
    const registration = storage.getPushRegistrations()[0];
    if (!registration) throw new Error("missing registration");
    expect(await push.send(registration, notification)).toBeNull();
    expect(calls).toHaveLength(0);
  });

  it("relays a sealed envelope only the device key opens, without rewriting config per push", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    const configBefore = readFileSync(join(dataDir, "config.json"), "utf8");
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    const push = sender(fetchImpl);
    const [registration] = push.registrations();
    if (!registration) throw new Error("missing registration");

    expect(await push.send(registration, notification)).toEqual({ status: "delivered" });
    expect(
      await push.send(registration, { ...notification, event: "notify", kind: undefined }),
    ).toEqual({
      status: "delivered",
    });

    expect(calls.map((call) => call.url)).toEqual([`${PRIMARY}/v1/push`, `${PRIMARY}/v1/push`]);
    expect(calls[0]?.authorization).toBe("Bearer osp1.r_a.p_a.secret-a");
    expect(calls[0]?.body.ttl).toBe(3600);
    expect(calls[0]?.body.collapseId).toMatch(/^[A-Za-z0-9_-]{22}$/);
    // A later Needs you never replaces what the agent asked the user to read.
    expect(calls[0]?.body.collapseId).toBe(pushCollapseId("osp1.r_a.p_a.secret-a", "s1"));
    expect(calls[1]?.body.collapseId).toBe(pushCollapseId("osp1.r_a.p_a.secret-a", "notify:s1"));
    // The relay body carries no readable content.
    expect(JSON.stringify(calls)).not.toContain("Deploy");
    expect(JSON.stringify(calls)).not.toContain("Needs Approval");

    const opened = calls.map((call) =>
      openPushEnvelopeForTest(call.body.envelope, {
        recipientPrivateKey,
        serverPublicKey: signing.publicKey,
      }),
    );
    expect(opened[0]).toMatchObject({ ...notification, v: 1 });
    expect(opened[0]).not.toHaveProperty("seq");
    // Replay protection needs no server state: sending writes nothing.
    expect(readFileSync(join(dataDir, "config.json"), "utf8")).toBe(configBefore);
  });

  it("seals and relays nothing for an event the phone did not list", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    const [registered] = storage.getPushRegistrations();
    if (!registered) throw new Error("missing registration");
    storage.setPushRegistration({ ...registered, events: ["blocked", "pairing_approval"] });
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    const push = sender(fetchImpl);
    const [registration] = push.registrations();
    if (!registration) throw new Error("missing registration");

    expect(push.registrations("notify")).toEqual([]);
    expect(push.registrations("blocked")).toEqual([registration]);
    expect(
      await push.send(registration, { ...notification, event: "notify", kind: undefined }),
    ).toBeNull();
    expect(calls).toHaveLength(0);
    expect(await push.send(registration, notification)).toEqual({ status: "delivered" });
    expect(calls).toHaveLength(1);
  });

  it("sends nothing to a registration that was replaced after the caller listed it", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    const push = sender(fetchImpl);
    const [listed] = push.registrations();
    if (!listed) throw new Error("missing registration");

    storage.setPushRegistration({ ...listed, sendToken: "osp1.r_a.p_b.secret-b" });

    expect(await push.send(listed, notification)).toBeNull();
    expect(calls).toHaveLength(0);
  });

  it("fails over to the standby on a network error or 5xx", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY, STANDBY] } });
    const down = relayFetch({ [STANDBY]: ok });
    const [registration] = sender(down.fetchImpl).registrations();
    if (!registration) throw new Error("missing registration");

    expect(await sender(down.fetchImpl).send(registration, notification)).toEqual({
      status: "delivered",
    });
    expect(down.calls.map((call) => new URL(call.url).origin)).toEqual([PRIMARY, STANDBY]);

    const failing = relayFetch({
      [PRIMARY]: () => new Response("{}", { status: 503 }),
      [STANDBY]: () => new Response("{}", { status: 502 }),
    });
    expect(await sender(failing.fetchImpl).send(registration, notification)).toEqual({
      status: "unavailable",
    });
  });

  it("prunes on a primary 410 but not on a standby 410", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY, STANDBY] } });
    const gone = () => new Response(JSON.stringify({ error: "gone" }), { status: 410 });

    const standbyGone = relayFetch({ [STANDBY]: gone });
    const [registration] = sender(standbyGone.fetchImpl).registrations();
    if (!registration) throw new Error("missing registration");
    expect(await sender(standbyGone.fetchImpl).send(registration, notification)).toEqual({
      status: "gone",
      prune: false,
    });
    expect(storage.getPushRegistrations()).toHaveLength(1);

    const primaryGone = relayFetch({ [PRIMARY]: gone, [STANDBY]: ok });
    expect(await sender(primaryGone.fetchImpl).send(registration, notification)).toEqual({
      status: "gone",
      prune: true,
    });
    expect(primaryGone.calls).toHaveLength(1);
    expect(storage.getPushRegistrations()).toEqual([]);
  });

  it("does not fail over a deterministic refusal such as a quota", async () => {
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY, STANDBY] } });
    const quota = relayFetch({
      [PRIMARY]: () => new Response(JSON.stringify({ error: "quota_exceeded" }), { status: 429 }),
      [STANDBY]: ok,
    });
    const [registration] = sender(quota.fetchImpl).registrations();
    if (!registration) throw new Error("missing registration");

    expect(await sender(quota.fetchImpl).send(registration, notification)).toEqual({
      status: "rejected",
      httpStatus: 429,
      error: "quota_exceeded",
    });
    expect(quota.calls).toHaveLength(1);
  });

  it("pushes through Oppi's relay unless the operator names another or turns push off", () => {
    const { fetchImpl } = relayFetch({});
    expect(sender(fetchImpl).relays()).toEqual([OPPI_PUSH_RELAY]);

    // A push block without a mode, read back from config.json, is relay mode.
    storage.updateConfig({ push: { relays: [PRIMARY] } } as never);
    const reloaded = new Storage(dataDir);
    expect(
      new PushSender(reloaded, { signingKey: signing.privateKey, fetch: fetchImpl }).relays(),
    ).toEqual([PRIMARY]);

    storage.updateConfig({ push: { mode: "off" } });
    const off = sender(fetchImpl);
    expect(off.relays()).toBeUndefined();
    expect(off.registrations()).toEqual([]);
  });

  it("keeps the push config it started with, whatever config.json says later", async () => {
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    storage.updateConfig({ push: { mode: "off" } });
    const off = sender(fetchImpl);
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    expect(off.relays()).toBeUndefined();
    expect(off.registrations()).toEqual([]);

    const on = sender(fetchImpl);
    const [registration] = on.registrations();
    if (!registration) throw new Error("missing registration");
    storage.updateConfig({ push: { mode: "off" } });
    expect(on.relays()).toEqual([PRIMARY]);
    expect(await on.send(registration, notification)).toEqual({ status: "delivered" });
    expect(calls).toHaveLength(1);
  });

  describe("send tokens the primary relay retired", () => {
    const gone = () => new Response(JSON.stringify({ error: "gone" }), { status: 410 });

    it("remembers a token pruned by the primary, not one a standby refused", async () => {
      storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY, STANDBY] } });
      const standbyGone = relayFetch({ [STANDBY]: gone });
      const push = sender(standbyGone.fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");

      await push.send(registration, notification);
      expect(push.isSendTokenGone(registration.sendToken)).toBe(false);

      const primaryGone = relayFetch({ [PRIMARY]: gone });
      const pruning = sender(primaryGone.fetchImpl);
      await pruning.send(registration, notification);
      expect(storage.getPushRegistrations()).toEqual([]);
      expect(pruning.isSendTokenGone(registration.sendToken)).toBe(true);
      expect(pruning.isSendTokenGone("osp1.r_a.p_b.other")).toBe(false);
    });

    it("keeps a bounded memory, forgetting the oldest token first", async () => {
      storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
      const { fetchImpl } = relayFetch({ [PRIMARY]: gone });
      // A new UTC day per send, so the device budget never refuses before the relay answers.
      let clock = Date.parse("2026-01-01T12:00:00Z");
      // A small bound: the claim is the eviction order, and 257 real signed sends took 6-10 s.
      const push = new PushSender(storage, {
        signingKey: signing.privateKey,
        fetch: fetchImpl,
        now: () => clock,
        goneSendTokensMax: 4,
      });
      const [first] = push.registrations();
      if (!first) throw new Error("missing registration");
      const tokens: string[] = [];
      for (let index = 0; index < 5; index += 1) {
        const sendToken = `osp1.r_a.p_a.secret-${index}`;
        tokens.push(sendToken);
        storage.setPushRegistration({ ...first, sendToken });
        const [current] = push.registrations();
        if (!current) throw new Error("missing registration");
        await push.send(current, notification);
        clock += 86_400_000;
      }
      expect(push.isSendTokenGone(tokens[0]!)).toBe(false);
      expect(push.isSendTokenGone(tokens[1]!)).toBe(true);
      expect(push.isSendTokenGone(tokens[4]!)).toBe(true);
    });
  });

  describe("a relay at capacity (503 with Retry-After)", () => {
    const capacity = (retryAfter?: string) => () =>
      new Response(JSON.stringify({ error: "relay_capacity" }), {
        status: 503,
        ...(retryAfter ? { headers: { "retry-after": retryAfter } } : {}),
      });
    let clock: number;
    beforeEach(() => {
      clock = Date.parse("2026-10-17T12:00:00Z");
    });

    function timed(fetchImpl: typeof fetch): PushSender {
      storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY, STANDBY] } });
      storage.setPushRegistration({
        deviceId,
        keyId: vectors.recipient.keyId,
        publicKey: vectors.recipient.publicKey,
        sendToken: "osp1.r_a.p_a.secret-a",
        liveActivity: true,
        events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
      });
      return new PushSender(storage, {
        signingKey: signing.privateKey,
        fetch: fetchImpl,
        now: () => clock,
      });
    }

    it("pauses the device like a 429 quota, without trying the standby", async () => {
      let answer = capacity("30");
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: () => answer(), [STANDBY]: ok });
      const push = timed(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");

      expect(await push.send(registration, notification)).toEqual({
        status: "rejected",
        httpStatus: 503,
        error: "relay_capacity",
        retryAfterSeconds: 30,
      });
      answer = () => ok();
      clock += 29_000;
      expect((await push.send(registration, notification))?.status).toBe("throttled");
      expect(calls).toHaveLength(1);
      clock += 1_000;
      expect((await push.send(registration, notification))?.status).toBe("delivered");
    });

    it("pauses Live Activity pushes of that kind and counts nothing", async () => {
      let answer = capacity("30");
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: () => answer(), [STANDBY]: ok });
      const push = timed(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");
      const update = { event: "update" as const, running: 1, needsYou: 0 };

      expect(await push.sendLiveActivity(registration, update)).toMatchObject({
        status: "rejected",
        retryAfterSeconds: 30,
      });
      answer = () => ok();
      expect((await push.sendLiveActivity(registration, update))?.status).toBe("throttled");
      expect(calls).toHaveLength(1);
      clock += 30_000;
      for (let index = 0; index < PUSH_DEVICE_BUDGET.liveActivityPerDay; index += 1) {
        expect((await push.sendLiveActivity(registration, update))?.status).toBe("delivered");
      }
    });

    it("accepts a pause of a full day, and nothing longer", async () => {
      const day = relayFetch({ [PRIMARY]: capacity("86400"), [STANDBY]: ok });
      const [registration] = timed(day.fetchImpl).registrations();
      if (!registration) throw new Error("missing registration");
      expect(await timed(day.fetchImpl).send(registration, notification)).toMatchObject({
        status: "rejected",
        retryAfterSeconds: 86_400,
      });

      const tooLong = relayFetch({ [PRIMARY]: capacity("86401"), [STANDBY]: ok });
      expect(await timed(tooLong.fetchImpl).send(registration, notification)).toEqual({
        status: "delivered",
      });
    });

    it.each([
      ["a proxy's 503 that names no capacity", "30", JSON.stringify({ error: "bad_gateway" })],
      ["a Retry-After that is an HTTP date", "Wed, 21 Oct 2026 07:28:00 GMT", undefined],
      ["a fractional Retry-After", "1.5", undefined],
      ["a Retry-After of zero", "0", undefined],
    ])("stays an outage for %s", async (_name, retryAfter, body) => {
      const refused = () =>
        new Response(body ?? JSON.stringify({ error: "relay_capacity" }), {
          status: 503,
          headers: { "retry-after": retryAfter },
        });
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: refused, [STANDBY]: ok });
      const push = timed(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");

      expect(await push.send(registration, notification)).toEqual({ status: "delivered" });
      expect(calls.map((call) => new URL(call.url).origin)).toEqual([PRIMARY, STANDBY]);
      // No pause was recorded: the next send goes out at once.
      expect((await push.send(registration, notification))?.status).toBe("delivered");
    });

    it("stays an outage, failing over to the standby, without Retry-After", async () => {
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: capacity(), [STANDBY]: ok });
      const push = timed(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");

      expect(await push.send(registration, notification)).toEqual({ status: "delivered" });
      expect(calls.map((call) => new URL(call.url).origin)).toEqual([PRIMARY, STANDBY]);

      const both = relayFetch({ [PRIMARY]: capacity(), [STANDBY]: capacity("abc") });
      expect(await timed(both.fetchImpl).send(registration, notification)).toEqual({
        status: "unavailable",
      });
    });
  });

  describe("per-device budget", () => {
    const agentAlert = { ...notification, event: "notify" as const, kind: undefined };
    let clock: number;

    function budgeted(fetchImpl: typeof fetch): PushSender {
      storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
      return new PushSender(storage, {
        signingKey: signing.privateKey,
        fetch: fetchImpl,
        now: () => clock,
      });
    }

    async function sendMany(
      push: PushSender,
      count: number,
      alert: typeof notification | typeof agentAlert,
    ): Promise<string[]> {
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");
      const results: string[] = [];
      for (let index = 0; index < count; index += 1) {
        results.push((await push.send(registration, alert))?.status ?? "none");
      }
      return results;
    }

    beforeEach(() => {
      clock = Date.parse("2026-10-17T12:00:00Z");
    });

    it("keeps per-minute room for approvals that routine alerts cannot use", async () => {
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
      const push = budgeted(fetchImpl);

      const routine = await sendMany(push, PUSH_DEVICE_BUDGET.routinePerMinute + 1, agentAlert);
      expect(routine.at(-1)).toBe("throttled");
      const reserve = PUSH_DEVICE_BUDGET.perMinute - PUSH_DEVICE_BUDGET.routinePerMinute;
      expect(await sendMany(push, reserve + 1, notification)).toEqual([
        ...Array<string>(reserve).fill("delivered"),
        "throttled",
      ]);
      expect(calls).toHaveLength(PUSH_DEVICE_BUDGET.perMinute);

      clock += 60_000;
      expect(await sendMany(push, 1, agentAlert)).toEqual(["delivered"]);
    });

    it("keeps daily room for approvals and resets on the next UTC day", async () => {
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
      const push = budgeted(fetchImpl);
      const perMinute = PUSH_DEVICE_BUDGET.routinePerMinute;

      for (let sent = 0; sent < PUSH_DEVICE_BUDGET.routinePerDay; sent += perMinute) {
        clock += 60_000;
        await sendMany(
          push,
          Math.min(perMinute, PUSH_DEVICE_BUDGET.routinePerDay - sent),
          agentAlert,
        );
      }
      clock += 60_000;
      expect(await sendMany(push, 1, agentAlert)).toEqual(["throttled"]);
      expect(await sendMany(push, 1, notification)).toEqual(["delivered"]);
      expect(calls).toHaveLength(PUSH_DEVICE_BUDGET.routinePerDay + 1);

      clock = Date.parse("2026-10-18T00:00:00Z");
      expect(await sendMany(push, 1, agentAlert)).toEqual(["delivered"]);
    });

    it("stops asking the relay until its quota Retry-After passes", async () => {
      let refuse = true;
      const { fetchImpl, calls } = relayFetch({
        [PRIMARY]: () =>
          refuse
            ? new Response(JSON.stringify({ error: "quota_exceeded" }), {
                status: 429,
                headers: { "retry-after": "30" },
              })
            : ok(),
      });
      const push = budgeted(fetchImpl);

      expect(await sendMany(push, 1, notification)).toEqual(["rejected"]);
      refuse = false;
      clock += 29_000;
      expect(await sendMany(push, 1, notification)).toEqual(["throttled"]);
      expect(calls).toHaveLength(1);
      clock += 1_000;
      expect(await sendMany(push, 1, notification)).toEqual(["delivered"]);
    });
  });

  describe("Live Activity", () => {
    let clock: number;
    const update = { event: "update" as const, running: 2, needsYou: 1 };

    function liveActivitySender(fetchImpl: typeof fetch, liveActivity = true): PushSender {
      storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
      storage.setPushRegistration({
        deviceId,
        keyId: vectors.recipient.keyId,
        publicKey: vectors.recipient.publicKey,
        sendToken: "osp1.r_a.p_a.secret-a",
        ...(liveActivity ? { liveActivity: true } : {}),
        events: ["blocked", "error", "notify", "pairing_approval", "device_enrolled"],
      });
      return new PushSender(storage, {
        signingKey: signing.privateKey,
        fetch: fetchImpl,
        now: () => clock,
      });
    }

    beforeEach(() => {
      clock = Date.parse("2026-10-17T12:00:00Z");
    });

    it("posts only the fixed schema, and only to devices that accept Live Activities", async () => {
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
      const off = liveActivitySender(fetchImpl, false);
      expect(await off.sendLiveActivity(off.registrations()[0]!, update)).toBeNull();
      expect(calls).toHaveLength(0);

      const push = liveActivitySender(fetchImpl);
      const extra = { ...update, title: "Deploy" } as typeof update;
      expect(await push.sendLiveActivity(push.registrations()[0]!, extra)).toEqual({
        status: "delivered",
      });
      expect(calls[0]?.url).toBe(`${PRIMARY}/v1/live-activity`);
      expect(calls[0]?.authorization).toBe("Bearer osp1.r_a.p_a.secret-a");
      expect(calls[0]?.body).toEqual({ event: "update", running: 2, needsYou: 1 });
    });

    it("spends budget only on sends the relay counted", async () => {
      let relay: (() => Response) | undefined = () =>
        new Response(JSON.stringify({ error: "no_activity" }), { status: 409 });
      const { fetchImpl } = relayFetch({ [PRIMARY]: () => (relay ? relay() : ok()) });
      const push = liveActivitySender(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");
      const sendAll = async () => {
        const results = new Set<string>();
        for (let index = 0; index < PUSH_DEVICE_BUDGET.liveActivityPerDay; index += 1) {
          results.add(JSON.stringify(await push.sendLiveActivity(registration, update)));
        }
        return [...results];
      };

      // No card at the relay: no refusal, and nothing charged.
      expect(await sendAll()).toEqual([JSON.stringify({ status: "no_activity" })]);
      expect(storage.getPushRegistrations()).toHaveLength(1);
      // The relay could not be reached, or failed before looking at the send: nothing charged.
      relay = () => {
        throw new TypeError("fetch failed");
      };
      expect(await sendAll()).toEqual([JSON.stringify({ status: "unavailable", charged: false })]);
      relay = () => new Response("{}", { status: 503 });
      expect(await sendAll()).toEqual([JSON.stringify({ status: "unavailable", charged: false })]);

      // The relay counted it, then APNs failed: the server counts it too.
      relay = () => new Response(JSON.stringify({ error: "apns_unavailable" }), { status: 502 });
      expect(await sendAll()).toEqual([JSON.stringify({ status: "unavailable", charged: true })]);
      relay = undefined;
      expect((await push.sendLiveActivity(registration, update))?.status).toBe("throttled");
    });

    it("shares the day with alerts: starts and updates stop at their share, ends go past the day", async () => {
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
      const push = liveActivitySender(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");
      const { perDay, routinePerDay, liveActivityPerDay, liveActivityEndOverdraft } =
        PUSH_DEVICE_BUDGET;
      const status = async (event: "start" | "update" | "end") =>
        (
          await push.sendLiveActivity(
            registration,
            event === "end" ? { event, running: 0, needsYou: 0 } : { ...update, event },
          )
        )?.status;
      // A minute apart, so only the day's budget can refuse.
      const alert = async (event: "notify" | "blocked") => {
        clock += 60_000;
        const sent =
          event === "blocked" ? notification : { ...notification, event, kind: undefined };
        return (await push.send(registration, sent))?.status;
      };

      // A start needs room for its end: the last start leaves one slot under the share.
      for (let index = 0; index < liveActivityPerDay - 2; index += 1) {
        expect(await status("update")).toBe("delivered");
      }
      expect(await status("start")).toBe("delivered");
      expect(await status("start")).toBe("throttled");
      expect(await status("update")).toBe("delivered");
      expect(await status("update")).toBe("throttled");

      // The rest is the alerts': routine ones stop short, so Needs you keeps the last.
      for (let index = liveActivityPerDay; index < routinePerDay; index += 1) {
        expect(await alert("notify")).toBe("delivered");
      }
      expect(await alert("notify")).toBe("throttled");
      for (let index = routinePerDay; index < perDay; index += 1) {
        expect(await alert("blocked")).toBe("delivered");
      }
      expect(await alert("blocked")).toBe("throttled");
      expect(calls).toHaveLength(perDay);

      // An end goes past the day's pushes, up to its overdraft, then stops.
      for (let index = 0; index < liveActivityEndOverdraft; index += 1) {
        expect(await status("end")).toBe("delivered");
      }
      expect(await status("end")).toBe("throttled");
      expect(calls).toHaveLength(perDay + liveActivityEndOverdraft);

      clock = Date.parse("2026-10-18T00:00:00Z");
      expect(await status("update")).toBe("delivered");
    });

    it("leaves a day of alerts with less room for the card", async () => {
      const { fetchImpl } = relayFetch({ [PRIMARY]: ok });
      const push = liveActivitySender(fetchImpl);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");
      const { liveActivityPerDay, routinePerMinute } = PUSH_DEVICE_BUDGET;
      for (let sent = 0; sent < liveActivityPerDay - 1; sent += 1) {
        if (sent % routinePerMinute === 0) clock += 60_000;
        const agentAlert = { ...notification, event: "notify" as const, kind: undefined };
        expect((await push.send(registration, agentAlert))?.status).toBe("delivered");
      }
      expect(
        (await push.sendLiveActivity(registration, { ...update, event: "start" }))?.status,
      ).toBe("throttled");
      expect((await push.sendLiveActivity(registration, update))?.status).toBe("delivered");
      expect((await push.sendLiveActivity(registration, update))?.status).toBe("throttled");
    });

    it("pauses starts and updates and ends apart: each waits out only its own 429", async () => {
      let refuse: "update" | "end" | undefined;
      const { fetchImpl } = relayFetch({
        [PRIMARY]: async () => new Response("{}", { status: 200 }),
      });
      const limited = (async (url: Parameters<typeof fetch>[0], init?: RequestInit) => {
        const event = (JSON.parse(String(init?.body)) as { event: string }).event;
        if (event === refuse) {
          return new Response(JSON.stringify({ error: "quota_exceeded" }), {
            status: 429,
            headers: { "retry-after": "36000" },
          });
        }
        return fetchImpl(url, init);
      }) as typeof fetch;
      const push = liveActivitySender(limited);
      const [registration] = push.registrations();
      if (!registration) throw new Error("missing registration");
      const status = async (event: "start" | "update" | "end") =>
        (
          await push.sendLiveActivity(
            registration,
            event === "end" ? { event, running: 0, needsYou: 0 } : { ...update, event },
          )
        )?.status;

      // The full day's quota refuses an update for hours; the end still goes.
      refuse = "update";
      expect(await status("update")).toBe("rejected");
      expect(await status("update")).toBe("throttled");
      expect(await status("start")).toBe("throttled");
      expect(await status("end")).toBe("delivered");

      // An end refused for hours holds back ends only, until its Retry-After passes.
      refuse = "end";
      clock += 11 * 3_600_000;
      expect(await status("end")).toBe("rejected");
      expect(await status("end")).toBe("throttled");
      expect(await status("update")).toBe("delivered");
      clock += 36_000_000;
      refuse = undefined;
      expect(await status("end")).toBe("delivered");
    });
  });
});

describe("RelayClient", () => {
  /** A response whose unread body reports being cancelled. */
  function tracked(status: number, cancelled: string[], label: string): Response {
    return new Response(
      new ReadableStream({
        cancel() {
          cancelled.push(label);
        },
      }),
      { status },
    );
  }

  it("cancels the bodies it does not read: success, failover, gone, and delete", async () => {
    const cancelled: string[] = [];
    const client = (responses: Record<string, () => Response>) =>
      new RelayClient([PRIMARY, STANDBY], { fetch: relayFetch(responses).fetchImpl });
    const request = {
      envelope: "x".repeat(Math.ceil((PUSH_ENVELOPE_BYTES * 4) / 3)) as SealedPushEnvelope,
    };
    const push = { event: "update" as const, running: 1, needsYou: 0 };

    await client({ [PRIMARY]: () => tracked(200, cancelled, "200") }).push("t", request);
    await client({
      [PRIMARY]: () => tracked(503, cancelled, "503"),
      [STANDBY]: () => tracked(200, cancelled, "standby 200"),
    }).push("t", request);
    await client({ [PRIMARY]: () => tracked(410, cancelled, "410") }).push("t", request);
    await client({
      [PRIMARY]: () => tracked(500, cancelled, "la 500"),
      [STANDBY]: () => tracked(200, cancelled, "la 200"),
    }).liveActivity("t", push);
    await client({ [PRIMARY]: () => tracked(404, cancelled, "delete") }).deletePermission("t");

    expect(cancelled).toEqual(["200", "503", "standby 200", "410", "la 500", "la 200", "delete"]);
  });

  it("refuses anything that is not a sealed v1 envelope", async () => {
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    const client = new RelayClient([PRIMARY], { fetch: fetchImpl });

    await expect(
      client.push("osp1.r.p.s", { envelope: "plaintext title" as SealedPushEnvelope }),
    ).rejects.toThrow("sealed v1 envelope");
    expect(calls).toHaveLength(0);
  });
});
