#!/usr/bin/env node
/**
 * oppi CLI
 *
 * Commands:
 *   init            Interactive first-time setup
 *   serve           Start the server
 *   pair [name]     Pair iOS client with server owner token
 *   status          Show server status
 *   doctor          Run security + environment diagnostics
 *   token           Rotate owner bearer token
 *   config          Show/get/set/validate server config
 */

import * as c from "./ansi.js";
import { renderTerminal as renderQR } from "./qr.js";
import { readFileSync, existsSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { hostname as osHostname, networkInterfaces } from "node:os";
import { Storage } from "./storage.js";
import { Server } from "./server.js";
import { envInit, envShow } from "./host-env.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import type { APNsConfig } from "./push.js";
import type { InviteData, InvitePayloadV3, ServerConfig } from "./types.js";

function loadAPNsConfig(storage: Storage): APNsConfig | undefined {
  const dataDir = storage.getDataDir();
  const apnsConfigPath = join(dataDir, "apns.json");

  if (!existsSync(apnsConfigPath)) return undefined;

  try {
    const raw = JSON.parse(readFileSync(apnsConfigPath, "utf-8"));
    if (!raw.keyPath || !raw.keyId || !raw.teamId || !raw.bundleId) {
      console.log(c.yellow("  ⚠️  apns.json incomplete — need keyPath, keyId, teamId, bundleId"));
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
    c.boldMagenta("  │") + c.bold("              π  oppi                   ") + c.boldMagenta("│"),
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
  // Prefer local network; fall back to Tailscale if no LAN host found.
  return getLocalHostname() || getLocalIp() || getTailscaleHostname() || getTailscaleIp();
}

function shortHostLabel(host: string): string {
  // Keep IPs as-is, trim FQDNs to first label.
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return host;
  return host.split(".")[0] || host;
}

// ─── Commands ───

async function cmdServe(storage: Storage, pairHost?: string): Promise<void> {
  printHeader();

  // Auto-init: generate owner token + identity keys if this is a fresh install.
  if (!storage.isPaired()) {
    storage.rotateToken();
    console.log(c.green("  ✓ First run — owner token generated"));
  }
  ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));

  // Capture host env if interactive shell and not already captured.
  if (process.env.PATH && process.env.PATH.includes("/homebrew/")) {
    envInit();
  }

  const config = storage.getConfig();
  const tailscaleHostname = getTailscaleHostname();
  const tailscaleIp = getTailscaleIp();
  const localHostname = getLocalHostname();
  const localIp = getLocalIp();

  if (tailscaleHostname || tailscaleIp) {
    console.log(c.dim("  Tailscale detected — remote access available"));
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
  if (localHostname) {
    console.log(`  Local:     ${c.cyan(localHostname)}:${config.port}`);
  }
  if (localIp) {
    console.log(`  LAN IP:    ${c.dim(localIp)}:${config.port}`);
  }
  if (tailscaleHostname) {
    console.log(`  Tailscale: ${c.dim(tailscaleHostname)}:${config.port}`);
  }
  if (tailscaleIp) {
    console.log(`  Tail IP:   ${c.dim(tailscaleIp)}:${config.port}`);
  }
  console.log(`  Data:      ${c.dim(storage.getDataDir())}`);
  console.log("");

  if (storage.isPaired()) {
    console.log(c.green("  ✓ Paired"));
    console.log("");
    console.log(c.green("  Waiting for connections..."));
    console.log(c.dim("  Press Ctrl+C to stop"));
    console.log(c.dim("  Run 'oppi pair' to re-pair or add devices."));
    console.log("");
  } else {
    // First run: show pairing QR inline so user doesn't need a separate command.
    console.log("");
    showPairingQR(storage, undefined, pairHost);
    console.log(c.green("  Server is running. Scan QR above, then Ctrl+C when done."));
    console.log("");
  }
}

/**
 * Show the pairing QR code + deep link. Reusable by both `pair` and `serve`.
 * Returns true if QR was shown, false if host detection failed.
 */
function showPairingQR(
  storage: Storage,
  requestedName?: string,
  hostOverride?: string,
  showToken = false,
): boolean {
  const config = storage.getConfig();
  storage.ensurePaired();
  const pairingToken = storage.issuePairingToken(90_000);
  const inviteHost = resolveInviteHost(hostOverride);

  if (!inviteHost) {
    console.log(c.red("  Error: Could not determine pairing host"));
    console.log(c.dim("  Pass --host <hostname-or-ip>, e.g. --host my-mac.local"));
    console.log("");
    return false;
  }

  if (hostOverride?.trim()) {
    console.log(c.dim(`  (using host override: ${inviteHost})`));
  } else {
    console.log(c.dim(`  (auto-detected host: ${inviteHost})`));
  }

  // Build unsigned v3 pairing payload.
  const inviteData: InviteData = {
    host: inviteHost,
    port: config.port,
    token: "",
    pairingToken,
    name: requestedName?.trim() || shortHostLabel(inviteHost),
  };

  const identity = ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));

  const invitePayload: InvitePayloadV3 = {
    v: 3,
    host: inviteData.host,
    port: inviteData.port,
    token: inviteData.token,
    pairingToken: inviteData.pairingToken,
    name: inviteData.name,
    fingerprint: identity.fingerprint,
  };

  const inviteJson = JSON.stringify(invitePayload);
  const inviteUrl = `oppi://connect?${new URLSearchParams({
    v: "3",
    invite: Buffer.from(inviteJson, "utf-8").toString("base64url"),
  }).toString()}`;

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
    console.log(`  ${c.dim(storage.getToken() ?? "(none)")}`);
    console.log("");
  }

  return true;
}

