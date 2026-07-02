/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import type { LocalApiHostResolvers } from "../local-api-client.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  writeJsonEnvelope,
} from "../output.js";
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
        printList(
          `Worktrees for ${result.workspaceId} (${result.worktrees.length})`,
          result.worktrees.map((worktree) => ({
            id: worktree.id,
            title: worktree.name ?? "(unnamed)",
            details: [worktree.path ?? ""],
          })),
          { empty: "No worktrees discovered for this workspace." },
        );
      });
      return;
    }

    const reference = positional[0];
    if (!reference) throw new Error("worktree id is required");
    const worktree = findWorktree(result.worktrees, reference);
    if (!worktree) throw new Error(`Worktree not found: ${reference}`);

    output({ workspaceId: result.workspaceId, worktree }, () => {
      printDetails(
        "Worktree",
        nonEmptyDetails([
          ["Workspace", codeValue(result.workspaceId)],
          ["ID", codeValue(worktree.id)],
          ["Name", worktree.name ?? "(unnamed)"],
          ["Path", worktree.path ? codeValue(worktree.path) : ""],
        ]),
      );
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
