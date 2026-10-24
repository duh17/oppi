/**
 * Linux systemd user-service management, the Linux counterpart of launchd.ts.
 *
 * Installs a per-user unit that keeps the Oppi server running in the background
 * and restarts it after a crash. No root: the unit lives in the user's own
 * systemd instance (`systemctl --user`).
 *
 * Unit: $XDG_CONFIG_HOME/systemd/user/oppi.service (default ~/.config/systemd/user)
 *
 * - ExecStart names the Node runtime and CLI by absolute path, resolved the same
 *   way as the LaunchAgent (launchd.ts `resolveServiceProgram`).
 * - Restart=on-failure mirrors the LaunchAgent's KeepAlive SuccessfulExit=false:
 *   a crash or the update path's exit(1) restarts; a clean stop does not.
 * - A user manager normally stops when the user's last session ends. Lingering
 *   (`loginctl enable-linger`) keeps it, and so Oppi, running across logouts
 *   and starting at boot. Enabling it can need an admin; install reports that
 *   instead of failing, because the service still works while logged in.
 * - Output goes to the journal: `journalctl --user -u oppi`.
 */

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { dirname, isAbsolute, join } from "node:path";

import { resolveServiceProgram } from "./launchd.js";
import { clearServerStopRequest, requestServerStop } from "./server-stop-marker.js";

const UNIT = "oppi.service";
const SERVICE_PATH = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/** Where the user's systemd instance reads `oppi.service`. */
export function systemdUnitPath(
  env: NodeJS.ProcessEnv = process.env,
  home: string = homedir(),
): string {
  const configHome = env.XDG_CONFIG_HOME;
  const base = configHome && isAbsolute(configHome) ? configHome : join(home, ".config");
  return join(base, "systemd", "user", UNIT);
}

/**
 * One ExecStart or Environment word: double-quoted, with backslash and quote
 * escaped and `%` doubled (systemd specifiers). ExecStart also expands `$NAME`,
 * so there `$` is doubled; Environment= does not. A line break cannot be
 * expressed and is refused.
 */
function quoteUnitWord(value: string, context: "exec" | "environment"): string {
  if (/[\n\r]/.test(value)) {
    throw new Error(`systemd unit value contains a line break: ${JSON.stringify(value)}`);
  }
  const escaped = value.replace(/[\\"%$]/g, (ch) => {
    if (ch === "%") return "%%";
    if (ch === "$") return context === "exec" ? "$$" : "$";
    return `\\${ch}`;
  });
  return `"${escaped}"`;
}

export function buildSystemdUnit(
  runtimePath: string,
  cliPath: string,
  dataDir: string,
  installerNode?: string,
): string {
  // The service PATH only matters until the server applies its configured
  // runtime PATH; the Node directory comes first so `#!/usr/bin/env node`
  // scripts started that early find the same runtime.
  const path = [dirname(runtimePath), ...SERVICE_PATH.split(":")]
    .filter((entry, index, all) => all.indexOf(entry) === index)
    .join(":");
  const execStart = [runtimePath, cliPath, "serve", "--data-dir", dataDir]
    .map((word) => quoteUnitWord(word, "exec"))
    .join(" ");
  // host-env.ts appends its directory to the session PATH.
  const installerNodeEnv = installerNode
    ? `\nEnvironment=${quoteUnitWord(`OPPI_NODE=${installerNode}`, "environment")}`
    : "";
  return `# Written by \`oppi server install\`; reinstalling rewrites this file.
[Unit]
Description=Oppi server
Documentation=https://github.com/duh17/oppi/blob/main/docs/onboarding.md

[Service]
Type=simple
ExecStart=${execStart}
WorkingDirectory=~
Environment=${quoteUnitWord(`PATH=${path}`, "environment")}
Environment=${quoteUnitWord(`OPPI_DATA_DIR=${dataDir}`, "environment")}${installerNodeEnv}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
`;
}

