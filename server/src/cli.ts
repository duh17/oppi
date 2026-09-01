#!/usr/bin/env node
/* eslint-disable local/structured-log-format */
/**
 * oppi CLI
 *
 * Command definitions and user-facing usage live in server/src/cli/help.ts.
 */

import * as c from "./ansi.js";
import { safeErrorMessage } from "./log-utils.js";
import { renderTerminal as renderQR } from "./qr.js";
import { readFileSync, existsSync, statSync, realpathSync } from "node:fs";
import { execSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runCli } from "./cli/runner.js";
import {
  getLocalHostname,
  getLocalIp,
  getTailscaleHostname,
  getTailscaleIp,
} from "./cli/status.js";
import { Storage } from "./storage.js";
import { Server } from "./server.js";
import {
  applyHostEnv,
  prependPathEntry,
  resolveExecutableOnPath,
  resolveHostEnv,
} from "./host-env.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "./security.js";
import type { APNsConfig } from "./push.js";
import {
  readCertificateExpiryMs,
  readCertificateFingerprint,
  resolveTlsConfig,
  validateTailscaleMaterial,
} from "./tls.js";
import type { ServerConfig } from "./types.js";
import { generateInvite, type GeneratedInvite } from "./invite.js";
import { getPackageInfo } from "./version.js";
import {
  getServiceStatus,
  installService,
  readInstalledPlist,
  restartService,
  stopService,
  uninstallService,
} from "./launchd.js";
import { parseCliArgs } from "./cli/args.js";
import {
  createCliConfigStorage,
  createCliConnectionConfig,
  type CliConfigStorage,
  type CliConnectionConfig,
} from "./cli/connection-config.js";
import {
  helpPathFor,
  isNestedHelpRequest,
  resolveHelpTopic,
  writeCliHelpOutput,
} from "./cli/help.js";
import { localApiRequest } from "./cli/local-api-client.js";
import { isNpmVersionNewer } from "./cli/npm-version.js";
import { cmdConfig } from "./cli/commands/config.js";
import { magicDnsSelfSignedDoctorCheck, wildcardBindDoctorCheck } from "./cli/doctor-checks.js";
import { setCapturedCliExitCode, writeJsonEnvelope } from "./cli/output.js";
import {
  assertPairingAdvertiseHostSuffix,
  rememberPairingAdvertiseHost,
  rememberValidatedPairingAdvertiseHost,
  resolvePairingAdvertiseHost,
} from "./cli/pairing-host.js";

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

function resolveInviteHost(config: ServerConfig, hostOverride?: string): string | null {
  return resolvePairingAdvertiseHost(config, hostOverride);
}

function shortHostLabel(host: string): string {
  // Keep IPs as-is, trim FQDNs to first label.
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return host;
  return host.split(".")[0] || host;
}

// ─── Commands ───

