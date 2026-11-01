import type { Message, TextContent } from "@earendil-works/pi-ai";

/** A diagnostic as pi-durable stores it in a `pi.tool-result` entry's `data`. */
type ToolDiagnostic = { readonly severity: "info" | "warn" | "error"; readonly message: string };

/**
 * A durable tool result as a client is sent it. pi-durable appends the result's diagnostics to
 * the stored message as one `<harness>` text block, so the model reads them
 * (`appendToolResult` → `renderDiagnostics` in `@earendil-works/pi-durable`'s `harness/tool.js`).
 * That block is model-facing text: a client would show it in the tool row as if the tool had
 * printed it, including the server path bash reports for its full output.
 *
 * Clients get the message without that block, and keep only the severities that tell a person
 * something: `warn` and `error` stay as a plain note on the result's text, the way a tool's own
 * error text reaches a client. `info` diagnostics are model notes (a read's remaining lines, an
 * image the model was given) and stay hidden.
 *
 * Only this entry's own rendering is removed, matched exactly, so a tool whose output prints
 * `<harness>…` itself keeps it; a rendering pi-durable changes in a later version stops matching
 * and is left in place rather than cutting a tool's text. The stored message is untouched: the
 * model still sees its diagnostics.
 */
export function clientToolResult<T extends Message | undefined>(message: T, data: unknown): T {
  if (message?.role !== "toolResult") return message;
  const diagnostics = storedDiagnostics(data);
  if (!diagnostics) return message;
  const content = message.content;
  const appended = content.at(-1);
  if (appended?.type !== "text" || appended.text !== renderedDiagnostics(diagnostics))
    return message;
  const kept = content.slice(0, -1);
  const note = diagnostics
    .filter((diagnostic) => diagnostic.severity !== "info")
    .map((diagnostic) => diagnostic.message)
    .join("\n");
  if (note === "") return { ...message, content: kept };
  // Keep the note on its own line of the result's text: the live path joins content blocks
  // without a separator, so a separate block would run into the output.
  const tail = kept.at(-1);
  if (tail?.type !== "text")
    return { ...message, content: [...kept, { type: "text", text: note }] };
  const withNote: TextContent = { ...tail, text: joinText(tail.text, note) };
  return { ...message, content: [...kept.slice(0, -1), withNote] };
}

/** A result's diagnostics, if the entry's data holds a well-formed list; never a guess. */
function storedDiagnostics(data: unknown): ToolDiagnostic[] | undefined {
  const listed = (data as { diagnostics?: unknown } | null | undefined)?.diagnostics;
  if (!Array.isArray(listed) || listed.length === 0) return undefined;
  const diagnostics: ToolDiagnostic[] = [];
  for (const raw of listed) {
    const { severity, message } = (raw ?? {}) as { severity?: unknown; message?: unknown };
    if (severity !== "info" && severity !== "warn" && severity !== "error") return undefined;
    if (typeof message !== "string") return undefined;
    diagnostics.push({ severity, message });
  }
  return diagnostics;
}

/** pi-durable's own rendering, which it does not export: the block a stored result ends with. */
function renderedDiagnostics(diagnostics: readonly ToolDiagnostic[]): string {
  const lines = diagnostics
    .map((diagnostic) => `[${diagnostic.severity}] ${diagnostic.message}`)
    .join("\n");
  return `<harness>\n${lines}\n</harness>`;
}

function joinText(text: string, note: string): string {
  if (text === "") return note;
  return text.endsWith("\n") ? `${text}${note}` : `${text}\n${note}`;
}
