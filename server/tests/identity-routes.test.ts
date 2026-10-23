import { createPrivateKey, generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { markLocalRequest } from "../src/request-trust.js";
import { PushSender } from "../src/push/push-sender.js";
import { pushRegistrationMessage } from "../src/push/registration.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "../src/security.js";
import { Storage } from "../src/storage.js";
import {
  makeRawRequest,
  makeRequest,
  makeResponse,
  makeUnconfiguredVoiceBackendHealth,
} from "./harness/route-test-helpers.js";

describe("identity module", () => {
  it("handles GET /me in isolation", async () => {
    const ctx = {
      storage: {
        getOwnerName: vi.fn(() => "Bob"),
      },
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/me",
      url: new URL("http://localhost/me"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({ user: "owner", name: "Bob" });
  });

  it("projects server-derived provider pacing through GET /server/provider-quotas", async () => {
    const status = {
      providers: [
        {
          providerId: "example",
          displayName: "Example",
          authenticated: true,
          planType: null,
          windows: [
            {
              key: "hourly",
              shortLabel: "1h",
              title: "Hourly",
              usedPercent: 46,
              remainingPercent: 54,
              limitWindowSeconds: 3600,
              resetAt: 203_309,
              includeWeekdayInReset: false,
              pacing: {
                source: "snapshot",
                status: "conserve",
                timeRemainingSeconds: 202_309,
                supplyRatio: 0.958,
                targetBurnPercentPerHour: 0.96,
                recentBurnPercentPerHour: null,
                paceRatio: null,
                projectedExhaustionAt: null,
                projectedRemainingPercent: null,
              },
            },
          ],
          credits: null,
          prepaidBalanceCents: null,
          fetchedAt: 1_000_000,
        },
      ],
      fetchedAt: 1_000_000,
    } as const;
    const ctx = {
      getProviderQuotasStatus: vi.fn(async () => status),
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    const handled = await dispatch({
      method: "GET",
      path: "/server/provider-quotas",
      url: new URL("http://localhost/server/provider-quotas"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual(status);
  });

  it("returns 404 for POST /pair/tailscale on the unix socket", async () => {
    const issuePairingToken = vi.fn(() => "pt_should_not_issue");
    const ctx = {
      storage: {
        getToken: vi.fn(() => "sk_owner"),
        getConfig: vi.fn(() => ({ tls: { mode: "self-signed" } })),
        issuePairingToken,
      },
    } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const req = makeRequest();
    markLocalRequest(req);
    const res = makeResponse();
    const handled = await dispatch({
      method: "POST",
      path: "/pair/tailscale",
      url: new URL("http://localhost/pair/tailscale"),
      req: req as never,
      res: res as never,
    });
    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body)).toEqual({ error: "Not found" });
    expect(issuePairingToken).not.toHaveBeenCalled();
  });

  it("returns 404 for POST /pair/tailscale with an owner sk_ bearer", async () => {
    const issuePairingToken = vi.fn(() => "pt_should_not_issue");
    const ctx = {
      storage: {
        getToken: vi.fn(() => "sk_owner"),
        getConfig: vi.fn(() => ({ tls: { mode: "self-signed" } })),
        issuePairingToken,
      },
    } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const req = makeRequest();
    req.headers = { authorization: "Bearer sk_owner" };
    const res = makeResponse();
    const handled = await dispatch({
      method: "POST",
      path: "/pair/tailscale",
      url: new URL("https://paired.example/pair/tailscale"),
      req: req as never,
      res: res as never,
    });
    expect(handled).toBe(true);
    expect(res.statusCode).toBe(404);
    expect(issuePairingToken).not.toHaveBeenCalled();
  });

  it("validates POST /pair body", async () => {
    const ctx = {
      storage: {},
      pairing: { customApproverAvailable: false },
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/pair",
      url: new URL("http://localhost/pair"),
      req: makeRequest({}) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "pairingToken required" });
  });

  it("rejects pairing requests that omit a device public key without consuming the invite", async () => {
    const pairWithInvite = vi.fn();
    const ctx = {
      storage: {},
      pairing: { customApproverAvailable: false, pairWithInvite },
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/pair",
      url: new URL("https://paired.example/pair"),
      req: makeRequest({ pairingToken: "pt_old" }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(pairWithInvite).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body)).toEqual({ error: "devicePublicKey required" });
  });

  it("issues a challenge without a live access token", async () => {
    const issueChallenge = vi.fn(() => ({
      nonce: "n1",
      audience: "oppi:refresh:v1",
      expiresAt: 123,
    }));
    const ctx = { storage: { issueChallenge } } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    const handled = await dispatch({
      method: "POST",
      path: "/auth/challenge",
      url: new URL("https://paired.example/auth/challenge"),
      req: makeRequest({ deviceId: "dev_known" }) as never,
      res: res as never,
    });
    expect(handled).toBe(true);
    expect(issueChallenge).toHaveBeenCalledWith("dev_known");
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({
      nonce: "n1",
      audience: "oppi:refresh:v1",
      expiresAt: 123,
    });
  });

  it("returns 429 when a source bursts unauthenticated challenges", async () => {
    const issueChallenge = vi.fn(() => ({
      nonce: "n",
      audience: "oppi:refresh:v1",
      expiresAt: 1,
    }));
    const ctx = { storage: { issueChallenge } } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    let last = makeResponse();
    for (let i = 0; i < 9; i += 1) {
      last = makeResponse();
      await dispatch({
        method: "POST",
        path: "/auth/challenge",
        url: new URL("https://paired.example/auth/challenge"),
        req: makeRequest({ deviceId: "dev_known" }) as never,
        res: last as never,
      });
    }
    expect(last.statusCode).toBe(429);
    expect(issueChallenge.mock.calls.length).toBeLessThan(9);
  });

  it("rejects oversized bootstrap bodies before challenge issuance", async () => {
    const issueChallenge = vi.fn();
    const ctx = { storage: { issueChallenge } } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    const handled = await dispatch({
      method: "POST",
      path: "/auth/challenge",
      url: new URL("https://paired.example/auth/challenge"),
      req: makeRawRequest(
        JSON.stringify({ deviceId: "dev_known", padding: "x".repeat(20_000) }),
      ) as never,
      res: res as never,
    });
    expect(handled).toBe(true);
    expect(issueChallenge).not.toHaveBeenCalled();
    expect(res.statusCode).toBe(413);
  });

  it("allows authenticated devices to list and revoke devices", async () => {
    const listDevices = vi.fn(() => [
      {
        id: "dev_a",
        name: "Phone",
        scope: "device",
        createdAt: 1,
        lastUsedAt: 2,
        publicKey: { kty: "EC" },
      },
    ]);
    const revokeDevice = vi.fn(() => true);
    const ctx = {
      storage: { listDevices, revokeDevice },
    } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());

    const listRes = makeResponse();
    await dispatch({
      method: "GET",
      path: "/auth/devices",
      url: new URL("https://paired.example/auth/devices"),
      req: makeRequest() as never,
      res: listRes as never,
    });
    expect(listRes.statusCode).toBe(200);
    expect(JSON.parse(listRes.body).devices[0].id).toBe("dev_a");

    const revokeRes = makeResponse();
    await dispatch({
      method: "DELETE",
      path: "/auth/devices/dev_a",
      url: new URL("https://paired.example/auth/devices/dev_a"),
      req: makeRequest() as never,
      res: revokeRes as never,
    });
    expect(revokeDevice).toHaveBeenCalledWith("dev_a");
    expect(revokeRes.statusCode).toBe(200);
  });

  describe("revoking a device that has a Live Activity card", () => {
    const registration = { deviceId: "dev_a", sendToken: "osp1.r.p.s", liveActivity: true };

    function revoke(
      endLiveActivityCard: (deviceId: string) => Promise<void>,
      order: string[],
    ): { res: ReturnType<typeof makeResponse>; releasePermission: ReturnType<typeof vi.fn> } {
      const releasePermission = vi.fn(() => void order.push("release"));
      const ctx = {
        storage: {
          getPushRegistrations: () => [registration],
          revokeDevice: () => {
            order.push("revoke");
            return true;
          },
        },
        push: { sender: { releasePermission } },
        endLiveActivityCard: (deviceId: string) => {
          order.push(`end ${deviceId}`);
          return endLiveActivityCard(deviceId);
        },
      } as unknown as RouteContext;
      const res = makeResponse();
      void createIdentityRoutes(
        ctx,
        createRouteHelpers(),
      )({
        method: "DELETE",
        path: "/auth/devices/dev_a",
        url: new URL("https://paired.example/auth/devices/dev_a"),
        req: makeRequest() as never,
        res: res as never,
      });
      return { res, releasePermission };
    }

    it("ends the card before the registration goes and releases the permission after it", async () => {
      const order: string[] = [];
      let finishEnd: () => void = () => undefined;
      const { res, releasePermission } = revoke(
        () => new Promise<void>((resolve) => (finishEnd = resolve)),
        order,
      );
      await vi.waitFor(() => expect(res.statusCode).toBe(200));
      // The revoke answered without waiting for the end.
      expect(order).toEqual(["end dev_a", "revoke"]);
      expect(releasePermission).not.toHaveBeenCalled();
      finishEnd();
      await vi.waitFor(() => expect(releasePermission).toHaveBeenCalledWith(registration));
      expect(order).toEqual(["end dev_a", "revoke", "release"]);
    });

    it("still revokes and releases when ending the card fails", async () => {
      const order: string[] = [];
      const { res, releasePermission } = revoke(
        () => Promise.reject(new Error("relay down")),
        order,
      );
      await vi.waitFor(() => expect(releasePermission).toHaveBeenCalledWith(registration));
      expect(res.statusCode).toBe(200);
      expect(order).toEqual(["end dev_a", "revoke", "release"]);
    });
  });

  it("rotating the owner token ends every device's card before it removes the registrations, then releases each permission", async () => {
    const registrations = [
      { deviceId: "dev_a", sendToken: "osp1.r.p.a", liveActivity: true },
      { deviceId: "dev_b", sendToken: "osp1.r.p.b", liveActivity: true },
    ];
    const order: string[] = [];
    const finish = new Map<string, () => void>();
    const releasePermission = vi.fn((registration: { deviceId: string }) =>
      order.push(`release ${registration.deviceId}`),
    );
    const ctx = {
      storage: {
        getPushRegistrations: () => registrations,
        rotateToken: () => order.push("rotate"),
      },
      push: { sender: { releasePermission } },
      endLiveActivityCard: (deviceId: string) => {
        order.push(`end ${deviceId}`);
        // dev_a's relay call fails; dev_b's is slow.
        if (deviceId === "dev_a") return Promise.reject(new Error("relay down"));
        return new Promise<void>((resolve) => finish.set(deviceId, resolve));
      },
    } as unknown as RouteContext;
    const req = makeRequest();
    markLocalRequest(req);
    const res = makeResponse();
    await createIdentityRoutes(
      ctx,
      createRouteHelpers(),
    )({
      method: "POST",
      path: "/auth/rotate",
      url: new URL("http://localhost/auth/rotate"),
      req: req as never,
      res: res as never,
    });
    // Answered without waiting for the ends; both ends started before the rotation.
    expect(res.statusCode).toBe(200);
    expect(order.slice(0, 3)).toEqual(["end dev_a", "end dev_b", "rotate"]);
    await vi.waitFor(() => expect(order).toContain("release dev_a"));
    expect(order).not.toContain("release dev_b");
    finish.get("dev_b")?.();
    await vi.waitFor(() => expect(order).toContain("release dev_b"));
  });

  it.each(["/auth/migrate", "/auth/finalize", "/auth/compat"])(
    "does not dispatch deleted %s",
    async (path) => {
      const dispatch = createIdentityRoutes({ storage: {} } as RouteContext, createRouteHelpers());
      expect(
        await dispatch({
          method: "POST",
          path,
          url: new URL(`https://paired.example${path}`),
          req: makeRequest() as never,
          res: makeResponse() as never,
        }),
      ).toBe(false);
    },
  );

  it("keeps rotate on the local socket", async () => {
    const rotateToken = vi.fn();
    const ctx = {
      storage: { rotateToken },
    } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());

    for (const path of ["/auth/rotate"]) {
      const res = makeResponse();
      await dispatch({
        method: "POST",
        path,
        url: new URL(`https://paired.example${path}`),
        req: makeRequest() as never,
        res: res as never,
      });
      expect(res.statusCode).toBe(403);
    }
    expect(rotateToken).not.toHaveBeenCalled();
  });

  it("includes uploadProtocol in GET /server/info", async () => {
    const ctx = {
      storage: {
        getConfig: vi.fn(() => ({
          configVersion: 2,
          uploadStore: {
            maxFileBytes: 123,
            maxTurnBytes: 456,
          },
          images: {
            autoResize: true,
          },
        })),
        listWorkspaces: vi.fn(() => []),
        listSessions: vi.fn(() => []),
      },
      sessions: {
        getActiveSessionIds: vi.fn(() => new Set()),
        durableSessionsAvailable: () => false,
        conversationStreamAvailable: () => false,
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set()),
      },
      skillRegistry: {
        list: vi.fn(() => []),
      },
      getModelCatalog: vi.fn(() => []),
      voiceBackendHealth: makeUnconfiguredVoiceBackendHealth(),
      serverStartedAt: Date.now(),
      serverVersion: "test",
      piVersion: "test",
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/server/info",
      url: new URL("http://localhost/server/info"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      uploadProtocol: { version: number; maxFileBytes: number; maxTurnBytes: number };
      images: { autoResize: boolean };
      capabilities: {
        extensionNativeUI: {
          version: number;
          capabilities: string[];
        };
        workspaceFileEditing: { version: number; maxBytes: number };
        skillFileEditing: { version: number; maxBytes: number };
      };
    };
    expect(body.uploadProtocol).toEqual({ version: 1, maxFileBytes: 123, maxTurnBytes: 456 });
    expect(body.images).toEqual({ autoResize: true });
    expect(body.capabilities.extensionNativeUI).toEqual({
      version: 1,
      capabilities: [
        "extension-native-ui:v1:text-fallback",
        "extension-native-ui:v1:prompt-native",
        "extension-native-ui:v1:surface-native",
        "extension-native-ui:v1:osc8-links",
      ],
    });
    expect(body.capabilities.workspaceFileEditing).toEqual({
      version: 1,
      maxBytes: 1_048_576,
    });
    expect(body.capabilities.skillFileEditing).toEqual({
      version: 1,
      maxBytes: 1_048_576,
    });
  });

  it("advertises pushNotifications in GET /server/info only in relay mode", async () => {
    async function capabilities(relays: string[] | undefined) {
      const ctx = {
        storage: {
          getConfig: vi.fn(() => ({ configVersion: 2 })),
          listWorkspaces: vi.fn(() => []),
          listSessions: vi.fn(() => []),
        },
        sessions: {
          durableSessionsAvailable: () => false,
          conversationStreamAvailable: () => false,
        },
        sessionRuntimes: { getActiveSessionIds: vi.fn(() => new Set()) },
        skillRegistry: { list: vi.fn(() => []) },
        getModelCatalog: vi.fn(() => []),
        voiceBackendHealth: makeUnconfiguredVoiceBackendHealth(),
        serverStartedAt: Date.now(),
        serverVersion: "test",
        piVersion: "test",
        push: {
          sender: { relays: () => relays },
          serverPublicKey: "server-public-key",
          serverFingerprint: "sha256:fixture",
        },
      } as unknown as RouteContext;
      const res = makeResponse();
      await createIdentityRoutes(
        ctx,
        createRouteHelpers(),
      )({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: res as never,
      });
      return (JSON.parse(res.body) as { capabilities: Record<string, unknown> }).capabilities;
    }

    // push.mode off advertises nothing, so apps never register or prompt.
    expect(await capabilities(undefined)).not.toHaveProperty("pushNotifications");
    expect(
      (await capabilities(["https://push.example.test", "https://standby.example.test"]))
        .pushNotifications,
    ).toEqual({ version: 1, relay: "https://push.example.test" });
  });

  it("uses ctx.piVersion as Pi SDK and includes piCliVersion when a TUI/CLI version is known", async () => {
    const ctx = {
      storage: {
        getConfig: vi.fn(() => ({ configVersion: 1 })),
        listWorkspaces: vi.fn(() => []),
        listSessions: vi.fn(() => []),
      },
      sessions: {
        getActiveSessionIds: vi.fn(() => new Set()),
        durableSessionsAvailable: () => false,
        conversationStreamAvailable: () => false,
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set()),
      },
      skillRegistry: {
        list: vi.fn(() => []),
      },
      getModelCatalog: vi.fn(() => []),
      voiceBackendHealth: makeUnconfiguredVoiceBackendHealth(),
      serverStartedAt: Date.now(),
      serverVersion: "0.48.0",
      piVersion: "0.85.0",
      piCliVersion: "0.84.4",
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();
    const handled = await dispatch({
      method: "GET",
      path: "/server/info",
      url: new URL("http://localhost/server/info"),
      req: {} as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as Record<string, unknown>;
    expect(body.piVersion).toBe("0.85.0");
    expect(body.piCliVersion).toBe("0.84.4");
  });

  it("omits piCliVersion on GET /server/info when CLI detection is unknown or empty", async () => {
    for (const piCliVersion of [undefined, "unknown", "", "   "]) {
      const ctx = {
        storage: {
          getConfig: vi.fn(() => ({ configVersion: 1 })),
          listWorkspaces: vi.fn(() => []),
          listSessions: vi.fn(() => []),
        },
        sessions: {
          getActiveSessionIds: vi.fn(() => new Set()),
          durableSessionsAvailable: () => false,
          conversationStreamAvailable: () => false,
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set()),
        },
        skillRegistry: {
          list: vi.fn(() => []),
        },
        getModelCatalog: vi.fn(() => []),
        voiceBackendHealth: makeUnconfiguredVoiceBackendHealth(),
        serverStartedAt: Date.now(),
        serverVersion: "0.48.0",
        piVersion: "0.85.0",
        piCliVersion,
      } as unknown as RouteContext;

      const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
      const res = makeResponse();
      const handled = await dispatch({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: res as never,
      });

      expect(handled).toBe(true);
      expect(res.statusCode).toBe(200);
      const body = JSON.parse(res.body) as Record<string, unknown>;
      expect(body.piVersion).toBe("0.85.0");
      expect(body).not.toHaveProperty("piCliVersion");
    }
  });

  it("returns false for unrelated routes", async () => {
    const dispatch = createIdentityRoutes({} as RouteContext, createRouteHelpers());

    const handled = await dispatch({
      method: "GET",
      path: "/identity/nope",
      url: new URL("http://localhost/identity/nope"),
      req: {} as never,
      res: makeResponse() as never,
    });

    expect(handled).toBe(false);
  });
});

describe("deleted auth route persistence", () => {
  let dataDir: string;
  let storage: Storage;

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("does not dispatch or write config for POST /auth/migrate", async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-identity-migrate-"));
    storage = new Storage(dataDir);
    storage.ensurePaired();
    const configPath = storage.getConfigPath();
    const before = statSync(configPath);
    const fingerprint = `${before.ino}:${before.mtimeNs}:${before.size}`;

    const dispatch = createIdentityRoutes(
      { storage } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const req = makeRequest({ devicePublicKey: {} });
    req.headers = { authorization: "Bearer not-a-credential" };
    const res = makeResponse();
    const handled = await dispatch({
      method: "POST",
      path: "/auth/migrate",
      url: new URL("https://paired.example/auth/migrate"),
      req: req as never,
      res: res as never,
    });

    expect(handled).toBe(false);
    const after = statSync(configPath);
    expect(`${after.ino}:${after.mtimeNs}:${after.size}`).toBe(fingerprint);
  });
});

describe("PUT /me/push-registration after the relay retired a send token", () => {
  const PRIMARY = "https://primary.example.test";
  const vectors = JSON.parse(
    readFileSync(
      new URL("../../protocol/push/vectors/cryptokit-hpke.json", import.meta.url),
      "utf8",
    ),
  ) as { recipient: { publicKey: string; keyId: string } };
  let dataDir: string;

  afterEach(() => rmSync(dataDir, { recursive: true, force: true }));

  it("answers 409 push_disabled while the server runs with push off", async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-identity-push-off-"));
    const dispatch = createIdentityRoutes(
      { push: { sender: { relays: () => undefined } } } as unknown as RouteContext,
      createRouteHelpers(),
    );
    const res = makeResponse();
    await dispatch({
      method: "PUT",
      path: "/me/push-registration",
      url: new URL("http://localhost/me/push-registration"),
      req: makeRequest({}) as never,
      res: res as never,
      principal: { kind: "device", deviceId: "dev", tokenClass: "at_" },
    });
    expect(res.statusCode).toBe(409);
    expect(JSON.parse(res.body)).toEqual({ error: "push_disabled" });
  });

  it("answers 410 send_token_gone for that token only", async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-identity-push-gone-"));
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    storage.updateConfig({ push: { mode: "relay", relays: [PRIMARY] } });
    const deviceKeys = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const jwk = deviceKeys.publicKey.export({ format: "jwk" }) as { x: string; y: string };
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    });
    if (!enrolled) throw new Error("enrollment failed");
    const identity = ensureIdentityMaterial(identityConfigForDataDir(dataDir));
    const relayAnswers = vi.fn(async () => new Response('{"error":"gone"}', { status: 410 }));
    const sender = new PushSender(storage, {
      signingKey: createPrivateKey(identity.privateKeyPem),
      fetch: relayAnswers as unknown as typeof fetch,
    });
    const dispatch = createIdentityRoutes(
      {
        storage,
        push: {
          sender,
          serverPublicKey: "server-public-key",
          serverFingerprint: identity.fingerprint,
        },
      } as unknown as RouteContext,
      createRouteHelpers(),
    );

    async function register(sendToken: string) {
      const issuedAt = Date.now();
      const signature = sign(
        "sha256",
        pushRegistrationMessage({
          deviceId: enrolled!.deviceId,
          serverFingerprint: identity.fingerprint,
          keyId: vectors.recipient.keyId,
          publicKey: Buffer.from(vectors.recipient.publicKey, "base64url"),
          sendToken,
          relay: PRIMARY,
          issuedAt,
        }),
        { key: deviceKeys.privateKey, dsaEncoding: "ieee-p1363" },
      );
      const res = makeResponse();
      await dispatch({
        method: "PUT",
        path: "/me/push-registration",
        url: new URL("http://localhost/me/push-registration"),
        req: makeRequest({
          keyId: vectors.recipient.keyId,
          publicKey: vectors.recipient.publicKey,
          sendToken,
          relay: PRIMARY,
          issuedAt,
          signature: signature.toString("base64url"),
          events: ["blocked"],
        }) as never,
        res: res as never,
        principal: { kind: "device", deviceId: enrolled!.deviceId, tokenClass: "at_" },
      });
      return { status: res.statusCode, body: JSON.parse(res.body) as Record<string, unknown> };
    }

    expect((await register("osp1.r_a.p_a.old")).status).toBe(200);
    const [registration] = storage.getPushRegistrations();
    if (!registration) throw new Error("missing registration");
    // The primary relay retires the token: the server prunes the registration.
    await sender.send(registration, {
      event: "blocked",
      kind: "question",
      sessionId: "s1",
      title: "Question",
      body: "Waiting for your answer.",
    });
    expect(storage.getPushRegistrations()).toEqual([]);

    expect(await register("osp1.r_a.p_a.old")).toEqual({
      status: 410,
      body: { error: "send_token_gone" },
    });
    expect(storage.getPushRegistrations()).toEqual([]);
    expect((await register("osp1.r_a.p_b.new")).status).toBe(200);
  });
});
