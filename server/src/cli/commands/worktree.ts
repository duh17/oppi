/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { LocalApiConnection, LocalApiHostResolvers } from "../local-api-client.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  writeJsonEnvelope,
} from "../output.js";
import {
  apiStatus,
  createWorktreeForCli,
  getWorktreeStatusForCli,
  listWorktreesForCli,
  openWorktreeForCli,
  previewWorktreeForCli,
  removeWorktreeForCli,
  type CliWorktree,
} from "../resources.js";

export async function cmdWorktree(
  storage: LocalApiConnection,
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
    if (!["list", "get", "create", "open", "status", "preview", "remove"].includes(mode)) {
      throw new Error(
        "Usage: oppi worktree list|get|create|open|status|preview|remove --workspace <workspace>",
      );
    }

    const workspace = flags.workspace?.trim();
    if (!workspace) throw new Error("--workspace is required");

    if (mode === "create") {
      const branch = flags.branch?.trim();
      if (!branch) throw new Error("--branch is required");
      const result = await createWorktreeForCli(
        storage,
        workspace,
        {
          branch,
          ...(flags.base?.trim() ? { base: flags.base.trim() } : {}),
          ...(flags.path?.trim() ? { path: flags.path.trim() } : {}),
        },
        hostResolvers,
      );
      output(result, () =>
        printWorktreeDetails("Created worktree", result.workspaceId, result.worktree),
      );
      return;
    }

    if (mode === "open") {
      const branch = flags.branch?.trim();
      const path = flags.path?.trim();
      if (!branch && !path) throw new Error("--branch or --path is required");
      const result = await openWorktreeForCli(
        storage,
        workspace,
        { ...(branch ? { branch } : {}), ...(path ? { path } : {}) },
        hostResolvers,
      );
      output(result, () => printWorktreeDetails("Worktree", result.workspaceId, result.worktree));
      return;
    }

    if (mode === "status") {
      const worktreeId = positional[0]?.trim();
      if (!worktreeId) throw new Error("worktree id is required");
      const result = await getWorktreeStatusForCli(storage, workspace, worktreeId, hostResolvers);
      output(result, () => {
        printWorktreeDetails("Worktree status", result.workspaceId, result.worktree);
        printStatusSummary(result.status);
      });
      return;
    }

    if (mode === "preview") {
      const worktreeId = positional[0]?.trim();
      if (!worktreeId) throw new Error("worktree id is required");
      const into = flags.into?.trim();
      if (!into) throw new Error("--into is required");
      const result = await previewWorktreeForCli(
        storage,
        workspace,
        worktreeId,
        { into, ...(flags.mode?.trim() ? { mode: flags.mode.trim() } : {}) },
        hostResolvers,
      );
      output(result, () => printPreviewSummary(result.preview));
      return;
    }

    if (mode === "remove") {
      const worktreeId = positional[0]?.trim();
      if (!worktreeId) throw new Error("worktree id is required");
      const result = await removeWorktreeForCli(
        storage,
        workspace,
        worktreeId,
        flags.force === "true",
        hostResolvers,
      );
      output(result, () =>
        printWorktreeDetails("Removed worktree", result.workspaceId, result.worktree),
      );
      return;
    }

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
      printWorktreeDetails("Worktree", result.workspaceId, worktree);
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

function printWorktreeDetails(title: string, workspaceId: string, worktree: CliWorktree): void {
  printDetails(
    title,
    nonEmptyDetails([
      ["Workspace", codeValue(workspaceId)],
      ["ID", codeValue(worktree.id)],
      ["Name", worktree.name ?? "(unnamed)"],
      ["Branch", worktree.branch ? codeValue(worktree.branch) : ""],
      ["Path", worktree.path ? codeValue(worktree.path) : ""],
    ]),
  );
}

function printStatusSummary(status: unknown): void {
  if (!status || typeof status !== "object") return;
  const gitStatus = status as {
    branch?: unknown;
    dirtyCount?: unknown;
    untrackedCount?: unknown;
    stagedCount?: unknown;
  };
  printDetails(
    "Git",
    nonEmptyDetails([
      ["Branch", typeof gitStatus.branch === "string" ? codeValue(gitStatus.branch) : ""],
      ["Dirty", typeof gitStatus.dirtyCount === "number" ? String(gitStatus.dirtyCount) : ""],
      [
        "Untracked",
        typeof gitStatus.untrackedCount === "number" ? String(gitStatus.untrackedCount) : "",
      ],
      ["Staged", typeof gitStatus.stagedCount === "number" ? String(gitStatus.stagedCount) : ""],
    ]),
  );
}

function printPreviewSummary(preview: unknown): void {
  if (!preview || typeof preview !== "object") return;
  const data = preview as {
    worktree?: { id?: unknown; name?: unknown };
    target?: { ref?: unknown };
    mode?: unknown;
    alreadyMerged?: unknown;
    fastForwardPossible?: unknown;
    commitCount?: unknown;
    changedFiles?: unknown[];
    conflictCheck?: unknown;
  };
  printDetails(
    "Worktree preview",
    nonEmptyDetails([
      ["Worktree", typeof data.worktree?.id === "string" ? codeValue(data.worktree.id) : ""],
      ["Name", typeof data.worktree?.name === "string" ? data.worktree.name : ""],
      ["Into", typeof data.target?.ref === "string" ? codeValue(data.target.ref) : ""],
      ["Mode", typeof data.mode === "string" ? data.mode : ""],
      ["Commits", typeof data.commitCount === "number" ? String(data.commitCount) : ""],
      ["Files", Array.isArray(data.changedFiles) ? String(data.changedFiles.length) : ""],
      ["Already merged", typeof data.alreadyMerged === "boolean" ? String(data.alreadyMerged) : ""],
      [
        "Fast-forward",
        typeof data.fastForwardPossible === "boolean" ? String(data.fastForwardPossible) : "",
      ],
      ["Conflicts", typeof data.conflictCheck === "string" ? data.conflictCheck : ""],
    ]),
  );
}

function findWorktree(worktrees: CliWorktree[], reference: string): CliWorktree | undefined {
  return worktrees.find((worktree) => worktree.id === reference || worktree.name === reference);
}
