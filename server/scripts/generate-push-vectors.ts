/**
 * Server side of the push test vectors (protocol/push/spec.md §7). Run only through
 * protocol/push/scripts/generate-vectors.sh, after the CryptoKit vectors exist: the recipient
 * public key comes from CryptoKit, so generation itself checks key compatibility.
 *
 * Writes envelopes sealed and signed by the production sealing code with test keys. Apple
 * tests verify and open them; the negative cases must fail with the named reason.
 */

import { createHash, createPrivateKey, createPublicKey, sign, type KeyObject } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  PUSH_CIPHERTEXT_OFFSET,
  PUSH_ENVELOPE_BYTES,
  PUSH_PADDED_PLAINTEXT_BYTES,
  PUSH_SIGNED_BYTES,
  encodePushPlaintextJSON,
  padPushPlaintext,
  pushKeyId,
  sealPaddedPlaintext,
  sealPushEnvelope,
  type PushPlaintext,
} from "../src/push/envelope.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const vectorsDir = path.join(repoRoot, "protocol/push/vectors");

interface CryptoKitVectors {
  recipient: { privateKey: string; publicKey: string; keyId: string };
  other: { privateKey: string; publicKey: string; keyId: string };
}

const cryptokit = JSON.parse(
  readFileSync(path.join(vectorsDir, "cryptokit-hpke.json"), "utf8"),
) as CryptoKitVectors;
const recipientPublicKey = Buffer.from(cryptokit.recipient.publicKey, "base64url");
const otherPublicKey = Buffer.from(cryptokit.other.publicKey, "base64url");
if (pushKeyId(recipientPublicKey) !== cryptokit.recipient.keyId) {
  throw new Error("server keyId disagrees with CryptoKit keyId");
}

function ed25519FromSeed(seed: Buffer): KeyObject {
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  return createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
}

function rawPublicKey(privateKey: KeyObject): Buffer {
  const jwk = createPublicKey(privateKey).export({ format: "jwk" });
  return Buffer.from(jwk.x as string, "base64url");
}

// Test-only signing keys.
const serverSeed = Buffer.alloc(32, 0x42);
const serverKey = ed25519FromSeed(serverSeed);
const serverPublicKey = rawPublicKey(serverKey);
const impostorKey = ed25519FromSeed(Buffer.alloc(32, 0x24));

/** Fixed receiver clock for every case. */
const NOW = 1_760_000_000_000;
const SIGNATURE_LABEL = Buffer.from("oppi-push-envelope-v1-sig\0", "utf8");
function resign(envelope: Buffer, key: KeyObject = serverKey): Buffer {
  const signed = envelope.subarray(0, PUSH_SIGNED_BYTES);
  return Buffer.concat([signed, sign(null, Buffer.concat([SIGNATURE_LABEL, signed]), key)]);
}

function base(overrides: Partial<PushPlaintext> = {}): PushPlaintext {
  return {
    v: 1,
    ts: NOW - 5_000,
    event: "blocked",
    kind: "permission",
    sessionId: "s_vector",
    workspaceId: "w_vector",
    title: "Needs Approval",
    subtitle: "Fix the flaky test",
    body: "Waiting for your approval.",
    ...overrides,
  };
}

function seal(plaintext: PushPlaintext, to: Buffer = recipientPublicKey): Buffer {
  const sealed = sealPushEnvelope({
    recipientPublicKey: to,
    plaintext,
    signingKey: serverKey,
  });
  return Buffer.from(sealed, "base64url");
}

function sealPadded(padded: Buffer): Buffer {
  const sealed = sealPaddedPlaintext({
    recipientPublicKey,
    paddedPlaintext: padded,
    signingKey: serverKey,
  });
  return Buffer.from(sealed, "base64url");
}

const valid: Array<{ name: string; envelope: string; plaintext: unknown }> = [];
function addValid(name: string, plaintext: PushPlaintext): Buffer {
  const envelope = seal(plaintext);
  valid.push({
    name,
    envelope: envelope.toString("base64url"),
    plaintext: JSON.parse(encodePushPlaintextJSON(plaintext).toString("utf8")),
  });
  return envelope;
}

const blocked = addValid("blocked-permission", base());
addValid(
  "done-no-workspace",
  base({
    event: "done",
    kind: undefined,
    workspaceId: undefined,
    title: "Session Done",
    body: "Finished.",
  }),
);
addValid(
  "long-subtitle-shortened",
  base({
    kind: "question",
    title: "Question",
    subtitle: "名".repeat(400),
    body: "Waiting for your answer.",
  }),
);
addValid(
  "blocked-auth",
  base({ kind: "auth", title: "Sign-in Needed", body: "Waiting for you to sign in." }),
);
// Pairing events carry no sessionId.
addValid("pairing-approval", {
  v: 1,
  ts: NOW - 5_000,
  event: "pairing_approval",
  approvalId: "pa_vector",
  title: "Approve New Device?",
  body: "iPad wants to pair (invite, 100.64.0.7).",
});
addValid("device-enrolled", {
  v: 1,
  ts: NOW - 5_000,
  event: "device_enrolled",
  deviceId: "dev_vector",
  title: "New Device Paired",
  body: "iPad paired (tailscale, chen@example.com).",
});