async function cmdPair(
  storage: Storage,
  requestedName: string | undefined,
  hostOverride?: string,
  showToken = false,
): Promise<void> {
  printHeader();

  if (!showPairingQR(storage, requestedName, hostOverride, showToken)) {
    process.exit(1);
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

  console.log("  " + c.bold("Local Network"));
  console.log("");
  if (localHostname || localIp) {
    console.log(`  Hostname:  ${localHostname || c.dim("unknown")}`);
    console.log(`  IP:        ${localIp || c.dim("unknown")}`);
  } else {
    console.log(`  Status:    ${c.yellow("No active LAN interface detected")}`);
  }
  console.log("");

  console.log("  " + c.bold("Tailscale"));
  console.log("");
  if (hostname) {
    console.log(`  Hostname:  ${c.green(hostname)}`);
    console.log(`  IP:        ${ip || c.dim("unknown")}`);
  } else {
    console.log(`  Status:    ${c.dim("Not connected")}`);
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

function isLoopbackHost(host: string): boolean {
  const normalized = host.trim().toLowerCase();
  return normalized === "127.0.0.1" || normalized === "localhost" || normalized === "::1";
}

function cmdDoctor(storage: Storage): void {
  printHeader();

  type CheckLevel = "pass" | "warn" | "fail";
  type Check = { level: CheckLevel; message: string };
  const checks: Check[] = [];

  const config = storage.getConfig();
  const host = config.host;
  const loopback = isLoopbackHost(host);

  const allowedCidrs = config.allowedCidrs || [];

  if (!loopback && !config.token) {
    checks.push({
      level: "fail",
      message: `non-loopback bind (${host}) without token configured`,
    });
  } else if (config.token) {
    checks.push({ level: "pass", message: "auth token configured" });
  } else {
    checks.push({ level: "warn", message: "no token configured (loopback-only bind)" });
  }

  try {
    const mode = statSync(storage.getConfigPath()).mode & 0o777;
    if ((mode & 0o077) !== 0) {
      checks.push({
        level: "warn",
        message: `config file permissions are ${mode.toString(8)} (recommend 600)`,
      });
    } else {
      checks.push({ level: "pass", message: "config file permissions are private" });
    }
  } catch {
    checks.push({ level: "warn", message: "could not inspect config file permissions" });
  }

  try {
    const mode = statSync(storage.getDataDir()).mode & 0o777;
    if ((mode & 0o077) !== 0) {
      checks.push({
        level: "warn",
        message: `data dir permissions are ${mode.toString(8)} (recommend 700)`,
      });
    } else {
      checks.push({ level: "pass", message: "data dir permissions are private" });
    }
  } catch {
    checks.push({ level: "warn", message: "could not inspect data directory permissions" });
  }

  if (allowedCidrs.some((cidr) => cidr === "0.0.0.0/0" || cidr === "::/0")) {
    checks.push({ level: "warn", message: "allowedCidrs contains global network range" });
  } else {
    checks.push({ level: "pass", message: "allowedCidrs excludes global ranges" });
  }

  if ((host === "0.0.0.0" || host === "::") && allowedCidrs.length > 0) {
    checks.push({
      level: "warn",
      message: "wildcard bind in use; rely on CIDR/firewall for exposure control",
    });
  }
  if (loopback && allowedCidrs.some((cidr) => cidr === "0.0.0.0/0" || cidr === "::/0")) {
    checks.push({ level: "warn", message: "loopback bind with wide CIDRs is inconsistent" });
  }

  try {
    execSync("command -v pi", { stdio: "ignore" });
    checks.push({ level: "pass", message: "pi executable found" });
  } catch {
    checks.push({ level: "warn", message: "pi executable not found in PATH" });
  }

  const nodeMajor = Number(process.versions.node.split(".")[0] || "0");
  if (nodeMajor < 22) {
    checks.push({
      level: "warn",
      message: `Node.js ${process.versions.node} detected (recommend >= 22)`,
    });
  } else {
    checks.push({ level: "pass", message: `Node.js ${process.versions.node}` });
  }

  let criticalFailures = 0;
  for (const check of checks) {
    if (check.level === "pass") {
      console.log(`  ${c.green("✓")} ${check.message}`);
    } else if (check.level === "warn") {
      console.log(`  ${c.yellow("!")} ${check.message}`);
    } else {
      criticalFailures++;
      console.log(`  ${c.red("✗")} ${check.message}`);
    }
  }

  console.log("");
  if (criticalFailures > 0) {
    console.log(c.red(`  Doctor failed: ${criticalFailures} critical issue(s)`));
    console.log("");
    process.exit(1);
  }

  console.log(c.green("  Doctor passed (no critical issues)"));
  console.log("");
}

function cmdToken(storage: Storage, action: string | undefined): void {
  printHeader();

  const mode = action || "help";

  if (mode === "rotate") {
    if (!storage.isPaired()) {
      console.log(c.red("  Error: server is not paired yet."));
      console.log(c.dim("  Run 'oppi pair' first to generate owner credentials."));
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
    defaultModel = flags.model || "openai-codex/gpt-5.3-codex";
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
    console.log(c.dim("    openai-codex/gpt-5.3-codex"));
    console.log(c.dim("    anthropic/claude-opus-4-6"));
    console.log(c.dim("    anthropic/claude-sonnet-4-20250514"));
    console.log("");
    defaultModel = await prompt("Default model", "openai-codex/gpt-5.3-codex");

    const maxSessionsStr = await prompt("Max concurrent sessions", "5");
    maxSessionsGlobal = parseInt(maxSessionsStr) || 5;
  }

  // Create storage (auto-creates dirs + default config)
  const storage = new Storage(dataDir);

  // Apply user choices + generate owner token so `oppi serve` can bind to 0.0.0.0
  storage.updateConfig({
    port,
    defaultModel,
    maxSessionsGlobal,
  });
  storage.rotateToken();

  console.log("");
  console.log(c.green("  ✓ Config written to ") + c.dim(storage.getConfigPath()));
  console.log(c.green("  ✓ Owner token generated"));

  // 4. Generate identity keys
  ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));
  console.log(c.green("  ✓ Identity keys generated"));

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
  console.log(
    `    ${c.cyan("2.")} oppi pair ${c.dim('"YourName"')}     ${c.dim("Generate pairing QR")}`,
  );
  console.log(`    ${c.cyan("3.")} Scan QR in Oppi app     ${c.dim("Connect your phone")}`);
  console.log("");
}

// ─── Config Command ───

/** Settable config keys and their types for `oppi config set`. */
const SETTABLE_KEYS: Record<string, { type: "number" | "string" | "boolean"; desc: string }> = {
  port: { type: "number", desc: "Server port" },
  host: { type: "string", desc: "Bind address" },
  defaultModel: { type: "string", desc: "Default model for new sessions" },
  maxSessionsGlobal: { type: "number", desc: "Max concurrent sessions" },
  maxSessionsPerWorkspace: { type: "number", desc: "Max sessions per workspace" },
  sessionIdleTimeoutMs: { type: "number", desc: "Session idle timeout (ms)" },
  workspaceIdleTimeoutMs: { type: "number", desc: "Workspace idle timeout (ms)" },
  approvalTimeoutMs: { type: "number", desc: "Permission approval timeout (ms)" },
};

function coerceValue(
  raw: string,
  type: "number" | "string" | "boolean",
): number | string | boolean {
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
      storage.updateConfig({ [key]: coerced } as Partial<ServerConfig>);
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
      console.log(c.bold("  oppi env") + " — manage local session environment");
      console.log("");
      console.log(`    ${c.cyan("env init")}    Capture current $PATH into ~/.config/oppi/env`);
      console.log(`    ${c.cyan("env show")}    Show resolved session PATH`);
      console.log("");
      console.log(c.dim("  Run 'env init' from your interactive shell (fish, zsh, bash)."));
      console.log(c.dim("  The server reads this file at startup for local sessions."));
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
  console.log(`    ${c.cyan("doctor")}                     Security + environment diagnostics`);
  console.log(`    ${c.cyan("token rotate")}               Rotate owner bearer token`);
  console.log(`    ${c.cyan("env init")}                   Capture shell PATH for local sessions`);
  console.log(`    ${c.cyan("env show")}                   Show resolved session PATH`);
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
  console.log(`    ${c.dim('oppi config set defaultModel "openai-codex/gpt-5.3-codex"')}`);
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
      await cmdServe(storage, flags.host);
      break;

    case "pair":
      await cmdPair(storage, positional[0], flags.host, flags["show-token"] === "true");
      break;

    case "status":
      cmdStatus(storage);
      break;

    case "doctor":
      cmdDoctor(storage);
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
