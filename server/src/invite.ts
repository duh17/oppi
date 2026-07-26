/**
 * Invite generation — reusable by CLI (QR rendering, --json) and future Mac app.
 */

import { sign } from "node:crypto";
import type {
  AuthTransport,
  InviteData,
  InvitePayloadV3,
  InvitePayloadV4,
  InviteTransports,
  InviteTransportPreference,
  ServerConfig,
  SignedInviteEnvelopeV3,
  SignedInviteEnvelopeV4,
} from "./types.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import {
  isTailscaleHostname,
  prepareTlsForServer,
  readCertificateFingerprint,
  readValidTailnetDnsName,
  resolveTlsConfig,
} from "./tls.js";

interface GeneratedInviteBase {
  name: string;
  pairingToken: string;
  fingerprint: string;
  tlsCertFingerprint?: string;
  preference?: InviteTransportPreference;
  transports?: InviteTransports;
  inviteURL: string;
}

export interface GeneratedInviteWithHttp extends GeneratedInviteBase {
  host: string;
  port: number;
  scheme: "http" | "https";
}

export type GeneratedInvite =
  | GeneratedInviteWithHttp
  | (GeneratedInviteBase & {
      preference: InviteTransportPreference;
      transports: InviteTransports;
      host?: undefined;
      port?: undefined;
      scheme?: undefined;
    });

interface GenerateInviteOptionsBase {
  hostOverride?: string;
  requestedName?: string;
  /** Pairing token TTL in ms. Defaults to 90 000 (90 seconds). */
  pairingTokenTtlMs?: number;
}

export interface InviteStorage {
  getConfig(): ServerConfig;
  getDataDir(): string;
  ensurePaired(): string;
  issuePairingToken(ttlMs?: number, options?: { allowedTransports?: AuthTransport[] }): string;
}

export interface GenerateInviteV3Options extends GenerateInviteOptionsBase {
  inviteVersion?: 3;
}

export interface GenerateInviteV4Options extends GenerateInviteOptionsBase {
  inviteVersion: 4;
  preference: InviteTransportPreference;
  transports: InviteTransports;
}

export type GenerateInviteOptions = GenerateInviteV3Options | GenerateInviteV4Options;

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
  opts?: GenerateInviteV3Options,
): GeneratedInviteWithHttp;
export function generateInvite(
  storage: InviteStorage,
  resolveInviteHost: (hostOverride?: string) => string | null,
  shortHostLabel: (host: string) => string,
  opts: GenerateInviteV4Options,
): GeneratedInvite;
export function generateInvite(
  storage: InviteStorage,
  resolveInviteHost: (hostOverride?: string) => string | null,
  shortHostLabel: (host: string) => string,
  opts: GenerateInviteOptions = {},
): GeneratedInvite {
  const config = storage.getConfig();
  storage.ensurePaired();

  const v4Options = opts.inviteVersion === 4 ? opts : undefined;
  const needsHttpTransport = !v4Options || v4Options.preference !== "irohOnly";

  let inviteHost: string | undefined;
  let inviteScheme: "http" | "https" | undefined;
  let tlsCertFingerprint: string | undefined;

  if (needsHttpTransport) {
    inviteHost = resolveInviteHost(opts.hostOverride) ?? undefined;
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

    const tls = prepareTlsForServer(config, storage.getDataDir(), {
      additionalHosts: [inviteHost, config.host],
      ensureSelfSigned: true,
    });

    inviteScheme = tls.enabled ? "https" : "http";
    // Tailscale certs are public-CA certificates and rotate; do not make
    // already-paired clients depend on a single leaf certificate.
    if (tls.enabled && tls.certPath && tls.mode !== "tailscale") {
      tlsCertFingerprint = readCertificateFingerprint(tls.certPath);
    }
  }

  // Issue pairing token
  const pairingToken = v4Options
    ? storage.issuePairingToken(opts.pairingTokenTtlMs ?? 90_000, {
        allowedTransports: allowedTransportsForPreference(v4Options.preference),
      })
    : storage.issuePairingToken(opts.pairingTokenTtlMs ?? 90_000);

  // Build identity
  const identity = ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));
  const inviteName =
    opts.requestedName?.trim() || (inviteHost ? shortHostLabel(inviteHost) : "Oppi Server");

  if (v4Options) {
    const transports = buildV4Transports(v4Options.preference, v4Options.transports, {
      host: inviteHost,
      port: config.port,
      scheme: inviteScheme,
      tlsCertFingerprint,
    });

    const signedPayload: InvitePayloadV4 = {
      v: 4,
      name: inviteName,
      pairingToken,
      fingerprint: identity.fingerprint,
      preference: v4Options.preference,
      transports,
    };
    const signedPayloadJson = JSON.stringify(signedPayload);
    const signedPayloadEncoded = Buffer.from(signedPayloadJson, "utf-8").toString("base64url");
    const signature = sign(
      null,
      Buffer.from(signedPayloadEncoded, "utf-8"),
      identity.privateKeyPem,
    ).toString("base64url");
    const invitePayload: SignedInviteEnvelopeV4 = {
      v: 4,
      alg: "ed25519",
      signedPayload: signedPayloadEncoded,
      publicKey: identity.publicKeyRaw,
      signature,
    };

    const inviteJson = JSON.stringify(invitePayload);
    const inviteURL = `oppi://connect?${new URLSearchParams({
      v: "4",
      invite: Buffer.from(inviteJson, "utf-8").toString("base64url"),
    }).toString()}`;

    const resultBase: GeneratedInviteBase & {
      preference: InviteTransportPreference;
      transports: InviteTransports;
    } = {
      name: inviteName,
      pairingToken,
      fingerprint: identity.fingerprint,
      tlsCertFingerprint,
      preference: v4Options.preference,
      transports,
      inviteURL,
    };

    if (transports.http) {
      return {
        ...resultBase,
        host: transports.http.host,
        port: transports.http.port,
        scheme: transports.http.scheme,
      };
    }

    return resultBase;
  }

  if (!inviteHost || !inviteScheme) {
    throw new Error("HTTP invite generation requires a resolved host and scheme");
  }

  // Build v3 invite payload
  const inviteData: InviteData = {
    host: inviteHost,
    port: config.port,
    scheme: inviteScheme,
    token: "",
    pairingToken,
    name: inviteName,
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

function allowedTransportsForPreference(preference: InviteTransportPreference): AuthTransport[] {
  if (preference === "irohOnly") return ["iroh"];
  if (preference === "httpOnly") return ["http"];
  return ["iroh", "http"];
}

function buildV4Transports(
  preference: InviteTransportPreference,
  requestedTransports: InviteTransports,
  http: {
    host?: string;
    port: number;
    scheme?: "http" | "https";
    tlsCertFingerprint?: string;
  },
): InviteTransports {
  if ((preference === "irohOnly" || preference === "irohPreferred") && !requestedTransports.iroh) {
    throw new Error(`${preference} invites require transports.iroh`);
  }

  const transports: InviteTransports = {
    iroh: requestedTransports.iroh,
  };

  if (preference !== "irohOnly") {
    if (!http.host || !http.scheme) {
      throw new Error(`${preference} invites require an HTTP transport`);
    }
    transports.http = {
      host: http.host,
      port: http.port,
      scheme: http.scheme,
      tlsCertFingerprint: http.tlsCertFingerprint,
    };
  }

  if (preference === "httpOnly") {
    delete transports.iroh;
  }

  return transports;
}
