/**
 * HPKE (RFC 9180) base mode, single shot, for exactly one ciphersuite:
 * DHKEM(X25519, HKDF-SHA256) 0x0020, HKDF-SHA256 0x0001, ChaCha20-Poly1305 0x0003.
 * CryptoKit calls it `HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly`.
 *
 * Only `node:crypto` primitives (X25519, HMAC-SHA256, ChaCha20-Poly1305) composed as the RFC
 * specifies; no primitive math here. Checked against RFC 9180 Appendix A.2.1 in
 * tests/push-hpke.test.ts. Single shot means sequence number 0, so the nonce is `base_nonce`
 * (§5.2) and no context outlives one call.
 */

import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  type KeyObject,
} from "node:crypto";

/** Npk, Nsk, Nenc, and Nsecret of DHKEM(X25519, HKDF-SHA256) (§7.1). */
export const HPKE_X25519_KEY_BYTES = 32;
const HPKE_KEY_BYTES = 32; // Nk for ChaCha20-Poly1305 (§7.3)
const HPKE_NONCE_BYTES = 12; // Nn
export const HPKE_TAG_BYTES = 16; // Nt

const MODE_BASE = 0x00;
const KEM_ID = 0x0020;
const KDF_ID = 0x0001;
const AEAD_ID = 0x0003;
const LABEL_VERSION = Buffer.from("HPKE-v1", "ascii");

function i2osp(value: number, length: number): Buffer {
  const out = Buffer.alloc(length);
  out.writeUIntBE(value, 0, length);
  return out;
}

const KEM_SUITE_ID = Buffer.concat([Buffer.from("KEM", "ascii"), i2osp(KEM_ID, 2)]); // §4.1
const HPKE_SUITE_ID = Buffer.concat([
  Buffer.from("HPKE", "ascii"),
  i2osp(KEM_ID, 2),
  i2osp(KDF_ID, 2),
  i2osp(AEAD_ID, 2),
]); // §5.1

// HKDF (RFC 5869) over HMAC-SHA256. An empty salt is an empty HMAC key, which HMAC pads to
// the same block as RFC 5869's HashLen zero bytes.
function extract(salt: Uint8Array, ikm: Uint8Array): Buffer {
  return createHmac("sha256", salt).update(ikm).digest();
}

function expand(prk: Uint8Array, info: Uint8Array, length: number): Buffer {
  const blocks: Buffer[] = [];
  let previous = Buffer.alloc(0);
  for (let counter = 1; blocks.length * 32 < length; counter++) {
    previous = createHmac("sha256", prk)
      .update(previous)
      .update(info)
      .update(Buffer.of(counter))
      .digest();
    blocks.push(previous);
  }
  return Buffer.concat(blocks).subarray(0, length);
}

// §4: LabeledExtract and LabeledExpand.
function labeledExtract(suiteId: Buffer, salt: Uint8Array, label: string, ikm: Uint8Array): Buffer {
  return extract(salt, Buffer.concat([LABEL_VERSION, suiteId, Buffer.from(label, "ascii"), ikm]));
}

function labeledExpand(
  suiteId: Buffer,
  prk: Uint8Array,
  label: string,
  info: Uint8Array,
  length: number,
): Buffer {
  const labeledInfo = Buffer.concat([
    i2osp(length, 2),
    LABEL_VERSION,
    suiteId,
    Buffer.from(label, "ascii"),
    info,
  ]);
  return expand(prk, labeledInfo, length);
}

// X25519 keys as KeyObjects, from raw 32-byte strings (RFC 8410 DER wrappers).
const X25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const X25519_SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex");

function x25519Private(raw: Uint8Array): KeyObject {
  if (raw.length !== HPKE_X25519_KEY_BYTES) throw new Error("X25519 private key must be 32 bytes");
  return createPrivateKey({
    key: Buffer.concat([X25519_PKCS8_PREFIX, raw]),
    format: "der",
    type: "pkcs8",
  });
}

/** §7.1.1 DeserializePublicKey: any 32-byte string; §7.1.4 checks the DH output instead. */
function x25519Public(raw: Uint8Array): KeyObject {
  if (raw.length !== HPKE_X25519_KEY_BYTES) throw new Error("X25519 public key must be 32 bytes");
  return createPublicKey({
    key: Buffer.concat([X25519_SPKI_PREFIX, raw]),
    format: "der",
    type: "spki",
  });
}

/** §7.1.1 SerializePublicKey. */
function rawPublicKey(key: KeyObject): Buffer {
  const { x } = createPublicKey(key).export({ format: "jwk" });
  if (typeof x !== "string") throw new Error("X25519 key has no public part");
  return Buffer.from(x, "base64url");
}

