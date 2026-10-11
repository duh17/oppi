import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { hpkeOpen, hpkeSeal, x25519PublicKey } from "../src/push/hpke.js";

interface KnownAnswer {
  mode: number;
  kem_id: number;
  kdf_id: number;
  aead_id: number;
  info: string;
  skRm: string;
  pkRm: string;
  skEm: string;
  enc: string;
  encryption: { aad: string; pt: string; ct: string };
}

const a2 = JSON.parse(
  readFileSync(new URL("./fixtures/hpke-rfc9180-a2.json", import.meta.url), "utf8"),
) as KnownAnswer;
const hex = (value: string) => Buffer.from(value, "hex");

describe("HPKE against RFC 9180 Appendix A.2.1", () => {
  it("is the base-mode X25519 / HKDF-SHA256 / ChaCha20-Poly1305 vector", () => {
    expect([a2.mode, a2.kem_id, a2.kdf_id, a2.aead_id]).toEqual([0, 0x20, 1, 3]);
    expect(x25519PublicKey(hex(a2.skRm)).toString("hex")).toBe(a2.pkRm);
  });

  it("seals to the published enc and ciphertext", () => {
    const sealed = hpkeSeal({
      recipientPublicKey: hex(a2.pkRm),
      info: hex(a2.info),
      aad: hex(a2.encryption.aad),
      plaintext: hex(a2.encryption.pt),
      ephemeralPrivateKey: hex(a2.skEm),
    });
    expect(sealed.enc.toString("hex")).toBe(a2.enc);
    expect(sealed.ciphertext.toString("hex")).toBe(a2.encryption.ct);
  });

  it("opens the published ciphertext and refuses altered inputs", () => {
    const input = {
      recipientPrivateKey: hex(a2.skRm),
      enc: hex(a2.enc),
      info: hex(a2.info),
      aad: hex(a2.encryption.aad),
      ciphertext: hex(a2.encryption.ct),
    };
    expect(hpkeOpen(input).toString("hex")).toBe(a2.encryption.pt);

    const flipped = Buffer.from(input.ciphertext);
    flipped[0] ^= 0x01;
    expect(() => hpkeOpen({ ...input, ciphertext: flipped })).toThrow();
    expect(() => hpkeOpen({ ...input, aad: Buffer.from("Count-1") })).toThrow();
    expect(() => hpkeOpen({ ...input, info: Buffer.alloc(0) })).toThrow();
  });
});

describe("HPKE X25519 validation (RFC 9180 section 7.1.4)", () => {
  // A low-order point: every scalar maps it to the all-zero shared secret.
  const zeroPoint = Buffer.alloc(32);

  it("refuses to seal to a low-order public key", () => {
    expect(() =>
      hpkeSeal({
        recipientPublicKey: zeroPoint,
        info: Buffer.alloc(0),
        aad: Buffer.alloc(0),
        plaintext: Buffer.from("x"),
      }),
    ).toThrow("shared secret");
  });

  it("refuses to open a low-order enc", () => {
    expect(() =>
      hpkeOpen({
        recipientPrivateKey: hex(a2.skRm),
        enc: zeroPoint,
        info: hex(a2.info),
        aad: hex(a2.encryption.aad),
        ciphertext: hex(a2.encryption.ct),
      }),
    ).toThrow("shared secret");
  });
});
