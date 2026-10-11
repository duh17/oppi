import { generateKeyPairSync } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  PUSH_ENVELOPE_BYTES,
  PUSH_MAX_PLAINTEXT_JSON_BYTES,
  encodePushPlaintextJSON,
  pushKeyId,
  sealPushEnvelope,
  type PushPlaintext,
} from "../src/push/envelope.js";
import { hpkeOpen } from "../src/push/hpke.js";
import { openPushEnvelopeForTest } from "./helpers/push-envelope-open.js";

const vectorsDir = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../protocol/push/vectors",
);

interface CryptoKitVectors {
  info: string;
  recipient: { privateKey: string; publicKey: string; keyId: string };
  cases: Array<{ plaintext: string; aad: string; enc: string; ciphertext: string }>;
}

const cryptokit = JSON.parse(
  readFileSync(path.join(vectorsDir, "cryptokit-hpke.json"), "utf8"),
) as CryptoKitVectors;
const recipientPrivateKey = Buffer.from(cryptokit.recipient.privateKey, "base64url");
const recipientPublicKey = Buffer.from(cryptokit.recipient.publicKey, "base64url");

function plaintext(overrides: Partial<PushPlaintext> = {}): PushPlaintext {
  return {
    v: 1,
    seq: 1,
    ts: 1_760_000_000_000,
    event: "blocked",
    kind: "permission",
    sessionId: "s_1",
    title: "Needs Approval",
    subtitle: "Fix the flaky test",
    body: "Waiting for your approval.",
    ...overrides,
  };
}

describe("push envelope v1 against CryptoKit", () => {
  it("opens every HPKE message CryptoKit sealed to the push key", () => {
    expect(cryptokit.cases.length).toBeGreaterThan(0);
    for (const vector of cryptokit.cases) {
      const opened = hpkeOpen({
        recipientPrivateKey,
        info: Buffer.from(cryptokit.info, "base64url"),
        aad: Buffer.from(vector.aad, "base64url"),
        enc: Buffer.from(vector.enc, "base64url"),
        ciphertext: Buffer.from(vector.ciphertext, "base64url"),
      });
      expect(opened.toString("base64url")).toBe(vector.plaintext);
    }
  });

  it("derives the same key id as CryptoKit", () => {
    expect(pushKeyId(recipientPublicKey)).toBe(cryptokit.recipient.keyId);
  });
});

describe("sealPushEnvelope", () => {
  const { privateKey: signingKey, publicKey: serverPublicKey } = generateKeyPairSync("ed25519");

  it("produces a fixed-size envelope that verifies and opens to the plaintext", () => {
    const short = sealPushEnvelope({
      recipientPublicKey,
      plaintext: plaintext({ subtitle: "a" }),
      signingKey,
    });
    const long = sealPushEnvelope({
      recipientPublicKey,
      plaintext: plaintext({ subtitle: "b".repeat(300) }),
      signingKey,
    });
    expect(Buffer.from(short, "base64url")).toHaveLength(PUSH_ENVELOPE_BYTES);
    expect(Buffer.from(long, "base64url")).toHaveLength(PUSH_ENVELOPE_BYTES);

    const opened = openPushEnvelopeForTest(short, { recipientPrivateKey, serverPublicKey });
    expect(opened).toEqual(plaintext({ subtitle: "a" }));
  });

  it("rejects a signature by another server key", () => {
    const sealed = sealPushEnvelope({
      recipientPublicKey,
      plaintext: plaintext(),
      signingKey,
    });
    const other = generateKeyPairSync("ed25519").publicKey;
    expect(() =>
      openPushEnvelopeForTest(sealed, { recipientPrivateKey, serverPublicKey: other }),
    ).toThrow("signature");
  });

  it("refuses a key that is not a 32-byte X25519 public key", () => {
    expect(() =>
      sealPushEnvelope({
        recipientPublicKey: Buffer.concat([recipientPublicKey, Buffer.alloc(1)]),
        plaintext: plaintext(),
        signingKey,
      }),
    ).toThrow("32-byte X25519");
  });
});

describe("encodePushPlaintextJSON", () => {
  it("shortens a long session name first and keeps the rest", () => {
    const encoded = encodePushPlaintextJSON(plaintext({ subtitle: "名".repeat(400) }));
    expect(encoded.length).toBeLessThanOrEqual(PUSH_MAX_PLAINTEXT_JSON_BYTES);
    const decoded = JSON.parse(encoded.toString("utf8")) as PushPlaintext;
    expect(decoded.subtitle?.startsWith("名")).toBe(true);
    expect(decoded.body).toBe("Waiting for your approval.");
  });

  it("drops the session name, then shortens the body, when the body alone is too long", () => {
    const encoded = encodePushPlaintextJSON(plaintext({ body: "x".repeat(700) }));
    expect(encoded.length).toBeLessThanOrEqual(PUSH_MAX_PLAINTEXT_JSON_BYTES);
    const decoded = JSON.parse(encoded.toString("utf8")) as PushPlaintext;
    expect(decoded.subtitle).toBeUndefined();
    expect(decoded.body.length).toBeGreaterThan(300);
  });
});
