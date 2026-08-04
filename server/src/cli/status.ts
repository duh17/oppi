import { execSync } from "node:child_process";
import { hostname as osHostname, networkInterfaces } from "node:os";

import * as c from "../ansi.js";
import { tlsSchemeForConfig } from "../tls.js";
import type { CliConnectionConfig } from "./connection-config.js";
import { captureHumanCliOutput, writeHumanLine, writeJsonEnvelope } from "./output.js";

export function getTailscaleHostname(): string | null {
  try {
    const result = execSync("tailscale status --json", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    const status = JSON.parse(result) as { Self?: { DNSName?: unknown } };
    if (typeof status.Self?.DNSName === "string" && status.Self.DNSName) {
      return status.Self.DNSName.replace(/\.$/, "");
    }
  } catch {}
  return null;
}

export function getTailscaleIp(): string | null {
  try {
    return (
      execSync("tailscale ip -4", { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] })
        .trim()
        .split("\n")[0] ?? null
    );
  } catch {}
  return null;
}

export function getLocalHostname(): string | null {
  try {
    const localHostName = execSync("scutil --get LocalHostName", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (localHostName) return `${localHostName}.local`;
  } catch {}

  try {
    const host = osHostname().trim();
    if (!host) return null;
    if (host.endsWith(".local")) return host;
    return `${host.split(".")[0] ?? host}.local`;
  } catch {}

  return null;
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
      dataDir: storage.getDataDir(),
      server: {
        host: config.host,
        port: config.port,
        transport: tlsSchemeForConfig(config),
        tlsMode: config.tls?.mode ?? "disabled",
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
    dataDir: string;
    server: { host: string; port: number; transport: string; tlsMode: string };
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
