import { execFile } from "node:child_process";
import { createLogger } from "../logger.js";
import { openProbe, run } from "./checks.js";
import { gitRemoteUrl, gitSshCommand } from "./git-ssh.js";
import { Placements, type Placement } from "./placements.js";
import { MachineRegistry, type Machine } from "./registry.js";

const log = createLogger({ base: { component: "machines" } });

/** Everything Oppi keeps on a machine lives under this directory of the target's home. */
export const POOL_DIR = ".oppi/pool";

const shellQuote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`;

function git(
  args: readonly string[],
  options: { cwd: string; sshCommand: string },
): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      "git",
      args,
      {
        cwd: options.cwd,
        timeout: 10 * 60_000,
        maxBuffer: 4 * 1024 * 1024,
        env: { ...process.env, GIT_SSH_COMMAND: options.sshCommand, GIT_TERMINAL_PROMPT: "0" },
      },
      (error, stdout, stderr) => {
        if (error) reject(new Error(`git ${args[0]} failed: ${stderr.trim() || error.message}`));
        else resolve(stdout);
      },
    );
  });
}

/** Run git's helper on the target with the machine's PATH: a non-login ssh may not have git on it. */
const helper = (machine: Machine, name: "git-receive-pack" | "git-upload-pack"): string =>
  `--${name === "git-receive-pack" ? "receive" : "upload"}-pack=env PATH=${shellQuote(machine.path)} ${name}`;

export interface RemoteWorktreeRequest {
  registry: MachineRegistry;
  machine: Machine;
  workspaceId: string;
  /** The workspace's git repository on this host. */
  repo: string;
  /** The commit the branch starts from. */
  base: string;
  branch: string;
  worktreeId: string;
  /** A branch that already exists on the machine is reused instead of refused. */
  adopt: boolean;
}

/**
 * Give a child a checkout on a machine: ensure the Oppi-owned bare mirror
 * (`~/.oppi/pool/<workspaceId>.git`), push `base` to it from this host as `branch`, and add a
 * worktree of it under `~/.oppi/pool/worktrees/<workspaceId>/<worktreeId>`. Returns the placement
 * (not saved: the caller records it with the child).
 */
export async function provisionRemoteWorktree(request: RemoteWorktreeRequest): Promise<Placement> {
  const { registry, machine, branch } = request;
  const started = Date.now();
  const target = registry.target(machine);
  const mirror = `${machine.home}/${POOL_DIR}/${request.workspaceId}.git`;
  const root = `${machine.home}/${POOL_DIR}/worktrees/${request.workspaceId}/${request.worktreeId}`;
  const probe = openProbe(registry, machine);
  try {
    const state = await run(
      probe.env,
      `set -e; m=${shellQuote(mirror)}; [ -d "$m" ] || git init --bare -q "$m"; ` +
        `if git -C "$m" rev-parse --verify -q ${shellQuote(`refs/heads/${branch}`)} >/dev/null; then echo exists; else echo new; fi`,
      120,
    );
    if (!state.ok) throw new Error(`Could not prepare the mirror on ${machine.name}: ${state.out}`);
    const exists = state.out.split("\n").pop() === "exists";
    if (exists && !request.adopt)
      throw new Error(`Branch ${branch} already exists on ${machine.name}; pick another name.`);
    if (!exists) {
      await git(
        [
          "push",
          "--quiet",
          helper(machine, "git-receive-pack"),
          gitRemoteUrl(target, mirror),
          `${request.base}:refs/heads/${branch}`,
        ],
        { cwd: request.repo, sshCommand: gitSshCommand(target) },
      );
    }
    const added = await run(
      probe.env,
      `set -e; mkdir -p ${shellQuote(`${machine.home}/${POOL_DIR}/worktrees/${request.workspaceId}`)}; ` +
        `git -C ${shellQuote(mirror)} worktree add -q ${shellQuote(root)} ${shellQuote(branch)}`,
      120,
    );
    if (!added.ok)
      throw new Error(`Could not create the worktree on ${machine.name}: ${added.out}`);
  } catch (error) {
    log.warn("machine.sync", {
      machine: machine.name,
      op: "push",
      branch,
      ok: false,
      ms: Date.now() - started,
    });
    throw error;
  } finally {
    probe.close();
  }
  log.info("machine.sync", {
    machine: machine.name,
    op: "push",
    branch,
    ok: true,
    ms: Date.now() - started,
  });
  return {
    worktreeId: request.worktreeId,
    machine: machine.name,
    workspaceId: request.workspaceId,
    repo: request.repo,
    branch,
    base: request.base,
    root,
    active: false,
    fetched: false,
  };
}

/**
 * Fetch a placement's branch from the machine's mirror into the workspace repository, so the
 * work is on this host whatever happens to the machine. True when it is fetched.
 */
export async function fetchPlacement(dataDir: string, placement: Placement): Promise<boolean> {
  const registry = new MachineRegistry(dataDir);
  const machine = registry.get(placement.machine);
  if (!machine) return false;
  const started = Date.now();
  const target = registry.target(machine);
  const mirror = `${machine.home}/${POOL_DIR}/${placement.workspaceId}.git`;
  try {
    await git(
      [
        "fetch",
        "--quiet",
        helper(machine, "git-upload-pack"),
        gitRemoteUrl(target, mirror),
        `refs/heads/${placement.branch}:refs/heads/${placement.branch}`,
      ],
      { cwd: placement.repo, sshCommand: gitSshCommand(target) },
    );
    new Placements(dataDir).update(placement.worktreeId, { fetched: true });
    log.info("machine.sync", {
      machine: machine.name,
      op: "fetch",
      branch: placement.branch,
      ok: true,
      ms: Date.now() - started,
    });
    return true;
  } catch {
    log.warn("machine.sync", {
      machine: machine.name,
      op: "fetch",
      branch: placement.branch,
      ok: false,
      ms: Date.now() - started,
    });
    return false;
  }
}
