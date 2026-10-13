/**
 * Push envelope v1 (protocol/push/spec.md §2): HPKE (DHKEM(X25519), HKDF-SHA256,
 * ChaCha20-Poly1305) encryption to the phone's push key, signed with the server's Ed25519
 * identity key.
 *
 * `SealedPushEnvelope` is the only thing the relay client sends, and only
 * `sealPushEnvelope` makes one. There is no plaintext push path.
 */

import { createHash, sign as signEd25519, type KeyObject } from "node:crypto";
import type { ProgramStatusKind, SessionPushEvent } from "../types.js";
import { HPKE_TAG_BYTES, HPKE_X25519_KEY_BYTES, hpkeSeal } from "./hpke.js";

export const PUSH_ENVELOPE_VERSION = 0x01;
export const PUSH_KEY_ID_BYTES = 16;
/** Raw X25519 push public key and HPKE `enc`. */
export const PUSH_PUBLIC_KEY_BYTES = HPKE_X25519_KEY_BYTES;
const PUSH_ENC_BYTES = HPKE_X25519_KEY_BYTES;
export const PUSH_PADDED_PLAINTEXT_BYTES = 512;
export const PUSH_MAX_PLAINTEXT_JSON_BYTES = PUSH_PADDED_PLAINTEXT_BYTES - 2;
const PUSH_CIPHERTEXT_BYTES = PUSH_PADDED_PLAINTEXT_BYTES + HPKE_TAG_BYTES;
const PUSH_SIGNATURE_BYTES = 64;
export const PUSH_HEADER_BYTES = 1 + PUSH_KEY_ID_BYTES;
export const PUSH_CIPHERTEXT_OFFSET = PUSH_HEADER_BYTES + PUSH_ENC_BYTES;
export const PUSH_SIGNED_BYTES = PUSH_CIPHERTEXT_OFFSET + PUSH_CIPHERTEXT_BYTES;
/** 641 bytes: `version || kid || enc || ct || sig`. */
export const PUSH_ENVELOPE_BYTES = PUSH_SIGNED_BYTES + PUSH_SIGNATURE_BYTES;

export const PUSH_HPKE_INFO = Buffer.from("oppi-push-envelope-v1", "utf8");
const SIGNATURE_LABEL = Buffer.from("oppi-push-envelope-v1-sig\0", "utf8");

declare const sealedPushEnvelope: unique symbol;

/** Base64url of a sealed, signed v1 envelope. Only `sealPushEnvelope` constructs one. */
export type SealedPushEnvelope = string & { readonly [sealedPushEnvelope]: true };

/** Decrypted push content (spec §2.4). */
export type PushPlaintext = {
  v: 1;
  ts: number;
  title: string;
  subtitle?: string;
  body: string;
} & PushSubject;

/** What a push is about. Pairing events carry no `sessionId`. */
export type PushSubject =
  | {
      event: SessionPushEvent;
      kind?: ProgramStatusKind;
      sessionId: string;
      workspaceId?: string;
    }
  | { event: "pairing_approval"; approvalId: string }
  | { event: "device_enrolled"; deviceId: string };

/** `kid`: the first 16 bytes of SHA-256 of the raw X25519 public key, base64url. */
export function pushKeyId(publicKey: Uint8Array): string {
  return createHash("sha256")
    .update(publicKey)
    .digest()
    .subarray(0, PUSH_KEY_ID_BYTES)
    .toString("base64url");
}

function truncateCodePoints(value: string, maxCodePoints: number): string {
  const points = Array.from(value);
  return points.length <= maxCodePoints ? value : points.slice(0, maxCodePoints).join("");
}

/**
 * The plaintext JSON bytes, at most 510. A long session name (subtitle) shrinks first, then a
 * long body; the subtitle is dropped when nothing else fits.
 */
export function encodePushPlaintextJSON(plaintext: PushPlaintext): Buffer {
  let candidate: PushPlaintext = { ...plaintext };
  const encode = (value: PushPlaintext): Buffer => Buffer.from(JSON.stringify(value), "utf8");
  let bytes = encode(candidate);
  while (bytes.length > PUSH_MAX_PLAINTEXT_JSON_BYTES) {
    const subtitlePoints = candidate.subtitle ? Array.from(candidate.subtitle).length : 0;
    const bodyPoints = Array.from(candidate.body).length;
    if (subtitlePoints > 1) {
      candidate = {
        ...candidate,
        subtitle: truncateCodePoints(candidate.subtitle ?? "", subtitlePoints - 1),
      };
    } else if (candidate.subtitle !== undefined) {
      const { subtitle: _dropped, ...rest } = candidate;
      candidate = rest as PushPlaintext;
    } else if (bodyPoints > 1) {
      candidate = { ...candidate, body: truncateCodePoints(candidate.body, bodyPoints - 1) };
    } else {
      throw new Error("push plaintext does not fit the v1 envelope");
    }
    bytes = encode(candidate);
  }
  return bytes;
}

