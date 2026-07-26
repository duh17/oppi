/**
 * macOS launchd service management.
 *
 * Installs/uninstalls a per-user LaunchAgent that keeps the Oppi server
 * running in the background. The server survives app quits, terminal closes,
 * and reboots.
 *
 * Label: dev.chaosdonkey.oppi
 * Plist: ~/Library/LaunchAgents/dev.chaosdonkey.oppi.plist
 *
 * Key design decisions (learned from OpenClaw #40659):
 * - All paths in ProgramArguments are resolved to absolute paths at install time
 * - PATH env includes /opt/homebrew/bin so git, pi, tailscale are available
 * - KeepAlive restarts on crash; RunAtLoad starts on boot/login
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { execSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

const LABEL = "dev.chaosdonkey.oppi";
const LEGACY_LABELS = ["dev.chenda.oppi"] as const;

function uid(): number {
  const id = process.getuid?.();
  if (id === undefined) throw new Error("uid() not available (not macOS?)");
  return id;
}

function plistPathForLabel(label: string): string {
  return join(homedir(), "Library", "LaunchAgents", `${label}.plist`);
}

function plistPath(): string {
  return plistPathForLabel(LABEL);
}

function bootoutLabel(label: string): void {
  try {
    execSync(`launchctl bootout gui/${uid()}/${label} 2>/dev/null`, { stdio: "pipe" });
  } catch {
    // Not loaded — fine.
  }
}

function bootoutPlist(path: string): void {
  try {
    execSync(`launchctl bootout gui/${uid()} ${path} 2>/dev/null`, { stdio: "pipe" });
  } catch {
    // Not loaded — fine.
  }
}

function disableLegacyLaunchAgents(): string[] {
  const removed: string[] = [];

  for (const legacyLabel of LEGACY_LABELS) {
    const legacyPlist = plistPathForLabel(legacyLabel);
    bootoutLabel(legacyLabel);

    if (!existsSync(legacyPlist)) {
      continue;
    }

    bootoutPlist(legacyPlist);
    unlinkSync(legacyPlist);
    removed.push(legacyPlist);
  }

  return removed;
}

export interface LaunchdStatus {
  installed: boolean;
  running: boolean;
  pid: number | null;
  plistPath: string;
  label: string;
}

type SemanticVersion = {
  major: number;
  minor: number;
  patch: number;
};

function parseSemanticVersion(raw: string): SemanticVersion | null {
  const normalized = raw.trim().replace(/^[vV]/, "");
  const match = normalized.match(/^(\d+)(?:\.(\d+))?(?:\.(\d+))?/);
  if (!match) {
    return null;
  }
  return {
    major: Number(match[1]),
    minor: Number(match[2] || 0),
    patch: Number(match[3] || 0),
  };
}

function compareSemanticVersion(left: SemanticVersion, right: SemanticVersion): number {
  if (left.major !== right.major) return left.major - right.major;
  if (left.minor !== right.minor) return left.minor - right.minor;
  return left.patch - right.patch;
}

function formatSemanticVersion(version: SemanticVersion): string {
  return `${version.major}.${version.minor}.${version.patch}`;
}

function packageJsonPathForCli(cliPath: string): string {
  let packageCliPath = cliPath;
  try {
    packageCliPath = realpathSync(cliPath);
  } catch {
    // Keep the original path when it is not a symlink or cannot be resolved.
  }
  return resolve(packageCliPath, "..", "..", "..", "package.json");
}

function minimumRequiredNodeVersion(cliPath?: string | null): SemanticVersion | null {
  if (!cliPath) {
    return null;
  }

  try {
    const content = readFileSync(packageJsonPathForCli(cliPath), "utf-8");
    const parsed = JSON.parse(content) as { engines?: { node?: string } };
    const range = parsed.engines?.node?.trim();
    if (!range) {
      return null;
    }
    const match = range.match(/>=\s*([0-9]+(?:\.[0-9]+){0,2})/);
    return match ? parseSemanticVersion(match[1]) : null;
  } catch {
    return null;
  }
}

function installedNodeVersion(nodePath: string): SemanticVersion | null {
  try {
    const output = execSync(`"${nodePath}" --version`, {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    return parseSemanticVersion(output);
  } catch {
    return null;
  }
}

function runtimeCompatibilityIssue(nodePath: string, cliPath?: string | null): string | null {
  const minimum = minimumRequiredNodeVersion(cliPath);
  if (!minimum) {
    return null;
  }
  const installed = installedNodeVersion(nodePath);
  if (!installed) {
    return `Could not read Node.js version at ${nodePath}`;
  }
  if (compareSemanticVersion(installed, minimum) < 0) {
    return `Node.js ${formatSemanticVersion(installed)} found, but Oppi requires Node.js ${formatSemanticVersion(minimum)} or newer`;
  }
  return null;
}

/**
 * Resolve the absolute path to the Node.js runtime.
 *
 * Search order:
 * 1. Homebrew Node.js
 * 2. /usr/local Node.js
 * 3. System Node.js
 */