/** Split an ExecStart value written by `quoteUnitWord` back into its words. */
function splitUnitWords(value: string): string[] {
  const words: string[] = [];
  let i = 0;
  while (i < value.length) {
    while (value[i] === " ") i++;
    if (i >= value.length) break;
    let word = "";
    const quoted = value[i] === '"';
    if (quoted) i++;
    while (i < value.length && (quoted ? value[i] !== '"' : value[i] !== " ")) {
      const ch = value[i];
      const next = value[i + 1];
      if (ch === "\\" && next !== undefined) {
        word += next;
        i += 2;
      } else if ((ch === "%" || ch === "$") && next === ch) {
        word += ch;
        i += 2;
      } else {
        word += ch;
        i++;
      }
    }
    if (quoted) i++;
    words.push(word);
  }
  return words;
}

/** Runtime, CLI, and data dir from a unit this module wrote. */
export function parseSystemdUnit(
  content: string,
): { runtimePath: string; cliPath: string; dataDir: string } | null {
  const line = content.split("\n").find((l) => l.startsWith("ExecStart="));
  if (!line) return null;
  const words = splitUnitWords(line.slice("ExecStart=".length));
  // [runtimePath, cliPath, "serve", "--data-dir", dataDir]
  if (words.length < 5 || words[2] !== "serve" || words[3] !== "--data-dir") return null;
  return { runtimePath: words[0], cliPath: words[1], dataDir: words[4] };
}

/**
 * Environment for `systemctl --user`. A non-login SSH command can arrive
 * without XDG_RUNTIME_DIR, and systemctl then cannot find the user bus even
 * though the user manager is running.
 */
function userManagerEnv(): NodeJS.ProcessEnv {
  if (process.env.XDG_RUNTIME_DIR) return process.env;
  const runtimeDir = `/run/user/${process.getuid?.() ?? ""}`;
  return existsSync(runtimeDir) ? { ...process.env, XDG_RUNTIME_DIR: runtimeDir } : process.env;
}

function run(command: string, args: string[]): string {
  return execFileSync(command, args, {
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
    env: userManagerEnv(),
  });
}

function systemctl(...args: string[]): string {
  return run("systemctl", ["--user", ...args]);
}

function errorMessage(err: unknown): string {
  if (typeof err === "object" && err !== null && "stderr" in err) {
    const stderr = String((err as { stderr: unknown }).stderr ?? "").trim();
    if (stderr) return stderr.split("\n")[0];
  }
  return err instanceof Error ? err.message : String(err);
}

/** Null when `systemctl --user` reaches a user manager; otherwise why not. */
function userManagerIssue(): string | null {
  try {
    systemctl("show-environment");
    return null;
  } catch (err: unknown) {
    return `systemd user manager unavailable (${errorMessage(err)}). Run 'oppi serve' under your own supervisor instead.`;
  }
}

function lingerEnabled(): boolean | null {
  try {
    const user = userInfo().username;
    return run("loginctl", ["show-user", user, "--property=Linger", "--value"]).trim() === "yes";
  } catch {
    return null;
  }
}

/** Keep the user manager (and Oppi) running without a login session. */
function ensureLinger(): string | undefined {
  if (lingerEnabled()) return undefined;
  try {
    run("loginctl", ["enable-linger"]);
  } catch {
    // Reported below.
  }
  if (lingerEnabled()) return undefined;
  const user = userInfo().username;
  return `Oppi stops when you log out until an admin runs: sudo loginctl enable-linger ${user}`;
}

export interface SystemdStatus {
  installed: boolean;
  running: boolean;
  pid: number | null;
  unitPath: string;
  unit: string;
  /** Null when loginctl could not say. */
  linger: boolean | null;
}

export function installService(dataDir?: string): {
  ok: boolean;
  message: string;
  runtimePath?: string;
  cliPath?: string;
  /** Set when the service runs only while the user is logged in. */
  lingerNote?: string;
} {
  const program = resolveServiceProgram();
  if (!program.ok) return { ok: false, message: program.message };
  const { runtimePath, cliPath } = program;

  const managerIssue = userManagerIssue();
  if (managerIssue) return { ok: false, message: managerIssue, runtimePath, cliPath };

  const resolvedDataDir = dataDir || join(homedir(), ".config", "oppi");
  const unitPath = systemdUnitPath();
  try {
    const unit = buildSystemdUnit(runtimePath, cliPath, resolvedDataDir, program.installerNode);
    mkdirSync(dirname(unitPath), { recursive: true });
    writeFileSync(unitPath, unit, { mode: 0o644 });
    systemctl("daemon-reload");
    systemctl("enable", UNIT);
    // restart, not start: a reinstall must pick up a new runtime, CLI, or version.
    systemctl("restart", UNIT);
  } catch (err: unknown) {
    return {
      ok: false,
      message: `Failed to install ${UNIT}: ${errorMessage(err)}`,
      runtimePath,
      cliPath,
    };
  }

  return {
    ok: true,
    message: `systemd user service ${UNIT} installed and started`,
    runtimePath,
    cliPath,
    lingerNote: ensureLinger(),
  };
}

