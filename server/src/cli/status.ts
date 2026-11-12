import { execFile, execFileSync, execSync } from "node:child_process";
import { hostname as osHostname, networkInterfaces } from "node:os";
import { promisify } from "node:util";

import * as c from "../ansi.js";
import { listenerHostLabel } from "../network-listeners.js";
import { parsePublicUrl } from "../proxy-config.js";
import { tailscaleBinary, tlsSchemeForConfig } from "../tls.js";
import type { ServerConfig } from "../types.js";
import type { CliConnectionConfig } from "./connection-config.js";
import { hasPendingPairingInvite } from "./pairing-invite.js";
import { captureHumanCliOutput, writeHumanLine, writeJsonEnvelope } from "./output.js";

const execFileAsync = promisify(execFile);

function parseTailscaleHostname(statusJson: string): string | null {
  try {
    const status = JSON.parse(statusJson) as { Self?: { DNSName?: unknown } };
    if (typeof status.Self?.DNSName === "string" && status.Self.DNSName) {
      return status.Self.DNSName.replace(/\.$/, "");
    }
  } catch {}
  return null;
}

function parseTailscaleIp(output: string): string | null {
  return output.trim().split("\n")[0] ?? null;
}

/** `scutil` output when it names this Mac, else the OS hostname as a `.local` name. */
function localHostnameFrom(scutilOutput: string | null): string | null {
  const localHostName = scutilOutput?.trim();
  if (localHostName) return `${localHostName}.local`;

  try {
    const host = osHostname().trim();
    if (!host) return null;
    if (host.endsWith(".local")) return host;
    return `${host.split(".")[0] ?? host}.local`;
  } catch {}

  return null;
}

export function getTailscaleHostname(): string | null {
  try {
    return parseTailscaleHostname(
      execFileSync(tailscaleBinary(), ["status", "--json"], {
        encoding: "utf-8",
        stdio: ["pipe", "pipe", "pipe"],
      }),
    );
  } catch {}
  return null;
}

export function getTailscaleIp(): string | null {
  try {
    return parseTailscaleIp(
      execFileSync(tailscaleBinary(), ["ip", "-4"], {
        encoding: "utf-8",
        stdio: ["pipe", "pipe", "pipe"],
      }),
    );
  } catch {}
  return null;
}

export function getLocalHostname(): string | null {
  try {
    return localHostnameFrom(
      execSync("scutil --get LocalHostName", {
        encoding: "utf-8",
        stdio: ["pipe", "pipe", "pipe"],
      }),
    );
  } catch {}
  return localHostnameFrom(null);
}

/**
 * Network identity of this host, looked up without blocking the event loop so `oppi serve`
 * can answer `/health` while `tailscale` and `scutil` run. The three lookups run in parallel;
 * a failed lookup is null, same as the synchronous getters.
 */
export async function lookUpHostNames(): Promise<{
  tailscaleHostname: string | null;
  tailscaleIp: string | null;
  localHostname: string | null;
}> {
  const [tailscaleStatus, tailscaleIp, scutil] = await Promise.all([
    execFileAsync(tailscaleBinary(), ["status", "--json"]).then(
      (r) => r.stdout,
      () => null,
    ),
    execFileAsync(tailscaleBinary(), ["ip", "-4"]).then(
      (r) => r.stdout,
      () => null,
    ),
    execFileAsync("scutil", ["--get", "LocalHostName"]).then(
      (r) => r.stdout,
      () => null,
    ),
  ]);
  return {
    tailscaleHostname: tailscaleStatus === null ? null : parseTailscaleHostname(tailscaleStatus),
    tailscaleIp: tailscaleIp === null ? null : parseTailscaleIp(tailscaleIp),
    localHostname: localHostnameFrom(scutil),
  };
}

