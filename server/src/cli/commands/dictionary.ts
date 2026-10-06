import { readFileSync } from "node:fs";
import * as c from "../../ansi.js";
import { createLocalApiCommandContext } from "../command-support.js";
import type { LocalApiConnection } from "../local-api-client.js";
import { apiStatus } from "../resources.js";
import {
  captureHumanCliOutput,
  setCapturedCliExitCode,
  writeHumanLine,
  writeStderrLine,
  writeJsonEnvelope,
} from "../output.js";

type AddResult = {
  phrases: string[];
  revision: number;
  added: number;
  skipped: { phrase: string; reason: string }[];
};

function readBatch(input: string): string[] {
  let parsed: unknown;
  if (input.trimStart().startsWith("[")) {
    try {
      parsed = JSON.parse(input) as unknown;
    } catch {
      throw new Error("Invalid JSON phrases array");
    }
  } else {
    parsed = input.replace(/\r\n/g, "\n").replace(/\n$/, "").split("\n");
  }
  if (
    !Array.isArray(parsed) ||
    !parsed.length ||
    !parsed.every((phrase) => typeof phrase === "string" && !!phrase)
  )
    throw new Error("Expected a non-empty JSON array of strings or newline-separated phrases");
  return parsed as string[];
}

/** `oppi dictionary list|add|remove|forget [--workspace ID]`. */
export async function cmdDictionary(
  connection: LocalApiConnection,
  action: string | undefined,
  flags: Record<string, string>,
): Promise<void> {
  const json = flags.json === "true";
  const { call, output } = createLocalApiCommandContext(connection, json);
  try {
    const workspace = flags.workspace;
    const path = workspace
      ? `/dictation/dictionary/workspaces/${encodeURIComponent(workspace)}`
      : "/dictation/dictionary/global";
    let result: { phrases: string[]; revision: number };
    let addition: AddResult | undefined;
    switch (action ?? "list") {
      case "list":
        result = await call(path);
        break;
      case "add": {
        const sources = [flags.phrase, flags.phrases, flags.file].filter(
          (value) => value !== undefined,
        );
        if (sources.length !== 1)
          throw new Error("Choose exactly one of --phrase, --phrases @-, or --file PATH");
        if (flags.phrases !== undefined && flags.phrases !== "@-")
          throw new Error("--phrases requires @- for stdin");
        const phrases =
          flags.phrase === undefined
            ? readBatch(readFileSync(flags.phrases ? 0 : (flags.file ?? ""), "utf8"))
            : undefined;
        addition = await call<AddResult>(path, {
          method: "POST",
          body: phrases ? { phrases } : { phrase: flags.phrase },
        });
        result = addition;
        break;
      }
      case "remove": {
        if (!flags.phrase) throw new Error("--phrase is required");
        result = await call(path, { method: "DELETE", body: { phrase: flags.phrase } });
        break;
      }
      case "forget":
        if (!workspace) throw new Error("--workspace is required to forget a workspace dictionary");
        result = await call(path, { method: "DELETE", body: {} });
        break;
      default:
        throw new Error(
          "Usage: oppi dictionary list|add|remove|forget [--workspace ID] [--phrase TEXT | --phrases @- | --file PATH]",
        );
    }
    output(result, () => {
      if (addition)
        writeHumanLine(
          `Dictionary (${workspace ?? "All Workspaces"}): ${addition.added} added, ${addition.skipped.length} skipped (${result.phrases.length} saved)`,
        );
      else
        writeHumanLine(
          `Dictionary (${workspace ?? "All Workspaces"}): ${result.phrases.join(", ") || "(empty)"}`,
        );
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Dictionary request failed";
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
