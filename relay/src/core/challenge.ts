/**
 * Registration challenges (protocol/push/spec.md §3.1) that the relay checks without storing
 * them: `expiresAt (6 bytes, ms, big-endian) ‖ nonce (10 bytes) ‖ tag (16 bytes)`, where the
 * tag is HMAC-SHA256 over the first 16 bytes, truncated to 128 bits. 32 bytes in all, the size
 * the phone has always received; it treats the challenge as opaque.
 *
 * Handing one out costs no storage, so an unauthenticated flood of `/v1/challenge` costs
 * Worker requests only, not Durable Object requests or rows.
 *
 * Not single use, on purpose. A challenge is good for any number of registrations until it
 * expires. What a reuse within those 300 s can do, per path:
 * - Unattested (sandbox only): nothing new. Anyone may fetch a fresh challenge and register
 *   any APNs token unattested; the challenge proves nothing there.
 * - Attested: the attestation binds the challenge, APNs token, and environment, so only the
 *   exact body can be replayed. Apple attests an App Attest key once and the app makes a new
 *   key per registration, so a registration whose token already belongs to a registration
 *   with the same key is a replay, and `postRegistration` refuses it without writing. A replay
 *   could still reach the relay after the phone registered again with a newer key in the same
 *   300 s; the registration it makes needs the phone's App Attest key for every later call, so
 *   it mints no send token, and the phone's next call answers `410` and it registers again.
 * - Registration-authenticated calls (mint, Live Activity state, deletes) use no challenge;
 *   App Attest assertions carry a counter that must rise (`advanceAssertionCounter`).
 */

import { base64urlDecode, base64urlEncode, bytesEqual, concatBytes, randomBytes, utf8 } from "./bytes.js";

export const CHALLENGE_TTL_MS = 300_000;
const EXPIRY_BYTES = 6;
const NONCE_BYTES = 10;
const TAG_BYTES = 16;
const SIGNED_BYTES = EXPIRY_BYTES + NONCE_BYTES;
/** Domain label for the derived key; a new label voids every outstanding challenge. */
const KEY_INFO = "oppi-relay-challenge-v1";

/**
 * `secret` is input keying material, never used as the key itself: HKDF-SHA256 with its own
 * `info` label derives the HMAC key, so the result reveals nothing about the secret and serves
 * no other purpose. Fails closed: a missing or short secret throws, so a relay without one
 * cannot start.
 */
export class ChallengeIssuer {
  private readonly key: Promise<CryptoKey>;

  constructor(secret: Uint8Array) {
    if (secret.length < 32) {
      throw new Error("relay challenge secret is missing or shorter than 32 bytes");
    }
    this.key = crypto.subtle
      .importKey("raw", secret as BufferSource, "HKDF", false, ["deriveKey"])
      .then((base) =>
        crypto.subtle.deriveKey(
          {
            name: "HKDF",
            hash: "SHA-256",
            salt: new Uint8Array(0) as BufferSource,
            info: utf8(KEY_INFO) as BufferSource,
          },
          base,
          { name: "HMAC", hash: "SHA-256", length: 256 },
          false,
          ["sign"],
        ),
      );
  }

  private async tag(signed: Uint8Array): Promise<Uint8Array> {
    const mac = await crypto.subtle.sign("HMAC", await this.key, signed as BufferSource);
    return new Uint8Array(mac, 0, TAG_BYTES);
  }

  async issue(now: number): Promise<{ challenge: string; expiresAt: number }> {
    const expiresAt = now + CHALLENGE_TTL_MS;
    const expiry = new Uint8Array(EXPIRY_BYTES);
    const view = new DataView(expiry.buffer);
    view.setUint16(0, Math.floor(expiresAt / 2 ** 32));
    view.setUint32(2, expiresAt % 2 ** 32);
    const signed = concatBytes(expiry, randomBytes(NONCE_BYTES));
    return { challenge: base64urlEncode(concatBytes(signed, await this.tag(signed))), expiresAt };
  }

  /**
   * The tag is compared in constant time, then the expiry checked. No upper bound on the
   * expiry: only this relay's key makes a valid tag, so every expiry it accepts is one it
   * issued, and a bound would only refuse valid challenges when instances' clocks differ.
   */
  async verify(challenge: string, now: number): Promise<boolean> {
    const bytes = base64urlDecode(challenge);
    if (!bytes || bytes.length !== SIGNED_BYTES + TAG_BYTES) return false;
    const signed = bytes.subarray(0, SIGNED_BYTES);
    if (!bytesEqual(await this.tag(signed), bytes.subarray(SIGNED_BYTES))) return false;
    const view = new DataView(bytes.buffer, bytes.byteOffset, EXPIRY_BYTES);
    const expiresAt = view.getUint16(0) * 2 ** 32 + view.getUint32(2);
    return expiresAt >= now;
  }
}
