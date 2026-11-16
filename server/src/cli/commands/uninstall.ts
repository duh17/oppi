/**
 * `oppi uninstall`: removes what installing and running Oppi added outside its data folder, then
 * the data folder itself when the owner says so. `oppi server uninstall` stays the service only.
 *
 * What it removes, and how it knows each one is Oppi's:
 * - The background service (LaunchAgent or systemd unit) and a server install.sh started without
 *   one (`~/.oppi/serve.pid`, checked against the process's command line).
 * - Linux lingering, only when `linger-enabled-by-oppi` in the data folder says Oppi turned it on.
 * - Oppi's Auto-Name entry in Pi's `settings.json` (a source path an Oppi install ships).
 * - The PATH line install.sh added to a shell profile: the line after its marker comment, when it
 *   is still the line install.sh writes. A profile install.sh created and that is empty after this
 *   is deleted, and so are directories it created that are now empty
 *   (`~/.oppi/install/created`).
 * - `~/.local/bin/oppi` when it links to `~/.oppi/bin/oppi`, then `~/.oppi`.
 * - The data folder (chats, settings, pairing), after a question or `--delete-data`.
 *
 * Everything else, an npm global install included, is the owner's; the command says what is left.
 */
import { execFileSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readFileSync,
  readlinkSync,
  rmdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { createInterface } from "node:readline";

import * as c from "../../ansi.js";
import { isManagedInstall } from "../../install-kind.js";
import { packageRootDir } from "../../version.js";
import { requestServerStop } from "../../server-stop-marker.js";
import { createCliConnectionConfig } from "../connection-config.js";
import { localApiRequest } from "../local-api-client.js";
import { setCapturedCliExitCode, writeHumanLine } from "../output.js";

/** install.sh writes this comment above each PATH line it adds (`ensure_on_login_path`). */
export const PROFILE_MARKER = "# Added by the Oppi installer";

/** The PATH lines install.sh writes after the marker, and nothing a person wrote by hand. */
const INSTALLER_PATH_LINE = /^(export PATH="[^"]*:\$PATH"|fish_add_path -g "[^"]*")$/;

/**
 * `text` without the marker and PATH line install.sh appended, each time it appears. The blank
 * line install.sh wrote before the marker goes too. A marker whose next line is not the one
 * install.sh writes is left alone: someone edited it, so it is theirs now.
 */
export function removeInstallerPathLines(text: string): { text: string; removed: number } {
  const lines = text.split("\n");
  let removed = 0;
  for (let index = lines.length - 1; index >= 0; index--) {
    if (lines[index] !== PROFILE_MARKER || !INSTALLER_PATH_LINE.test(lines[index + 1] ?? "")) {
      continue;
    }
    const start = index > 0 && lines[index - 1] === "" ? index - 1 : index;
    lines.splice(start, index + 2 - start);
    removed++;
  }
  return { text: lines.join("\n"), removed };
}

/** Every profile install.sh may have written (`profile_file`), whatever the shell is now. */
export function profileCandidates(home: string, env: NodeJS.ProcessEnv = process.env): string[] {
  const zdotdir = env.ZDOTDIR?.trim();
  return [
    ...new Set([
      join(zdotdir || home, ".zprofile"),
      join(home, ".zprofile"),
      join(home, ".bash_profile"),
      join(home, ".bash_login"),
      join(home, ".profile"),
      join(home, ".config", "fish", "conf.d", "oppi.fish"),
    ]),
  ];
}

interface Step {
  ok: boolean;
  message: string;
}

export async function cmdUninstall(flags: Record<string, string>): Promise<void> {
  const deleteData = flags["delete-data"] === "true";
  const keepData = flags["keep-data"] === "true";
  if (deleteData && keepData) {
    writeHumanLine(c.red("  Error: choose one of --delete-data and --keep-data."));
    setCapturedCliExitCode(1);
    return;
  }

  // Everything this command loads is loaded before it deletes ~/.oppi, which may be its own code.
  // An npm package outside the installer's releases stays: npm put it there. Told from the path,
  // not by running npm, which would write its logs into ~/.npm.
  const packageDir = packageRootDir();
  const npmPackage =
    packageDir !== undefined &&
    packageDir.includes(`${sep}node_modules${sep}`) &&
    !isManagedInstall(packageDir);
  const home = homedir();
  const oppiHome = join(home, ".oppi");
  const systemd = process.platform === "linux" ? await import("../../systemd.js") : undefined;
  const launchd = process.platform === "darwin" ? await import("../../launchd.js") : undefined;
  const service = systemd ?? launchd;
  // The service this home installed. A job loaded without that file is another home's or the
  // Mac app's (same user, same launchd label), and stays.
  const serviceFile = systemd?.systemdUnitPath() ?? launchd?.plistPath();
  const installed = systemd?.readInstalledUnit() ?? launchd?.readInstalledPlist() ?? null;
  // The service's data folder, else the one every other command uses.
  const dataDir = resolve(
    dirname(createCliConnectionConfig(installed?.dataDir || undefined).getConfigPath()),
  );

  writeHumanLine(c.bold("  Uninstalling Oppi"));
  writeHumanLine("");
  const steps: Step[] = [];
  const report = (step: Step | null): void => {
    if (!step) return;
    steps.push(step);
    writeHumanLine(
      step.ok ? c.green(`  \u2713 ${step.message}`) : c.red(`  \u2717 ${step.message}`),
    );
  };

  // Nothing is removed while a server still runs: it would write into a folder being deleted.
  if (service && serviceFile && existsSync(serviceFile)) {
    const result = service.uninstallService();
    report(result);
    if (!result.ok) return finish(steps);
  }
  report(await stopInstallerServer(oppiHome, dataDir));
  const running = await ownerSocketPid(dataDir);
  if (running !== null) {
    report({
      ok: false,
      message: `An Oppi server is still running on ${dataDir} (pid ${running}). Stop it, then run 'oppi uninstall' again.`,
    });
    return finish(steps);
  }

  if (systemd) report(systemd.undoLinger(dataDir));
  report(await removePiEntry());
  const created = readCreated(oppiHome);
  for (const profile of profileCandidates(home)) report(cleanProfile(profile, created));
  report(removeLink(join(home, ".local", "bin", "oppi"), join(oppiHome, "bin", "oppi")));

  if (await shouldDeleteData(dataDir, { deleteData, keepData }, home)) {
    rmSync(dataDir, { recursive: true, force: true });
    report({ ok: true, message: `Removed the data folder ${dataDir}` });
  } else if (existsSync(dataDir)) {
    writeHumanLine(c.dim(`  Kept the data folder ${dataDir} (chats, settings, pairing).`));
  }

  // Last: this command may be running from it.
  if (existsSync(oppiHome)) {
    rmSync(oppiHome, { recursive: true, force: true });
    report({ ok: true, message: `Removed ${oppiHome}` });
  }
  removeCreatedDirs(created);

  if (npmPackage) {
    writeHumanLine("");
    writeHumanLine(
      c.dim(
        `  This oppi came from npm (${packageDir}). Remove it with: npm uninstall -g oppi-server`,
      ),
    );
  }
  finish(steps);
}

function finish(steps: Step[]): void {
  writeHumanLine("");
  if (steps.some((step) => !step.ok)) setCapturedCliExitCode(1);
}

/** The server install.sh started without a service, when serve.pid still names it. */
async function stopInstallerServer(oppiHome: string, dataDir: string): Promise<Step | null> {
  const pidFile = join(oppiHome, "serve.pid");
  if (!existsSync(pidFile)) return null;
  const pid = Number(readFileSync(pidFile, "utf8").trim());
  unlinkSync(pidFile);
  if (!Number.isInteger(pid) || pid <= 0) return null;
  let command: string;
  try {
    command = execFileSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" });
  } catch {
    return null; // Not running.
  }
  // A reused pid runs something else; only install.sh's own server is stopped.
  if (!command.includes(join(oppiHome, "install") + "/") || !/ serve\b/.test(command)) return null;
  requestServerStop(dataDir);
  process.kill(pid, "SIGTERM");
  for (let waited = 0; waited < 100 && alive(pid); waited++) {
    await new Promise((done) => setTimeout(done, 100));
  }
  return alive(pid)
    ? { ok: false, message: `The Oppi server (pid ${pid}) did not stop` }
    : { ok: true, message: `Stopped the Oppi server install.sh started (pid ${pid})` };
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** The pid of a server on this data folder's owner socket, or null when nothing answers. */
async function ownerSocketPid(dataDir: string): Promise<number | null> {
  try {
    const info = await localApiRequest<{ process?: { pid?: number } }>(
      createCliConnectionConfig(dataDir),
      "/server/info",
      { signal: AbortSignal.timeout(5_000) },
    );
    return typeof info.process?.pid === "number" ? info.process.pid : null;
  } catch {
    return null;
  }
}

async function removePiEntry(): Promise<Step | null> {
  const { getAgentDir } = await import("@earendil-works/pi-coding-agent");
  const agentDir = getAgentDir();
  if (!existsSync(join(agentDir, "settings.json"))) return null;
  const { removeShippedAutoName } = await import("../../auto-name-package.js");
  try {
    return (await removeShippedAutoName(agentDir))
      ? {
          ok: true,
          message: `Removed Oppi's Auto-Name entry from ${join(agentDir, "settings.json")}`,
        }
      : null;
  } catch (error) {
    return {
      ok: false,
      message: `Could not edit ${join(agentDir, "settings.json")}: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

/** Paths install.sh created (`~/.oppi/install/created`), deepest first. */
function readCreated(oppiHome: string): string[] {
  try {
    return readFileSync(join(oppiHome, "install", "created"), "utf8")
      .split("\n")
      .filter((line) => line.startsWith("/"));
  } catch {
    return [];
  }
}

function cleanProfile(profile: string, created: readonly string[]): Step | null {
  let text: string;
  try {
    text = readFileSync(profile, "utf8");
  } catch {
    return null;
  }
  const cleaned = removeInstallerPathLines(text);
  if (cleaned.removed === 0) return null;
  if (created.includes(profile) && cleaned.text.trim() === "") {
    unlinkSync(profile);
    return { ok: true, message: `Removed ${profile}, which only held Oppi's PATH line` };
  }
  writeFileSync(profile, cleaned.text, { mode: statSync(profile).mode & 0o7777 });
  return { ok: true, message: `Removed the PATH line Oppi added to ${profile}` };
}

function removeLink(link: string, target: string): Step | null {
  try {
    if (!lstatSync(link).isSymbolicLink() || readlinkSync(link) !== target) return null;
  } catch {
    return null;
  }
  unlinkSync(link);
  return { ok: true, message: `Removed the link ${link}` };
}

/** Directories install.sh created, when nothing else lives in them now. */
function removeCreatedDirs(created: readonly string[]): void {
  for (const path of created) {
    try {
      if (statSync(path).isDirectory()) rmdirSync(path);
    } catch {
      // Gone already, or no longer empty: someone else's now.
    }
  }
}

async function shouldDeleteData(
  dataDir: string,
  flags: { deleteData: boolean; keepData: boolean },
  home: string,
): Promise<boolean> {
  if (!existsSync(dataDir)) return false;
  // OPPI_DATA_DIR pointing at a home or the root is a setting, not a folder Oppi owns.
  if (dataDir === resolve(home) || dataDir === "/") {
    writeHumanLine(c.yellow(`  ! The data folder is ${dataDir}; delete what you want by hand.`));
    return false;
  }
  if (flags.deleteData) return true;
  if (flags.keepData) return false;
  if (!process.stdin.isTTY) {
    writeHumanLine(
      c.dim("  No terminal to ask whether to delete the data folder: kept. Use --delete-data."),
    );
    return false;
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise<string>((done) => {
    // Input that ends before an answer (Ctrl-D) is a no; without this the command would stop here.
    rl.once("close", () => done(""));
    rl.question(
      `  Also delete ${dataDir}? It holds your chats, settings, and paired devices. [y/N] `,
      (reply) => {
        rl.close();
        done(reply.trim());
      },
    );
  });
  return /^y(es)?$/i.test(answer);
}
