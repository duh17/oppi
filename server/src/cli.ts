#!/usr/bin/env node
/**
 * oppi CLI
 *
 * Commands:
 *   init            Interactive first-time setup
 *   serve           Start the server
 *   pair [name]     Pair iOS client with server owner token
 *   status          Show server status
 *   token           Rotate owner bearer token
 *   config          Show/get/set/validate server config
 */

import * as c from "./ansi.js";
import { renderTerminal as renderQR } from "./qr.js";
import { readFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { hostname as osHostname, networkInterfaces } from "node:os";
import { Storage } from "./storage.js";
import { Server } from "./server.js";
import { envInit, envShow } from "./host-env.js";
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
        c.yellow("  ⚠️  apns.json incomplete — need keyPath, keyId, teamId, bundleId"),
      );
      return undefined;
    }
    return raw as APNsConfig;
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.log(c.yellow(`  ⚠️  apns.json parse error: ${message}`));
    return undefined;
  }
}

function printHeader(): void {
  console.log("");
  console.log(c.boldMagenta("  ╭─────────────────────────────────────╮"));
  console.log(
    c.boldMagenta("  │") +
      c.bold("              π  oppi                   ") +
      c.boldMagenta("│"),
  );
  console.log(c.boldMagenta("  ╰─────────────────────────────────────╯"));
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
    console.log(c.yellow("  ⚠️  Tailscale not connected (local network still works)"));
    console.log(c.dim("     Run 'tailscale up' if you want remote/tailnet access"));
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
      console.error(c.red("Shutdown error:"), err);
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
    console.error(c.red("Uncaught exception:"), err);
    void shutdown(1);
  });

  process.on("unhandledRejection", (reason) => {
    console.error(c.red("Unhandled rejection:"), reason);
    void shutdown(1);
  });

  await server.start();

  console.log("");
  if (tailscaleHostname) {
    console.log(`  Tailscale: ${c.cyan(tailscaleHostname)}:${config.port}`);
  }
  if (tailscaleIp) {
    console.log(`  Tail IP:   ${c.dim(tailscaleIp)}:${config.port}`);
  }
  if (localHostname) {
    console.log(`  Local:     ${c.dim(localHostname)}:${config.port}`);
  }
  if (localIp) {
    console.log(`  LAN IP:    ${c.dim(localIp)}:${config.port}`);
  }
  console.log(`  Data:      ${c.dim(storage.getDataDir())}`);
  console.log("");

  if (!storage.isPaired()) {
    console.log(c.yellow("  Server not paired yet."));
    console.log(c.dim("  Run 'oppi pair' to generate pairing QR."));
  } else {
    console.log(c.green("  ✓ Paired"));
  }

  console.log("");
  console.log(c.green("  Waiting for connections..."));
  console.log(c.dim("  Press Ctrl+C to stop"));
  console.log("");
}

