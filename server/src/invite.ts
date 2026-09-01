/** Invite generation — reusable by CLI (QR rendering, --json) and future Mac app. */

import { sign } from "node:crypto";
import type { InviteData, InvitePayloadV3, ServerConfig, SignedInviteEnvelopeV3 } from "./types.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import {
  assertPairingAdvertiseHostGrammar,
  normalizePairingAdvertiseHost,
} from "./cli/pairing-host.js";
import {
  isTailscaleHostname,
  prepareTlsForServer,
  readCertificateFingerprint,
  readValidTailnetDnsName,
  resolveTlsConfig,
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

  inviteHost = normalizePairingAdvertiseHost(inviteHost);
  assertPairingAdvertiseHostGrammar(inviteHost);

  if (config.tls?.mode === "tailscale" && !isTailscaleHostname(inviteHost)) {
    throw new Error(
      "Tailscale TLS mode requires a *.ts.net pairing host. " +
        "Use --host <machine>.<tailnet>.ts.net or disable tls.mode=tailscale",
    );
  }

  const tls = prepareTlsForServer(config, storage.getDataDir(), {
    additionalHosts: [inviteHost, config.host],
    ensureSelfSigned: true,
  });
  const scheme = tls.enabled ? "https" : "http";
  const tlsCertFingerprint =
    tls.enabled && tls.certPath && tls.mode !== "tailscale"
      ? readCertificateFingerprint(tls.certPath)
      : undefined;
  const pairingToken = storage.issuePairingToken(opts.pairingTokenTtlMs ?? 90_000);
  const identity = ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));
  const name = opts.requestedName?.trim() || shortHostLabel(inviteHost);
  const inviteData: InviteData = {
    host: inviteHost,
    port: config.port,
    scheme,
    token: "",
    pairingToken,
    name,
    tlsCertFingerprint,
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
    name,
    pairingToken,
    fingerprint: identity.fingerprint,
    tlsCertFingerprint,
    host: inviteHost,
    port: config.port,
    scheme,
    inviteURL,
  };
}
