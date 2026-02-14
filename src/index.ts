#!/usr/bin/env node
/**
 * oppi-server CLI
 *
 * Commands:
 *   serve           Start the server
 *   pair [name]     Pair iOS client with server owner token
 *   status          Show server status
 *   token           Rotate owner bearer token
 *   config          Show/validate server config
 */

import chalk from "chalk";
import qrcode from "qrcode-terminal";
import QRCode from "qrcode";
import { readFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { join } from "node:path";
import { hostname as osHostname, networkInterfaces } from "node:os";
import { Storage } from "./storage.js";
import { Server } from "./server.js";
import {
  createSignedInviteV2,
  ensureIdentityMaterial,
  type InviteV2Envelope,
  type InviteV2Payload,
} from "./security.js";
import type { APNsConfig } from "./push.js";
import type { InviteData } from "./types.js";

function loadAPNsConfig(storage: Storage): APNsConfig | undefined {
  const dataDir = storage.getDataDir();
  const apnsConfigPath = join(dataDir, "apns.json");

  if (!existsSync(apnsConfigPath)) return undefined;

  try {
    const raw = JSON.parse(readFileSync(apnsConfigPath, "utf-8"));
    if (!raw.keyPath || !raw.keyId || !raw.teamId || !raw.bundleId) {
      console.log(
        chalk.yellow("  ⚠️  apns.json incomplete — need keyPath, keyId, teamId, bundleId"),
      );
      return undefined;
    }
    return raw as APNsConfig;
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.log(chalk.yellow(`  ⚠️  apns.json parse error: ${message}`));
    return undefined;
  }
}

function printHeader(): void {
  console.log("");
  console.log(chalk.bold.magenta("  ╭─────────────────────────────────────╮"));
  console.log(
    chalk.bold.magenta("  │") +
      chalk.bold("          π  oppi-server               ") +
      chalk.bold.magenta("│"),
  );
  console.log(chalk.bold.magenta("  ╰─────────────────────────────────────╯"));
  console.log("");
}

function getTailscaleHostname(): string | null {
  try {
    const result = execSync("tailscale status --json", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    const status = JSON.parse(result);
    if (status.Self?.DNSName) {
      return status.Self.DNSName.replace(/\.$/, "");
    }
  } catch {}
  return null;
}

function getTailscaleIp(): string | null {
  try {
    return execSync("tailscale ip -4", { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] })
      .trim()
      .split("\n")[0];
  } catch {}
  return null;
}

function getLocalHostname(): string | null {
  try {
    const localHostName = execSync("scutil --get LocalHostName", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (localHostName) {
      return `${localHostName}.local`;
    }
  } catch {}

  try {
    const host = osHostname().trim();
    if (!host) return null;
    if (host.endsWith(".local")) return host;
    return `${host.split(".")[0]}.local`;
  } catch {}

  return null;
}

function getLocalIp(): string | null {
  const nets = networkInterfaces();

  for (const iface of Object.values(nets)) {
    if (!iface) continue;

    for (const addr of iface) {
      if (addr.family !== "IPv4") continue;
      if (addr.internal) continue;
      if (addr.address.startsWith("169.254.")) continue; // Link-local fallback
      return addr.address;
    }
  }

  return null;
}

function resolveInviteHost(hostOverride?: string): string | null {
  if (hostOverride?.trim()) return hostOverride.trim();
  return getTailscaleHostname() || getTailscaleIp() || getLocalHostname() || getLocalIp();
}

function shortHostLabel(host: string): string {
  // Keep IPs as-is, trim FQDNs to first label.
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return host;
  return host.split(".")[0] || host;
}

// ─── Commands ───

async function cmdServe(storage: Storage): Promise<void> {
  printHeader();

  const config = storage.getConfig();
  const tailscaleHostname = getTailscaleHostname();
  const tailscaleIp = getTailscaleIp();
  const localHostname = getLocalHostname();
  const localIp = getLocalIp();

  if (!tailscaleHostname && !tailscaleIp) {
    console.log(chalk.yellow("  ⚠️  Tailscale not connected (local network still works)"));
    console.log(chalk.dim("     Run 'tailscale up' if you want remote/tailnet access"));
    console.log("");
  }

  if (storage.hasInvalidOwnerData()) {
    console.log(chalk.red("  Error: users.json has invalid owner data."));
    console.log(chalk.dim("  Keep exactly one owner object in users.json before starting."));
    console.log(chalk.dim(`  Data file: ${join(storage.getDataDir(), "users.json")}`));
    console.log("");
    process.exit(1);
  }

  // Load APNs config from config file if present
  const apnsConfig = loadAPNsConfig(storage);
  const server = new Server(storage, apnsConfig);
  let shuttingDown = false;

  async function shutdown(code: number, reason?: string): Promise<void> {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;

    if (reason) {
      console.log(`\n${reason}`);
    }

    await server.stop().catch((err: unknown) => {
      console.error(chalk.red("Shutdown error:"), err);
    });

    process.exit(code);
  }

  process.on("SIGINT", () => {
    void shutdown(0, "\nShutting down...");
  });

  process.on("SIGTERM", () => {
    void shutdown(0);
  });

  process.on("uncaughtException", (err) => {
    console.error(chalk.red("Uncaught exception:"), err);
    void shutdown(1);
  });

  process.on("unhandledRejection", (reason) => {
    console.error(chalk.red("Unhandled rejection:"), reason);
    void shutdown(1);
  });

  await server.start();

  console.log("");
  if (tailscaleHostname) {
    console.log(`  Tailscale: ${chalk.cyan(tailscaleHostname)}:${config.port}`);
  }
  if (tailscaleIp) {
    console.log(`  Tail IP:   ${chalk.dim(tailscaleIp)}:${config.port}`);
  }
  if (localHostname) {
    console.log(`  Local:     ${chalk.dim(localHostname)}:${config.port}`);
  }
  if (localIp) {
    console.log(`  LAN IP:    ${chalk.dim(localIp)}:${config.port}`);
  }
  console.log(`  Data:      ${chalk.dim(storage.getDataDir())}`);
  console.log("");

  const owner = storage.getOwnerUser();
  if (!owner) {
    console.log(chalk.yellow("  Server not paired yet."));
    console.log(chalk.dim("  Run 'oppi-server pair [name]' to generate pairing QR."));
  } else {
    console.log(`  Owner: ${owner.name}`);
  }

  console.log("");
  console.log(chalk.green("  Waiting for connections..."));
  console.log(chalk.dim("  Press Ctrl+C to stop"));
  console.log("");
}

async function cmdPair(
  storage: Storage,
  requestedName: string | undefined,
  saveFile?: string,
  hostOverride?: string,
  showToken = false,
): Promise<void> {
  printHeader();

  if (storage.hasInvalidOwnerData()) {
    console.log(chalk.red("  Error: users.json has invalid owner data."));
    console.log(chalk.dim("  Keep exactly one owner object in users.json, then run pair again."));
    console.log(chalk.dim(`  Data file: ${join(storage.getDataDir(), "users.json")}`));
    console.log("");
    process.exit(1);
  }

  const ownerName = requestedName?.trim() || "Owner";
  const config = storage.getConfig();
  const inviteHost = resolveInviteHost(hostOverride);

  if (!inviteHost) {
    console.log(chalk.red("  Error: Could not determine pairing host"));
    console.log(chalk.dim("  Pass --host <hostname-or-ip>, e.g. --host my-mac.local"));
    console.log("");
    process.exit(1);
  }

  if (hostOverride?.trim()) {
    console.log(chalk.dim(`  (using host override: ${inviteHost})`));
  } else if (!inviteHost.endsWith(".ts.net")) {
    console.log(chalk.dim(`  (using local-network host: ${inviteHost})`));
  }

  // Reuse existing owner identity or create one.
  const existingOwner = storage.getOwnerUser();
  const user = existingOwner ?? storage.createUser(ownerName);
  if (existingOwner) {
    console.log(chalk.dim(`  (owner already paired: ${existingOwner.name})`));
    if (
      requestedName?.trim() &&
      requestedName.trim().toLowerCase() !== existingOwner.name.toLowerCase()
    ) {
      console.log(
        chalk.dim(
          `  (ignoring requested name "${requestedName.trim()}"; keeping existing owner name)`,
        ),
      );
    }
  }

  // Build signed v2 pairing payload.
  const inviteData: InviteData = {
    host: inviteHost,
    port: config.port,
    token: user.token,
    name: shortHostLabel(inviteHost),
  };

  const identityConfig = config.identity;
  if (!identityConfig) {
    console.log(chalk.red("  Error: config.identity is missing; cannot issue pairing QR."));
    console.log(chalk.dim("  Run 'oppi-server config validate' to repair config."));
    console.log("");
    process.exit(1);
  }

  const identity = ensureIdentityMaterial(identityConfig);
  if (identityConfig.fingerprint !== identity.fingerprint) {
    storage.updateConfig({ identity: { ...identityConfig, fingerprint: identity.fingerprint } });
  }

  const payload: InviteV2Payload = {
    host: inviteData.host,
    port: inviteData.port,
    token: inviteData.token,
    name: inviteData.name,
    fingerprint: identity.fingerprint,
    securityProfile: config.security?.profile || "legacy",
  };

  const maxAgeSeconds = config.invite?.maxAgeSeconds || 600;
  const envelope: InviteV2Envelope = createSignedInviteV2(identity, payload, maxAgeSeconds);
  const inviteJson = JSON.stringify(envelope);
  const inviteUrl = `pi://connect?${new URLSearchParams({
    v: "2",
    invite: Buffer.from(inviteJson, "utf-8").toString("base64url"),
  }).toString()}`;

  console.log(chalk.dim(`  (pairing format: v2-signed, expires in ${maxAgeSeconds}s)`));

  // Display
  console.log(`  📱 Pair server owner ${chalk.bold(user.name)}`);
  console.log("");
  console.log("  Scan this QR code in Oppi:");
  console.log("");

  qrcode.generate(inviteJson, { small: true }, (qr) => {
    // Indent QR code
    console.log(
      qr
        .split("\n")
        .map((line) => "     " + line)
        .join("\n"),
    );
  });

  console.log("");
  console.log("  Or share this link:");
  console.log(`  ${chalk.cyan(inviteUrl)}`);
  console.log("");

  // Save QR as image if requested
  if (saveFile) {
    const outputPath = saveFile.endsWith(".png") ? saveFile : `${saveFile}.png`;
    await QRCode.toFile(outputPath, inviteJson, {
      width: 400,
      margin: 2,
    });
    console.log(`  Saved QR code to: ${chalk.dim(outputPath)}`);
    console.log("");
  }

  if (showToken) {
    console.log(chalk.yellow("  ⚠️  Manual token display enabled (--show-token)"));
    console.log(chalk.dim("  Owner token:"));
    console.log(`  ${chalk.dim(user.token)}`);
    console.log("");
  } else {
    console.log(chalk.dim("  Manual token output hidden by default."));
    console.log(chalk.dim("  Use --show-token only for emergency/manual setup."));
    console.log("");
  }
}

function cmdStatus(storage: Storage): void {
  printHeader();

  const config = storage.getConfig();
  const hostname = getTailscaleHostname();
  const ip = getTailscaleIp();
  const localHostname = getLocalHostname();
  const localIp = getLocalIp();

  console.log("  " + chalk.bold("Server Configuration"));
  console.log("");
  console.log(`  Port:       ${config.port}`);
  console.log(`  Data:       ${chalk.dim(storage.getDataDir())}`);
  console.log("");

  console.log("  " + chalk.bold("Tailscale"));
  console.log("");
  if (hostname) {
    console.log(`  Hostname:  ${chalk.green(hostname)}`);
    console.log(`  IP:        ${ip || chalk.dim("unknown")}`);
  } else {
    console.log(`  Status:    ${chalk.yellow("Not connected")}`);
  }
  console.log("");

  console.log("  " + chalk.bold("Local Network"));
  console.log("");
  if (localHostname || localIp) {
    console.log(`  Hostname:  ${localHostname || chalk.dim("unknown")}`);
    console.log(`  IP:        ${localIp || chalk.dim("unknown")}`);
  } else {
    console.log(`  Status:    ${chalk.yellow("No active LAN interface detected")}`);
  }
  console.log("");

  const owner = storage.getOwnerUser();
  console.log("  " + chalk.bold("Owner Pairing"));
  console.log("");

  if (storage.hasInvalidOwnerData()) {
    console.log(chalk.red("  Invalid state: users.json has invalid owner data"));
    console.log(chalk.dim(`  Data file: ${join(storage.getDataDir(), "users.json")}`));
  } else if (!owner) {
    console.log(chalk.dim("  Not paired"));
    console.log(chalk.dim("  Run 'oppi-server pair [name]'"));
  } else {
    const sessions = storage.listUserSessions(owner.id);
    console.log(`  Owner:    ${chalk.cyan(owner.name)}`);
    console.log(`  Sessions: ${sessions.length}`);
  }
  console.log("");
}

function cmdToken(storage: Storage, action: string | undefined): void {
  printHeader();

  if (storage.hasInvalidOwnerData()) {
    console.log(chalk.red("  Error: users.json has invalid owner data."));
    console.log(chalk.dim("  Keep exactly one owner object in users.json."));
    console.log(chalk.dim(`  Data file: ${join(storage.getDataDir(), "users.json")}`));
    console.log("");
    process.exit(1);
  }

  const mode = action || "help";

  if (mode === "rotate") {
    const owner = storage.getOwnerUser();
    if (!owner) {
      console.log(chalk.red("  Error: server is not paired yet."));
      console.log(chalk.dim("  Run 'oppi-server pair [name]' first."));
      console.log("");
      process.exit(1);
    }

    storage.rotateOwnerToken();

    console.log(chalk.green("  ✓ Owner bearer token rotated."));
    console.log("");
    console.log(chalk.yellow("  Existing clients will be unauthorized until re-paired."));
    console.log(chalk.dim("  Next step: run 'oppi-server pair' to issue a fresh invite."));
    console.log("");
    return;
  }

  console.log(chalk.red(`  Unknown token action: ${mode}`));
  console.log(chalk.dim("  Usage: oppi-server token rotate"));
  console.log("");
  process.exit(1);
}

function cmdConfig(storage: Storage, action: string | undefined, flags: Record<string, string>): void {
  printHeader();

  const mode = action || "show";

  if (mode === "show") {
    const showDefault = flags.default === "true";
    const config = showDefault
      ? Storage.getDefaultConfig(storage.getDataDir())
      : storage.getConfig();

    console.log(`  ${chalk.bold(showDefault ? "Default config" : "Current config")}`);
    console.log("");
    const pretty = JSON.stringify(config, null, 2)
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n");
    console.log(pretty);
    console.log("");
    return;
  }

  if (mode === "validate") {
    const target = flags["config-file"] || storage.getConfigPath();
    const result = Storage.validateConfigFile(target);

    if (!result.valid) {
      console.log(chalk.red(`  ✗ Config validation failed: ${target}`));
      console.log("");
      for (const err of result.errors) {
        console.log(chalk.red(`  - ${err}`));
      }
      console.log("");
      process.exit(1);
    }

    console.log(chalk.green(`  ✓ Config valid: ${target}`));
    if (result.warnings.length > 0) {
      console.log("");
      for (const warning of result.warnings) {
        console.log(chalk.yellow(`  ! ${warning}`));
      }
    }
    console.log("");
    return;
  }

  console.log(chalk.red(`  Unknown config action: ${mode}`));
  console.log(chalk.dim("  Usage: oppi-server config [show|validate] [--config-file <path>]"));
  console.log("");
  process.exit(1);
}

function cmdHelp(): void {
  printHeader();

  console.log("  " + chalk.bold("Commands:"));
  console.log("");
  console.log(`    ${chalk.cyan("serve")}              Start the server`);
  console.log(`    ${chalk.cyan("pair")} [name]        Generate pairing QR for server owner`);
  console.log(`    ${chalk.cyan("status")}             Show server status`);
  console.log(`    ${chalk.cyan("token rotate")}       Rotate owner bearer token`);
  console.log(`    ${chalk.cyan("config show")}        Show current server config`);
  console.log(`    ${chalk.cyan("config validate")}    Validate server config`);
  console.log(`    ${chalk.cyan("help")}               Show this help`);
  console.log("");
  console.log("  " + chalk.bold("Options:"));
  console.log("");
  console.log(`    ${chalk.dim("--save <file>")}      Save pairing QR as PNG`);
  console.log(`    ${chalk.dim("--host <host>")}      Hostname/IP encoded in pairing QR`);
  console.log(`    ${chalk.dim("--show-token")}       Print owner token in pair output (unsafe)`);
  console.log(`    ${chalk.dim("--port <n>")}         Override port (default: 7749)`);
  console.log(`    ${chalk.dim("--config-file <p>")}  Config path for 'config validate'`);
  console.log("");
  console.log("  " + chalk.bold("Examples:"));
  console.log("");
  console.log(`    ${chalk.dim("oppi-server serve")}`);
  console.log(`    ${chalk.dim('oppi-server pair "Sam" --save owner-pair.png')}`);
  console.log(`    ${chalk.dim('oppi-server pair "Sam" --host my-mac.local')}`);
  console.log(`    ${chalk.dim("oppi-server token rotate")}`);
  console.log(`    ${chalk.dim("oppi-server config show")}`);
  console.log(`    ${chalk.dim("oppi-server config validate")}`);
  console.log("");
}

// ─── Main ───

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const command = args[0] || "help";

  // Parse flags
  const flags: Record<string, string> = {};
  const positional: string[] = [];

  for (let i = 1; i < args.length; i++) {
    if (args[i].startsWith("--")) {
      const key = args[i].slice(2);
      const value = args[i + 1] && !args[i + 1].startsWith("--") ? args[++i] : "true";
      flags[key] = value;
    } else {
      positional.push(args[i]);
    }
  }

  const storage = new Storage();

  // Apply port override
  if (flags.port) {
    storage.updateConfig({ port: parseInt(flags.port) });
  }

  switch (command) {
    case "serve":
    case "start":
      await cmdServe(storage);
      break;

    case "pair":
      await cmdPair(storage, positional[0], flags.save, flags.host, flags["show-token"] === "true");
      break;

    case "status":
      cmdStatus(storage);
      break;

    case "token":
      cmdToken(storage, positional[0]);
      break;

    case "config":
      cmdConfig(storage, positional[0], flags);
      break;

    case "help":
    case "--help":
    case "-h":
      cmdHelp();
      break;

    default:
      console.log(chalk.red(`Unknown command: ${command}`));
      console.log(chalk.dim("Run 'oppi-server help' for usage."));
      process.exit(1);
  }
}

main().catch((err) => {
  console.error(chalk.red("Fatal error:"), err);
  process.exit(1);
});
