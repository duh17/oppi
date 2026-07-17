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

  it("generates a signed v4 iroh-only invite without host, port, or HTTP transport", () => {
    const storage = makeStorage({ port: 7777, host: "0.0.0.0" });
    const identity = makeIdentity();
    mockEnsureIdentityMaterial.mockReturnValue(identity);
    const resolveHost = vi.fn(() => {
      throw new Error("host resolver should not run for iroh-only invites");
    });
    const shortLabel = vi.fn(() => "unused");

    const invite = generateInvite(storage as Storage, resolveHost, shortLabel, {
      inviteVersion: 4,
      requestedName: "Host-free Mac",
      preference: "irohOnly",
      transports: {
        iroh: {
          version: 2,
          nodeId: "iroh-node-abc123",
          alpns: ["oppi/pair/1", "oppi/http/1"],
          addressMode: "node-id",
        },
      },
    });

    expect(resolveHost).not.toHaveBeenCalled();
    expect(shortLabel).not.toHaveBeenCalled();
    expect(mockPrepareTlsForServer).not.toHaveBeenCalled();
    expect(invite).toMatchObject({
      name: "Host-free Mac",
      pairingToken: "pair-90000",
      fingerprint: identity.fingerprint,
    });
    expect((storage as Storage).issuePairingToken).toHaveBeenCalledWith(90_000, {
      allowedTransports: ["iroh"],
    });
    expect(Object.hasOwn(invite, "host")).toBe(false);
    expect(Object.hasOwn(invite, "port")).toBe(false);
    expect(new URL(invite.inviteURL).searchParams.get("v")).toBe("4");

    const { envelope, signedPayload, signedPayloadJson } = decodeInvite(invite.inviteURL);
    expect(envelope.v).toBe(4);
    expect(envelope.alg).toBe("ed25519");
    expect(envelope.publicKey).toBe(identity.publicKeyRaw);
    expect(signedPayload).toEqual({
      v: 4,
      name: "Host-free Mac",
      pairingToken: "pair-90000",
      fingerprint: identity.fingerprint,
      preference: "irohOnly",
      transports: {
        iroh: {
          version: 2,
          nodeId: "iroh-node-abc123",
          alpns: ["oppi/pair/1", "oppi/http/1"],
          addressMode: "node-id",
        },
      },
    });
    expect(
      verify(
        null,
        Buffer.from(envelope.signedPayload, "utf-8"),
        createPublicKey(identity.publicKeyPem),
        Buffer.from(envelope.signature, "base64url"),
      ),
    ).toBe(true);
    expect(
      verify(
        null,
        Buffer.from(signedPayloadJson, "utf-8"),
        createPublicKey(identity.publicKeyPem),
        Buffer.from(envelope.signature, "base64url"),
      ),
    ).toBe(false);
  });

  it("generates a signed v4 http-only invite with HTTP-only pairing constraints", () => {
    const storage = makeStorage({ port: 7777, host: "0.0.0.0" });

    const invite = generateInvite(
      storage as Storage,
      () => "server.local",
      () => "Fallback Label",
      {
        inviteVersion: 4,
        requestedName: "HTTP Mac",
        preference: "httpOnly",
        transports: {},
      },
    );

    expect(invite.host).toBe("server.local");
    expect(invite.port).toBe(7777);
    expect(invite.scheme).toBe("http");
    expect((storage as Storage).issuePairingToken).toHaveBeenCalledWith(90_000, {
      allowedTransports: ["http"],
    });

    const { signedPayload } = decodeInvite(invite.inviteURL);
    expect(signedPayload).toMatchObject({
      v: 4,
      preference: "httpOnly",
      transports: {
        http: { host: "server.local", port: 7777, scheme: "http" },
      },
    });
    expect((signedPayload.transports as Record<string, unknown>).iroh).toBeUndefined();
  });

  it("generates a signed v4 iroh-preferred invite with HTTP fallback and ticket as a hint", () => {
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
      {
        inviteVersion: 4,
        requestedName: "  Preferred Mac  ",
        preference: "irohPreferred",
        transports: {
          iroh: {
            version: 2,
            nodeId: "iroh-node-preferred",
            alpns: ["oppi/pair/1"],
            addressMode: "ticket",
            ticket: "iroh-ticket-hint",
          },
        },
      },
    );

    expect(invite.host).toBe("server.local");
    expect(invite.port).toBe(7777);
    expect(invite.scheme).toBe("https");
    expect((storage as Storage).issuePairingToken).toHaveBeenCalledWith(90_000, {
      allowedTransports: ["iroh", "http"],
    });

    const { envelope, signedPayload } = decodeInvite(invite.inviteURL);
    expect(envelope.v).toBe(4);
    expect(signedPayload).toMatchObject({
      v: 4,
      name: "Preferred Mac",
      preference: "irohPreferred",
      transports: {
        iroh: {
          nodeId: "iroh-node-preferred",
          addressMode: "ticket",
          ticket: "iroh-ticket-hint",
        },
        http: {
          host: "server.local",
          port: 7777,
          scheme: "https",
          tlsCertFingerprint: "sha256:cert-fingerprint",
        },
      },
    });
  });
});
