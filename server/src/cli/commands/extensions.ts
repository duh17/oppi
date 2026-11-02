import * as c from "../../ansi.js";
import type { DurableExtensionReport } from "../../durable-harness.js";
import type { ServerExtensionSummary } from "../../server-resource-service.js";
import { createLocalApiCommandContext } from "../command-support.js";
import type { LocalApiConnection } from "../local-api-client.js";
import {
  captureHumanCliOutput,
  setCapturedCliExitCode,
  writeHumanLine,
  writeJsonEnvelope,
  writeStderrLine,
} from "../output.js";
import { apiStatus } from "../resources.js";

const EXTENSIONS = "/server/resources/extensions";
/** The list with the rows that are only a plugin. */
const ALL_EXTENSIONS = `${EXTENSIONS}?plugins=true`;

function listingLine(extension: ServerExtensionSummary): string {
  const state =
    extension.state === "on"
      ? c.green("on   ")
      : extension.state === "error"
        ? c.red("error")
        : c.dim("off  ");
  const origin = extension.plugin?.required ? "required" : extension.source;
  const kinds = extension.kinds.join(" + ");
  const tools = extension.plugin?.tools ?? extension.contributedTools ?? [];
  const detail = [origin, kinds, tools.length ? tools.join(", ") : "no tools"].join(" \u00b7 ");
  const line = `${state}  ${extension.name}  ${c.dim(detail)}`;
  return extension.loadError ? `${line}\n       ${c.red(extension.loadError)}` : line;
}

/**
 * The one row `key` names: its ID, its name, or its plugin's extension name. A name more than
 * one row has is refused with their IDs.
 */
function rowFor(rows: readonly ServerExtensionSummary[], key: string): ServerExtensionSummary {
  const byId = rows.find((row) => row.id === key);
  if (byId) return byId;
  const named = rows.filter((row) => row.name === key || row.plugin?.extension === key);
  const [only] = named;
  if (only && named.length === 1) return only;
  if (!only) throw new Error(`No extension named ${key}`);
  throw new Error(
    `${named.length} extensions are named ${key}; name one by ID: ${named.map((row) => row.id).join(", ")}`,
  );
}

/**
 * `oppi extensions list|enable|disable|reload`: the server's extension list (classic Pi
 * extensions and plugins), and plugin reload.
 */
export async function cmdExtensions(
  connection: LocalApiConnection,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  signal?: AbortSignal,
): Promise<void> {
  const json = flags.json === "true";
  const { call, output } = createLocalApiCommandContext(connection, json, signal);
  try {
    if (action === "list" && positional.length === 0) {
      const { extensions } = await call<{ extensions: ServerExtensionSummary[] }>(ALL_EXTENSIONS);
      output({ extensions }, () => {
        for (const extension of extensions) writeHumanLine(listingLine(extension));
      });
      return;
    }
    const [key] = positional;
    if ((action === "enable" || action === "disable") && key && positional.length === 1) {
      const { extensions } = await call<{ extensions: ServerExtensionSummary[] }>(ALL_EXTENSIONS);
      const { id } = rowFor(extensions, key);
      const extension = await call<ServerExtensionSummary>(
        `${EXTENSIONS}/${encodeURIComponent(id)}/enabled`,
        { method: "PUT", body: { enabled: action === "enable" } },
      );
      output({ extension }, () => {
        writeHumanLine(listingLine(extension));
        writeHumanLine(
          c.dim(
            extension.kinds.includes("pi-extension")
              ? "Classic sessions follow at their next start; durable sessions at their next attach."
              : "New sessions follow now; open sessions at their next attach.",
          ),
        );
      });
      return;
    }
    if (action !== "reload" || positional.length > 0)
      throw new Error("Usage: oppi extensions list | enable <name> | disable <name> | reload");
    const report = await call<DurableExtensionReport>(`${EXTENSIONS}/reload`, {
      method: "POST",
      body: {},
    });
    output({ ...report }, () => {
      for (const loaded of report.loaded)
        writeHumanLine(`${c.green("loaded")}  ${loaded.name}  ${c.dim(loaded.entry)}`);
      for (const kept of report.kept)
        writeHumanLine(
          `${c.yellow("kept")}    ${kept.name}  ${c.dim("previous code; reload failed")}`,
        );
      for (const name of report.removed) writeHumanLine(`${c.yellow("removed")} ${name}`);
      for (const issue of report.skipped)
        writeHumanLine(`${c.dim("skipped")} ${issue.message}  ${c.dim(issue.entry)}`);
      for (const issue of report.errors)
        writeHumanLine(`${c.red("error")}   ${issue.message}  ${c.dim(issue.entry)}`);
      if (
        !report.loaded.length &&
        !report.kept.length &&
        !report.removed.length &&
        !report.errors.length
      )
        writeHumanLine("No plugins found.");
    });
    // JSON callers read `errors` from the ok envelope; a terminal gets a failing exit code.
    if (report.errors.length && !json) setCapturedCliExitCode(1);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Extension command failed";
    if (json)
      writeJsonEnvelope({
        ok: false,
        error: { message, ...(apiStatus(error) ? { status: apiStatus(error) } : {}) },
      });
    writeStderrLine(c.red(`  Error: ${message}`));
    captureHumanCliOutput(() => writeHumanLine(c.red(`  Error: ${message}`)));
    setCapturedCliExitCode(1);
  }
}
