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
import { apiStatus, listWorkspacesForCli, resolveWorkspaceForCli } from "../resources.js";

export async function cmdWorkspace(
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
    if (mode === "list") {
      const workspaces = await listWorkspacesForCli(storage, hostResolvers);
      output({ workspaces }, () => {
        printList(
          `Workspaces (${workspaces.length})`,
          workspaces.map((workspace) => ({
            id: workspace.id,
            title: workspace.name ?? "(unnamed)",
            details: [typeof workspace.hostMount === "string" ? workspace.hostMount : ""],
          })),
          { empty: "No workspaces configured." },
        );
      });
      return;
    }

    if (mode === "get") {
      const reference = positional[0];
      if (!reference) throw new Error("workspace id or name is required");
      const workspace = await resolveWorkspaceForCli(storage, reference, hostResolvers);
      output({ workspace }, () => {
        printDetails(
          "Workspace",
          nonEmptyDetails([
            ["ID", codeValue(workspace.id)],
            ["Name", workspace.name ?? "(unnamed)"],
            ["Path", typeof workspace.hostMount === "string" ? codeValue(workspace.hostMount) : ""],
          ]),
        );
      });
      return;
    }

    throw new Error("Usage: oppi workspace list|get");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    if (jsonOutput) {
      writeJsonEnvelope({
        ok: false,
        error: { message, ...(apiStatus(error) ? { status: apiStatus(error) } : {}) },
      });
      process.exitCode = 1;
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}