function isActive(): boolean {
  try {
    return systemctl("is-active", UNIT).trim() === "active";
  } catch {
    // is-active exits non-zero for inactive, failed, and unknown units.
    return false;
  }
}

export function uninstallService(): { ok: boolean; message: string } {
  const unitPath = systemdUnitPath();
  if (!existsSync(unitPath)) {
    return { ok: true, message: `${UNIT} not installed (nothing to remove)` };
  }
  const managerIssue = userManagerIssue();
  if (managerIssue) return { ok: false, message: managerIssue };

  // An explicit stop, not a restart: the server ends away phones' Live Activity cards.
  const stopRequestDir = isActive() ? readInstalledUnit()?.dataDir : undefined;
  if (stopRequestDir) requestServerStop(stopRequestDir);
  try {
    systemctl("disable", "--now", UNIT);
  } catch (err: unknown) {
    if (stopRequestDir) clearServerStopRequest(stopRequestDir);
    return { ok: false, message: `Failed to stop ${UNIT}: ${errorMessage(err)}` };
  }
  try {
    unlinkSync(unitPath);
    systemctl("daemon-reload");
  } catch (err: unknown) {
    return { ok: false, message: `Failed to remove ${unitPath}: ${errorMessage(err)}` };
  }
  return { ok: true, message: `${UNIT} uninstalled` };
}

export function restartService(): { ok: boolean; message: string } {
  if (!existsSync(systemdUnitPath())) {
    return { ok: false, message: `${UNIT} not installed. Run 'oppi server install' first.` };
  }
  try {
    systemctl("restart", UNIT);
    return { ok: true, message: "Service restarted" };
  } catch (err: unknown) {
    return { ok: false, message: `Restart failed: ${errorMessage(err)}` };
  }
}

/** Stop until the next boot (with linger), login, or `oppi server restart`. */
export function stopService(): { ok: boolean; message: string } {
  if (!existsSync(systemdUnitPath())) {
    return { ok: false, message: `${UNIT} not installed.` };
  }
  if (!isActive()) return { ok: true, message: "Service was not running" };

  const stopRequestDir = readInstalledUnit()?.dataDir;
  if (stopRequestDir) requestServerStop(stopRequestDir);
  try {
    systemctl("stop", UNIT);
  } catch (err: unknown) {
    if (stopRequestDir) clearServerStopRequest(stopRequestDir);
    return { ok: false, message: `Stop failed: ${errorMessage(err)}` };
  }
  return {
    ok: true,
    message: "Service stopped (starts again at next boot or login, or with 'oppi server restart')",
  };
}

export function getServiceStatus(): SystemdStatus {
  const unitPath = systemdUnitPath();
  let running = false;
  let pid: number | null = null;
  try {
    const output = systemctl("show", UNIT, "--property=ActiveState", "--property=MainPID");
    const values = new Map(
      output
        .split("\n")
        .map((line) => line.split("=", 2) as [string, string | undefined])
        .filter((pair): pair is [string, string] => pair[1] !== undefined),
    );
    const mainPid = Number(values.get("MainPID"));
    running = values.get("ActiveState") === "active";
    pid = running && mainPid > 0 ? mainPid : null;
  } catch {
    // No user manager: report the unit file only.
  }
  return {
    installed: existsSync(unitPath),
    running,
    pid,
    unitPath,
    unit: UNIT,
    linger: lingerEnabled(),
  };
}

export function readInstalledUnit(): {
  runtimePath: string;
  cliPath: string;
  dataDir: string;
} | null {
  const unitPath = systemdUnitPath();
  if (!existsSync(unitPath)) return null;
  try {
    return parseSystemdUnit(readFileSync(unitPath, "utf-8"));
  } catch {
    return null;
  }
}
