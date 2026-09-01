/**
 * Pairing advertise host — not the HTTP bind address.
 *
 * `config.host` is the listener bind. Pairing QR/invite host comes from
 * `--host`, then `OPPI_PAIR_HOST`, then persisted `pairHost`. Do not set
 * bind=0.0.0.0 to advertise MagicDNS; pass the MagicDNS name to pair/serve
 * `--host` or `OPPI_PAIR_HOST`.
 */

import { isIP } from "node:net";

import type { ServerConfig } from "../types.js";
import { isTailscaleHostname, resolveTlsConfig, validateTailscaleMaterial } from "../tls.js";
import { getLocalHostname, getLocalIp, getTailscaleHostname, getTailscaleIp } from "./status.js";

const PAIRING_HOST_GRAMMAR_ERROR =
  "Pairing --host must be a hostname or IP only (no scheme, no port). " +
  "The invite port comes from config.port. Example: --host my-mac.local";

/**
 * Apple builds `https://<host>:<config.port>`, so a scheme or :port in the
 * advertised host makes the invite unusable and must not be persisted.
 */
export function assertPairingAdvertiseHostGrammar(host?: string): void {
  const trimmed = host?.trim();
  if (!trimmed) return;
  if (isPairingAdvertiseHost(trimmed)) return;
  throw new Error(PAIRING_HOST_GRAMMAR_ERROR);
}

export function isPairingAdvertiseHost(host: string): boolean {
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(host)) return false;
  if (/[/\\?#@\s]/.test(host)) return false;

  if (host.startsWith("[")) {
    if (!host.endsWith("]")) return false;
    return isIP(host.slice(1, -1)) === 6;
  }
  if (isIP(host)) return true;
  if (host.includes(":")) return false;
  return isDnsHostname(host);
}

/**
 * Apple builds `https://<host>:<port>`, so a bare IPv6 literal becomes
 * `https://2001:db8::1:7749`. Persist and advertise the bracketed form.
 */
export function normalizePairingAdvertiseHost(host: string): string {
  const trimmed = host.trim();
  if (trimmed.startsWith("[") && trimmed.endsWith("]")) return trimmed;
  if (isIP(trimmed) === 6) return `[${trimmed}]`;
  return trimmed;
}

function isDnsHostname(host: string): boolean {
  if (host.length === 0 || host.length > 253) return false;
  if (host.startsWith(".") || host.endsWith(".") || host.includes("..")) return false;
  return host.split(".").every((label) => {
    if (label.length === 0 || label.length > 63) return false;
    return /^(?!-)[A-Za-z0-9-]{1,63}(?<!-)$/.test(label);
  });
}

export function rememberPairingAdvertiseHost(
  storage: { updateConfig: (updates: Partial<ServerConfig>) => void },
  host?: string,
): void {
  const trimmed = host?.trim();
  if (!trimmed) return;
  assertPairingAdvertiseHostGrammar(trimmed);
  storage.updateConfig({ pairHost: normalizePairingAdvertiseHost(trimmed) });
}

/** Suffix-only check so serve can start and renew certs before SAN validation. */
export function assertPairingAdvertiseHostSuffix(
  config: Pick<ServerConfig, "tls">,
  host?: string,
): void {
  const trimmed = host?.trim();
  if (!trimmed) return;
  assertPairingAdvertiseHostGrammar(trimmed);
  if (config.tls?.mode === "tailscale" && !isTailscaleHostname(trimmed)) {
    throw new Error(
      "Tailscale TLS mode requires a *.ts.net pairing host. " +
        "Use --host <machine>.<tailnet>.ts.net or disable tls.mode=tailscale",
    );
  }
}

/** Missing/expired Tailscale material can be renewed; a SAN mismatch cannot. */
export function isRetryablePairingHostMaterialError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return (
    /certificate not found/i.test(message) ||
    /certificate is expired/i.test(message) ||
    /not yet valid/i.test(message) ||
    /unavailable/i.test(message) ||
    /no usable existing certificate/i.test(message)
  );
}

/**
 * Persist an explicit serve --host after the same Tailscale suffix + cert SAN
 * checks generateInvite uses. Call this only when the remote HTTP listener is
 * up (after start() or listener recovery). Missing Tailscale material is
 * retryable; a SAN mismatch on a live listener is not.
 */
export function rememberValidatedPairingAdvertiseHost(
  storage: {
    getConfig: () => Pick<ServerConfig, "tls">;
    getDataDir: () => string;
    updateConfig: (updates: Partial<ServerConfig>) => void;
  },
  host?: string,
): void {
  const trimmed = host?.trim();
  if (!trimmed) return;
  const config = storage.getConfig();
  assertPairingAdvertiseHostSuffix(config, trimmed);
  if (config.tls?.mode === "tailscale") {
    validateTailscaleMaterial(resolveTlsConfig(config, storage.getDataDir()), trimmed);
  }
  rememberPairingAdvertiseHost(storage, trimmed);
}

export function resolvePairingAdvertiseHost(
  config: Pick<ServerConfig, "tls" | "pairHost">,
  hostOverride?: string,
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  if (hostOverride?.trim()) return normalizePairingAdvertiseHost(hostOverride);

  const envHost = env.OPPI_PAIR_HOST?.trim();
  if (envHost) return normalizePairingAdvertiseHost(envHost);

  if (config.pairHost?.trim()) return normalizePairingAdvertiseHost(config.pairHost);

  if (config.tls?.mode === "tailscale") {
    const tailscale = getTailscaleHostname();
    return tailscale ? normalizePairingAdvertiseHost(tailscale) : tailscale;
  }

  const detected =
    getLocalHostname() || getLocalIp() || getTailscaleHostname() || getTailscaleIp();
  return detected ? normalizePairingAdvertiseHost(detected) : detected;
}
