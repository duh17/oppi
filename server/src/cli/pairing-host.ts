/**
 * Pairing advertise host — not the HTTP bind address.
 *
 * `config.host` is the listener bind. Pairing QR/invite host comes from
 * `--host`, then `OPPI_PAIR_HOST`. Do not set bind=0.0.0.0 to advertise
 * MagicDNS; pass the MagicDNS name to pair/serve --host or OPPI_PAIR_HOST.
 */

import type { ServerConfig } from "../types.js";
import { getLocalHostname, getLocalIp, getTailscaleHostname, getTailscaleIp } from "./status.js";

export function resolvePairingAdvertiseHost(
  config: Pick<ServerConfig, "tls">,
  hostOverride?: string,
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  if (hostOverride?.trim()) return hostOverride.trim();

  const envHost = env.OPPI_PAIR_HOST?.trim();
  if (envHost) return envHost;

  if (config.tls?.mode === "tailscale") {
    return getTailscaleHostname();
  }

  return getLocalHostname() || getLocalIp() || getTailscaleHostname() || getTailscaleIp();
}
