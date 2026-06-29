/* eslint-disable no-console, local/structured-log-format */
import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import type { LocalApiHostResolvers } from "../local-api-client.js";
import { writeJsonEnvelope } from "../output.js";
import { apiStatus, listWorktreesForCli, type CliWorktree } from "../resources.js";

export async function cmdWorktree(
  storage: Storage,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<void> {
  const mode = action || "list";
  const jsonOutput = flags.json === "true";

  function output(data: Record<string, unknown>, human: () => void): void {
    if (jsonOutput) writeJsonEnvelope({ ok: true, data });
    else human();
  }

  try {
    if (mode !== "list" && mode !== "get") {
      throw new Error("Usage: oppi worktree list|get --workspace <workspace>");
    }

    const workspace = flags.workspace?.trim();
    if (!workspace) throw new Error("--workspace is required");

    const result = await listWorktreesForCli(storage, workspace, hostResolvers);
    if (mode === "list") {
      output(result, () => {
        console.log(c.bold(`  Worktrees for ${result.workspaceId} (${result.worktrees.length})`));
        for (const worktree of result.worktrees) {
          console.log(
            `  ${c.cyan(worktree.id)}  ${worktree.name ?? "(unnamed)"}  ${c.dim(worktree.path ?? "")}`,
          );
        }
        console.log("");
      });
      return;
    }

    const reference = positional[0];
    if (!reference) throw new Error("worktree id is required");
    const worktree = findWorktree(result.worktrees, reference);
    if (!worktree) throw new Error(`Worktree not found: ${reference}`);

    output({ workspaceId: result.workspaceId, worktree }, () => {
      console.log(c.green("  Worktree"));
      console.log(`  Workspace: ${c.cyan(result.workspaceId)}`);
      console.log(`  ID:        ${c.cyan(worktree.id)}`);
      console.log(`  Name:      ${worktree.name ?? "(unnamed)"}`);
      if (worktree.path) console.log(`  Path:      ${c.dim(worktree.path)}`);
      console.log("");
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    const status = apiStatus(error);
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message, ...(status ? { status } : {}) } });
      process.exitCode = 1;
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

function findWorktree(worktrees: CliWorktree[], reference: string): CliWorktree | undefined {
  return worktrees.find((worktree) => worktree.id === reference || worktree.name === reference);
}