async function cmdPair(
  storage: Storage,
  requestedName: string | undefined,
  hostOverride?: string,
  showToken = false,
): Promise<void> {
  printHeader();

  const config = storage.getConfig();
  const token = storage.ensurePaired();
  const inviteHost = resolveInviteHost(hostOverride);

  if (!inviteHost) {
    console.log(c.red("  Error: Could not determine pairing host"));
    console.log(c.dim("  Pass --host <hostname-or-ip>, e.g. --host my-mac.local"));
    console.log("");
    process.exit(1);
  }

  if (hostOverride?.trim()) {
    console.log(c.dim(`  (using host override: ${inviteHost})`));
  } else if (!inviteHost.endsWith(".ts.net")) {
    console.log(c.dim(`  (using local-network host: ${inviteHost})`));
  }

  // Build signed v2 pairing payload.
  const inviteData: InviteData = {
    host: inviteHost,
    port: config.port,
    token,
    name: shortHostLabel(inviteHost),
  };

  const identityConfig = config.identity;
  if (!identityConfig) {
    console.log(c.red("  Error: config.identity is missing; cannot issue pairing QR."));
    console.log(c.dim("  Run 'oppi config validate' to repair config."));
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
    securityProfile: config.security?.profile || "tailscale-permissive",
  };

  const maxAgeSeconds = config.invite?.maxAgeSeconds || 600;
  const envelope: InviteV2Envelope = createSignedInviteV2(identity, payload, maxAgeSeconds);
  const inviteJson = JSON.stringify(envelope);
  const inviteUrl = `oppi://connect?${new URLSearchParams({
    v: "2",
    invite: Buffer.from(inviteJson, "utf-8").toString("base64url"),
  }).toString()}`;

  console.log(c.dim(`  (pairing format: v2-signed, expires in ${maxAgeSeconds}s)`));

  // Display
  console.log(`  📱 Pair with ${c.bold(shortHostLabel(inviteHost))}`);
  console.log("");
  console.log("  Scan this QR code in Oppi:");
  console.log("");

  const qr = renderQR(inviteJson);
  console.log(
    qr
      .split("\n")
      .map((line) => "     " + line)
      .join("\n"),
  );

  console.log("");
  console.log("  Or share this link:");
  console.log(`  ${c.cyan(inviteUrl)}`);
  console.log("");

  if (showToken) {
    console.log(c.yellow("  ⚠️  Manual token display enabled (--show-token)"));
    console.log(c.dim("  Owner token:"));
    console.log(`  ${c.dim(token)}`);
    console.log("");
  } else {
    console.log(c.dim("  Manual token output hidden by default."));
    console.log(c.dim("  Use --show-token only for emergency/manual setup."));
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

  console.log("  " + c.bold("Server Configuration"));
  console.log("");
  console.log(`  Port:       ${config.port}`);
  console.log(`  Data:       ${c.dim(storage.getDataDir())}`);
  console.log("");

  console.log("  " + c.bold("Tailscale"));
  console.log("");
  if (hostname) {
    console.log(`  Hostname:  ${c.green(hostname)}`);
    console.log(`  IP:        ${ip || c.dim("unknown")}`);
  } else {
    console.log(`  Status:    ${c.yellow("Not connected")}`);
  }
  console.log("");

  console.log("  " + c.bold("Local Network"));
  console.log("");
  if (localHostname || localIp) {
    console.log(`  Hostname:  ${localHostname || c.dim("unknown")}`);
    console.log(`  IP:        ${localIp || c.dim("unknown")}`);
  } else {
    console.log(`  Status:    ${c.yellow("No active LAN interface detected")}`);
  }
  console.log("");

  console.log("  " + c.bold("Pairing"));
  console.log("");

  if (!storage.isPaired()) {
    console.log(c.dim("  Not paired"));
    console.log(c.dim("  Run 'oppi pair'"));
  } else {
    const sessions = storage.listSessions();
    console.log(`  Status:   ${c.green("Paired")}`);
    console.log(`  Sessions: ${sessions.length}`);
  }
  console.log("");
}

function cmdToken(storage: Storage, action: string | undefined): void {
  printHeader();

  const mode = action || "help";

  if (mode === "rotate") {
    if (!storage.isPaired()) {
      console.log(c.red("  Error: server is not paired yet."));
      console.log(c.dim("  Run 'oppi pair' first."));
      console.log("");
      process.exit(1);
    }

    storage.rotateToken();

    console.log(c.green("  ✓ Bearer token rotated."));
    console.log("");
    console.log(c.yellow("  Existing clients will be unauthorized until re-paired."));
    console.log(c.dim("  Next step: run 'oppi pair' to issue a fresh invite."));
    console.log("");
    return;
  }

  console.log(c.red(`  Unknown token action: ${mode}`));
  console.log(c.dim("  Usage: oppi token rotate"));
  console.log("");
  process.exit(1);
}

// ─── Prompt Helper ───

function prompt(question: string, defaultValue?: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const suffix = defaultValue ? c.dim(` [${defaultValue}]`) : "";
  return new Promise((resolve) => {
    rl.question(`  ${question}${suffix}: `, (answer) => {
      rl.close();
      resolve(answer.trim() || defaultValue || "");
    });
  });
}

// ─── Init Command ───

async function cmdInit(flags: Record<string, string>): Promise<void> {
  printHeader();
  console.log(c.bold("  First-time setup"));
  console.log("");

  const { homedir } = await import("node:os");
  const dataDir = flags["data-dir"] || join(homedir(), ".config", "oppi");
  const alreadyExists = existsSync(join(dataDir, "config.json"));
  const nonInteractive = flags.yes === "true" || flags.y === "true" || !process.stdin.isTTY;

  if (alreadyExists && flags.force !== "true") {
    console.log(c.yellow(`  Config already exists at ${dataDir}/config.json`));
    console.log(c.dim("  Use --force to re-initialize (keeps existing data)."));
    console.log("");
    if (nonInteractive) {
      process.exit(1);
    }
    const answer = await prompt("Continue anyway? (y/N)", "n");
    if (answer.toLowerCase() !== "y") {
      console.log("");
      return;
    }
    console.log("");
  }

  let port: number;
  let defaultModel: string;
  let maxSessionsGlobal: number;

  if (nonInteractive) {
    // Non-interactive: use flags or defaults
    port = parseInt(flags.port || "7749") || 7749;
    defaultModel = flags.model || "anthropic/claude-sonnet-4-20250514";
    maxSessionsGlobal = parseInt(flags["max-sessions"] || "5") || 5;

    console.log(c.dim(`  Port:         ${port}`));
    console.log(c.dim(`  Model:        ${defaultModel}`));
    console.log(c.dim(`  Max sessions: ${maxSessionsGlobal}`));
    console.log("");
  } else {
    // Interactive prompts
    const portStr = await prompt("Port", "7749");
    port = parseInt(portStr) || 7749;

    console.log("");
    console.log(c.dim("  Popular models:"));
    console.log(c.dim("    anthropic/claude-sonnet-4-20250514"));
    console.log(c.dim("    anthropic/claude-opus-4-6"));
    console.log(c.dim("    anthropic/claude-haiku-3.5"));
    console.log("");
    defaultModel = await prompt("Default model", "anthropic/claude-sonnet-4-20250514");

    const maxSessionsStr = await prompt("Max concurrent sessions", "5");
    maxSessionsGlobal = parseInt(maxSessionsStr) || 5;
  }

  // Create storage (auto-creates dirs + default config)
  const storage = new Storage(dataDir);

  // Apply user choices
  storage.updateConfig({
    port,
    defaultModel,
    maxSessionsGlobal,
  });

  console.log("");
  console.log(c.green("  ✓ Config written to ") + c.dim(storage.getConfigPath()));

  // 4. Generate identity keys
  const config = storage.getConfig();
  if (config.identity) {
    ensureIdentityMaterial(config.identity);
    const identity = ensureIdentityMaterial(config.identity);
    if (config.identity.fingerprint !== identity.fingerprint) {
      storage.updateConfig({ identity: { ...config.identity, fingerprint: identity.fingerprint } });
    }
    console.log(c.green("  ✓ Identity keys generated"));
  }

  // 5. Capture env if interactive shell
  if (process.env.PATH && process.env.PATH.includes("/homebrew/")) {
    envInit();
    console.log(c.green("  ✓ Host environment captured"));
  } else {
    console.log(c.yellow("  ⚠ Run 'oppi env init' from your interactive shell to capture PATH"));
  }

  // 6. Summary
  console.log("");
  console.log(c.bold("  Next steps:"));
  console.log("");
  console.log(`    ${c.cyan("1.")} oppi serve              ${c.dim("Start the server")}`);
  console.log(`    ${c.cyan("2.")} oppi pair ${c.dim('"YourName"')}     ${c.dim("Generate pairing QR")}`);
  console.log(`    ${c.cyan("3.")} Scan QR in Oppi app     ${c.dim("Connect your phone")}`);
  console.log("");
}

// ─── Config Command ───

/** Settable config keys and their types for `oppi config set`. */
const SETTABLE_KEYS: Record<string, { type: "number" | "string" | "boolean"; desc: string }> = {
  port:                     { type: "number",  desc: "Server port" },
  host:                     { type: "string",  desc: "Bind address" },
  defaultModel:             { type: "string",  desc: "Default model for new sessions" },
  maxSessionsGlobal:        { type: "number",  desc: "Max concurrent sessions" },
  maxSessionsPerWorkspace:  { type: "number",  desc: "Max sessions per workspace" },
  sessionIdleTimeoutMs:     { type: "number",  desc: "Session idle timeout (ms)" },
  workspaceIdleTimeoutMs:   { type: "number",  desc: "Workspace idle timeout (ms)" },
  approvalTimeoutMs:        { type: "number",  desc: "Permission approval timeout (ms)" },
};

function coerceValue(raw: string, type: "number" | "string" | "boolean"): number | string | boolean {
  switch (type) {
    case "number": {
      const n = Number(raw);
      if (isNaN(n)) throw new Error(`"${raw}" is not a valid number`);
      return n;
    }
    case "boolean": {
      const lower = raw.toLowerCase();
      if (["true", "1", "yes", "on"].includes(lower)) return true;
      if (["false", "0", "no", "off"].includes(lower)) return false;
      throw new Error(`"${raw}" is not a valid boolean`);
    }
    case "string":
      return raw;
  }
}

function cmdConfig(
  storage: Storage,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
): void {
  const mode = action || "show";

  // `get` is machine-readable — no header
  if (mode === "get") {
    const key = positional[0];
    if (!key) {
      console.log(c.red("  Usage: oppi config get <key>"));
      console.log("");
      process.exit(1);
    }

    const config = storage.getConfig() as unknown as Record<string, unknown>;
    const value = config[key];
    if (value === undefined) {
      console.error(`Unknown key: ${key}`);
      process.exit(1);
    }

    if (typeof value === "object") {
      console.log(JSON.stringify(value, null, 2));
    } else {
      console.log(String(value));
    }
    return;
  }

  printHeader();

  if (mode === "show") {
    const showDefault = flags.default === "true";
    const config = showDefault
      ? Storage.getDefaultConfig(storage.getDataDir())
      : storage.getConfig();

    console.log(`  ${c.bold(showDefault ? "Default config" : "Current config")}`);
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
      console.log(c.red(`  ✗ Config validation failed: ${target}`));
      console.log("");
      for (const err of result.errors) {
        console.log(c.red(`  - ${err}`));
      }
      console.log("");
      process.exit(1);
    }

    console.log(c.green(`  ✓ Config valid: ${target}`));
    if (result.warnings.length > 0) {
      console.log("");
      for (const warning of result.warnings) {
        console.log(c.yellow(`  ! ${warning}`));
      }
    }
    console.log("");
    return;
  }

  if (mode === "set") {
    const key = positional[0];
    const value = positional[1];

    if (!key || value === undefined) {
      console.log(c.red("  Usage: oppi config set <key> <value>"));
      console.log("");
      console.log(c.bold("  Available keys:"));
      console.log("");
      for (const [k, meta] of Object.entries(SETTABLE_KEYS)) {
        const current = (storage.getConfig() as unknown as Record<string, unknown>)[k];
        console.log(`    ${c.cyan(k.padEnd(28))} ${c.dim(meta.desc)}`);
        console.log(`    ${"".padEnd(28)} ${c.dim("current:")} ${current}`);
      }
      console.log("");
      process.exit(1);
    }

    const meta = SETTABLE_KEYS[key];
    if (!meta) {
      console.log(c.red(`  Unknown config key: ${key}`));
      console.log(c.dim(`  Available: ${Object.keys(SETTABLE_KEYS).join(", ")}`));
      console.log("");
      process.exit(1);
    }

    try {
      const coerced = coerceValue(value, meta.type);
      storage.updateConfig({ [key]: coerced } as Partial<import("./types.js").ServerConfig>);
      console.log(c.green(`  ✓ ${key} = ${coerced}`));
      console.log(c.dim(`    Saved to ${storage.getConfigPath()}`));
      console.log("");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.log(c.red(`  ✗ ${message}`));
      console.log("");
      process.exit(1);
    }
    return;
  }

  console.log(c.red(`  Unknown config action: ${mode}`));
  console.log(c.dim("  Usage: oppi config [show|get|set|validate]"));
  console.log("");
  process.exit(1);
}

