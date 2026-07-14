/**
 * Invite generation — reusable by CLI (QR rendering, --json) and future Mac app.
 */

import { sign } from "node:crypto";
import type { InviteData, InvitePayloadV3, ServerConfig, SignedInviteEnvelopeV3 } from "./types.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import {
  isTailscaleHostname,
  prepareTlsForServer,
  readCertificateFingerprint,
  readValidTailnetDnsName,
  resolveTlsConfig,
} from "./tls.js";

/** Structured invite result returned by generateInvite(). */
export interface GeneratedInvite {
  host: string;
  port: number;
  scheme: "http" | "https";
  name: string;
  pairingToken: string;
  fingerprint: string;
  tlsCertFingerprint?: string;
  inviteURL: string;
}

export interface GenerateInviteOptions {
  hostOverride?: string;
  requestedName?: string;
  /** Pairing token TTL in ms. Defaults to 90 000 (90 seconds). */
  pairingTokenTtlMs?: number;
}

export interface InviteStorage {
  getConfig(): ServerConfig;
  getDataDir(): string;
  ensurePaired(): string;
  issuePairingToken(ttlMs?: number): string;
}

/**
 * Generate a structured invite payload.
 *
 * Resolves the pairing host, prepares TLS material, issues a short-lived
 * pairing token, and builds the invite deep-link URL.
 *
 * Throws on unrecoverable errors (no host detected, TLS mode mismatch, etc.).
 */
export function generateInvite(
  storage: InviteStorage,
  resolveInviteHost: (hostOverride?: string) => string | null,
  shortHostLabel: (host: string) => string,
  opts: GenerateInviteOptions = {},
): GeneratedInvite {
  const config = storage.getConfig();
  storage.ensurePaired();

  let inviteHost = resolveInviteHost(opts.hostOverride);
  if (!inviteHost && config.tls?.mode === "tailscale") {
    const resolved = resolveTlsConfig(config, storage.getDataDir());
    if (resolved.certPath) {
      try {
        inviteHost = readValidTailnetDnsName(resolved.certPath);
      } catch (error: unknown) {
        const detail = error instanceof Error ? error.message : String(error);
        throw new Error(
          `Could not determine pairing host from live Tailscale or existing certificate: ${detail}. ` +
            "Start Tailscale to obtain or renew the certificate, or pass --host <machine>.<tailnet>.ts.net.",
        );
      }
    }
  }

  if (!inviteHost) {
    const hint =
      config.tls?.mode === "tailscale"
        ? "Start Tailscale to obtain a certificate or pass --host <machine>.<tailnet>.ts.net"
        : "Pass --host <hostname-or-ip>, e.g. --host my-mac.local";
    throw new Error(`Could not determine pairing host. ${hint}`);
  }

  if (config.tls?.mode === "tailscale" && !isTailscaleHostname(inviteHost)) {
    throw new Error(
      "Tailscale TLS mode requires a *.ts.net pairing host. " +
        "Use --host <machine>.<tailnet>.ts.net or disable tls.mode=tailscale",
    );
  }

  // Resolve TLS state
  let inviteScheme: "http" | "https" = "http";
  let tlsCertFingerprint: string | undefined;

  const tls = prepareTlsForServer(config, storage.getDataDir(), {
    additionalHosts: [inviteHost, config.host],
    ensureSelfSigned: true,
  });

  inviteScheme = tls.enabled ? "https" : "http";
  // Tailscale-issued leaves rotate, so do not make already-paired clients
  // depend on one leaf pin. Oppi validates local consistency; clients still
  // enforce normal certificate-chain trust for the HTTPS connection.
  if (tls.enabled && tls.certPath && tls.mode !== "tailscale") {
    tlsCertFingerprint = readCertificateFingerprint(tls.certPath);
  }

  // Issue pairing token
  const pairingToken = storage.issuePairingToken(opts.pairingTokenTtlMs ?? 90_000);

  // Build identity
  const identity = ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));

  // Build v3 invite payload
  const inviteData: InviteData = {
    host: inviteHost,
    port: config.port,
    scheme: inviteScheme,
    token: "",
    pairingToken,
    name: opts.requestedName?.trim() || shortHostLabel(inviteHost),
    tlsCertFingerprint,
  };

  const signedPayload: InvitePayloadV3 = {
    v: 3,
    host: inviteData.host,
    port: inviteData.port,
    scheme: inviteData.scheme,
    token: inviteData.token,
    pairingToken: inviteData.pairingToken,
    name: inviteData.name,
    tlsCertFingerprint: inviteData.tlsCertFingerprint,
    fingerprint: identity.fingerprint,
  };
  const signedPayloadJson = JSON.stringify(signedPayload);
  const signature = sign(
    null,
    Buffer.from(signedPayloadJson, "utf-8"),
    identity.privateKeyPem,
  ).toString("base64url");
  const invitePayload: SignedInviteEnvelopeV3 = {
    v: 3,
    signedPayload: Buffer.from(signedPayloadJson, "utf-8").toString("base64url"),
    publicKey: identity.publicKeyRaw,
    signature,
  };

  const inviteJson = JSON.stringify(invitePayload);
  const inviteURL = `oppi://connect?${new URLSearchParams({
    v: "3",
    invite: Buffer.from(inviteJson, "utf-8").toString("base64url"),
  }).toString()}`;

  return {
    host: inviteData.host,
    port: inviteData.port,
    scheme: inviteScheme,
    name: inviteData.name,
    pairingToken,
    fingerprint: identity.fingerprint,
    tlsCertFingerprint,
    inviteURL,
  };
}