async function cmdServe(storage: Storage, pairHost?: string): Promise<void> {
  const wasPaired = storage.isPaired();
  // Grammar/suffix before start on first-run and paired installs so a
  // malformed --host cannot boot a server that then prints "Scan QR above"
  // with no QR.
  assertPairingAdvertiseHostSuffix(storage.getConfig(), pairHost);

  // Auto-init: generate owner token + identity keys if this is a fresh install.
  if (!wasPaired) {
    const currentTlsMode = storage.getConfig().tls?.mode ?? "disabled";
    if (currentTlsMode === "disabled") {
      storage.updateConfig({ tls: { mode: "self-signed" } });
      console.log(c.green("  ✓ First run — TLS mode set to self-signed"));
    }

    storage.rotateToken();
    console.log(c.green("  ✓ First run — owner token generated"));
  }
  ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));

  const config = storage.getConfig();

  // Apply the explicit host environment, then keep the npm bin directory that
  // supplied this `oppi` executable first for managed host-session tools.
  applyHostEnv(config);
  const invokedCli = process.argv[1];
  if (invokedCli && basename(invokedCli) === "oppi") {
    process.env.PATH = prependPathEntry(process.env.PATH, dirname(invokedCli));
  }
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
      console.error(c.red("Shutdown error:"), safeErrorMessage(err));
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
    console.error(c.red("Uncaught exception:"), safeErrorMessage(err));
    void shutdown(1);
  });

  process.on("unhandledRejection", (reason) => {
    console.error(c.red("Unhandled rejection:"), safeErrorMessage(reason));
    void shutdown(1);
  });

  await server.start();
  // start() may return with only the local socket while Tailscale certs
  // renew. Do not reread missing material here — that throws and would
  // cancel the retry. Persist after the remote listener is up.
  if (wasPaired && pairHost?.trim()) {
    const persistServeHost = (): void => {
      rememberValidatedPairingAdvertiseHost(storage, pairHost);
    };
    if (server.hasPublicHttpListener) {
      try {
        persistServeHost();
      } catch (error: unknown) {
        await shutdown(1, safeErrorMessage(error));
        return;
      }
    } else {
      console.log(c.yellow("  ! Remote TLS is not ready yet."));
      console.log(c.dim("  Local API is up. pairHost will be stored after remote TLS is ready."));
      server.onRemoteListenerReady(() => {
        try {
          persistServeHost();
        } catch (error: unknown) {
          void shutdown(1, safeErrorMessage(error));
        }
      });
    }
  }

  console.log("");
  const scheme = server.scheme;
  const displayPort = server.port;
  if (server.hasPublicHttpListener) {
    if (localHostname) {
      console.log(`  Local:     ${c.cyan(`${scheme}://${localHostname}:${displayPort}`)}`);
    }
    if (localIp) {
      console.log(`  LAN IP:    ${c.dim(`${scheme}://${localIp}:${displayPort}`)}`);
    }
    if (tailscaleHostname) {
      console.log(`  Tailscale: ${c.dim(`${scheme}://${tailscaleHostname}:${displayPort}`)}`);
    }
    if (tailscaleIp) {
      console.log(`  Tail IP:   ${c.dim(`${scheme}://${tailscaleIp}:${displayPort}`)}`);
    }
  }
  console.log(`  Data:      ${c.dim(storage.getDataDir())}`);
  console.log("");

  if (wasPaired) {
    console.log(c.green("  ✓ Paired"));
    console.log("");
    console.log(c.green("  Waiting for connections..."));
    console.log(c.dim("  Press Ctrl+C to stop"));
    console.log(c.dim("  Run 'oppi pair' to re-pair or add devices."));
    console.log("");
  } else {
    // First run: show pairing QR inline. If start() returned without a
    // remote listener (Tailscale certs not ready), keep the retry and
    // print the QR when the listener recovers.
    const showFirstRunQr = (): boolean => {
      if (!showPairingQR(storage, undefined, pairHost)) return false;
      console.log(c.green("  Server is running. Scan QR above, then Ctrl+C when done."));
      console.log("");
      return true;
    };
    if (server.hasPublicHttpListener) {
      if (!showFirstRunQr()) {
        await shutdown(1);
        return;
      }
    } else {
      console.log(c.yellow("  ! Remote TLS is not ready yet."));
      console.log(c.dim("  Local API is up. Pairing QR will be shown after remote TLS is ready."));
      console.log(c.dim("  Press Ctrl+C to stop"));
      console.log("");
      server.onRemoteListenerReady(() => {
        if (!showFirstRunQr()) {
          void shutdown(1);
        }
      });
    }
  }
}

function inviteHasHttpTransport(invite: GeneratedInvite): boolean {
  return invite.host.length > 0;
}

function generatePairInvite(
  storage: CliConfigStorage,
  hostOverride?: string,
  requestedName?: string,
): GeneratedInvite {
  const invite = generateInvite(
    storage,
    (override) => resolveInviteHost(storage.getConfig(), override),
    shortHostLabel,
    { hostOverride, requestedName },
  );
  // Persist only after the invite is valid so a rejected --host cannot stick.
  if (hostOverride?.trim()) {
    rememberPairingAdvertiseHost(storage, invite.host);
  }
  return invite;
}

/**
 * Show the pairing QR code + deep link. Reusable by both `pair` and `serve`.
 * Returns true if QR was shown, false if host detection failed.
 */
function showPairingQR(
  storage: CliConfigStorage,
  requestedName?: string,
  hostOverride?: string,
  showToken = false,
): boolean {
  let invite;
  try {
    invite = generatePairInvite(storage, hostOverride, requestedName);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.log(c.red(`  Error: ${message}`));
    console.log("");
    return false;
  }

  if (inviteHasHttpTransport(invite)) {
    if (hostOverride?.trim()) {
      console.log(c.dim(`  (using host override: ${invite.host})`));
    } else {
      console.log(c.dim(`  (auto-detected host: ${invite.host})`));
    }

    console.log(`  📱 Pair with ${c.bold(shortHostLabel(invite.host))}`);
    console.log(
      c.dim(`  Transport: ${invite.scheme.toUpperCase()} (${invite.host}:${invite.port})`),
    );
    if (invite.tlsCertFingerprint) {
      console.log(c.dim(`  Cert pin:  ${invite.tlsCertFingerprint}`));
    }
  }
  console.log("");
  console.log("  Scan this QR code in Oppi:");
  console.log("");

  // Render the same signed deep link that we print below so scan + share paths match.
  const qr = renderQR(invite.inviteURL);
  console.log(
    qr
      .split("\n")
      .map((line) => "     " + line)
      .join("\n"),
  );

  console.log("");
  console.log("  Or share this link:");
  console.log(`  ${c.cyan(invite.inviteURL)}`);
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
  storage: CliConfigStorage,
  requestedName: string | undefined,
  hostOverride?: string,
  showToken = false,
  jsonOutput = false,
): Promise<void> {
  if (jsonOutput) {
    try {
      const invite = generatePairInvite(storage, hostOverride, requestedName);
      process.stdout.write(JSON.stringify(invite, null, 2) + "\n");
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`Error: ${message}\n`);
      process.exit(1);
    }
    return;
  }

  if (!showPairingQR(storage, requestedName, hostOverride, showToken)) {
    process.exit(1);
  }
}

function isLoopbackHost(host: string): boolean {
  const normalized = host.trim().toLowerCase();
  return normalized === "127.0.0.1" || normalized === "localhost" || normalized === "::1";
}

function cmdDoctor(storage: CliConnectionConfig, hostOverride?: string): void {
  type CheckLevel = "pass" | "warn" | "fail";
  type Check = { level: CheckLevel; message: string };
  const checks: Check[] = [];

  const config = storage.getConfig();
  const host = config.host;
  const loopback = isLoopbackHost(host);

  // Official image/Compose set OPPI_CONTAINER_LISTENER=1. Do not key this
  // on /.dockerenv: a generic container with host networking or -p 7750:7750
  // still needs the wildcard-bind failure.
  const containerListener = process.env.OPPI_CONTAINER_LISTENER === "1";
  const wildcardBind = wildcardBindDoctorCheck(host, { containerListener });
  if (wildcardBind) {
    checks.push(wildcardBind);
  }

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

  const runtimeEnv = resolveHostEnv(config);
  const runtimePath = runtimeEnv.env.PATH || "";
  const runtimePathEntries = runtimePath.split(":").filter(Boolean).length;
  checks.push({
    level: runtimePathEntries > 0 ? "pass" : "warn",
    message:
      runtimePathEntries > 0
        ? `runtime PATH has ${runtimePathEntries} configured entries`
        : "runtime PATH is empty (configure runtimePathEntries in config)",
  });

  const piPath = resolveExecutableOnPath("pi", runtimePath);
  if (piPath) {
    checks.push({ level: "pass", message: `pi executable found (${piPath})` });
  } else {
    checks.push({ level: "warn", message: "pi executable not found in runtime PATH" });
  }

  const tls = resolveTlsConfig(config, storage.getDataDir());
  const advertisedHost = resolvePairingAdvertiseHost(config, hostOverride);
  const magicDnsSelfSigned = magicDnsSelfSignedDoctorCheck(
    config.tls?.mode ?? tls.mode,
    advertisedHost,
    config.port,
  );
  if (magicDnsSelfSigned) {
    checks.push(magicDnsSelfSigned);
  }
  if (!tls.enabled) {
    checks.push({
      level: loopback ? "pass" : "warn",
      message: loopback
        ? "TLS disabled (loopback-only bind)"
        : `TLS disabled while binding to ${config.host}`,
    });
  } else {
    checks.push({ level: "pass", message: `TLS mode configured (${tls.mode})` });

    if (tls.mode === "tailscale") {
      const tailscaleHostname = getTailscaleHostname();
      let validatedTailnetName: string | undefined;
      try {
        validatedTailnetName = validateTailscaleMaterial(
          tls,
          advertisedHost ?? tailscaleHostname ?? undefined,
        );
        checks.push({
          level: "pass",
          message: `Tailscale cert/key are locally valid for ${validatedTailnetName}`,
        });
        checks.push({
          level: "warn",
          message:
            "Tailscale certificate provenance/public chain is not checked by doctor; public trust is enforced by TLS clients",
        });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        checks.push({
          level: "fail",
          message: `Tailscale TLS material is unusable (${message})`,
        });
      }

      if (tailscaleHostname) {
        checks.push({
          level: "pass",
          message: `Tailscale hostname detected (${tailscaleHostname})`,
        });
      } else if (validatedTailnetName) {
        checks.push({
          level: "warn",
          message:
            "Tailscale is not connected; locally valid certificate material still supports local operation on the configured bind address",
        });
      }
    }

    if (!tls.certPath) {
      checks.push({ level: "fail", message: "tls.certPath is not configured" });
    } else if (!existsSync(tls.certPath)) {
      checks.push({ level: "fail", message: `TLS cert missing: ${tls.certPath}` });
    } else {
      checks.push({ level: "pass", message: `TLS cert found (${tls.certPath})` });

      try {
        const expiresAt = readCertificateExpiryMs(tls.certPath);
        const msRemaining = expiresAt - Date.now();
        const daysRemaining = Math.floor(msRemaining / (24 * 60 * 60 * 1000));

        if (msRemaining <= 0) {
          checks.push({ level: "fail", message: "TLS certificate is expired" });
        } else if (daysRemaining <= 14) {
          checks.push({
            level: "warn",
            message: `TLS certificate expires in ${daysRemaining} day(s)`,
          });
        } else {
          checks.push({
            level: "pass",
            message: `TLS certificate valid for ${daysRemaining} more day(s)`,
          });
        }
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        checks.push({
          level: "warn",
          message: `could not read TLS certificate expiry (${message})`,
        });
      }

      try {
        const fingerprint = readCertificateFingerprint(tls.certPath);
        checks.push({ level: "pass", message: `TLS cert fingerprint ${fingerprint}` });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        checks.push({ level: "warn", message: `could not read TLS cert fingerprint (${message})` });
      }
    }

    if (!tls.keyPath) {
      checks.push({ level: "fail", message: "tls.keyPath is not configured" });
    } else if (!existsSync(tls.keyPath)) {
      checks.push({ level: "fail", message: `TLS key missing: ${tls.keyPath}` });
    } else {
      checks.push({ level: "pass", message: `TLS key found (${tls.keyPath})` });
    }

    if (tls.mode === "self-signed") {
      if (!tls.caPath) {
        checks.push({
          level: "fail",
          message: "tls.caPath is not configured for self-signed mode",
        });
      } else if (!existsSync(tls.caPath)) {
        checks.push({ level: "fail", message: `TLS CA missing: ${tls.caPath}` });
      } else {
        checks.push({ level: "pass", message: `TLS CA found (${tls.caPath})` });
      }
    }
  }

  const packageInfo = getPackageInfo();
  checks.push({
    level: "pass",
    message: `Oppi CLI: ${packageInfo.name}@${packageInfo.version}`,
  });

  // ── LaunchAgent checks ──
  // launchctl is macOS-only. On npm/VPS Linux hosts the lookup throws; keep
  // bind/TLS diagnostics visible instead of aborting doctor.

  try {
    const svcStatus = getServiceStatus();
    if (svcStatus.installed) {
      checks.push({ level: "pass", message: "LaunchAgent installed" });
      if (svcStatus.running) {
        checks.push({
          level: "pass",
          message: `LaunchAgent running (PID ${svcStatus.pid})`,
        });
      } else {
        checks.push({
          level: "warn",
          message: "LaunchAgent installed but not running (oppi server restart)",
        });
      }

      const paths = readInstalledPlist();
      if (paths) {
        if (!existsSync(paths.runtimePath)) {
          checks.push({
            level: "fail",
            message: `LaunchAgent runtime missing: ${paths.runtimePath} (oppi server install to fix)`,
          });
        }
        if (!existsSync(paths.cliPath)) {
          checks.push({
            level: "fail",
            message: `LaunchAgent CLI missing: ${paths.cliPath} (oppi server install to fix)`,
          });
        }
      }
    } else {
      checks.push({
        level: "warn",
        message: "LaunchAgent not installed (oppi server install for background service)",
      });
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    checks.push({
      level: "warn",
      message: `could not inspect LaunchAgent (${message})`,
    });
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

async function cmdToken(
  connection: CliConnectionConfig,
  action: string | undefined,
): Promise<void> {
  const mode = action || "help";

  if (mode === "rotate") {
    if (!connection.isPaired()) {
      console.log(c.red("  Error: server is not paired yet."));
      console.log(c.dim("  Run 'oppi pair' first to generate owner credentials."));
      console.log("");
      process.exit(1);
    }

    try {
      await localApiRequest(connection, "/auth/rotate", { method: "POST" });
    } catch (error) {
      console.log(c.red(`  Error: could not rotate live credentials: ${safeErrorMessage(error)}`));
      console.log(c.dim("  Is the Oppi server running? Rotation now applies immediately."));
      console.log("");
      process.exit(1);
    }

    console.log(c.green("  ✓ Bearer token rotated live."));
    console.log("");
    console.log(c.yellow("  Existing clients are now unauthorized until re-paired."));
    console.log(c.dim("  Next step: run 'oppi pair' to issue a fresh invite."));
    console.log("");
    return;
  }

  console.log(c.red(`  Unknown token action: ${mode}`));
  console.log(c.dim("  Usage: oppi token rotate"));
  console.log("");
  process.exit(1);
}

async function cmdDevices(
  connection: CliConnectionConfig,
  action: string | undefined,
  id: string | undefined,
): Promise<void> {
  const mode = action || "list";

  if (mode === "list") {
    try {
      const data = await localApiRequest<{
        devices: Array<{
          id: string;
          name: string;
          scope: string;
          createdAt: number;
          lastUsedAt?: number;
          revokedAt?: number;
          keyEnrolled: boolean;
        }>;
      }>(connection, "/auth/devices");
      const devices = data.devices ?? [];
      console.log(c.bold(`  Devices (${devices.length})`));
      for (const device of devices) {
        const state = device.revokedAt !== undefined ? "revoked" : "active";
        const proof = device.keyEnrolled ? "device-key" : "legacy";
        const lastUsed = device.lastUsedAt ? new Date(device.lastUsedAt).toISOString() : "never";
        console.log(`  - ${device.id}  ${device.name}  [${state}, ${proof}]  lastUsed=${lastUsed}`);
      }
      console.log("");
      return;
    } catch (error) {
      console.log(c.red(`  Error: could not list devices: ${safeErrorMessage(error)}`));
      console.log("");
      process.exit(1);
    }
  }

  if (mode === "revoke") {
    if (!id) {
      console.log(c.red("  Error: missing device id."));
      console.log(c.dim("  Usage: oppi devices revoke <id>"));
      console.log("");
      process.exit(1);
    }
    try {
      await localApiRequest(connection, `/auth/devices/${encodeURIComponent(id)}`, {
        method: "DELETE",
      });
    } catch (error) {
      console.log(c.red(`  Error: could not revoke device ${id}: ${safeErrorMessage(error)}`));
      console.log("");
      process.exit(1);
    }
    console.log(
      c.green(`  ✓ Revoked device ${id}. Its access tokens are invalidated immediately.`),
    );
    console.log("");
    return;
  }

  console.log(c.red(`  Unknown devices action: ${mode}`));
  console.log(c.dim("  Usage: oppi devices list | oppi devices revoke <id>"));
  console.log("");
  process.exit(1);
}

async function cmdAuth(connection: CliConnectionConfig, action: string | undefined): Promise<void> {
  const mode = action || "status";

  if (mode === "status") {
    const finalized = connection.getConfig().authMigrationMode === "finalized";
    console.log(
      c.bold(
        `  Legacy device-token migration: ${finalized ? "finalized (dt_ rejected on network)" : "compat (dt_ still accepted)"}`,
      ),
    );
    console.log("");
    return;
  }

  if (mode === "finalize" || mode === "compat") {
    const finalized = mode === "finalize";
    try {
      await localApiRequest(connection, finalized ? "/auth/finalize" : "/auth/compat", {
        method: "POST",
      });
    } catch (error) {
      console.log(c.red(`  Error: could not update migration mode: ${safeErrorMessage(error)}`));
      console.log("");
      process.exit(1);
    }
    console.log(
      c.green(
        finalized
          ? "  ✓ Finalized device-key migration. Legacy dt_ tokens are now rejected immediately."
          : "  ✓ Restored legacy dt_ compatibility window.",
      ),
    );
    if (finalized) {
      console.log(c.yellow("  Existing Apple clients must be on a device-key build or re-pair."));
    }
    console.log("");
    return;
  }

  console.log(c.red(`  Unknown auth action: ${mode}`));
  console.log(c.dim("  Usage: oppi auth status | oppi auth finalize | oppi auth compat"));
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
  let maxSessionsGlobal: number;

  if (nonInteractive) {
    // Non-interactive: use flags or defaults
    port = parseInt(flags.port || "7749") || 7749;
    maxSessionsGlobal = parseInt(flags["max-sessions"] || "200") || 200;

    console.log(c.dim(`  Port:         ${port}`));
    console.log(c.dim("  Model:        Pi settings (~/.pi/agent/settings.json)"));
    console.log(c.dim(`  Max sessions: ${maxSessionsGlobal}`));
    console.log("");
  } else {
    // Interactive prompts
    const portStr = await prompt("Port", "7749");
    port = parseInt(portStr) || 7749;

    console.log("");
    console.log(c.dim("  Model defaults are read from Pi settings:"));
    console.log(c.dim("    ~/.pi/agent/settings.json"));
    console.log(c.dim("    <workspace>/.pi/settings.json"));
    console.log("");

    const maxSessionsStr = await prompt("Max concurrent sessions", "200");
    maxSessionsGlobal = parseInt(maxSessionsStr) || 200;
  }

  // Create config storage (auto-creates dirs + default config)
  const storage = createCliConfigStorage(dataDir);

  // Apply user choices + generate owner token so `oppi serve` can bind to 0.0.0.0.
  // Default to self-signed TLS so first `oppi serve` boots HTTPS/WSS out of the box.
  storage.updateConfig({
    port,
    maxSessionsGlobal,
    tls: { mode: "self-signed" },
  });
  storage.rotateToken();

  console.log("");
  console.log(c.green("  ✓ Config written to ") + c.dim(storage.getConfigPath()));
  console.log(c.green("  ✓ Owner token generated"));
  console.log(c.green("  ✓ TLS mode set to self-signed (cert generated on first serve)"));

  // 4. Generate identity keys
  ensureIdentityMaterial(identityConfigForDataDir(storage.getDataDir()));
  console.log(c.green("  ✓ Identity keys generated"));

  // 5. Summary
  console.log("");
  console.log(c.bold("  Next steps:"));
  console.log("");
  console.log(
    `    ${c.cyan("1.")} oppi serve              ${c.dim("Start the server (HTTPS/WSS)")}`,
  );
  console.log(
    `    ${c.cyan("2.")} oppi pair ${c.dim('"YourName"')}     ${c.dim("Generate pairing QR")}`,
  );
  console.log(`    ${c.cyan("3.")} Scan QR in Oppi app     ${c.dim("Connect your phone")}`);
  console.log("");
}

function cmdServer(action: string | undefined, flags: Record<string, string>): void {
  const mode = action || "status";

  if (mode === "install") {
    const dataDir = flags["data-dir"] || undefined;
    console.log(c.bold("  Installing LaunchAgent..."));
    console.log("");

    const result = installService(dataDir);
    if (!result.ok) {
      console.log(c.red(`  \u2717 ${result.message}`));
      console.log("");
      process.exit(1);
    }

    console.log(c.green(`  \u2713 ${result.message}`));
    if (result.runtimePath) {
      console.log(c.dim(`    Runtime: ${result.runtimePath}`));
    }
    if (result.cliPath) {
      console.log(c.dim(`    CLI:     ${result.cliPath}`));
    }
    console.log("");
    console.log(c.dim("  The server will start automatically on login."));
    console.log(c.dim("  It will restart if it crashes."));
    console.log(c.dim("  The Mac app will detect and attach to it."));
    console.log("");
    return;
  }

  if (mode === "uninstall") {
    const result = uninstallService();
    if (!result.ok) {
      console.log(c.red(`  \u2717 ${result.message}`));
      console.log("");
      process.exit(1);
    }

    console.log(c.green(`  \u2713 ${result.message}`));
    console.log("");
    return;
  }

  if (mode === "restart") {
    const result = restartService();
    if (!result.ok) {
      console.log(c.red(`  \u2717 ${result.message}`));
      console.log("");
      process.exit(1);
    }

    console.log(c.green(`  \u2713 ${result.message}`));
    console.log("");
    return;
  }

  if (mode === "stop") {
    const result = stopService();
    if (!result.ok) {
      console.log(c.red(`  \u2717 ${result.message}`));
      console.log("");
      process.exit(1);
    }

    console.log(c.green(`  \u2713 ${result.message}`));
    console.log("");
    return;
  }

  if (mode === "status") {
    const status = getServiceStatus();
    console.log("  " + c.bold("LaunchAgent Service"));
    console.log("");

    console.log(`  Label:     ${c.dim(status.label)}`);
    console.log(`  Plist:     ${c.dim(status.plistPath)}`);
    console.log(`  Installed: ${status.installed ? c.green("yes") : c.dim("no")}`);
    console.log(
      `  Running:   ${status.running ? c.green(`yes (PID ${status.pid})`) : c.dim("no")}`,
    );

    if (status.installed) {
      const paths = readInstalledPlist();
      if (paths) {
        console.log("");
        console.log(`  Runtime:   ${c.dim(paths.runtimePath)}`);
        console.log(`  CLI:       ${c.dim(paths.cliPath)}`);
        console.log(`  Data dir:  ${c.dim(paths.dataDir)}`);
      }
    } else {
      console.log("");
      console.log(c.dim("  Run 'oppi server install' to set up the LaunchAgent."));
    }
    console.log("");
    return;
  }

  console.log(c.red(`  Unknown server action: ${mode}`));
  console.log(c.dim("  Usage: oppi server [install|uninstall|status|restart|stop]"));
  console.log("");
  process.exit(1);
}

function currentPackageDir(): string | undefined {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (let i = 0; i < 5; i++) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate)) return dir;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return undefined;
}

function isLikelyGlobalNpmInstall(packageName: string): boolean {
  try {
    const packageDir = currentPackageDir();
    if (!packageDir) return false;
    const globalRoot = execSync("npm root -g", {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!globalRoot) return false;
    const installed = realpathSync(packageDir);
    const expected = realpathSync(join(globalRoot, packageName));
    return installed === expected;
  } catch {
    return false;
  }
}

async function runInherited(command: string, args: string[]): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: "inherit",
      shell: process.platform === "win32",
    });
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code === 0) resolve();
      else if (signal) reject(new Error(`${command} ${args.join(" ")} terminated by ${signal}`));
      else reject(new Error(`${command} ${args.join(" ")} exited with code ${code ?? "unknown"}`));
    });
  });
}

