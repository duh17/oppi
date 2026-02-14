import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  createSignedInviteV2,
  ensureIdentityMaterial,
  verifyInviteV2,
  type InviteV2Payload,
} from "../src/security.js";
import type { ServerIdentityConfig } from "../src/types.js";

describe("security invite signing", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-security-invite-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  function identityConfig(): ServerIdentityConfig {
    return {
      enabled: true,
      algorithm: "ed25519",
      keyId: "srv-test",
      privateKeyPath: join(dir, "identity_ed25519"),
      publicKeyPath: join(dir, "identity_ed25519.pub"),
      fingerprint: "",
    };
  }

  function payload(fingerprint: string): InviteV2Payload {
    return {
      host: "myhost.tail12345.ts.net",
      port: 7749,
      token: "sk_test_123",
      name: "my-mac",
      fingerprint,
      securityProfile: "tailscale-permissive",
    };
  }

  it("creates identity keys and computes fingerprint", () => {
    const id = ensureIdentityMaterial(identityConfig());

    expect(id.algorithm).toBe("ed25519");
    expect(id.keyId).toBe("srv-test");
    expect(id.publicKeyRaw.length).toBeGreaterThan(10);
    expect(id.fingerprint.startsWith("sha256:")).toBe(true);
  });

  it("signs and verifies v2 invites", () => {
    const id = ensureIdentityMaterial(identityConfig());
    const invite = createSignedInviteV2(id, payload(id.fingerprint), 600, 1_760_000_000_000);

    expect(invite.v).toBe(2);
    expect(invite.kid).toBe("srv-test");
    expect(invite.payload.fingerprint).toBe(id.fingerprint);
    expect(verifyInviteV2(invite)).toBe(true);
  });

  it("fails verification if payload is tampered", () => {
    const id = ensureIdentityMaterial(identityConfig());
    const invite = createSignedInviteV2(id, payload(id.fingerprint), 600, 1_760_000_000_000);
    invite.payload.host = "evil.example.com";

    expect(verifyInviteV2(invite)).toBe(false);
  });
});
