/**
 * Push envelope v1 (protocol/push/spec.md §2): HPKE X-Wing encryption to the phone's push
 * key, signed with the server's Ed25519 identity key.
 *
 * `SealedPushEnvelope` is the only thing the relay client sends, and only
 * `sealPushEnvelope` makes one. There is no plaintext push path.
 */

import { createHash, sign as signEd25519, type KeyObject } from "node:crypto";
import { Aes256Gcm, CipherSuite, HkdfSha256 } from "@hpke/core";
import { XWing } from "@hpke/hybridkem-x-wing";
import type { ProgramStatusKind, PushEvent } from "../types.js";

export const PUSH_ENVELOPE_VERSION = 0x01;
export const PUSH_KEY_ID_BYTES = 16;
export const XWING_PUBLIC_KEY_BYTES = 1216;
export const XWING_ENC_BYTES = 1120;
export const PUSH_PADDED_PLAINTEXT_BYTES = 512;
export const PUSH_MAX_PLAINTEXT_JSON_BYTES = PUSH_PADDED_PLAINTEXT_BYTES - 2;
const AEAD_TAG_BYTES = 16;
export const PUSH_CIPHERTEXT_BYTES = PUSH_PADDED_PLAINTEXT_BYTES + AEAD_TAG_BYTES;
export const PUSH_SIGNATURE_BYTES = 64;
const HEADER_BYTES = 1 + PUSH_KEY_ID_BYTES;
const SIGNED_BYTES = HEADER_BYTES + XWING_ENC_BYTES + PUSH_CIPHERTEXT_BYTES;
export const PUSH_ENVELOPE_BYTES = SIGNED_BYTES + PUSH_SIGNATURE_BYTES;

const HPKE_INFO = new TextEncoder().encode("oppi-push-envelope-v1");
const SIGNATURE_LABEL = Buffer.from("oppi-push-envelope-v1-sig\0", "utf8");

declare const sealedPushEnvelope: unique symbol;

/** Base64url of a sealed, signed v1 envelope. Only `sealPushEnvelope` constructs one. */
export type SealedPushEnvelope = string & { readonly [sealedPushEnvelope]: true };

/** Decrypted push content (spec §2.4). */
export interface PushPlaintext {
  v: 1;
  seq: number;
  ts: number;
  event: PushEvent;
  kind?: ProgramStatusKind;
  sessionId: string;
  workspaceId?: string;
  incognito?: true;
  title: string;
  subtitle?: string;
  body: string;
}

const suite = new CipherSuite({ kem: new XWing(), kdf: new HkdfSha256(), aead: new Aes256Gcm() });

/** `kid`: the first 16 bytes of SHA-256 of the raw X-Wing public key, base64url. */
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
      candidate = rest;
    } else if (bodyPoints > 1) {
      candidate = { ...candidate, body: truncateCodePoints(candidate.body, bodyPoints - 1) };
    } else {
      throw new Error("push plaintext does not fit the v1 envelope");
    }
    bytes = encode(candidate);
  }
  return bytes;
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
  /** Raw X-Wing public key the phone registered (1216 bytes). */
  recipientPublicKey: Uint8Array;
  plaintext: PushPlaintext;
  /** The server's Ed25519 identity private key. */
  signingKey: KeyObject;
}

/** Encrypt, sign, and encode one push. Throws on a malformed key; never falls back. */
export async function sealPushEnvelope(input: SealPushEnvelopeInput): Promise<SealedPushEnvelope> {
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
export async function sealPaddedPlaintext(input: {
  recipientPublicKey: Uint8Array;
  paddedPlaintext: Uint8Array;
  signingKey: KeyObject;
}): Promise<SealedPushEnvelope> {
  const { recipientPublicKey, paddedPlaintext, signingKey } = input;
  if (recipientPublicKey.length !== XWING_PUBLIC_KEY_BYTES) {
    throw new Error("push public key must be a 1216-byte X-Wing key");
  }
  if (paddedPlaintext.length !== PUSH_PADDED_PLAINTEXT_BYTES) {
    throw new Error("padded push plaintext must be 512 bytes");
  }

  const header = Buffer.alloc(HEADER_BYTES);
  header[0] = PUSH_ENVELOPE_VERSION;
  Buffer.from(pushKeyId(recipientPublicKey), "base64url").copy(header, 1);

  const recipientKey = await suite.kem.importKey("raw", toArrayBuffer(recipientPublicKey), true);
  const sender = await suite.createSenderContext({
    recipientPublicKey: recipientKey,
    info: toArrayBuffer(HPKE_INFO),
  });
  const ciphertext = Buffer.from(
    await sender.seal(toArrayBuffer(paddedPlaintext), toArrayBuffer(header)),
  );
  const enc = Buffer.from(sender.enc);
  if (enc.length !== XWING_ENC_BYTES || ciphertext.length !== PUSH_CIPHERTEXT_BYTES) {
    throw new Error("unexpected HPKE output size");
  }

  const signed = Buffer.concat([header, enc, ciphertext]);
  const signature = signEd25519(null, Buffer.concat([SIGNATURE_LABEL, signed]), signingKey);
  if (signature.length !== PUSH_SIGNATURE_BYTES) {
    throw new Error("push signing key must be Ed25519");
  }
  return Buffer.concat([signed, signature]).toString("base64url") as SealedPushEnvelope;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
