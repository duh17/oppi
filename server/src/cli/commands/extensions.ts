import * as c from "../../ansi.js";
import type { DurableExtensionListing, DurableExtensionReport } from "../../durable-harness.js";
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

function listingLine(extension: DurableExtensionListing): string {
  const state = extension.enabled ? c.green("on ") : c.dim("off");
  const origin = extension.builtIn ? "built-in" : "package";
  const tools = extension.tools.length ? extension.tools.join(", ") : "no tools";
  return `${state}  ${extension.name}  ${c.dim(`${origin} \u00b7 ${tools}`)}`;
}

/**
 * `oppi extensions list|enable|disable|reload`: the durable extensions of the running server.
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
    const unsupported = Object.keys(flags).filter((flag) => flag !== "json");
    if (unsupported.length > 0)
      throw new Error(
        `Unsupported flag for 'extensions ${action ?? ""}': --${unsupported.sort().join(", --")}`,
      );
    if (action === "list" && positional.length === 0) {
      const { extensions } = await call<{ extensions: DurableExtensionListing[] }>(
        "/durable/extensions",
      );
      output({ extensions }, () => {
        for (const extension of extensions) writeHumanLine(listingLine(extension));
      });
      return;
    }
    const [name] = positional;
    if ((action === "enable" || action === "disable") && name && positional.length === 1) {
      const { extension } = await call<{ extension: DurableExtensionListing }>(
        `/durable/extensions/${encodeURIComponent(name)}/enabled`,
        { method: "PUT", body: { enabled: action === "enable" } },
      );
      output({ extension }, () => {
        writeHumanLine(listingLine(extension));
        writeHumanLine(c.dim("New sessions follow now; open sessions at their next attach."));
      });
      return;
    }
    if (action !== "reload" || positional.length > 0)
      throw new Error("Usage: oppi extensions list | enable <name> | disable <name> | reload");
    const report = await call<DurableExtensionReport>("/durable/extensions/reload", {
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
        writeHumanLine("No durable extensions found in enabled Pi packages.");
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
