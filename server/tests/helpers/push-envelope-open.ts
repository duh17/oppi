/**
 * Test-only receiver for push envelope v1: what the phone does, written with the server's
 * HPKE code so server tests can check sealed output. Production server code never opens
 * envelopes.
 */

import { verify, type KeyObject } from "node:crypto";
import {
  PUSH_CIPHERTEXT_OFFSET,
  PUSH_ENVELOPE_BYTES,
  PUSH_HEADER_BYTES,
  PUSH_HPKE_INFO,
  PUSH_SIGNED_BYTES,
  type PushPlaintext,
} from "../../src/push/envelope.js";
import { hpkeOpen } from "../../src/push/hpke.js";

const SIGNATURE_LABEL = Buffer.from("oppi-push-envelope-v1-sig\0", "utf8");

export function openPushEnvelopeForTest(
  envelope: string,
  keys: { recipientPrivateKey: Uint8Array; serverPublicKey: KeyObject },
): PushPlaintext {
  const bytes = Buffer.from(envelope, "base64url");
  if (bytes.length !== PUSH_ENVELOPE_BYTES || bytes[0] !== 0x01) throw new Error("size");
  const signed = bytes.subarray(0, PUSH_SIGNED_BYTES);
  const signature = bytes.subarray(PUSH_SIGNED_BYTES);
  if (!verify(null, Buffer.concat([SIGNATURE_LABEL, signed]), keys.serverPublicKey, signature)) {
    throw new Error("signature");
  }
  const padded = hpkeOpen({
    recipientPrivateKey: keys.recipientPrivateKey,
    info: PUSH_HPKE_INFO,
    aad: bytes.subarray(0, PUSH_HEADER_BYTES),
    enc: bytes.subarray(PUSH_HEADER_BYTES, PUSH_CIPHERTEXT_OFFSET),
    ciphertext: bytes.subarray(PUSH_CIPHERTEXT_OFFSET, PUSH_SIGNED_BYTES),
  });
  const length = padded.readUInt16BE(0);
  return JSON.parse(padded.subarray(2, 2 + length).toString("utf8")) as PushPlaintext;
}
