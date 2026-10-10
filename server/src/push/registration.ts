/**
 * `PUT /me/push-registration` checks (protocol/push/spec.md §5). The phone's enrolled P-256
 * device key signs its push key and send token, so a TLS-terminating proxy on the paired
 * channel cannot substitute either.
 */

import { createHash } from "node:crypto";
import { verifyDeviceSignature } from "../storage/device-auth.js";
import type { DevicePublicKey, PushRegistrationRequest } from "../types.js";
import { XWING_PUBLIC_KEY_BYTES, pushKeyId } from "./envelope.js";

/** How far `issuedAt` may be from the server clock. */
export const PUSH_REGISTRATION_MAX_SKEW_MS = 10 * 60 * 1000;
const MAX_SEND_TOKEN_LENGTH = 512;

export type PushRegistrationCheck =
  | { ok: true; keyId: string; publicKey: string; sendToken: string }
  | { ok: false; status: 400 | 401 | 409; error: string };

/** The exact bytes the device key signs. */
export function pushRegistrationMessage(input: {
  deviceId: string;
  serverFingerprint: string;
  keyId: string;
  publicKey: Uint8Array;
  sendToken: string;
  relay: string;
  issuedAt: number;
}): Buffer {
  return Buffer.from(
    [
      "oppi-push-registration-v1",
      input.deviceId,
      input.serverFingerprint,
      input.keyId,
      createHash("sha256").update(input.publicKey).digest("base64url"),
      createHash("sha256").update(input.sendToken, "utf8").digest("base64url"),
      input.relay,
      String(input.issuedAt),
    ].join("\n"),
    "utf8",
  );
}

export function checkPushRegistration(input: {
  body: Partial<Record<keyof PushRegistrationRequest, unknown>>;
  deviceId: string;
  devicePublicKey: DevicePublicKey;
  serverFingerprint: string;
  primaryRelay: string;
  now: number;
}): PushRegistrationCheck {
  const { body } = input;
  const { keyId, publicKey, sendToken, relay, issuedAt, signature } = body;
  if (
    typeof keyId !== "string" ||
    typeof publicKey !== "string" ||
    typeof sendToken !== "string" ||
    typeof relay !== "string" ||
    typeof signature !== "string" ||
    typeof issuedAt !== "number" ||
    !Number.isSafeInteger(issuedAt)
  ) {
    return {
      ok: false,
      status: 400,
      error: "keyId, publicKey, sendToken, relay, issuedAt, signature required",
    };
  }
  const publicKeyBytes = Buffer.from(publicKey, "base64url");
  if (publicKeyBytes.length !== XWING_PUBLIC_KEY_BYTES) {
    return { ok: false, status: 400, error: "publicKey must be a 1216-byte X-Wing key" };
  }
  if (pushKeyId(publicKeyBytes) !== keyId) {
    return { ok: false, status: 400, error: "keyId does not match publicKey" };
  }
  if (sendToken.length === 0 || sendToken.length > MAX_SEND_TOKEN_LENGTH || /\s/.test(sendToken)) {
    return { ok: false, status: 400, error: "sendToken invalid" };
  }
  if (Math.abs(input.now - issuedAt) > PUSH_REGISTRATION_MAX_SKEW_MS) {
    return { ok: false, status: 401, error: "issuedAt outside the allowed clock skew" };
  }
  const signatureBytes = Buffer.from(signature, "base64url");
  const message = pushRegistrationMessage({
    deviceId: input.deviceId,
    serverFingerprint: input.serverFingerprint,
    keyId,
    publicKey: publicKeyBytes,
    sendToken,
    relay,
    issuedAt,
  });
  if (
    signatureBytes.length !== 64 ||
    !verifyDeviceSignature(input.devicePublicKey, message, signatureBytes)
  ) {
    return { ok: false, status: 401, error: "bad_signature" };
  }
  // Checked after the signature, so only the device learns the server's relay changed.
  if (relay !== input.primaryRelay) {
    return { ok: false, status: 409, error: "relay_mismatch" };
  }
  return { ok: true, keyId, publicKey: publicKeyBytes.toString("base64url"), sendToken };
}
