/**
 * Pairing advertise host — not the HTTP bind address.
 *
 * `config.host` is the listener bind. Pairing QR/invite host comes from
 * `--host`, then `OPPI_PAIR_HOST`, then persisted `pairHost`. Do not set
 * bind=0.0.0.0 to advertise MagicDNS; pass the MagicDNS name to pair/serve
 * `--host` or `OPPI_PAIR_HOST`.
 */

import type { ServerConfig } from "../types.js";
import { isTailscaleHostname, resolveTlsConfig, validateTailscaleMaterial } from "../tls.js";
import { getLocalHostname, getLocalIp, getTailscaleHostname, getTailscaleIp } from "./status.js";

export function rememberPairingAdvertiseHost(
  storage: { updateConfig: (updates: Partial<ServerConfig>) => void },
  host?: string,
): void {
  const trimmed = host?.trim();
  if (!trimmed) return;
  storage.updateConfig({ pairHost: trimmed });
}

/**
 * Persist an explicit serve --host after the same Tailscale suffix + cert SAN
 * checks generateInvite uses. Call this when no invite is generated (already paired).
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
  if (config.tls?.mode === "tailscale") {
    if (!isTailscaleHostname(trimmed)) {
      throw new Error(
        "Tailscale TLS mode requires a *.ts.net pairing host. " +
          "Use --host <machine>.<tailnet>.ts.net or disable tls.mode=tailscale",
      );
    }
    validateTailscaleMaterial(resolveTlsConfig(config, storage.getDataDir()), trimmed);
  }
  rememberPairingAdvertiseHost(storage, trimmed);
}

export function resolvePairingAdvertiseHost(
  config: Pick<ServerConfig, "tls" | "pairHost">,
  hostOverride?: string,
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  if (hostOverride?.trim()) return hostOverride.trim();

  const envHost = env.OPPI_PAIR_HOST?.trim();
  if (envHost) return envHost;

  if (config.pairHost?.trim()) return config.pairHost.trim();

  if (config.tls?.mode === "tailscale") {
    return getTailscaleHostname();
  }

  return getLocalHostname() || getLocalIp() || getTailscaleHostname() || getTailscaleIp();
}
