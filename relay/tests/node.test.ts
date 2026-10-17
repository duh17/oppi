import { generateKeyPairSync, verify } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer, type Http2Server } from "node:http2";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  PUSHES_PER_ADDRESS_PER_MINUTE,
  requestClientData,
  registrationClientData,
} from "../src/core/relay.js";
import { CaptureApnsSender, Http2ApnsSender } from "../src/node/apns-http2.js";
import { MemoryRelayStore } from "../src/node/memory-store.js";
import { DEFAULT_QUOTA_LIMITS } from "../src/core/store.js";
import { startNodeRelay } from "../src/node/server.js";
import {
  createAssertion,
  createAttestation,
  createCA,
  sha256,
  type AppAttestCA,
  type AttestationOptions,
} from "./helpers/app-attest-fixture.js";
import {
  APNS_TOKEN,
  APP_ID,
  BUNDLE_ID,
  call,
  defineRelaySuite,
  fakeEnvelope,
  mintSendToken,
  nextAddress,
  registerUnattested,
  type CapturedApnsRequest,
  type RelayHarness,
} from "./suite/relay-suite.js";

const apnsKey = generateKeyPairSync("ec", { namedCurve: "P-256" });
const apnsKeyP8 = apnsKey.privateKey.export({ type: "pkcs8", format: "pem" }).toString();

interface MockApns {
  origins: { sandbox: string; production: string };
  requests: CapturedApnsRequest[];
  authorizations: string[];
  handler: (request: CapturedApnsRequest) => { status: number; reason?: string };
  close(): Promise<void>;
}