/** The `oppi serve` banner lines that say where phones and local clients reach the server. */
export async function printServeListeners(
  server: { scheme: string; port: number; remoteAvailable: boolean; listenerAddresses: string[] },
  config: ServerConfig,
): Promise<void> {
  // The `tailscale` and `scutil` lookups run after the listener is up (so /health answers
  // meanwhile) and the banner prints once they have resolved.
  const { tailscaleHostname, tailscaleIp, localHostname } = await lookUpHostNames();
  const localIp = getLocalIp();
  if (tailscaleHostname || tailscaleIp) {
    writeHumanLine(c.dim("  Tailscale detected — remote access available"));
  }

  writeHumanLine("");
  const { scheme, port } = server;
  const tailscaleLines = (): void => {
    if (tailscaleHostname) {
      writeHumanLine(`  Tailscale: ${c.dim(`${scheme}://${tailscaleHostname}:${port}`)}`);
    }
    if (tailscaleIp) writeHumanLine(`  Tail IP:   ${c.dim(`${scheme}://${tailscaleIp}:${port}`)}`);
  };
  const publicOrigin = config.publicUrl ? parsePublicUrl(config.publicUrl) : undefined;
  if (publicOrigin?.ok) {
    writeHumanLine(`  Public:    ${c.cyan(publicOrigin.value.href)}`);
    writeHumanLine(
      c.dim(
        `  Listener:  ${scheme}://${listenerHostLabel(config)}:${port} (tls.mode=${config.tls?.mode ?? "disabled"})`,
      ),
    );
    const peers = config.proxy?.trustedPeers ?? [];
    if (peers.length > 0) {
      writeHumanLine(c.dim(`  Proxy:     trustedPeers ${peers.join(", ")}`));
    }
  } else if (server.remoteAvailable && config.host === undefined) {
    // Default listeners: loopback plus Tailscale. The local network is not served.
    writeHumanLine(`  Listening: ${c.dim(server.listenerAddresses.join(", "))}`);
    if (tailscaleIp && server.listenerAddresses.includes(tailscaleIp)) {
      tailscaleLines();
    } else {
      writeHumanLine(
        c.yellow("  No Tailscale address yet: phones connect once Tailscale is running."),
      );
      writeHumanLine(
        c.dim("  To serve your local network instead, run: oppi config set host 0.0.0.0"),
      );
    }
  } else if (server.remoteAvailable) {
    if (localHostname) {
      writeHumanLine(`  Local:     ${c.cyan(`${scheme}://${localHostname}:${port}`)}`);
    }
    if (localIp) writeHumanLine(`  LAN IP:    ${c.dim(`${scheme}://${localIp}:${port}`)}`);
    tailscaleLines();
  }
}

export function getLocalIp(): string | null {
  for (const iface of Object.values(networkInterfaces())) {
    if (!iface) continue;
    for (const address of iface) {
      if (address.family !== "IPv4" || address.internal || address.address.startsWith("169.254.")) {
        continue;
      }
      return address.address;
    }
  }
  return null;
}

export function cmdStatus(storage: CliConnectionConfig, jsonOutput = false): void {
  const config = storage.getConfig();
  const data = {
    status: {
      paired: storage.isPaired(),
      // An unexpired invite is outstanding; minting another would replace it.
      pairingInvitePending: hasPendingPairingInvite(config),
      dataDir: storage.getDataDir(),
      server: {
        host: config.host,
        port: config.port,
        transport: tlsSchemeForConfig(config),
        tlsMode: config.tls?.mode ?? "disabled",
        publicUrl: config.publicUrl,
        trustedPeers: config.proxy?.trustedPeers ?? [],
      },
    },
  };

  if (jsonOutput) {
    writeJsonEnvelope({ ok: true, data });
    captureHumanCliOutput(() => renderStatus(storage, data.status));
    return;
  }
  renderStatus(storage, data.status);
}

function renderStatus(
  storage: CliConnectionConfig,
  status: {
    paired: boolean;
    pairingInvitePending: boolean;
    dataDir: string;
    server: {
      host?: string;
      port: number;
      transport: string;
      tlsMode: string;
      publicUrl?: string;
      trustedPeers: string[];
    };
  },
): void {
  const hostname = getTailscaleHostname();
  const ip = getTailscaleIp();
  const localHostname = getLocalHostname();
  const localIp = getLocalIp();
  const { server } = status;

  writeHumanLine(`  ${c.bold("Server Configuration")}`);
  writeHumanLine("");
  writeHumanLine(`  Port:       ${server.port}`);
  writeHumanLine(`  Transport:  ${server.transport.toUpperCase()} (${server.tlsMode})`);
  if (server.publicUrl) {
    writeHumanLine(`  Public URL: ${server.publicUrl}`);
  }
  if (server.trustedPeers.length > 0) {
    writeHumanLine(`  Proxy:      ${server.trustedPeers.join(", ")}`);
  }
  writeHumanLine(`  Data:       ${c.dim(storage.getDataDir())}`);
  writeHumanLine("");

  writeHumanLine(`  ${c.bold("Local Network")}`);
  writeHumanLine("");
  if (localHostname || localIp) {
    writeHumanLine(`  Hostname:  ${localHostname || c.dim("unknown")}`);
    writeHumanLine(`  IP:        ${localIp || c.dim("unknown")}`);
  } else {
    writeHumanLine(`  Status:    ${c.yellow("No active LAN interface detected")}`);
  }
  writeHumanLine("");

  writeHumanLine(`  ${c.bold("Tailscale")}`);
  writeHumanLine("");
  if (hostname) {
    writeHumanLine(`  Hostname:  ${c.green(hostname)}`);
    writeHumanLine(`  IP:        ${ip || c.dim("unknown")}`);
  } else {
    writeHumanLine(`  Status:    ${c.dim("Not connected")}`);
  }
  writeHumanLine("");

  writeHumanLine(`  ${c.bold("Pairing")}`);
  writeHumanLine("");
  if (!status.paired) {
    writeHumanLine(c.dim("  Not paired"));
    writeHumanLine(c.dim("  Run 'oppi pair'"));
  } else {
    writeHumanLine(`  Status:   ${c.green("Paired")}`);
  }
  writeHumanLine("");
}