function resolveRuntimeAbsolute(cliPath?: string | null): string | null {
  const nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"];
  for (const p of nodeCandidates) {
    if (existsSync(p) && !runtimeCompatibilityIssue(p, cliPath)) return p;
  }
  return null;
}

function runtimeResolutionFailureMessage(cliPath?: string | null): string {
  const minimum = minimumRequiredNodeVersion(cliPath);
  const nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"];

  for (const path of nodeCandidates) {
    if (!existsSync(path)) continue;
    return runtimeCompatibilityIssue(path, cliPath) || "Node.js runtime unavailable";
  }

  if (minimum) {
    return `Node.js ${formatSemanticVersion(minimum)} or newer not found. Install Node.js and try again.`;
  }
  return "Node.js not found. Install Node.js and try again.";
}

/**
 * Resolve the absolute path to the server CLI entry point.
 *
 * Search order:
 * 1. The CLI that's currently running, including npm bin symlinks
 * 2. npm global fallback locations
 */
function resolveCurrentCLIAbsolute(): string | null {
  const selfCLI = process.argv[1];
  if (!selfCLI || !existsSync(selfCLI)) return null;

  // Preserve npm's public bin path instead of collapsing it to node_modules.
  // The server then knows the exact directory that supplies `oppi` to humans
  // and can keep that directory first for managed host-session tools.
  if (basename(selfCLI) === "oppi" || selfCLI.endsWith("cli.js")) {
    return resolve(selfCLI);
  }

  try {
    const resolvedCLI = realpathSync(selfCLI);
    return resolvedCLI.endsWith("cli.js") ? resolve(resolvedCLI) : null;
  } catch {
    return null;
  }
}

function resolveCLIAbsolute(): string | null {
  const currentCLI = resolveCurrentCLIAbsolute();
  if (currentCLI) return currentCLI;

  const globalCandidates = [
    "/opt/homebrew/bin/oppi",
    "/usr/local/bin/oppi",
    join(homedir(), ".npm", "bin", "oppi"),
    "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js",
    "/usr/local/lib/node_modules/oppi-server/dist/src/cli.js",
    join(homedir(), ".npm", "lib", "node_modules", "oppi-server", "dist", "src", "cli.js"),
  ];
  for (const p of globalCandidates) {
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
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>OPPI_DATA_DIR</key>
        <string>${dataDir}</string>
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
  legacyRemoved?: string[];
} {
  const cliPath = resolveCLIAbsolute();
  const runtimePath = resolveRuntimeAbsolute(cliPath);
  if (!runtimePath) {
    return {
      ok: false,
      message: runtimeResolutionFailureMessage(cliPath),
    };
  }

  if (!cliPath) {
    return {
      ok: false,
      message: "Oppi CLI not found. Run 'npm install -g oppi-server' and try again.",
    };
  }

  const resolvedDataDir = dataDir || join(homedir(), ".config", "oppi");
  const plist = plistPath();
  const launchAgentsDir = join(homedir(), "Library", "LaunchAgents");
  let legacyRemoved: string[];

  try {
    legacyRemoved = disableLegacyLaunchAgents();
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      ok: false,
      message: `Failed to disable legacy LaunchAgent: ${msg}`,
      runtimePath,
      cliPath,
    };
  }

  // Unload existing if present
  if (existsSync(plist)) {
    bootoutPlist(plist);
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
    legacyRemoved,
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
