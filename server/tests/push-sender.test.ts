import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SealedPushEnvelope } from "../src/push/envelope.js";
import { PUSH_DEVICE_BUDGET, PushSender } from "../src/push/push-sender.js";
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
      await push.send(registration, { ...notification, event: "done", kind: undefined }),
    ).toEqual({
      status: "delivered",
    });

    expect(calls.map((call) => call.url)).toEqual([`${PRIMARY}/v1/push`, `${PRIMARY}/v1/push`]);
    expect(calls[0]?.authorization).toBe("Bearer osp1.r_a.p_a.secret-a");
    expect(calls[0]?.body.ttl).toBe(3600);
    expect(calls[0]?.body.collapseId).toMatch(/^[A-Za-z0-9_-]{22}$/);
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

  describe("per-device budget", () => {
    const done = { ...notification, event: "done" as const, kind: undefined };
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
      alert: typeof notification | typeof done,
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

      const routine = await sendMany(push, PUSH_DEVICE_BUDGET.routinePerMinute + 1, done);
      expect(routine.at(-1)).toBe("throttled");
      const reserve = PUSH_DEVICE_BUDGET.perMinute - PUSH_DEVICE_BUDGET.routinePerMinute;
      expect(await sendMany(push, reserve + 1, notification)).toEqual([
        ...Array<string>(reserve).fill("delivered"),
        "throttled",
      ]);
      expect(calls).toHaveLength(PUSH_DEVICE_BUDGET.perMinute);

      clock += 60_000;
      expect(await sendMany(push, 1, done)).toEqual(["delivered"]);
    });

    it("keeps daily room for approvals and resets on the next UTC day", async () => {
      const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
      const push = budgeted(fetchImpl);
      const perMinute = PUSH_DEVICE_BUDGET.routinePerMinute;

      for (let sent = 0; sent < PUSH_DEVICE_BUDGET.routinePerDay; sent += perMinute) {
        clock += 60_000;
        await sendMany(push, Math.min(perMinute, PUSH_DEVICE_BUDGET.routinePerDay - sent), done);
      }
      clock += 60_000;
      expect(await sendMany(push, 1, done)).toEqual(["throttled"]);
      expect(await sendMany(push, 1, notification)).toEqual(["delivered"]);
      expect(calls).toHaveLength(PUSH_DEVICE_BUDGET.routinePerDay + 1);

      clock = Date.parse("2026-10-18T00:00:00Z");
      expect(await sendMany(push, 1, done)).toEqual(["delivered"]);
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
});

describe("RelayClient", () => {
  it("refuses anything that is not a sealed v1 envelope", async () => {
    const { fetchImpl, calls } = relayFetch({ [PRIMARY]: ok });
    const client = new RelayClient([PRIMARY], { fetch: fetchImpl });

    await expect(
      client.push("osp1.r.p.s", { envelope: "plaintext title" as SealedPushEnvelope }),
    ).rejects.toThrow("sealed v1 envelope");
    expect(calls).toHaveLength(0);
  });
});
