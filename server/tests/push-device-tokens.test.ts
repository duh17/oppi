import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import type { RequestPrincipal } from "../src/request-principal.js";
import { Storage } from "../src/storage.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-push-tokens-"));
  storage = new Storage(dataDir);
  storage.ensurePaired();
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

function pairDevice(name: string): string {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
    publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    name,
  });
  if (!enrolled) throw new Error("enrollment failed");
  return enrolled.deviceId;
}

async function register(principal: RequestPrincipal | undefined, body: unknown) {
  const dispatch = createIdentityRoutes(
    { storage, pushNotificationsAvailable: true } as unknown as RouteContext,
    createRouteHelpers(),
  );
  const res = makeResponse();
  await dispatch({
    method: "POST",
    path: "/me/device-token",
    url: new URL("https://paired.example/me/device-token"),
    req: makeRequest(body) as never,
    res: res as never,
    principal,
  });
  return res;
}

function device(deviceId: string): RequestPrincipal {
  return { kind: "device", deviceId, tokenClass: "at_" };
}

function storedTokens(): Array<{ deviceId: string; token: string; environment: string }> {
  return storage
    .getPushDeviceTokens("apns")
    .map(({ deviceId, token, environment }) => ({ deviceId, token, environment }));
}

describe("push device tokens", () => {
  it("stores each device's token with the environment it reported", async () => {
    const phone = pairDevice("Phone");
    const ipad = pairDevice("iPad");

    expect(
      (await register(device(phone), { deviceToken: "aa01", apnsEnvironment: "production" }))
        .statusCode,
    ).toBe(400);
    expect(
      (
        await register(device(phone), {
          deviceToken: "AA01AA01AA01AA01",
          apnsEnvironment: "production",
        })
      ).statusCode,
    ).toBe(200);
    await register(device(ipad), { deviceToken: "bb02bb02bb02bb02", apnsEnvironment: "sandbox" });

    expect(storedTokens()).toEqual([
      { deviceId: phone, token: "aa01aa01aa01aa01", environment: "production" },
      { deviceId: ipad, token: "bb02bb02bb02bb02", environment: "sandbox" },
    ]);
  });

  it("refuses registration without a paired device credential", async () => {
    const owner = await register(
      { kind: "owner" },
      {
        deviceToken: "aa01aa01aa01aa01",
        apnsEnvironment: "production",
      },
    );

    expect(owner.statusCode).toBe(403);
    expect(storedTokens()).toEqual([]);
  });

  it("keeps one token per device and moves a token to the device that re-registers it", async () => {
    const oldPairing = pairDevice("Phone (old pairing)");
    const phone = pairDevice("Phone");
    await register(device(phone), { deviceToken: "aa01aa01aa01aa01", apnsEnvironment: "sandbox" });
    await register(device(phone), { deviceToken: "cc03cc03cc03cc03", apnsEnvironment: "sandbox" });
    await register(device(oldPairing), {
      deviceToken: "cc03cc03cc03cc03",
      apnsEnvironment: "production",
    });

    expect(storedTokens()).toEqual([
      { deviceId: oldPairing, token: "cc03cc03cc03cc03", environment: "production" },
    ]);
  });

  it("removes only the revoked device's tokens, and a revoked device cannot register", async () => {
    const phone = pairDevice("Phone");
    const ipad = pairDevice("iPad");
    await register(device(phone), {
      deviceToken: "aa01aa01aa01aa01",
      apnsEnvironment: "production",
    });
    await register(device(ipad), { deviceToken: "bb02bb02bb02bb02", apnsEnvironment: "sandbox" });

    expect(storage.revokeDevice(phone)).toBe(true);
    expect(storedTokens()).toEqual([
      { deviceId: ipad, token: "bb02bb02bb02bb02", environment: "sandbox" },
    ]);

    const late = await register(device(phone), {
      deviceToken: "aa01aa01aa01aa01",
      apnsEnvironment: "production",
    });
    expect(late.statusCode).toBe(403);
    expect(new Storage(dataDir).getPushDeviceTokens("apns").map((entry) => entry.deviceId)).toEqual(
      [ipad],
    );
  });

  it("drops tokens stored before devices and environments were recorded", () => {
    const configPath = storage.getConfigPath();
    const legacy = JSON.parse(readFileSync(configPath, "utf-8")) as Record<string, unknown>;
    writeFileSync(
      configPath,
      JSON.stringify({
        ...legacy,
        pushDeviceTokens: ["aa01aa01aa01aa01"],
        liveActivityToken: "bb02bb02bb02bb02",
      }),
    );

    const migrated = new Storage(dataDir);

    expect(migrated.getPushDeviceTokens("apns")).toEqual([]);
    expect(migrated.getPushDeviceTokens("liveactivity")).toEqual([]);
    const onDisk = readFileSync(configPath, "utf-8");
    expect(onDisk).not.toContain("aa01aa01aa01aa01");
    expect(onDisk).not.toContain("liveActivityToken");
  });
});
