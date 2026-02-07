#!/usr/bin/env node
/**
 * pi-remote CLI
 * 
 * Commands:
 *   serve           Start the server
 *   setup           Initial setup
 *   invite <name>   Create user and show QR code
 *   users           List users
 *   users remove    Remove a user
 *   status          Show server status
 */

import chalk from "chalk";
import qrcode from "qrcode-terminal";
import QRCode from "qrcode";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { join } from "node:path";
import { Storage } from "./storage.js";
import { Server } from "./server.js";
import type { APNsConfig } from "./push.js";
import type { InviteData } from "./types.js";

function loadAPNsConfig(storage: Storage): APNsConfig | undefined {
  const dataDir = storage.getDataDir();
  const apnsConfigPath = join(dataDir, "apns.json");

  if (!existsSync(apnsConfigPath)) return undefined;

  try {
    const raw = JSON.parse(readFileSync(apnsConfigPath, "utf-8"));
    if (!raw.keyPath || !raw.keyId || !raw.teamId || !raw.bundleId) {
      console.log(chalk.yellow("  ⚠️  apns.json incomplete — need keyPath, keyId, teamId, bundleId"));
      return undefined;
    }
    return raw as APNsConfig;
  } catch (err: any) {
    console.log(chalk.yellow(`  ⚠️  apns.json parse error: ${err.message}`));
    return undefined;
  }
}

function printHeader(): void {
  console.log("");
  console.log(chalk.bold.magenta("  ╭─────────────────────────────────────╮"));
  console.log(chalk.bold.magenta("  │") + chalk.bold("          π  pi-remote               ") + chalk.bold.magenta("│"));
  console.log(chalk.bold.magenta("  ╰─────────────────────────────────────╯"));
  console.log("");
}

function getTailscaleHostname(): string | null {
  try {
    const result = execSync("tailscale status --json", { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] });
    const status = JSON.parse(result);
    if (status.Self?.DNSName) {
      return status.Self.DNSName.replace(/\.$/, "");
    }
  } catch {}
  return null;
}

function getTailscaleIp(): string | null {
  try {
    return execSync("tailscale ip -4", { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] }).trim().split("\n")[0];
  } catch {}
  return null;
}

// ─── Commands ───

