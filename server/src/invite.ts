/**
 * Invite generation — reusable by CLI (QR rendering, --json) and future Mac app.
 */

import type { Storage } from "./storage.js";
import type { InviteData, InvitePayloadV3 } from "./types.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import { isTailscaleHostname, prepareTlsForServer, readCertificateFingerprint } from "./tls.js";

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

/**
 * Generate a structured invite payload.
 *
 * Resolves the pairing host, prepares TLS material, issues a short-lived
 * pairing token, and builds the invite deep-link URL.
 *
 * Throws on unrecoverable errors (no host detected, TLS mode mismatch, etc.).
 */
export function generateInvite(
  storage: Storage,
  resolveInviteHost: (hostOverride?: string) => string | null,
  shortHostLabel: (host: string) => string,
  opts: GenerateInviteOptions = {},
): GeneratedInvite {
  const config = storage.getConfig();
  storage.ensurePaired();

  const inviteHost = resolveInviteHost(opts.hostOverride);
  if (!inviteHost) {
    const hint =
      config.tls?.mode === "tailscale"
        ? "Pass --host <machine>.<tailnet>.ts.net and ensure Tailscale is connected"
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
  if (tls.enabled && tls.certPath) {
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

  const invitePayload: InvitePayloadV3 = {
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
