import { createHash, createPublicKey, generateKeyPairSync, verify } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

const {
  mockEnsureIdentityMaterial,
  mockIdentityConfigForDataDir,
  mockIsTailscaleHostname,
  mockPrepareTlsForServer,
  mockReadCertificateFingerprint,
  mockReadValidTailnetDnsName,
  mockResolveTlsConfig,
} = vi.hoisted(() => ({
  mockEnsureIdentityMaterial: vi.fn(),
  mockIdentityConfigForDataDir: vi.fn(),
  mockIsTailscaleHostname: vi.fn(),
  mockPrepareTlsForServer: vi.fn(),
  mockReadCertificateFingerprint: vi.fn(),
  mockReadValidTailnetDnsName: vi.fn(),
  mockResolveTlsConfig: vi.fn(),
}));

vi.mock("../src/security.js", () => ({
  ensureIdentityMaterial: (...args: unknown[]) => mockEnsureIdentityMaterial(...args),
  identityConfigForDataDir: (...args: unknown[]) => mockIdentityConfigForDataDir(...args),
}));

vi.mock("../src/tls.js", () => ({
  isTailscaleHostname: (...args: unknown[]) => mockIsTailscaleHostname(...args),
  prepareTlsForServer: (...args: unknown[]) => mockPrepareTlsForServer(...args),
  readCertificateFingerprint: (...args: unknown[]) => mockReadCertificateFingerprint(...args),
  readValidTailnetDnsName: (...args: unknown[]) => mockReadValidTailnetDnsName(...args),
  resolveTlsConfig: (...args: unknown[]) => mockResolveTlsConfig(...args),
}));

import { generateInvite } from "../src/invite.js";
import type { Storage } from "../src/storage.js";

function fingerprintForPublicKeyRaw(publicKeyRaw: string): string {
  const raw = Buffer.from(publicKeyRaw, "base64url");
  const digest = createHash("sha256").update(raw).digest("base64url");
  return `sha256:${digest}`;
}

function makeIdentity() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }).toString();
  const jwk = publicKey.export({ format: "jwk" }) as { x: string };
  const publicKeyRaw = jwk.x;
  return {
    keyId: "srv-default",
    algorithm: "ed25519" as const,
    privateKeyPem,
    publicKeyPem,
    publicKeyRaw,
    fingerprint: fingerprintForPublicKeyRaw(publicKeyRaw),
  };
}

function makeStorage(config: {
  port: number;
  host: string;
  tls?: { mode?: "disabled" | "self-signed" | "tailscale" };
}) {
  return {
    getConfig: vi.fn(() => config),
    ensurePaired: vi.fn(() => "server-token"),
    getDataDir: vi.fn(() => "/tmp/oppi-test"),
    issuePairingToken: vi.fn((ttlMs?: number) => `pair-${ttlMs ?? 90_000}`),
  } as unknown as Pick<Storage, "getConfig" | "ensurePaired" | "getDataDir" | "issuePairingToken">;
}

function decodeInvite(urlString: string) {
  const url = new URL(urlString);
  const invite = url.searchParams.get("invite");
  expect(invite).toBeTruthy();

  const envelope = JSON.parse(Buffer.from(invite!, "base64url").toString("utf-8")) as {
    v: number;
    alg?: string;
    signedPayload: string;
    publicKey: string;
    signature: string;
  };
  const signedPayloadJson = Buffer.from(envelope.signedPayload, "base64url").toString("utf-8");
  const signedPayload = JSON.parse(signedPayloadJson) as Record<string, unknown>;

  return { envelope, signedPayloadJson, signedPayload };
}

