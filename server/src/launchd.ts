/**
 * macOS launchd service management.
 *
 * Installs/uninstalls a per-user LaunchAgent that keeps the Oppi server
 * running in the background. The server survives app quits, terminal closes,
 * and reboots.
 *
 * Label: dev.chenda.oppi
 * Plist: ~/Library/LaunchAgents/dev.chenda.oppi.plist
 *
 * Key design decisions (learned from OpenClaw #40659):
 * - All paths in ProgramArguments are resolved to absolute paths at install time
 * - PATH env includes /opt/homebrew/bin so git, pi, tailscale are available
 * - KeepAlive restarts on crash; RunAtLoad starts on boot/login
 */

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const LABEL = "dev.chenda.oppi";

function uid(): number {
  const id = process.getuid?.();
  if (id === undefined) throw new Error("uid() not available (not macOS?)");
  return id;
}

function plistPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${LABEL}.plist`);
}

export interface LaunchdStatus {
  installed: boolean;
  running: boolean;
  pid: number | null;
  plistPath: string;
  label: string;
}

/**
 * Resolve the absolute path to the JS runtime (Bun preferred, Node fallback).
 *
 * Search order:
 * 1. Bundled Bun in the Mac app (if installed from DMG)
 * 2. System Bun (Homebrew, ~/.bun)
 * 3. System Node.js (Homebrew, /usr/local)
 */
function resolveRuntimeAbsolute(): string | null {
  // Bundled Bun from DMG install
  const bundledBun = "/Applications/Oppi.app/Contents/Resources/bun";
  if (existsSync(bundledBun)) return bundledBun;

  // System Bun
  const bunCandidates = [
    "/opt/homebrew/bin/bun",
    "/usr/local/bin/bun",
    join(homedir(), ".bun", "bin", "bun"),
  ];
  for (const p of bunCandidates) {
    if (existsSync(p)) return p;
  }

  // Node.js fallback
  const nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"];
  for (const p of nodeCandidates) {
    if (existsSync(p)) return p;
  }

  return null;
}

/**
 * Resolve the absolute path to the server CLI entry point.
 *
 * Search order:
 * 1. Mutable runtime dir (seeded from DMG)
 * 2. App bundle seed (direct)
 * 3. Homebrew global
 */
function resolveCLIAbsolute(): string | null {
  const runtimeCLI = join(homedir(), ".config", "oppi", "server-runtime", "dist", "src", "cli.js");
  if (existsSync(runtimeCLI)) return runtimeCLI;

  const seedCLI = "/Applications/Oppi.app/Contents/Resources/server-seed/dist/src/cli.js";
  if (existsSync(seedCLI)) return seedCLI;

  const brewCandidates = [
    "/opt/homebrew/lib/node_modules/@anthropic-ai/oppi/dist/src/cli.js",
    "/usr/local/lib/node_modules/@anthropic-ai/oppi/dist/src/cli.js",
  ];
  for (const p of brewCandidates) {
    if (existsSync(p)) return p;
  }

  return null;
}

function buildPlistXML(runtimePath: string, cliPath: string, dataDir: string): string {
  const logPath = join(dataDir, "server.log");

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${runtimePath}</string>
        <string>${cliPath}</string>
        <string>serve</string>
        <string>--data-dir</string>
        <string>${dataDir}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${homedir()}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${homedir()}/.bun/bin</string>
        <key>OPPI_DATA_DIR</key>
        <string>${dataDir}</string>
        <key>OPPI_RUNTIME_BIN</key>
        <string>${runtimePath}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${logPath}</string>
    <key>StandardErrorPath</key>
    <string>${logPath}</string>
    <key>ProcessType</key>
    <string>Standard</string>
</dict>
</plist>`;
}

/**
 * Install the LaunchAgent plist and load it.
 *
 * Returns a human-readable status message.
 */
