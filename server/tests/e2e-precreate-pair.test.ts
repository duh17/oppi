import { createPrivateKey } from "node:crypto";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { pairingApprovalMessage } from "../src/device-pairing.js";
import { REFRESH_AUDIENCE, verifyDeviceSignature } from "../src/storage/device-auth.js";
import {
  approvalSignature,
  createApprover,
  refreshSignature,
  writeTokenFile,
} from "../scripts/e2e-pairing-approver.mjs";
import {
  interpretPairResponse,
  makeDeviceKeyPair,
  pairRequestBody,
} from "../scripts/e2e-precreate-pair.mjs";

describe("e2e pre-create pair helper", () => {
  it("builds a pairing body with pairingToken and a P-256 devicePublicKey", () => {
    const { publicKey } = makeDeviceKeyPair();
    const body = pairRequestBody("pt_valid", publicKey);
    expect(body.pairingToken).toBe("pt_valid");
    expect(body.deviceName).toBe("e2e-script-bootstrap");
    expect(body.devicePublicKey).toMatchObject({ kty: "EC", crv: "P-256" });
    expect(body.devicePublicKey.x).toBeTruthy();
    expect(body.devicePublicKey.y).toBeTruthy();
  });

  it("returns the enrolled device from 200 and surfaces status plus body otherwise", () => {
    expect(
      interpretPairResponse(200, JSON.stringify({ deviceId: "dev_e2e", accessToken: "at_e2e" })),
    ).toEqual({ ok: true, accessToken: "at_e2e", deviceId: "dev_e2e" });
    expect(
      interpretPairResponse(400, JSON.stringify({ error: "devicePublicKey required" })),
    ).toEqual({
      ok: false,
      error: 'status=400 body={"error":"devicePublicKey required"}',
    });
    // 202 approval_required is not an enrollment.
    const pending = JSON.stringify({ status: "approval_required", approvalId: "pa_1" });
    expect(interpretPairResponse(202, pending)).toEqual({
      ok: false,
      error: `status=202 body=${pending}`,
    });
  });
});

describe("e2e pairing approver signatures", () => {
  it("signs approvals and refreshes the way the server verifies them", () => {
    const keyPair = makeDeviceKeyPair();
    const privateKey = createPrivateKey({ key: keyPair.privateKey, format: "jwk" });
    const verify = (message: Buffer, signature: string) =>
      verifyDeviceSignature(keyPair.publicKey, message, Buffer.from(signature, "base64url"));

    const approval = approvalSignature(privateKey, "pa_1", "thumb");
    expect(verify(pairingApprovalMessage("pa_1", "thumb"), approval)).toBe(true);
    expect(verify(pairingApprovalMessage("pa_2", "thumb"), approval)).toBe(false);

    const refresh = refreshSignature(privateKey, "nonce_1");
    expect(verify(Buffer.from(`${REFRESH_AUDIENCE}.nonce_1`), refresh)).toBe(true);
  });
});

describe("e2e pairing approver token handoff", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("hands the refreshed access token to the run directory the fixtures read", async () => {
    const keyPair = makeDeviceKeyPair();
    const directory = mkdtempSync(join(tmpdir(), "oppi-approver-"));
    const tokenFile = join(directory, "device-token.txt");
    writeTokenFile(tokenFile, "at_old");

    const responses: Array<{ status: number; body: unknown }> = [
      { status: 401, body: { error: "Unauthorized" } }, // list with the expired token
      { status: 200, body: { nonce: "n1" } }, // challenge
      { status: 200, body: { accessToken: "at_new" } }, // refresh
      { status: 200, body: { approvals: [] } }, // list again
    ];
    const seenAuthorization: Array<string | null> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: string, init?: { headers?: Record<string, string> }) => {
        seenAuthorization.push(init?.headers?.Authorization ?? null);
        const next = responses.shift();
        return new Response(JSON.stringify(next?.body), { status: next?.status ?? 500 });
      }),
    );

    const approver = createApprover({
      baseURL: "https://127.0.0.1:1",
      credential: { deviceId: "dev_e2e", accessToken: "at_old", privateKey: keyPair.privateKey },
      log: () => {},
      onAccessToken: (token: string) => writeTokenFile(tokenFile, token),
    });
    await approver.approvePending();

    expect(readFileSync(tokenFile, "utf8")).toBe("at_new\n");
    expect(seenAuthorization.at(-1)).toBe("Bearer at_new");
  });
});
