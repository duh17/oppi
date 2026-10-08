/**
 * HTML export of a durable conversation through Pi's own exporter, so a durable share or
 * export is the page a classic session produces. Pi's exporter reads a `SessionManager`, so
 * the conversation's entries go through a private JSONL file that lives only for the call.
 */
import { randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { sanitizeTranscriptCard } from "../extensions/durable/durable-ui.js";
import type { SessionEntry } from "./trace.js";

export interface DurableExportState {
  systemPrompt: string;
  tools: ReadonlyArray<{ name: string; description: string; parameters: unknown }>;
}

interface PiHtmlExport {
  exportSessionToHtml(
    sm: SessionManager,
    state: DurableExportState,
    options: { outputPath: string; themeName?: string },
  ): Promise<string>;
  getThemeByName(name: string): unknown;
}

let loading: Promise<PiHtmlExport> | undefined;

/** Pi exports neither piece from its package root. Same dist loading as `pi-mcp-internals.ts`. */
function loadPiHtmlExport(): Promise<PiHtmlExport> {
  return (loading ??= (async () => {
    const dist = dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")));
    const load = (path: string): Promise<Record<string, unknown>> =>
      import(pathToFileURL(join(dist, path)).href) as Promise<Record<string, unknown>>;
    const [exporter, theme] = await Promise.all([
      load("core/export-html/index.js"),
      load("modes/interactive/theme/theme.js"),
    ]);
    return {
      exportSessionToHtml: exporter.exportSessionToHtml,
      getThemeByName: theme.getThemeByName,
    } as PiHtmlExport;
  })().catch((error: unknown) => {
    loading = undefined;
    throw error;
  }));
}

/**
 * The page needs entries Pi's template can draw. A durable compaction records no
 * `tokensBefore` (the template formats it as a number), so the summary exports as a
 * message with its text instead of a made-up count. A display card (a failure or a
 * background job result) exports as its title and body.
 */
function exportEntry(entry: SessionEntry): SessionEntry {
  if (entry.type === "compaction")
    return {
      type: "custom_message",
      id: entry.id,
      parentId: entry.parentId ?? null,
      timestamp: entry.timestamp,
      customType: "compaction",
      content: entry.summary ?? "",
      display: true,
    };
  if (entry.type === "custom") {
    const data = entry.data;
    const card = sanitizeTranscriptCard(
      data && typeof data === "object" && !Array.isArray(data)
        ? (data as Record<string, unknown>).card
        : undefined,
    );
    if (card)
      return {
        type: "custom_message",
        id: entry.id,
        parentId: entry.parentId ?? null,
        timestamp: entry.timestamp,
        customType: entry.customType ?? "card",
        content: [card.title, card.status, card.body].filter(Boolean).join("\n\n"),
        display: true,
      };
  }
  return entry;
}

/** Write the conversation as a Pi session HTML page at `outputPath`. */
export async function exportDurableToHtml(options: {
  entries: readonly SessionEntry[];
  cwd: string;
  state: DurableExportState;
  outputPath: string;
  /** The user's theme setting; an unknown name falls back to Pi's default, as for classic. */
  themeName?: string;
}): Promise<string> {
  // Prompt sections are `system` messages in the store. Pi's page shows the prompt from
  // `state.systemPrompt`, never as a turn, so they leave the chain and the rest re-links.
  const entries: SessionEntry[] = [];
  for (const entry of options.entries) {
    if (entry.type === "message" && entry.message?.role === "system") continue;
    entries.push({ ...exportEntry(entry), parentId: entries.at(-1)?.id ?? null });
  }
  if (entries.length === 0) throw new Error("Nothing to export yet - start a conversation first");
  const pi = await loadPiHtmlExport();
  const directory = await mkdtemp(join(tmpdir(), "oppi-durable-export-"));
  try {
    const file = join(directory, "session.jsonl");
    const header = {
      type: "session",
      version: 3,
      id: randomUUID(),
      timestamp: entries[0]?.timestamp ?? new Date().toISOString(),
      cwd: options.cwd,
    };
    await writeFile(
      file,
      `${[header, ...entries].map((line) => JSON.stringify(line)).join("\n")}\n`,
      { mode: 0o600 },
    );
    const themeName =
      options.themeName !== undefined && pi.getThemeByName(options.themeName) !== undefined
        ? options.themeName
        : undefined;
    return await pi.exportSessionToHtml(SessionManager.open(file), options.state, {
      outputPath: options.outputPath,
      ...(themeName === undefined ? {} : { themeName }),
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