export function installService(dataDir?: string): {
  ok: boolean;
  message: string;
  runtimePath?: string;
  cliPath?: string;
} {
  const runtimePath = resolveRuntimeAbsolute();
  if (!runtimePath) {
    return {
      ok: false,
      message: "No JS runtime found (Bun or Node.js). Install Bun: brew install oven-sh/bun/bun",
    };
  }

  const cliPath = resolveCLIAbsolute();
  if (!cliPath) {
    return {
      ok: false,
      message:
        "Server CLI not found. Install the Mac app (DMG) or run 'oppi init' from the repo first.",
    };
  }

  const resolvedDataDir = dataDir || join(homedir(), ".config", "oppi");
  const plist = plistPath();
  const launchAgentsDir = join(homedir(), "Library", "LaunchAgents");

  // Unload existing if present
  if (existsSync(plist)) {
    try {
      execSync(`launchctl bootout gui/${uid()} ${plist} 2>/dev/null`, {
        stdio: "pipe",
      });
    } catch {
      // May not be loaded — that's fine
    }
  }

  // Ensure LaunchAgents directory exists
  mkdirSync(launchAgentsDir, { recursive: true });

  // Write plist
  const xml = buildPlistXML(runtimePath, cliPath, resolvedDataDir);
  writeFileSync(plist, xml, { mode: 0o644 });

  // Load the service
  try {
    execSync(`launchctl bootstrap gui/${uid()} ${plist}`, {
      stdio: "pipe",
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    // Error 37 = already loaded — that's fine, just restart
    if (msg.includes("37")) {
      try {
        execSync(`launchctl kickstart -k gui/${uid()}/${LABEL}`, { stdio: "pipe" });
      } catch {
        // Ignore restart failure
      }
    } else {
      return { ok: false, message: `Failed to load LaunchAgent: ${msg}`, runtimePath, cliPath };
    }
  }

  return {
    ok: true,
    message: `LaunchAgent installed and started`,
    runtimePath,
    cliPath,
  };
}

/**
 * Uninstall the LaunchAgent — stop the service and remove the plist.
 */
export function uninstallService(): { ok: boolean; message: string } {
  const plist = plistPath();

  if (!existsSync(plist)) {
    return { ok: true, message: "LaunchAgent not installed (nothing to remove)" };
  }

  // Unload
  try {
    execSync(`launchctl bootout gui/${uid()} ${plist}`, { stdio: "pipe" });
  } catch {
    // May already be unloaded
  }

  // Remove plist
  try {
    unlinkSync(plist);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return { ok: false, message: `Failed to remove plist: ${msg}` };
  }

  return { ok: true, message: "LaunchAgent uninstalled" };
}

/**
 * Restart the service via launchctl kickstart.
 */
export function restartService(): { ok: boolean; message: string } {
  const plist = plistPath();
  if (!existsSync(plist)) {
    return { ok: false, message: "LaunchAgent not installed. Run 'oppi server install' first." };
  }

  try {
    execSync(`launchctl kickstart -k gui/${uid()}/${LABEL}`, { stdio: "pipe" });
    return { ok: true, message: "Service restarted" };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return { ok: false, message: `Restart failed: ${msg}` };
  }
}

/**
 * Stop the service (it will NOT auto-restart due to KeepAlive config).
 *
 * To fully stop, we bootout which unloads the job. The plist remains
 * on disk so a subsequent `server install` or reboot re-loads it.
 */
export function stopService(): { ok: boolean; message: string } {
  const plist = plistPath();
  if (!existsSync(plist)) {
    return { ok: false, message: "LaunchAgent not installed." };
  }

  try {
    execSync(`launchctl bootout gui/${uid()}/${LABEL}`, { stdio: "pipe" });
    return {
      ok: true,
      message: "Service stopped (will start again on next login or 'oppi server install')",
    };
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("No such process") || msg.includes("Could not find")) {
      return { ok: true, message: "Service was not running" };
    }
    return { ok: false, message: `Stop failed: ${msg}` };
  }
}

/**
 * Check whether the LaunchAgent is installed and running.
 */
export function getServiceStatus(): LaunchdStatus {
  const plist = plistPath();
  const installed = existsSync(plist);
  let running = false;
  let pid: number | null = null;

  if (installed) {
    try {
      const output = execSync(`launchctl print gui/${uid()}/${LABEL} 2>/dev/null`, {
        encoding: "utf-8",
        stdio: ["pipe", "pipe", "pipe"],
      });

      // Parse PID from launchctl print output
      const pidMatch = output.match(/pid\s*=\s*(\d+)/);
      if (pidMatch) {
        pid = parseInt(pidMatch[1]);
        running = pid > 0;
      }

      // Also check "state = running"
      if (output.includes("state = running")) {
        running = true;
      }
    } catch {
      // Service not loaded
    }
  }

  return { installed, running, pid, plistPath: plist, label: LABEL };
}

/**
 * Read key paths from an installed plist (for display/diagnostics).
 */
export function readInstalledPlist(): {
  runtimePath: string;
  cliPath: string;
  dataDir: string;
} | null {
  const plist = plistPath();
  if (!existsSync(plist)) return null;

  try {
    const content = readFileSync(plist, "utf-8");
    const args =
      content.match(/<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/)?.[1] || "";
    const strings = [...args.matchAll(/<string>(.*?)<\/string>/g)].map((m) => m[1]);

    // ProgramArguments: [runtimePath, cliPath, "serve", "--data-dir", dataDir]
    if (strings.length >= 5) {
      return {
        runtimePath: strings[0],
        cliPath: strings[1],
        dataDir: strings[4],
      };
    }
  } catch {
    // Ignore parse errors
  }
  return null;
}
