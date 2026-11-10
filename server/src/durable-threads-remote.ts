import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import type { SubagentWorktree } from "../plugins/subagents/contract.js";
import type { SubagentWorktreePlan } from "./durable-extension-api.js";
import { placementsFor } from "./machines/placements.js";
import { fetchPlacement, provisionRemoteWorktree } from "./machines/provision.js";
import { MachineRegistry, type Machine } from "./machines/registry.js";
import type { Workspace } from "./types.js";
import { workspaceGitRoot } from "./worktrees.js";

/** File tools a conversation on a machine does not get: they search this host's disk. */
export const REMOTE_EXCLUDED_TOOLS = ["ls", "find", "grep"] as const;

/**
 * The machine a spawn's `host` names, refused unless it is set up and its last check passed.
 * Names a fix in every refusal.
 */
export function spawnMachine(dataDir: string, name: string): Machine {
  const registry = new MachineRegistry(dataDir);
  const machine = registry.get(name);
  if (!machine) {
    const known = registry.list().map((entry) => entry.name);
    throw new Error(
      `Unknown machine "${name}". ${known.length > 0 ? `Machines: ${known.join(", ")}.` : "No machine is set up; `oppi machines add` sets one up."}`,
    );
  }
  if (machine.test && !machine.test.ok)
    throw new Error(
      `${name} failed its last check; run \`oppi machines test ${name}\` and fix what it reports.`,
    );
  return machine;
}

const slug = (branch: string): string =>
  branch
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 30) || "child";

/** Create the planned branch's worktree on the machine and record where it is. */
export async function provisionRemote(
  dataDir: string,
  plan: Extract<SubagentWorktreePlan, { mode: "create" }>,
  workspace: Workspace,
): Promise<SubagentWorktree> {
  if (!plan.host) throw new Error("provisionRemote needs a machine");
  const machine = spawnMachine(dataDir, plan.host);
  const id = `wt_${slug(plan.branch)}-${randomBytes(4).toString("hex")}`;
  const placement = await provisionRemoteWorktree({
    registry: new MachineRegistry(dataDir),
    machine,
    workspaceId: workspace.id,
    repo: await workspaceGitRoot(workspace),
    base: plan.base,
    branch: plan.branch,
    worktreeId: id,
    adopt: false,
  });
  placementsFor(dataDir).put(placement);
  return { id, path: placement.root, branch: plan.branch, base: plan.base, machine: machine.name };
}

function countAhead(repo: string, base: string, branch: string): Promise<number> {
  return new Promise((resolve) => {
    execFile(
      "git",
      ["rev-list", "--count", `${base}..refs/heads/${branch}`],
      { cwd: repo },
      (error, stdout) => resolve(error ? 0 : Number(stdout.trim()) || 0),
    );
  });
}

/**
 * `list`'s and the answers' line for a child on a machine: the branch, where it is, and how far
 * ahead it is, read from the copy fetched here. A worker that finished and is not fetched yet is
 * fetched now (the fetch at its end may have failed); the machine's own path is never read here.
 */
export async function remoteWorktreeLine(
  dataDir: string,
  worktree: SubagentWorktree,
): Promise<string> {
  const placements = placementsFor(dataDir);
  let placement = placements.get(worktree.id);
  if (placement && !placement.fetched && !placement.active) {
    await fetchPlacement(dataDir, placement);
    placement = placements.get(worktree.id);
  }
  const parts = [worktree.branch ?? "detached", `on ${worktree.machine}`];
  if (placement?.fetched) {
    const ahead = await countAhead(placement.repo, placement.base, placement.branch);
    parts.push(ahead === 1 ? "1 commit ahead" : `${ahead} commits ahead`, "fetched");
  } else parts.push("not fetched");
  return parts.join(" \u00b7 ");
}
