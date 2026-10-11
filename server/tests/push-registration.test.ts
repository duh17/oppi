import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { checkPushRegistration, pushRegistrationMessage } from "../src/push/registration.js";
import { Storage } from "../src/storage.js";
import type { DevicePublicKey } from "../src/types.js";

const vectors = JSON.parse(
  readFileSync(
    new URL("../../protocol/push/vectors/server-envelopes.json", import.meta.url),
    "utf8",
  ),
) as {
  registrationSignature: {
    input: {
      deviceId: string;
      serverFingerprint: string;
      keyId: string;
      publicKey: string;
      sendToken: string;
      relay: string;
      issuedAt: number;
    };
    message: string;
  };
};

describe("push registration signature", () => {
  it("signs the bytes in the committed vector the Apple client also builds", () => {
    const { input, message } = vectors.registrationSignature;
    expect(
      pushRegistrationMessage({ ...input, publicKey: Buffer.from(input.publicKey, "base64url") }),
    ).toEqual(Buffer.from(message, "base64url"));
  });

  it("rejects a stale issuedAt even when the device signed it", () => {
    const keys = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const jwk = keys.publicKey.export({ format: "jwk" }) as { x: string; y: string };
    const devicePublicKey: DevicePublicKey = { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
    const { input } = vectors.registrationSignature;
    const issuedAt = input.issuedAt;
    const signature = sign(
      "sha256",
      pushRegistrationMessage({
        ...input,
        publicKey: Buffer.from(input.publicKey, "base64url"),
        issuedAt,
      }),
      { key: keys.privateKey, dsaEncoding: "ieee-p1363" },
    ).toString("base64url");
    const body = { ...input, issuedAt, signature };
    const check = (now: number) =>
      checkPushRegistration({
        body,
        deviceId: input.deviceId,
        devicePublicKey,
        serverFingerprint: input.serverFingerprint,
        primaryRelay: input.relay,
        now,
      });

    expect(check(issuedAt + 60_000).ok).toBe(true);
    expect(check(issuedAt + 11 * 60_000)).toMatchObject({ ok: false, status: 401 });
  });
});

describe("push registration storage", () => {
  let dataDir: string;
  let storage: Storage;

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-push-registration-"));
    storage = new Storage(dataDir);
    storage.ensurePaired();
  });

  afterEach(() => rmSync(dataDir, { recursive: true, force: true }));

  function enroll(): string {
    const jwk = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({
      format: "jwk",
    }) as { x: string; y: string };
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
    });
    if (!enrolled) throw new Error("enrollment failed");
    return enrolled.deviceId;
  }

  function register(deviceId: string, keyId = "kid-1", sendToken = "osp1.r.p.one") {
    return storage.setPushRegistration({ deviceId, keyId, publicKey: "pk", sendToken });
  }

  it("revoking a device removes only its push registration", () => {
    const phone = enroll();
    const ipad = enroll();
    register(phone);
    register(ipad, "kid-ipad", "osp1.r.p.ipad");

    expect(storage.revokeDevice(phone)).toBe(true);

    expect(storage.getPushRegistrations().map((entry) => entry.deviceId)).toEqual([ipad]);
    expect(register(phone)).toBe(false);
  });

  it("a 410 for an old send token does not remove a newer registration", () => {
    const phone = enroll();
    register(phone, "kid-1", "osp1.r.p.old");
    register(phone, "kid-1", "osp1.r.p.new");

    expect(storage.removePushRegistration(phone, "osp1.r.p.old")).toBeNull();
    expect(storage.getPushRegistrations()).toHaveLength(1);
  });
});
