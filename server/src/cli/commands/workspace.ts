/* eslint-disable no-console */
import { readFileSync } from "node:fs";

import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import {
  localApiRequest,
  type LocalApiHostResolvers,
  type LocalApiRequestOptions,
} from "../local-api-client.js";
import {
  codeValue,
  nonEmptyDetails,
  printDetails,
  printList,
  printNextCommands,
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

  async function call<T>(path: string, options?: LocalApiRequestOptions): Promise<T> {
    return localApiRequest<T>(storage, path, options, hostResolvers);
  }

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
      output({ workspace }, () => printWorkspaceDetails("Workspace", workspace));
      return;
    }

    if (mode === "create") {
      const definition = workspaceDefinitionFromFlags(flags);
      if (!definition.name) throw new Error("--name or definition.name is required");
      const result = await call<Record<string, unknown>>("/workspaces", {
        method: "POST",
        body: definition,
      });
      output(result, () => {
        const workspace = result.workspace as Record<string, unknown> | undefined;
        printWorkspaceDetails("✓ Workspace created", workspace, definition.name as string);
        printNextCommands([
          `oppi workspace get ${workspace?.id ?? "<workspace>"}`,
          `oppi session create --workspace ${workspace?.id ?? "<workspace>"} --prompt "..."`,
        ]);
      });
      return;
    }

    if (mode === "update") {
      const reference = positional[0];
      if (!reference) throw new Error("workspace id or name is required");
      const workspace = await resolveWorkspaceForCli(storage, reference, hostResolvers);
      const definition = workspaceDefinitionFromFlags(flags, { requireFields: true });
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspace.id)}`,
        {
          method: "PUT",
          body: definition,
        },
      );
      output(result, () => {
        const updated = result.workspace as Record<string, unknown> | undefined;
        printWorkspaceDetails("✓ Workspace updated", updated, workspace.name);
      });
      return;
    }

    if (mode === "delete" || mode === "remove") {
      const reference = positional[0];
      if (!reference) throw new Error("workspace id or name is required");
      const workspace = await resolveWorkspaceForCli(storage, reference, hostResolvers);
      const result = await call<Record<string, unknown>>(
        `/workspaces/${encodeURIComponent(workspace.id)}`,
        {
          method: "DELETE",
        },
      );
      output(result, () => {
        printDetails("✓ Workspace deleted", [["Workspace", codeValue(workspace.id)]]);
      });
      return;
    }

    throw new Error("Usage: oppi workspace list|get|create|update|delete");
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

function workspaceDefinitionFromFlags(
  flags: Record<string, string>,
  options: { requireFields?: boolean } = {},
): Record<string, unknown> {
  const definition = flags.definition ? parseJsonFile(flags.definition) : {};
  applyStringFlag(definition, flags, "name", "name");
  applyStringFlag(definition, flags, "description", "description");
  applyStringFlag(definition, flags, "icon", "icon");
  applyStringFlag(definition, flags, "system-prompt", "systemPrompt");
  applyStringFlag(definition, flags, "host-mount", "hostMount");
  applyStringFlag(definition, flags, "default-model", "defaultModel");
  applyStringFlag(definition, flags, "runtime", "runtime");
  if (options.requireFields && Object.keys(definition).length === 0) {
    throw new Error("--definition or at least one workspace field flag is required");
  }
  return definition;
}

function applyStringFlag(
  definition: Record<string, unknown>,
  flags: Record<string, string>,
  flagName: string,
  fieldName: string,
): void {
  if (Object.prototype.hasOwnProperty.call(flags, flagName)) {
    definition[fieldName] = flags[flagName];
  }
}

function parseJsonFile(path: string): Record<string, unknown> {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("definition must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}

function printWorkspaceDetails(
  title: string,
  workspace: Record<string, unknown> | undefined,
  fallbackName?: string,
): void {
  printDetails(
    title,
    nonEmptyDetails([
      ["ID", codeValue(typeof workspace?.id === "string" ? workspace.id : "?")],
      [
        "Name",
        typeof workspace?.name === "string" ? workspace.name : (fallbackName ?? "(unnamed)"),
      ],
      ["Path", typeof workspace?.hostMount === "string" ? codeValue(workspace.hostMount) : ""],
      ["Runtime", typeof workspace?.runtime === "string" ? workspace.runtime : ""],
      ["Default model", typeof workspace?.defaultModel === "string" ? workspace.defaultModel : ""],
    ]),
  );
}
