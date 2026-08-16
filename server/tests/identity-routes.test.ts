import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

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
    expect(enrollViaPairing).toHaveBeenCalledWith(
      "pt_dual",
        { publicKey: { kty: "EC", crv: "P-256", x: "x", y: "y" }, name: undefined },
    );
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toEqual({
      deviceId: "dev_bound",
      accessToken: "at_bound",
      expiresAt: 123,
      refreshChallenge: { nonce: "n", audience: "oppi:refresh:v1", expiresAt: 456 },
    });
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