/** The raw X25519 public key of a raw private key. */
export function x25519PublicKey(privateKey: Uint8Array): Buffer {
  return rawPublicKey(x25519Private(privateKey));
}

/** DH with the §7.1.4 check: abort on an all-zero shared secret (a low-order public key). */
function dh(privateKey: KeyObject, publicKey: KeyObject): Buffer {
  let shared: Buffer;
  try {
    shared = diffieHellman({ privateKey, publicKey });
  } catch {
    // OpenSSL also refuses an all-zero X25519 result; same failure either way.
    throw new Error("X25519 shared secret is invalid");
  }
  if (shared.every((byte) => byte === 0)) throw new Error("X25519 shared secret is invalid");
  return shared;
}

/** §4.1 ExtractAndExpand. */
function extractAndExpand(dhOutput: Buffer, kemContext: Buffer): Buffer {
  const eaePrk = labeledExtract(KEM_SUITE_ID, Buffer.alloc(0), "eae_prk", dhOutput);
  return labeledExpand(KEM_SUITE_ID, eaePrk, "shared_secret", kemContext, HPKE_X25519_KEY_BYTES);
}

/** §5.1 KeySchedule for mode_base (empty psk and psk_id); the exporter secret is unused. */
function keySchedule(sharedSecret: Buffer, info: Uint8Array): { key: Buffer; nonce: Buffer } {
  const pskIdHash = labeledExtract(HPKE_SUITE_ID, Buffer.alloc(0), "psk_id_hash", Buffer.alloc(0));
  const infoHash = labeledExtract(HPKE_SUITE_ID, Buffer.alloc(0), "info_hash", info);
  const context = Buffer.concat([Buffer.of(MODE_BASE), pskIdHash, infoHash]);
  const secret = labeledExtract(HPKE_SUITE_ID, sharedSecret, "secret", Buffer.alloc(0));
  return {
    key: labeledExpand(HPKE_SUITE_ID, secret, "key", context, HPKE_KEY_BYTES),
    nonce: labeledExpand(HPKE_SUITE_ID, secret, "base_nonce", context, HPKE_NONCE_BYTES),
  };
}

/**
 * §6.1 SealBase: `enc` (32 bytes) and the ciphertext (plaintext length + 16).
 * `ephemeralPrivateKey` is fixed only by the RFC known-answer test; production omits it and
 * gets a fresh key (§4.1 Encap, GenerateKeyPair).
 */
export function hpkeSeal(input: {
  recipientPublicKey: Uint8Array;
  info: Uint8Array;
  aad: Uint8Array;
  plaintext: Uint8Array;
  ephemeralPrivateKey?: Uint8Array;
}): { enc: Buffer; ciphertext: Buffer } {
  const pkR = x25519Public(input.recipientPublicKey);
  const skE = input.ephemeralPrivateKey
    ? x25519Private(input.ephemeralPrivateKey)
    : generateKeyPairSync("x25519").privateKey;
  // §4.1 Encap.
  const enc = rawPublicKey(skE);
  const kemContext = Buffer.concat([enc, input.recipientPublicKey]);
  const sharedSecret = extractAndExpand(dh(skE, pkR), kemContext);

  const { key, nonce } = keySchedule(sharedSecret, input.info);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: HPKE_TAG_BYTES });
  cipher.setAAD(input.aad, { plaintextLength: input.plaintext.length });
  const ciphertext = Buffer.concat([
    cipher.update(input.plaintext),
    cipher.final(),
    cipher.getAuthTag(),
  ]);
  return { enc, ciphertext };
}

/** §6.1 OpenBase. Throws when the key, `enc`, or ciphertext is wrong. Tests and tools only. */
export function hpkeOpen(input: {
  recipientPrivateKey: Uint8Array;
  enc: Uint8Array;
  info: Uint8Array;
  aad: Uint8Array;
  ciphertext: Uint8Array;
}): Buffer {
  const skR = x25519Private(input.recipientPrivateKey);
  // §4.1 Decap.
  const kemContext = Buffer.concat([input.enc, rawPublicKey(skR)]);
  const sharedSecret = extractAndExpand(dh(skR, x25519Public(input.enc)), kemContext);

  if (input.ciphertext.length < HPKE_TAG_BYTES) throw new Error("HPKE ciphertext too short");
  const { key, nonce } = keySchedule(sharedSecret, input.info);
  const tagStart = input.ciphertext.length - HPKE_TAG_BYTES;
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, {
    authTagLength: HPKE_TAG_BYTES,
  });
  decipher.setAAD(input.aad, { plaintextLength: tagStart });
  decipher.setAuthTag(input.ciphertext.subarray(tagStart));
  return Buffer.concat([decipher.update(input.ciphertext.subarray(0, tagStart)), decipher.final()]);
}