/** Two h2c servers standing in for Apple's sandbox and production hosts. */
async function startMockApns(): Promise<MockApns> {
  const mock: MockApns = {
    origins: { sandbox: "", production: "" },
    requests: [],
    authorizations: [],
    handler: () => ({ status: 200 }),
    close: async () => {},
  };
  const servers: Http2Server[] = [];
  for (const environment of ["sandbox", "production"] as const) {
    const host = environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const server = createServer();
    server.on("stream", (stream, headers) => {
      let payload = "";
      stream.setEncoding("utf8");
      stream.on("data", (chunk: string) => (payload += chunk));
      stream.on("end", () => {
        const apnsHeaders = Object.fromEntries(
          Object.entries(headers).filter(([name]) => name.startsWith("apns-")),
        ) as Record<string, string>;
        const request = { host, path: String(headers[":path"]), headers: apnsHeaders, payload };
        mock.requests.push(request);
        mock.authorizations.push(String(headers.authorization ?? ""));
        const result = mock.handler(request);
        stream.respond({ ":status": result.status, "content-type": "application/json" });
        stream.end(result.reason ? JSON.stringify({ reason: result.reason }) : "");
      });
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    mock.origins[environment] = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    servers.push(server);
  }
  mock.close = async () => {
    await Promise.all(servers.map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
  };
  return mock;
}

interface NodeHarness extends RelayHarness {
  apns: MockApns;
  advance(ms: number): void;
}

async function startHarness(options: { trustRootPem?: string; now?: number } = {}): Promise<NodeHarness> {
  const apns = await startMockApns();
  const sender = new Http2ApnsSender({ keyP8: apnsKeyP8, keyId: "KEYID12345", teamId: "TESTTEAM01" }, apns.origins);
  const store = new MemoryRelayStore();
  const logs: string[] = [];
  let offset = 0;
  const base = options.now;
  const relay = await startNodeRelay({
    store,
    apns: sender,
    config: { appId: APP_ID, bundleId: BUNDLE_ID, ...(options.trustRootPem ? { trustRootPem: options.trustRootPem } : {}) },
    log: (event, fields) => logs.push(JSON.stringify({ event, ...fields })),
    now: () => (base ?? Date.now()) + offset,
    trustForwardedFor: true,
  });
  return {
    url: relay.url,
    apns,
    apnsRequests: apns.requests,
    respondApns: (handler) => {
      apns.handler = handler;
    },
    storageText: async () => store.dump(),
    logs,
    advance: (ms) => {
      offset += ms;
    },
    close: async () => {
      sender.close();
      await relay.close();
      await apns.close();
    },
  };
}

defineRelaySuite("node", () => startHarness());

describe("node adapter", () => {
  let harness: NodeHarness;
  afterEach(async () => harness?.close());

  it("signs APNs requests with an ES256 provider token from the .p8 key", async () => {
    harness = await startHarness();
    const sendToken = await mintSendToken(harness, await registerUnattested(harness));
    await call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } });

    const [authorization] = harness.apns.authorizations;
    const [header, claims, signature] = (authorization ?? "").replace(/^bearer /, "").split(".");
    expect(JSON.parse(Buffer.from(header ?? "", "base64url").toString())).toEqual({ alg: "ES256", kid: "KEYID12345" });
    expect(JSON.parse(Buffer.from(claims ?? "", "base64url").toString())).toMatchObject({ iss: "TESTTEAM01" });
    expect(
      verify(
        "sha256",
        Buffer.from(`${header}.${claims}`),
        { key: apnsKey.publicKey, dsaEncoding: "ieee-p1363" },
        Buffer.from(signature ?? "", "base64url"),
      ),
    ).toBe(true);
  });

  it("expires challenges after five minutes", async () => {
    harness = await startHarness();
    const address = nextAddress();
    const challenge = (await call(harness, "POST", "/v1/challenge", { address })).json.challenge;
    harness.advance(301_000);
    const response = await call(harness, "POST", "/v1/registrations", {
      address,
      body: { challenge, apnsToken: APNS_TOKEN, environment: "sandbox", attestation: null },
    });
    expect(response.json.error).toBe("challenge_invalid");
  });

  it("allows five unattested registrations per client address an hour", async () => {
    harness = await startHarness();
    const address = nextAddress();
    const register = async () => {
      const challenge = (await call(harness, "POST", "/v1/challenge")).json.challenge;
      return call(harness, "POST", "/v1/registrations", {
        address,
        body: { challenge, apnsToken: APNS_TOKEN, environment: "sandbox", attestation: null },
      });
    };
    for (let index = 0; index < 5; index += 1) expect((await register()).status).toBe(201);
    expect((await register()).json.error).toBe("rate_limited");
    harness.advance(3_600_000);
    expect((await register()).status).toBe(201);
  });

  it("limits pushes per client address a minute before looking up the send token", async () => {
    harness = await startHarness();
    const address = nextAddress();
    const madeUp = `osp1.r_${"A".repeat(22)}.p_${"B".repeat(22)}.${"C".repeat(43)}`;
    const push = (bearer: string, from = address) =>
      call(harness, "POST", "/v1/push", { address: from, bearer, body: { envelope: fakeEnvelope() } });
    for (let index = 0; index < PUSHES_PER_ADDRESS_PER_MINUTE; index += 1) {
      expect((await push(madeUp)).status).toBe(410);
    }
    const limited = await push(madeUp);
    expect(limited).toMatchObject({ status: 429, json: { error: "rate_limited" } });
    expect(limited.headers.get("retry-after")).toBe("60");
    // The limit is the address's, not the token's: a real token from it waits too.
    const sendToken = await mintSendToken(harness, await registerUnattested(harness));
    expect((await push(sendToken)).status).toBe(429);
    expect((await push(sendToken, nextAddress())).status).toBe(200);
    harness.advance(60_000);
    expect((await push(sendToken)).status).toBe(200);
  });

  it("stops an unattested registration at its daily limit until the next UTC day", async () => {
    harness = await startHarness({ now: Date.parse("2026-10-10T00:00:00Z") });
    const sendToken = await mintSendToken(harness, await registerUnattested(harness));
    const push = () => call(harness, "POST", "/v1/push", { bearer: sendToken, body: { envelope: fakeEnvelope() } });
    for (let index = 0; index < DEFAULT_QUOTA_LIMITS.unattestedPerDay; index += 1) {
      if (index % DEFAULT_QUOTA_LIMITS.perMinute === 0) harness.advance(61_000);
      expect((await push()).status).toBe(200);
    }
    harness.advance(61_000);
    const limited = await push();
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(3600);
    harness.advance(24 * 3_600_000);
    expect((await push()).status).toBe(200);
  });

  it("records the exact APNs request in capture mode instead of sending it", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-relay-capture-"));
    const capturePath = join(dir, "apns.jsonl");
    const relay = await startNodeRelay({
      store: new MemoryRelayStore(),
      apns: new CaptureApnsSender(capturePath),
      config: { appId: APP_ID, bundleId: BUNDLE_ID },
      trustForwardedFor: true,
    });
    try {
      const capture = { url: relay.url } as RelayHarness;
      const sendToken = await mintSendToken(capture, await registerUnattested(capture));
      const envelope = fakeEnvelope();
      expect((await call(capture, "POST", "/v1/push", { bearer: sendToken, body: { envelope } })).status).toBe(200);
      const [line] = readFileSync(capturePath, "utf8").trim().split("\n");
      const captured = JSON.parse(line ?? "{}") as CapturedApnsRequest;
      expect(captured.host).toBe("api.sandbox.push.apple.com");
      expect(captured.path).toBe(`/3/device/${APNS_TOKEN}`);
      expect(JSON.parse(captured.payload)).toMatchObject({ e: envelope, aps: { "mutable-content": 1 } });
    } finally {
      await relay.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("App Attest (node adapter with a test root)", () => {
  let harness: NodeHarness;
  let ca: AppAttestCA;

  beforeEach(async () => {
    ca = await createCA(Date.now());
    harness = await startHarness({ trustRootPem: ca.rootPem });
  });
  afterEach(async () => harness.close());

  async function attest(
    environment: "sandbox" | "production",
    options: Partial<AttestationOptions> = {},
  ) {
    const address = nextAddress();
    const challenge = (await call(harness, "POST", "/v1/challenge", { address })).json.challenge as string;
    const clientDataHash = await sha256(
      new TextEncoder().encode(registrationClientData(challenge, APNS_TOKEN, environment)),
    );
    const attestation = await createAttestation(ca, {
      appId: APP_ID,
      clientDataHash,
      now: Date.now(),
      aaguid: environment === "sandbox" ? "development" : "production",
      ...options,
    });
    const response = await call(harness, "POST", "/v1/registrations", {
      address,
      body: {
        challenge,
        apnsToken: APNS_TOKEN,
        environment,
        attestation: { keyId: attestation.keyId, object: attestation.object },
      },
    });
    return { response, attestation };
  }

  async function assertionHeader(
    credential: Awaited<ReturnType<typeof attest>>["attestation"]["credential"],
    method: string,
    path: string,
    body: string,
    counter: number,
  ): Promise<string> {
    const clientData = await requestClientData(method, path, new TextEncoder().encode(body));
    return createAssertion({
      credential,
      appId: APP_ID,
      counter,
      clientDataHash: await sha256(new TextEncoder().encode(clientData)),
    });
  }

  it("registers an attested development key for sandbox with the higher limit", async () => {
    const { response } = await attest("sandbox");
    expect(response.status).toBe(201);
    expect(response.json).toMatchObject({
      attested: true,
      limits: { pushesPerDay: DEFAULT_QUOTA_LIMITS.attestedPerDay },
    });
  });

  it("registers an attested production key for production and pushes to the production host", async () => {
    const { response, attestation } = await attest("production", { aaguid: "production" });
    expect(response.status).toBe(201);
    const { registrationId, registrationSecret } = response.json as { registrationId: string; registrationSecret: string };
    const path = `/v1/registrations/${registrationId}/permissions`;
    const minted = await call(harness, "POST", path, {
      bearer: registrationSecret,
      rawBody: "{}",
      headers: { "x-oppi-assertion": await assertionHeader(attestation.credential, "POST", path, "{}", 1) },
    });
    expect(minted.status).toBe(201);
    const pushed = await call(harness, "POST", "/v1/push", {
      bearer: minted.json.sendToken as string,
      body: { envelope: fakeEnvelope() },
    });
    expect(pushed.status).toBe(200);
    expect(harness.apnsRequests.at(-1)?.host).toBe("api.push.apple.com");
  });

  it.each<[string, Partial<AttestationOptions>, "sandbox" | "production"]>([
    ["a development key for production", { aaguid: "development" }, "production"],
    ["an unknown AAGUID", { aaguid: "bogus" }, "sandbox"],
    ["a certificate nonce for other data", { wrongNonce: true }, "sandbox"],
    ["another app ID", { appId: "OTHERTEAM.dev.chenda.Oppi" }, "sandbox"],
    ["a nonzero counter", { counter: 1 }, "sandbox"],
    ["an expired credential certificate", { expired: true }, "sandbox"],
    ["a chain to another root", { untrustedIssuer: true }, "sandbox"],
  ])("rejects %s", async (_label, options, environment) => {
    expect((await attest(environment, options)).response).toMatchObject({
      status: 401,
      json: { error: "attestation_invalid" },
    });
  });

  it.each(["not-ca", "absent"] as const)(
    "rejects a chain whose intermediate is not a CA (basicConstraints %s)",
    async (constraints) => {
      await harness.close();
      ca = await createCA(Date.now(), constraints);
      harness = await startHarness({ trustRootPem: ca.rootPem });
      expect((await attest("sandbox")).response).toMatchObject({
        status: 401,
        json: { error: "attestation_invalid" },
      });
    },
  );

  it("rejects an attestation for a different key ID", async () => {
    const address = nextAddress();
    const challenge = (await call(harness, "POST", "/v1/challenge", { address })).json.challenge as string;
    const clientDataHash = await sha256(
      new TextEncoder().encode(registrationClientData(challenge, APNS_TOKEN, "sandbox")),
    );
    const attestation = await createAttestation(ca, { appId: APP_ID, clientDataHash, now: Date.now() });
    const response = await call(harness, "POST", "/v1/registrations", {
      address,
      body: {
        challenge,
        apnsToken: APNS_TOKEN,
        environment: "sandbox",
        attestation: { keyId: Buffer.alloc(32, 7).toString("base64"), object: attestation.object },
      },
    });
    expect(response.json.error).toBe("attestation_invalid");
  });

  it("requires a fresh assertion over the exact request for an attested registration", async () => {
    const { response, attestation } = await attest("sandbox");
    const { registrationId, registrationSecret } = response.json as { registrationId: string; registrationSecret: string };
    const path = `/v1/registrations/${registrationId}/permissions`;
    const mint = (headers: Record<string, string> = {}) =>
      call(harness, "POST", path, { bearer: registrationSecret, rawBody: "{}", headers });

    expect((await mint()).json.error).toBe("assertion_invalid");
    const first = await assertionHeader(attestation.credential, "POST", path, "{}", 1);
    expect((await mint({ "x-oppi-assertion": first })).status).toBe(201);
    // Replaying the same assertion (same counter) fails.
    expect((await mint({ "x-oppi-assertion": first })).json.error).toBe("assertion_invalid");
    // An assertion over a different body fails.
    const otherBody = await assertionHeader(attestation.credential, "POST", path, '{"x":1}', 2);
    expect((await mint({ "x-oppi-assertion": otherBody })).json.error).toBe("assertion_invalid");
    const next = await assertionHeader(attestation.credential, "POST", path, "{}", 3);
    expect((await mint({ "x-oppi-assertion": next })).status).toBe(201);
  });
});
