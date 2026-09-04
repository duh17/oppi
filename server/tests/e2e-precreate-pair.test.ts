import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  interpretPairResponse,
  makeDevicePublicKey,
  pairRequestBody,
} from "../scripts/e2e-precreate-pair.mjs";

const serverRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

describe("e2e pre-create pair helper", () => {
  it("builds a pairing body with pairingToken and a P-256 devicePublicKey", () => {
    const body = pairRequestBody("pt_valid");
    expect(body.pairingToken).toBe("pt_valid");
    expect(body.deviceName).toBe("e2e-script-bootstrap");
    expect(body.devicePublicKey).toMatchObject({ kty: "EC", crv: "P-256" });
    expect(body.devicePublicKey.x).toBeTruthy();
    expect(body.devicePublicKey.y).toBeTruthy();
    expect(makeDevicePublicKey()).toMatchObject({ kty: "EC", crv: "P-256" });
  });

  it("prints accessToken from 200 and surfaces status plus body on 400", () => {
    expect(interpretPairResponse(200, JSON.stringify({ accessToken: "at_e2e" }))).toEqual({
      ok: true,
      accessToken: "at_e2e",
    });
    expect(
      interpretPairResponse(400, JSON.stringify({ error: "devicePublicKey required" })),
    ).toEqual({
      ok: false,
      error: 'status=400 body={"error":"devicePublicKey required"}',
    });
  });

  it("keeps the official helper on crypto fetch pairing only", () => {
    const helper = readFileSync(join(serverRoot, "scripts/e2e-precreate-pair.mjs"), "utf8");
    expect(helper).toContain("devicePublicKey");
    expect(helper).toContain("accessToken");
    expect(helper).toContain("status=");
    expect(helper).not.toContain("curl -f");
    expect(helper).not.toContain("deviceToken");
  });
});