async function cmdSelfUpdate(flags: Record<string, string>): Promise<void> {
  const info = getPackageInfo();
  console.log("  " + c.bold("Updating Oppi server"));
  console.log("");
  console.log(`  Current: ${c.dim(`${info.name}@${info.version}`)}`);

  let latest = "latest";
  try {
    const registryLatest = execSync(`npm view ${info.name} version`, {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!registryLatest) throw new Error("npm returned an empty version");

    const newer = isNpmVersionNewer(registryLatest, info.version);
    const currentAhead = isNpmVersionNewer(info.version, registryLatest);
    latest = registryLatest;
    const label = newer
      ? `${c.green(latest)} ${c.yellow("(update available)")}`
      : currentAhead
        ? `${c.dim(latest)} ${c.yellow("(registry is behind this install)")}`
        : c.dim(`${latest} (current)`);
    console.log(`  Latest:  ${label}`);
  } catch {
    console.log(c.yellow("  Could not check npm for the latest version."));
    console.log(c.dim("  Continuing with npm install -g oppi-server@latest."));
  }
  console.log("");

  if (flags.check === "true" || flags.dry === "true") {
    if (latest !== "latest" && !isNpmVersionNewer(latest, info.version)) {
      console.log(c.green("  Oppi server is already current."));
    } else {
      console.log(c.yellow("  Update available."));
    }
    console.log(c.dim(`  Command: npm install -g ${info.name}@latest`));
    console.log("");
    return;
  }

  if (!isLikelyGlobalNpmInstall(info.name)) {
    console.log(c.yellow("  This Oppi CLI does not look like a global npm install."));
    console.log(c.dim("  npm global:   npm install -g oppi-server@latest"));
    console.log(c.dim("  git checkout: git pull && npm install && npm run build"));
    console.log(
      c.dim("  Mac app:      install the shared CLI with npm install -g oppi-server@latest"),
    );
    console.log("");
    process.exit(1);
  }

  await runInherited("npm", ["install", "-g", `${info.name}@latest`]);
  console.log("");
  console.log(c.green("  Updated Oppi server."));
  console.log(c.dim("  Restart any running Oppi server process to use the new version."));
  console.log("");
}

async function cmdUpdate(flags: Record<string, string>): Promise<void> {
  await cmdSelfUpdate(flags);
}

function cmdHelp(path: string[] = [], jsonOutput = false): void {
  const topic = resolveHelpTopic(path);
  if (!topic) {
    const label = path.length > 0 ? path.join(" ") : "help";
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message: `No help topic for ${label}` } });
      setCapturedCliExitCode(1);
      return;
    }
    console.log(c.red(`No help topic for ${label}`));
    console.log(c.dim("Run 'oppi help' for top-level usage."));
    setCapturedCliExitCode(1);
    return;
  }

  writeCliHelpOutput(topic, jsonOutput);
}