describe("generateInvite", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockIdentityConfigForDataDir.mockReturnValue({ keyId: "srv-default" });
    mockPrepareTlsForServer.mockReturnValue({ enabled: false, mode: "disabled" });
    mockIsTailscaleHostname.mockReturnValue(true);
    mockReadCertificateFingerprint.mockReturnValue("sha256:cert-fingerprint");
    mockReadValidTailnetDnsName.mockReturnValue("cert-host.tail00000.ts.net");
    mockResolveTlsConfig.mockReturnValue({
      enabled: true,
      mode: "tailscale",
      certPath: "/tmp/oppi-test/tls/tailscale/server.crt",
      keyPath: "/tmp/oppi-test/tls/tailscale/server.key",
    });
    mockEnsureIdentityMaterial.mockReturnValue(makeIdentity());
  });

  it("throws a generic host hint when invite host resolution fails", () => {
    const storage = makeStorage({ port: 7777, host: "0.0.0.0" });

    expect(() =>
      generateInvite(
        storage as Storage,
        () => null,
        () => "unused",
      ),
    ).toThrowError(
      "Could not determine pairing host. Pass --host <hostname-or-ip>, e.g. --host my-mac.local",
    );
  });

  it("recovers the pairing hostname from an existing Tailnet certificate SAN", () => {
    const storage = makeStorage({
      port: 7777,
      host: "0.0.0.0",
      tls: { mode: "tailscale" },
    });
    mockPrepareTlsForServer.mockReturnValue({
      enabled: true,
      mode: "tailscale",
      certPath: "/tmp/oppi-test/tls/tailscale/server.crt",
    });

    const invite = generateInvite(
      storage as Storage,
      () => null,
      (host) => host.split(".")[0] ?? host,
    );

    expect(invite.host).toBe("cert-host.tail00000.ts.net");
    expect(invite.scheme).toBe("https");
    expect(mockReadValidTailnetDnsName).toHaveBeenCalledWith(
      "/tmp/oppi-test/tls/tailscale/server.crt",
    );
    expect(mockPrepareTlsForServer).toHaveBeenCalledWith(
      expect.anything(),
      "/tmp/oppi-test",
      expect.objectContaining({
        additionalHosts: ["cert-host.tail00000.ts.net", "0.0.0.0"],
      }),
    );
  });

  it("fails with renewal guidance when discovery and existing certificate recovery fail", () => {
    const storage = makeStorage({
      port: 7777,
      host: "0.0.0.0",
      tls: { mode: "tailscale" },
    });
    mockReadValidTailnetDnsName.mockImplementation(() => {
      throw new Error("Tailscale TLS certificate is expired: /tmp/server.crt");
    });

    expect(() =>
      generateInvite(
        storage as Storage,
        () => null,
        () => "unused",
      ),
    ).toThrowError(/Could not determine pairing host.*certificate is expired.*Start Tailscale/);
    expect(mockPrepareTlsForServer).not.toHaveBeenCalled();
  });

  it("rejects a pairing host that includes a port before TLS setup", () => {
    const storage = makeStorage({
      port: 7777,
      host: "0.0.0.0",
      tls: { mode: "self-signed" },
    });

    expect(() =>
      generateInvite(
        storage as Storage,
        () => "server.local:7749",
        () => "unused",
      ),
    ).toThrowError(/hostname or IP only/);
    expect(mockPrepareTlsForServer).not.toHaveBeenCalled();
  });

  it("rejects non-tailnet hosts in tailscale TLS mode before TLS setup", () => {
    const storage = makeStorage({
      port: 7777,
      host: "0.0.0.0",
      tls: { mode: "tailscale" },
    });
    mockIsTailscaleHostname.mockReturnValue(false);

    expect(() =>
      generateInvite(
        storage as Storage,
        () => "example.local",
        () => "unused",
      ),
    ).toThrowError(
      "Tailscale TLS mode requires a *.ts.net pairing host. Use --host <machine>.<tailnet>.ts.net or disable tls.mode=tailscale",
    );
    expect(mockPrepareTlsForServer).not.toHaveBeenCalled();
  });

  it("generates a signed https invite with trimmed requested name and cert pin", () => {
    const storage = makeStorage({
      port: 7777,
      host: "0.0.0.0",
      tls: { mode: "self-signed" },
    });
    const identity = makeIdentity();
    mockEnsureIdentityMaterial.mockReturnValue(identity);
    mockPrepareTlsForServer.mockReturnValue({
      enabled: true,
      mode: "self-signed",
      certPath: "/tmp/server.crt",
    });

    const invite = generateInvite(
      storage as Storage,
      () => "server.local",
      () => "Fallback Label",
      { requestedName: "  My Work Mac  ", pairingTokenTtlMs: 12_345 },
    );

    expect(invite).toMatchObject({
      host: "server.local",
      port: 7777,
      scheme: "https",
      name: "My Work Mac",
      pairingToken: "pair-12345",
      fingerprint: identity.fingerprint,
      tlsCertFingerprint: "sha256:cert-fingerprint",
    });
    expect((storage as Storage).ensurePaired).toHaveBeenCalledOnce();
    expect((storage as Storage).issuePairingToken).toHaveBeenCalledWith(12_345);
    expect(mockReadCertificateFingerprint).toHaveBeenCalledWith("/tmp/server.crt");
    expect(mockIdentityConfigForDataDir).toHaveBeenCalledWith("/tmp/oppi-test");

    const { envelope, signedPayload, signedPayloadJson } = decodeInvite(invite.inviteURL);
    expect(envelope.v).toBe(3);
    expect(envelope.publicKey).toBe(identity.publicKeyRaw);
    expect(signedPayload).toMatchObject({
      v: 3,
      host: "server.local",
      port: 7777,
      scheme: "https",
      token: "",
      pairingToken: "pair-12345",
      name: "My Work Mac",
      tlsCertFingerprint: "sha256:cert-fingerprint",
      fingerprint: identity.fingerprint,
    });
    expect(
      verify(
        null,
        Buffer.from(signedPayloadJson, "utf-8"),
        createPublicKey(identity.publicKeyPem),
        Buffer.from(envelope.signature, "base64url"),
      ),
    ).toBe(true);
  });

  it("omits a rotating leaf cert pin for tailscale invites and uses the short host label", () => {
    const storage = makeStorage({
      port: 7777,
      host: "0.0.0.0",
      tls: { mode: "tailscale" },
    });

    mockPrepareTlsForServer.mockReturnValue({
      enabled: true,
      mode: "tailscale",
      certPath: "/tmp/tailscale.crt",
    });

    const invite = generateInvite(
      storage as Storage,
      () => "my-server.tail00000.ts.net",
      () => "Tailnet Mac",
      { requestedName: "   " },
    );

    expect(invite.scheme).toBe("https");
    expect(invite.name).toBe("Tailnet Mac");
    expect(invite.tlsCertFingerprint).toBeUndefined();
    expect((storage as Storage).issuePairingToken).toHaveBeenCalledWith(90_000);
    expect(mockReadCertificateFingerprint).not.toHaveBeenCalled();

    const { signedPayload } = decodeInvite(invite.inviteURL);
    expect(signedPayload).toMatchObject({
      host: "my-server.tail00000.ts.net",
      scheme: "https",
      name: "Tailnet Mac",
      pairingToken: "pair-90000",
    });
    expect(signedPayload.tlsCertFingerprint).toBeUndefined();
  });

  it("brackets a bare IPv6 pairing host in the signed invite", () => {
    const storage = makeStorage({ port: 7777, host: "0.0.0.0" });
    mockIsTailscaleHostname.mockReturnValue(false);

    const invite = generateInvite(storage as Storage, () => "2001:db8::1", () => "studio");

    expect(invite.host).toBe("[2001:db8::1]");
    const { signedPayload } = decodeInvite(invite.inviteURL);
    expect(signedPayload.host).toBe("[2001:db8::1]");
  });

});