/**
 * A body of `head + tail` where `head` gives way first: the longest prefix of `head` (then of
 * `tail`) whose plaintext fits the 510 bytes at any `ts`, so the server never has to cut the
 * fixed facts at the end of a body (for pairing pushes: method and source).
 */
export function fitPushBody(
  /** Every plaintext field except `v`, `ts`, and `body`. */
  plaintext: Record<string, unknown>,
  head: string,
  tail: string,
): string {
  const fits = (body: string): boolean =>
    Buffer.byteLength(
      JSON.stringify({ v: 1, ts: Number.MAX_SAFE_INTEGER, ...plaintext, body }),
      "utf8",
    ) <= PUSH_MAX_PLAINTEXT_JSON_BYTES;
  const headPoints = Array.from(head);
  for (let keep = headPoints.length; keep >= 0; keep -= 1) {
    const body = `${headPoints.slice(0, keep).join("")}${tail}`;
    if (fits(body)) return body;
  }
  const tailPoints = Array.from(tail);
  for (let keep = tailPoints.length - 1; keep > 0; keep -= 1) {
    const body = tailPoints.slice(0, keep).join("");
    if (fits(body)) return body;
  }
  return "";
}

/** `uint16 length || JSON || zero padding` to 512 bytes (spec §2.3). */
export function padPushPlaintext(json: Uint8Array): Buffer {
  if (json.length > PUSH_MAX_PLAINTEXT_JSON_BYTES) {
    throw new Error("push plaintext JSON exceeds 510 bytes");
  }
  const padded = Buffer.alloc(PUSH_PADDED_PLAINTEXT_BYTES);
  padded.writeUInt16BE(json.length, 0);
  padded.set(json, 2);
  return padded;
}

export interface SealPushEnvelopeInput {
  /** Raw X25519 public key the phone registered (32 bytes). */
  recipientPublicKey: Uint8Array;
  plaintext: PushPlaintext;
  /** The server's Ed25519 identity private key. */
  signingKey: KeyObject;
}

/** Encrypt, sign, and encode one push. Throws on a malformed key; never falls back. */
export function sealPushEnvelope(input: SealPushEnvelopeInput): SealedPushEnvelope {
  return sealPaddedPlaintext({
    recipientPublicKey: input.recipientPublicKey,
    paddedPlaintext: padPushPlaintext(encodePushPlaintextJSON(input.plaintext)),
    signingKey: input.signingKey,
  });
}

/**
 * Seal exact padded bytes. Exported for the vector generator, which also needs envelopes with
 * deliberately invalid padding; production code calls `sealPushEnvelope`.
 */
export function sealPaddedPlaintext(input: {
  recipientPublicKey: Uint8Array;
  paddedPlaintext: Uint8Array;
  signingKey: KeyObject;
}): SealedPushEnvelope {
  const { recipientPublicKey, paddedPlaintext, signingKey } = input;
  if (recipientPublicKey.length !== PUSH_PUBLIC_KEY_BYTES) {
    throw new Error("push public key must be a 32-byte X25519 key");
  }
  if (paddedPlaintext.length !== PUSH_PADDED_PLAINTEXT_BYTES) {
    throw new Error("padded push plaintext must be 512 bytes");
  }

  const header = Buffer.alloc(PUSH_HEADER_BYTES);
  header[0] = PUSH_ENVELOPE_VERSION;
  Buffer.from(pushKeyId(recipientPublicKey), "base64url").copy(header, 1);

  const { enc, ciphertext } = hpkeSeal({
    recipientPublicKey,
    info: PUSH_HPKE_INFO,
    aad: header,
    plaintext: paddedPlaintext,
  });
  if (enc.length !== PUSH_ENC_BYTES || ciphertext.length !== PUSH_CIPHERTEXT_BYTES) {
    throw new Error("unexpected HPKE output size");
  }

  const signed = Buffer.concat([header, enc, ciphertext]);
  const signature = signEd25519(null, Buffer.concat([SIGNATURE_LABEL, signed]), signingKey);
  if (signature.length !== PUSH_SIGNATURE_BYTES) {
    throw new Error("push signing key must be Ed25519");
  }
  return Buffer.concat([signed, signature]).toString("base64url") as SealedPushEnvelope;
}