// ─── Env Command ───

function cmdEnv(action: string | undefined): void {
  switch (action) {
    case "init":
      envInit();
      break;
    case "show":
      envShow();
      break;
    default:
      console.log(c.bold("  oppi env") + " — manage host environment for sessions");
      console.log("");
      console.log(`    ${c.cyan("env init")}    Capture current $PATH into ~/.config/oppi/env`);
      console.log(`    ${c.cyan("env show")}    Show resolved host PATH`);
      console.log("");
      console.log(c.dim("  Run 'env init' from your interactive shell (fish, zsh, bash)."));
      console.log(c.dim("  The server reads this file at startup for host-mode sessions."));
      break;
  }
}

function cmdHelp(): void {
  printHeader();

  console.log("  " + c.bold("Getting Started:"));
  console.log("");
  console.log(`    ${c.cyan("init")}                       Interactive first-time setup`);
  console.log(`    ${c.cyan("serve")}                      Start the server`);
  console.log(`    ${c.cyan("pair")}                       Generate pairing QR for server owner`);
  console.log("");

  console.log("  " + c.bold("Server:"));
  console.log("");
  console.log(`    ${c.cyan("status")}                     Show server status`);
  console.log(`    ${c.cyan("token rotate")}               Rotate owner bearer token`);
  console.log(`    ${c.cyan("env init")}                   Capture shell PATH for host sessions`);
  console.log(`    ${c.cyan("env show")}                   Show resolved host PATH`);
  console.log("");

  console.log("  " + c.bold("Configuration:"));
  console.log("");
  console.log(`    ${c.cyan("config show")}                Show current config`);
  console.log(`    ${c.cyan("config set")} <key> <value>   Update a config value`);
  console.log(`    ${c.cyan("config get")} <key>           Get a config value`);
  console.log(`    ${c.cyan("config validate")}            Validate config file`);
  console.log("");

  console.log("  " + c.bold("Options:"));
  console.log("");
  console.log(`    ${c.dim("--host <host>")}      Hostname/IP encoded in pairing QR`);
  console.log(`    ${c.dim("--show-token")}       Print owner token in pair output (unsafe)`);
  console.log(`    ${c.dim("--config-file <p>")}  Config path for 'config validate'`);
  console.log("");

  console.log("  " + c.bold("Examples:"));
  console.log("");
  console.log(`    ${c.dim("oppi init")}`);
  console.log(`    ${c.dim("oppi serve")}`);
  console.log(`    ${c.dim('oppi config set defaultModel "anthropic/claude-opus-4-6"')}`);
  console.log(`    ${c.dim("oppi config set port 8080")}`);
  console.log(`    ${c.dim("oppi env init   # run from fish/zsh/bash")}`);
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

  // These commands run before Storage to avoid creating default config prematurely
  if (command === "init") {
    await cmdInit(flags);
    return;
  }
  if (command === "help" || command === "--help" || command === "-h") {
    cmdHelp();
    return;
  }

  const storage = new Storage(process.env.OPPI_DATA_DIR || undefined);

  switch (command) {
    case "serve":
    case "start":
      await cmdServe(storage);
      break;

    case "pair":
      await cmdPair(storage, positional[0], flags.host, flags["show-token"] === "true");
      break;

    case "status":
      cmdStatus(storage);
      break;

    case "token":
      cmdToken(storage, positional[0]);
      break;

    case "config":
      cmdConfig(storage, positional[0], positional.slice(1), flags);
      break;

    case "env":
      cmdEnv(positional[0]);
      break;

    default:
      console.log(c.red(`Unknown command: ${command}`));
      console.log(c.dim("Run 'oppi help' for usage."));
      process.exit(1);
  }
}

main().catch((err) => {
  console.error(c.red("Fatal error:"), err);
  process.exit(1);
});