async function cmdServe(storage: Storage): Promise<void> {
  printHeader();

  const config = storage.getConfig();
  const hostname = getTailscaleHostname();
  const ip = getTailscaleIp();

  if (!hostname && !ip) {
    console.log(chalk.yellow("  ⚠️  Tailscale not connected"));
    console.log(chalk.dim("     Run 'tailscale up' first"));
    console.log("");
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
  if (hostname) {
    console.log(`  Tailscale: ${chalk.cyan(hostname)}:${config.port}`);
  }
  if (ip) {
    console.log(`  IP:        ${chalk.dim(ip)}:${config.port}`);
  }
  console.log(`  Data:      ${chalk.dim(storage.getDataDir())}`);
  console.log("");

  const users = storage.listUsers();
  if (users.length === 0) {
    console.log(chalk.yellow("  No users configured."));
    console.log(chalk.dim("  Run 'pi-remote invite <name>' to create an invite."));
  } else {
    console.log(`  Users: ${users.map(u => u.name).join(", ")}`);
  }

  console.log("");
  console.log(chalk.green("  Waiting for connections..."));
  console.log(chalk.dim("  Press Ctrl+C to stop"));
  console.log("");
}

async function cmdInvite(storage: Storage, name: string, saveFile?: string): Promise<void> {
  printHeader();

  if (!name) {
    console.log(chalk.red("  Error: Name required"));
    console.log(chalk.dim("  Usage: pi-remote invite <name>"));
    console.log("");
    process.exit(1);
  }

  const config = storage.getConfig();
  const hostname = getTailscaleHostname();
  
  if (!hostname) {
    console.log(chalk.red("  Error: Tailscale not connected"));
    console.log(chalk.dim("  Run 'tailscale up' first"));
    console.log("");
    process.exit(1);
  }

  // Reuse existing user or create new one
  const existing = storage.listUsers().find(u => u.name.toLowerCase() === name.toLowerCase());
  const user = existing ?? storage.createUser(name);
  if (existing) {
    console.log(chalk.dim(`  (showing QR for existing user "${name}")`));
  }

  // Build invite data
  const inviteData: InviteData = {
    host: hostname,
    port: config.port,
    token: user.token,
    name: hostname.split(".")[0], // Short name like "mac-studio"
  };

  // QR payload is JSON (matches iOS app's JSONDecoder expectation)
  const inviteJson = JSON.stringify(inviteData);
  const inviteUrl = `pi://connect?${new URLSearchParams({
    host: inviteData.host,
    port: inviteData.port.toString(),
    token: inviteData.token,
    name: inviteData.name,
  }).toString()}`;

  // Display
  console.log(`  📱 Invite for ${chalk.bold(name)}`);
  console.log("");
  console.log("  Scan this QR code with the Pi app:");
  console.log("");

  qrcode.generate(inviteJson, { small: true }, (qr) => {
    // Indent QR code
    console.log(qr.split("\n").map(line => "     " + line).join("\n"));
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

  console.log(chalk.dim("  Token (for manual setup):"));
  console.log(`  ${chalk.dim(user.token)}`);
  console.log("");
}

function cmdUsers(storage: Storage, action?: string, target?: string): void {
  printHeader();

  const users = storage.listUsers();

  if (action === "remove" && target) {
    const user = users.find(u => u.name.toLowerCase() === target.toLowerCase() || u.id === target);
    if (!user) {
      console.log(chalk.red(`  User not found: ${target}`));
      process.exit(1);
    }

    storage.removeUser(user.id);
    console.log(chalk.green(`  ✓ Removed user: ${user.name}`));
    console.log("");
    return;
  }

  if (action === "regenerate" && target) {
    const user = users.find(u => u.name.toLowerCase() === target.toLowerCase() || u.id === target);
    if (!user) {
      console.log(chalk.red(`  User not found: ${target}`));
      process.exit(1);
    }

    const updated = storage.regenerateToken(user.id);
    if (updated) {
      console.log(chalk.green(`  ✓ New token for ${user.name}:`));
      console.log(`    ${updated.token}`);
      console.log("");
      console.log(chalk.dim("  Run 'pi-remote invite <name>' to show new QR code"));
    }
    console.log("");
    return;
  }

  if (users.length === 0) {
    console.log(chalk.dim("  No users configured."));
    console.log(chalk.dim("  Run 'pi-remote invite <name>' to create one."));
    console.log("");
    return;
  }

  console.log(`  ${chalk.bold("Users")} (${users.length}):`);
  console.log("");

  for (const user of users) {
    const lastSeen = user.lastSeen 
      ? new Date(user.lastSeen).toLocaleString()
      : "never";
    const sessions = storage.listUserSessions(user.id);
    console.log(`  ${chalk.cyan("•")} ${chalk.bold(user.name)}`);
    console.log(`    ID:       ${chalk.dim(user.id)}`);
    console.log(`    Sessions: ${sessions.length}`);
    console.log(`    Last seen: ${chalk.dim(lastSeen)}`);
    console.log("");
  }
}

function cmdStatus(storage: Storage): void {
  printHeader();

  const config = storage.getConfig();
  const hostname = getTailscaleHostname();
  const ip = getTailscaleIp();

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

  const users = storage.listUsers();
  console.log("  " + chalk.bold("Users"));
  console.log("");
  if (users.length === 0) {
    console.log(chalk.dim("  None configured"));
  } else {
    for (const user of users) {
      const sessions = storage.listUserSessions(user.id);
      console.log(`  ${chalk.cyan("•")} ${user.name}: ${sessions.length} sessions`);
    }
  }
  console.log("");
}

function cmdHelp(): void {
  printHeader();

  console.log("  " + chalk.bold("Commands:"));
  console.log("");
  console.log(`    ${chalk.cyan("serve")}              Start the server`);
  console.log(`    ${chalk.cyan("invite")} <name>      Create invite QR for a user`);
  console.log(`    ${chalk.cyan("users")}              List all users`);
  console.log(`    ${chalk.cyan("users remove")} <n>   Remove a user`);
  console.log(`    ${chalk.cyan("users regenerate")} <n>  New token for user`);
  console.log(`    ${chalk.cyan("status")}             Show server status`);
  console.log(`    ${chalk.cyan("help")}               Show this help`);
  console.log("");
  console.log("  " + chalk.bold("Options:"));
  console.log("");
  console.log(`    ${chalk.dim("--save <file>")}      Save invite QR as PNG`);
  console.log(`    ${chalk.dim("--port <n>")}         Override port (default: 7749)`);
  console.log("");
  console.log("  " + chalk.bold("Examples:"));
  console.log("");
  console.log(`    ${chalk.dim("pi-remote serve")}`);
  console.log(`    ${chalk.dim('pi-remote invite "Wife" --save wife-invite.png')}`);
  console.log(`    ${chalk.dim("pi-remote users remove Wife")}`);
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

    case "invite":
      await cmdInvite(storage, positional[0], flags.save);
      break;

    case "users":
      cmdUsers(storage, positional[0], positional[1]);
      break;

    case "status":
      cmdStatus(storage);
      break;

    case "help":
    case "--help":
    case "-h":
      cmdHelp();
      break;

    default:
      console.log(chalk.red(`Unknown command: ${command}`));
      console.log(chalk.dim("Run 'pi-remote help' for usage."));
      process.exit(1);
  }
}

main().catch((err) => {
  console.error(chalk.red("Fatal error:"), err);
  process.exit(1);
});