const invalid: Array<{ name: string; envelope: string; reason: string }> = [];
function addInvalid(name: string, envelope: Buffer, reason: string): void {
  invalid.push({ name, envelope: envelope.toString("base64url"), reason });
}

const flipped = Buffer.from(blocked);
flipped[PUSH_CIPHERTEXT_OFFSET + 10] ^= 0x01;
addInvalid("tampered-ciphertext", flipped, "signature");

const badSig = Buffer.from(blocked);
badSig[PUSH_ENVELOPE_BYTES - 1] ^= 0x01;
addInvalid("tampered-signature", badSig, "signature");

addInvalid("resigned-tampered-ciphertext", resign(flipped), "decrypt");
addInvalid("wrong-signer", resign(blocked, impostorKey), "signature");
addInvalid("other-recipient-key", seal(base(), otherPublicKey), "unknownKey");

const otherWithOurKid = seal(base(), otherPublicKey);
Buffer.from(cryptokit.recipient.keyId, "base64url").copy(otherWithOurKid, 1);
addInvalid("other-recipient-key-relabelled", resign(otherWithOurKid), "decrypt");

addInvalid("stale", seal(base({ ts: NOW - 3_901_000 })), "stale");
addInvalid("future", seal(base({ ts: NOW + 301_000 })), "stale");
addInvalid("oversize", Buffer.concat([blocked, Buffer.alloc(1)]), "size");
addInvalid("truncated", blocked.subarray(0, PUSH_ENVELOPE_BYTES - 1), "size");

const wrongVersion = Buffer.from(blocked);
wrongVersion[0] = 0x02;
addInvalid("wrong-version", resign(wrongVersion), "version");

const nonzeroPadding = padPushPlaintext(encodePushPlaintextJSON(base()));
nonzeroPadding[PUSH_PADDED_PLAINTEXT_BYTES - 1] = 0x01;
addInvalid("nonzero-padding", sealPadded(nonzeroPadding), "plaintext");

const overlongLength = Buffer.alloc(PUSH_PADDED_PLAINTEXT_BYTES);
overlongLength.writeUInt16BE(511, 0);
addInvalid("length-over-510", sealPadded(overlongLength), "plaintext");

addInvalid("not-json", sealPadded(padPushPlaintext(Buffer.from("not json", "utf8"))), "plaintext");
addInvalid(
  "plaintext-version-2",
  sealPadded(padPushPlaintext(Buffer.from(JSON.stringify({ ...base(), v: 2 }), "utf8"))),
  "plaintext",
);

// Registration signature input (spec §5): Apple tests build the same bytes.
const registrationInput = {
  deviceId: "dev_vector",
  serverFingerprint: `sha256:${createHash("sha256").update(serverPublicKey).digest("base64url")}`,
  keyId: cryptokit.recipient.keyId,
  publicKey: cryptokit.recipient.publicKey,
  sendToken: "osp1.r_vector.p_vector.secret",
  relay: "https://push.example.test",
  issuedAt: NOW,
};
const registrationMessage = [
  "oppi-push-registration-v1",
  registrationInput.deviceId,
  registrationInput.serverFingerprint,
  registrationInput.keyId,
  createHash("sha256").update(recipientPublicKey).digest("base64url"),
  createHash("sha256").update(registrationInput.sendToken, "utf8").digest("base64url"),
  registrationInput.relay,
  String(registrationInput.issuedAt),
].join("\n");

const output = {
  _meta: {
    description:
      "Push envelope v1 vectors sealed and signed by server/src/push/envelope.ts. Test keys only.",
    generator: "server/scripts/generate-push-vectors.ts",
    reasons: {
      size: `not exactly ${PUSH_ENVELOPE_BYTES} bytes`,
      version: "version byte is not 0x01",
      unknownKey: "no push key with this kid",
      signature: "Ed25519 signature does not verify",
      decrypt: "HPKE open fails",
      plaintext: "padding, JSON, or v invalid",
      stale: "ts more than 3900 s before now or more than 300 s after",
      replay:
        "enc already accepted for this kid within 4200 s (maxAge + maxClockSkew); stateful, build from valid cases",
    },
  },
  now: NOW,
  recipient: cryptokit.recipient,
  server: {
    seed: serverSeed.toString("base64url"),
    publicKey: serverPublicKey.toString("base64url"),
    fingerprint: `sha256:${createHash("sha256").update(serverPublicKey).digest("base64url")}`,
  },
  valid,
  invalid,
  registrationSignature: {
    input: registrationInput,
    message: Buffer.from(registrationMessage, "utf8").toString("base64url"),
  },
};

writeFileSync(
  path.join(vectorsDir, "server-envelopes.json"),
  `${JSON.stringify(output, null, 2)}\n`,
);
console.log(`wrote ${valid.length} valid and ${invalid.length} invalid envelopes`);
