/**
 * Test-only receiver for push envelope v1: what the phone does, written with the server's
 * HPKE library so server tests can check sealed output. Production server code never opens
 * envelopes.
 */

import { verify, type KeyObject } from "node:crypto";
import { Aes256Gcm, CipherSuite, HkdfSha256 } from "@hpke/core";
import { XWing } from "@hpke/hybridkem-x-wing";
import { PUSH_ENVELOPE_BYTES, type PushPlaintext } from "../../src/push/envelope.js";

const suite = new CipherSuite({ kem: new XWing(), kdf: new HkdfSha256(), aead: new Aes256Gcm() });
const INFO = Buffer.from("oppi-push-envelope-v1", "utf8");
const SIGNATURE_LABEL = Buffer.from("oppi-push-envelope-v1-sig\0", "utf8");

function ab(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export async function openHpkeForTest(input: {
  recipientSeed: Uint8Array;
  info: Uint8Array;
  aad: Uint8Array;
  enc: Uint8Array;
  ciphertext: Uint8Array;
}): Promise<Buffer> {
  const recipientKey = await suite.kem.importKey("raw", ab(input.recipientSeed), false);
  const recipient = await suite.createRecipientContext({
    recipientKey,
    enc: ab(input.enc),
    info: ab(input.info),
  });
  return Buffer.from(await recipient.open(ab(input.ciphertext), ab(input.aad)));
}

export async function openPushEnvelopeForTest(
  envelope: string,
  keys: { recipientSeed: Uint8Array; serverPublicKey: KeyObject },
): Promise<PushPlaintext> {
  const bytes = Buffer.from(envelope, "base64url");
  if (bytes.length !== PUSH_ENVELOPE_BYTES || bytes[0] !== 0x01) throw new Error("size");
  const signed = bytes.subarray(0, PUSH_ENVELOPE_BYTES - 64);
  const signature = bytes.subarray(PUSH_ENVELOPE_BYTES - 64);
  if (!verify(null, Buffer.concat([SIGNATURE_LABEL, signed]), keys.serverPublicKey, signature)) {
    throw new Error("signature");
  }
  const padded = await openHpkeForTest({
    recipientSeed: keys.recipientSeed,
    info: INFO,
    aad: bytes.subarray(0, 17),
    enc: bytes.subarray(17, 1137),
    ciphertext: bytes.subarray(1137, 1665),
  });
  const length = padded.readUInt16BE(0);
  return JSON.parse(padded.subarray(2, 2 + length).toString("utf8")) as PushPlaintext;
}