// ─── Main ───

export async function runCliMain(args: readonly string[] = process.argv.slice(2)): Promise<void> {
  const invocationArgs = [...args];
  const { command, flags, positional } = parseCliArgs(invocationArgs);

  if (isNestedHelpRequest(command, positional, flags)) {
    cmdHelp(helpPathFor(command, positional), flags.json === "true");
    return;
  }

  // These commands run before Storage to avoid creating default config prematurely
  if (command === "init") {
    await cmdInit(flags);
    return;
  }
  if (command === "update") {
    await cmdUpdate(flags);
    return;
  }
  if (command === "server") {
    cmdServer(positional[0], flags);
    return;
  }
  if (command === "version" || command === "--version" || command === "-v") {
    const info = getPackageInfo();
    console.log(`${info.name} ${info.version}`);
    return;
  }
  const dataDir = process.env.OPPI_DATA_DIR || undefined;
  const connection = createCliConnectionConfig(dataDir);

  switch (command) {
    case "serve":
    case "start":
      await cmdServe(new Storage(dataDir), flags.host);
      break;

    case "pair":
      await cmdPair(
        createCliConfigStorage(dataDir),
        positional[0],
        flags.host,
        flags["show-token"] === "true",
        flags.json === "true",
      );
      break;

    case "status":
    case "quota":
    case "models":
    case "agent":
    case "workspace":
    case "worktree":
    case "session":
    case "schedule":
    case "wait":
      await runCli(invocationArgs);
      break;

    case "doctor":
      cmdDoctor(connection, flags.host);
      break;

    case "token":
      await cmdToken(connection, positional[0]);
      break;

    case "devices":
      await cmdDevices(connection, positional[0], positional[1]);
      break;

    case "auth":
      await cmdAuth(connection, positional[0]);
      break;

    case "config":
      cmdConfig(createCliConfigStorage(dataDir), positional[0], positional.slice(1), flags);
      break;

    default:
      console.log(c.red(`Unknown command: ${command}`));
      console.log(c.dim("Run 'oppi help' for usage."));
      process.exit(1);
  }
}

if (import.meta.main) {
  runCliMain().catch((err) => {
    console.error(c.red("Fatal error:"), safeErrorMessage(err));
    process.exit(1);
  });
}
