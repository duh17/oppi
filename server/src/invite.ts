/** Invite generation — reusable by CLI (QR rendering, --json) and future Mac app. */

import { sign } from "node:crypto";
import type { InviteData, InvitePayloadV3, ServerConfig, SignedInviteEnvelopeV3 } from "./types.js";
import { parsePublicUrl } from "./proxy-config.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import {
  isTailscaleHostname,
  prepareTlsForServer,
  readCertificateFingerprint,
  readValidTailnetDnsName,
  resolveTlsConfig,
  validateTailscaleMaterial,
} from "./tls.js";

export interface GeneratedInvite {
  name: string;
  pairingToken: string;
  fingerprint: string;
  tlsCertFingerprint?: string;
  host: string;
  port: number;
  scheme: "http" | "https";
  inviteURL: string;
  /** ISO time after which the single-use pairing token is rejected. */
  expiresAt: string;
}

export interface GenerateInviteOptions {
  hostOverride?: string;
  requestedName?: string;
  /** Pairing token TTL in ms. Defaults to 90 000 (90 seconds). */
  pairingTokenTtlMs?: number;
  /** Advertise hostOverride even when publicUrl is configured. */
  ignorePublicUrl?: boolean;
  /**
   * When true and tls.mode=tailscale, validate on-disk certs only.
   * Skips prepareTlsForServer (no renewal lock, no `tailscale cert` / status).
   */
  skipRenewal?: boolean;
}

export interface InviteStorage {
  getConfig(): ServerConfig;
  getDataDir(): string;
  ensurePaired(): string;
  issuePairingToken(ttlMs?: number): string;
}

/**
 * Generate a signed HTTPS/HTTP pairing invite. Authentication is rejected on
 * plaintext network listeners; HTTPS is the supported remote route.
 */
export function generateInvite(
  storage: InviteStorage,
  resolveInviteHost: (hostOverride?: string) => string | null,
  shortHostLabel: (host: string) => string,
  opts: GenerateInviteOptions = {},
): GeneratedInvite {
  const config = storage.getConfig();
  storage.ensurePaired();

  const publicOrigin = config.publicUrl ? parsePublicUrl(config.publicUrl) : undefined;
  if (config.publicUrl && publicOrigin && !publicOrigin.ok) {
    throw new Error(`Invalid publicUrl: ${publicOrigin.error}`);
  }
  const publicUrl = publicOrigin?.ok ? publicOrigin.value : undefined;
  if (publicUrl && !opts.ignorePublicUrl) {
    if (opts.hostOverride?.trim()) {
      const override = opts.hostOverride.trim();
      if (override.toLowerCase() !== publicUrl.host.toLowerCase()) {
        throw new Error(
          `--host ${override} conflicts with publicUrl ${publicUrl.href}. Omit --host to advertise the public origin, or change publicUrl.`,
        );
      }
    }
    return signInvite(storage, {
      host: publicUrl.host,
      port: publicUrl.port,
      scheme: "https",
      name: opts.requestedName?.trim() || shortHostLabel(publicUrl.host),
      pairingTokenTtlMs: opts.pairingTokenTtlMs,
    });
  }

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
          { cause: error },
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
  // iOS App Transport Security applies default CA trust to *.ts.net names and
  // the app has no exception for them, so a pinned self-signed or manual leaf
  // cannot connect there. Tailnet names use Tailscale-issued certificates; the
  // other modes reach a tailnet peer by IP, which ATS treats as local.
  if (config.tls?.mode !== "tailscale" && isTailscaleHostname(inviteHost)) {
    throw new Error(
      `A *.ts.net pairing host requires tls.mode=tailscale (current: ${config.tls?.mode ?? "disabled"}). ` +
        "Enable HTTPS certificates for the tailnet, run `oppi config set tls.mode tailscale`, and restart, " +
        "or pass --host <lan-host-or-tailscale-ip>.",
    );
  }

  const dataDir = storage.getDataDir();
  if (opts.skipRenewal && config.tls?.mode === "tailscale") {
    const resolved = resolveTlsConfig(config, dataDir);
    validateTailscaleMaterial(resolved, inviteHost);
    const name = opts.requestedName?.trim() || shortHostLabel(inviteHost);
    return signInvite(storage, {
      host: inviteHost,
      port: config.port,
      scheme: "https",
      name,
      pairingTokenTtlMs: opts.pairingTokenTtlMs,
    });
  }

  const tls = prepareTlsForServer(config, dataDir, {
    additionalHosts: [inviteHost, config.host],
    ensureSelfSigned: true,
  });
  const scheme = tls.enabled ? "https" : "http";
  const tlsCertFingerprint =
    tls.enabled && tls.certPath && tls.mode !== "tailscale"
      ? readCertificateFingerprint(tls.certPath)
      : undefined;
  const name = opts.requestedName?.trim() || shortHostLabel(inviteHost);
  return signInvite(storage, {
    host: inviteHost,
    port: config.port,
    scheme,
    name,
    tlsCertFingerprint,
    pairingTokenTtlMs: opts.pairingTokenTtlMs,
  });
}

function signInvite(
  storage: InviteStorage,
  invite: {
    host: string;
    port: number;
    scheme: "http" | "https";
    name: string;
    tlsCertFingerprint?: string;
    pairingTokenTtlMs?: number;
  },
): GeneratedInvite {
  const pairingToken = storage.issuePairingToken(invite.pairingTokenTtlMs ?? 90_000);
  // Read back the stored deadline so output matches what pairing enforces.
  const expiresAtMs = storage.getConfig().pairingTokenExpiresAt;
  if (expiresAtMs === undefined) {
    throw new Error("Pairing token was issued without an expiry");
  }
  const identity = ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));
  const inviteData: InviteData = {
    host: invite.host,
    port: invite.port,
    scheme: invite.scheme,
    token: "",
    pairingToken,
    name: invite.name,
    tlsCertFingerprint: invite.tlsCertFingerprint,
  };
  const signedPayload: InvitePayloadV3 = {
    v: 3,
    ...inviteData,
    fingerprint: identity.fingerprint,
  };
  const signedPayloadJson = JSON.stringify(signedPayload);
  const signature = sign(
    null,
    Buffer.from(signedPayloadJson, "utf8"),
    identity.privateKeyPem,
  ).toString("base64url");
  const envelope: SignedInviteEnvelopeV3 = {
    v: 3,
    signedPayload: Buffer.from(signedPayloadJson, "utf8").toString("base64url"),
    publicKey: identity.publicKeyRaw,
    signature,
  };
  const inviteURL = `oppi://connect?${new URLSearchParams({
    v: "3",
    invite: Buffer.from(JSON.stringify(envelope), "utf8").toString("base64url"),
  }).toString()}`;

  return {
    name: invite.name,
    pairingToken,
    fingerprint: identity.fingerprint,
    tlsCertFingerprint: invite.tlsCertFingerprint,
    host: invite.host,
    port: invite.port,
    scheme: invite.scheme,
    inviteURL,
    expiresAt: new Date(expiresAtMs).toISOString(),
  };
}
