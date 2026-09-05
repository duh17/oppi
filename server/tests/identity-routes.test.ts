import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { Storage } from "../src/storage.js";
import { makeRawRequest, makeRequest, makeResponse } from "./harness/route-test-helpers.js";

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

  it("validates POST /pair body", async () => {
    const ctx = {
      storage: {
        enrollViaPairing: vi.fn(() => null),
      },
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

  it("enrolls an HTTPS device key", async () => {
    const enrollViaPairing = vi.fn(() => ({
      deviceId: "dev_bound",
      accessToken: "at_bound",
      expiresAt: 123,
      refreshChallenge: { nonce: "n", audience: "oppi:refresh:v1", expiresAt: 456 },
    }));
    const ctx = {
      storage: { enrollViaPairing },
    } as unknown as RouteContext;

    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "POST",
      path: "/pair",
      url: new URL("https://paired.example/pair"),
      req: makeRequest({
        pairingToken: "pt_dual",
        devicePublicKey: { kty: "EC", crv: "P-256", x: "x", y: "y" },
      }) as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(enrollViaPairing).toHaveBeenCalledWith("pt_dual", {
      publicKey: { kty: "EC", crv: "P-256", x: "x", y: "y" },
      name: undefined,
    });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({
      deviceId: "dev_bound",
      accessToken: "at_bound",
      expiresAt: 123,
      refreshChallenge: { nonce: "n", audience: "oppi:refresh:v1", expiresAt: 456 },
    });
  });

  it("rejects pairing requests that omit a device public key without issuing dt_", async () => {
    const consumePairingToken = vi.fn(() => ({ deviceToken: "dt_old_client" }));
    const enrollViaPairing = vi.fn();
    const ctx = {
      storage: { consumePairingToken, enrollViaPairing },
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
    expect(enrollViaPairing).not.toHaveBeenCalled();
    expect(consumePairingToken).not.toHaveBeenCalled();
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

  it("keeps rotate, finalize, and compat on the local socket", async () => {
    const rotateToken = vi.fn();
    const setMigrationFinalized = vi.fn();
    const ctx = {
      storage: { rotateToken, setMigrationFinalized },
    } as unknown as RouteContext;
    const dispatch = createIdentityRoutes(ctx, createRouteHelpers());

    for (const path of ["/auth/rotate", "/auth/finalize", "/auth/compat"]) {
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
    expect(setMigrationFinalized).not.toHaveBeenCalled();
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
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set()),
      },
      skillRegistry: {
        list: vi.fn(() => []),
      },
      getModelCatalog: vi.fn(() => []),
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
      },
      sessionRuntimes: {
        getActiveSessionIds: vi.fn(() => new Set()),
      },
      skillRegistry: {
        list: vi.fn(() => []),
      },
      getModelCatalog: vi.fn(() => []),
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
        },
        sessionRuntimes: {
          getActiveSessionIds: vi.fn(() => new Set()),
        },
        skillRegistry: {
          list: vi.fn(() => []),
        },
        getModelCatalog: vi.fn(() => []),
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

describe("identity migrate persistence", () => {
  let dataDir: string;
  let storage: Storage;

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true });
  });

  it("does not write config for invalid POST /auth/migrate", async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-identity-migrate-"));
    storage = new Storage(dataDir);
    storage.ensurePaired();
    const configPath = storage.getConfigPath();
    const before = statSync(configPath);
    const fingerprint = `${before.ino}:${before.mtimeNs}:${before.size}`;

    const dispatch = createIdentityRoutes({ storage } as unknown as RouteContext, createRouteHelpers());
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

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(401);
    const after = statSync(configPath);
    expect(`${after.ino}:${after.mtimeNs}:${after.size}`).toBe(fingerprint);
  });
});
