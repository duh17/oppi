// Pure: places from panes that a message carries, as the model reads them and as the
// transcript shows them. Safe to import without loading the Durable runtime.
import type { JsonValue } from "@earendil-works/chord/json";
import { asRecord } from "./json-shape.js";
import type { PromptContextItem, PromptContextSource } from "./types/protocol.js";

/** Most items one message carries. */
export const PROMPT_CONTEXT_MAX_ITEMS = 20;
/** Longest quote, anchor, or note, in characters. */
export const PROMPT_CONTEXT_MAX_TEXT = 4000;
/** Largest rendered block, in UTF-8 bytes. */
export const PROMPT_CONTEXT_MAX_BLOCK_BYTES = 32 * 1024;

const MAX_PATH = 4096;
const MAX_URL = 4096;
const MAX_LABEL = 500;
const MAX_SHORT = 64;

const SOURCE_NAMES: Record<PromptContextSource, string> = {
  git_diff: "git diff",
  file: "file",
  timeline_text: "timeline text",
  tool_output: "tool output",
  terminal_output: "terminal output",
  image: "image",
};

/**
 * Entry kind a user input with context items is placed as, instead of `pi.user` (pi-durable
 * `InputEntry`). Its model message is the rendered block, then the typed text; the entry data
 * says where the typed text starts and keeps the items, without quotes, for the transcript.
 */
export const USER_INPUT_ENTRY_KIND = "oppi.user-input";

/** What a user input entry stores and the transcript reads. */
export type UserInputData = {
  /** UTF-16 offset where the typed text starts: the context block before it is model-only. */
  textOffset: number;
  context: PromptContextItem[];
};

/** A request whose context breaks a limit or the shape. The message says which item and why. */
export class PromptContextError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PromptContextError";
  }
}

const count = (value: number): string => value.toLocaleString("en-US");

/** Line breaks and other control characters: a one-line field holding one could forge a line
 *  of the block (`**Where:**`, a heading) or of the transcript. */
function hasControl(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x20 || (code >= 0x7f && code <= 0x9f) || code === 0x2028 || code === 0x2029)
      return true;
  }
  return false;
}

function readString(
  record: Record<string, unknown>,
  key: string,
  max: number,
  where: string,
  oneLine = false,
): string | undefined {
  const value = record[key];
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new PromptContextError(`${where}: ${key} must be a string`);
  if (value.length > max)
    throw new PromptContextError(
      `${where}: ${key} is ${count(value.length)} characters; the limit is ${count(max)}`,
    );
  if (oneLine && hasControl(value))
    throw new PromptContextError(
      `${where}: ${key} must not hold line breaks or control characters`,
    );
  return value;
}

function readPosition(
  record: Record<string, unknown>,
  key: string,
  where: string,
): number | undefined {
  const value = record[key];
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1)
    throw new PromptContextError(`${where}: ${key} must be a positive integer`);
  return value;
}

function readRange(
  record: Record<string, unknown>,
  start: string,
  end: string,
  where: string,
): { start?: number; end?: number } {
  const from = readPosition(record, start, where);
  const to = readPosition(record, end, where);
  if (to !== undefined && from === undefined)
    throw new PromptContextError(`${where}: ${end} needs ${start}`);
  if (from !== undefined && to !== undefined && to < from)
    throw new PromptContextError(`${where}: ${end} is before ${start}`);
  return { start: from, end: to };
}

function readItem(value: unknown, index: number): PromptContextItem {
  const where = `Context item ${index + 1}`;
  const record = asRecord(value);
  if (!record) throw new PromptContextError(`${where} must be an object`);
  const source = record.source;
  if (typeof source !== "string" || !Object.hasOwn(SOURCE_NAMES, source))
    throw new PromptContextError(`${where}: unknown source ${JSON.stringify(source)}`);
  const lines = readRange(record, "startLine", "endLine", where);
  const pages = readRange(record, "startPage", "endPage", where);
  const fields = {
    id: readString(record, "id", MAX_SHORT * 2, where, true),
    label: readString(record, "label", MAX_LABEL, where, true),
    path: readString(record, "path", MAX_PATH, where, true),
    side: readString(record, "side", MAX_SHORT, where, true),
    url: readString(record, "url", MAX_URL, where, true),
    language: readString(record, "language", MAX_SHORT, where, true),
    quote: readString(record, "quote", PROMPT_CONTEXT_MAX_TEXT, where),
    anchor: readString(record, "anchor", PROMPT_CONTEXT_MAX_TEXT, where),
    note: readString(record, "note", PROMPT_CONTEXT_MAX_TEXT, where),
  };
  // Key order is fixed, so an identical replay renders and hashes the same.
  const item: PromptContextItem = { source: source as PromptContextSource };
  if (fields.id !== undefined) item.id = fields.id;
  if (fields.label !== undefined) item.label = fields.label;
  if (fields.path !== undefined) item.path = fields.path;
  if (fields.side !== undefined) item.side = fields.side;
  if (lines.start !== undefined) item.startLine = lines.start;
  if (lines.end !== undefined) item.endLine = lines.end;
  if (pages.start !== undefined) item.startPage = pages.start;
  if (pages.end !== undefined) item.endPage = pages.end;
  if (fields.url !== undefined) item.url = fields.url;
  if (fields.language !== undefined) item.language = fields.language;
  if (fields.quote !== undefined) item.quote = fields.quote;
  if (fields.anchor !== undefined) item.anchor = fields.anchor;
  if (fields.note !== undefined) item.note = fields.note;
  return item;
}

/** Items checked for shape and per-field limits only: what a stored entry is read back with. */
function readItems(value: unknown): PromptContextItem[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value)) throw new PromptContextError("Context must be a list of items");
  if (value.length > PROMPT_CONTEXT_MAX_ITEMS)
    throw new PromptContextError(
      `Context has ${value.length} items; the limit is ${PROMPT_CONTEXT_MAX_ITEMS}`,
    );
  return value.length ? value.map(readItem) : undefined;
}

/**
 * A request's `context`, checked against the shape and every limit: undefined when absent or
 * empty. Throws `PromptContextError` naming the item and the limit; nothing is ever cut.
 */
export function readPromptContext(value: unknown): PromptContextItem[] | undefined {
  const items = readItems(value);
  if (!items) return undefined;
  const bytes = Buffer.byteLength(renderPromptContext(items), "utf8");
  if (bytes > PROMPT_CONTEXT_MAX_BLOCK_BYTES)
    throw new PromptContextError(
      `Context is ${count(bytes)} bytes; the limit is ${count(PROMPT_CONTEXT_MAX_BLOCK_BYTES)}`,
    );
  return items;
}

const LANGUAGES: Record<string, string> = {
  swift: "swift",
  ts: "typescript",
  tsx: "typescript",
  js: "javascript",
  jsx: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  py: "python",
  go: "go",
  rs: "rust",
  rb: "ruby",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  json: "json",
  yaml: "yaml",
  yml: "yaml",
  md: "markdown",
  markdown: "markdown",
  html: "html",
  css: "css",
};

function languageOf(item: PromptContextItem): string {
  if (item.language !== undefined) return item.language;
  const extension = item.path?.split(".").pop()?.toLowerCase();
  return (extension && LANGUAGES[extension]) ?? "";
}

function where(item: PromptContextItem): string {
  const source = SOURCE_NAMES[item.source];
  if (item.path) {
    let title = `\`${item.path}\``;
    if (item.startLine !== undefined)
      title +=
        item.endLine !== undefined && item.endLine !== item.startLine
          ? `:${item.startLine}-${item.endLine}`
          : `:${item.startLine}`;
    if (item.startPage !== undefined)
      title +=
        item.endPage !== undefined && item.endPage !== item.startPage
          ? ` pages ${item.startPage}–${item.endPage}`
          : ` page ${item.startPage}`;
    return `${title} (${item.side ? `${item.side}, ` : ""}${source})`;
  }
  if (item.label) return `${item.label} (${source})`;
  if (item.url) return `${item.url} (${source})`;
  return source;
}

const BLOCK_OPEN = "<pane-context>";
const BLOCK_CLOSE = "</pane-context>";

/** Text the person chose, unable to close the block early: a closing tag inside it is escaped,
 *  so the block's real end stays the first one (`stripPromptContext`). */
function contained(text: string): string {
  return text.replace(/<\/pane-context/gi, "<\\/pane-context");
}

/** A fence longer than any backtick run inside `text`. */
function fence(text: string): string {
  let longest = 0;
  for (const run of text.match(/`+/g) ?? []) longest = Math.max(longest, run.length);
  return "`".repeat(Math.max(3, longest + 1));
}

/**
 * The model-only block for `items`, in order. Deterministic: the same items always render the
 * same text, so a replayed request keeps its content hash (`clientTurnId` dedupe).
 */
export function renderPromptContext(items: readonly PromptContextItem[]): string {
  const lines = [
    BLOCK_OPEN,
    "The user attached these places from the app's panes. Their message follows the block.",
  ];
  items.forEach((item, index) => {
    lines.push("", `### ${item.note ? "Comment" : "Reference"} ${index + 1}`, "");
    lines.push(`**Where:** ${where(item)}`);
    if (item.url && (item.path || item.label)) lines.push(`**URL:** ${item.url}`);
    if (item.quote?.trim()) {
      const quote = contained(item.quote);
      const marks = fence(quote);
      lines.push("", "**Selected text:**", "", `${marks}${languageOf(item)}`, quote, marks);
    }
    if (item.anchor?.trim()) lines.push("", contained(item.anchor));
    if (item.note?.trim()) {
      lines.push("", "**Comment:**", "");
      // Every line break, CR included, starts a quoted line: none can escape the quote.
      for (const line of contained(item.note).split(/\r?\n|\r/))
        lines.push(line ? `> ${line}` : ">");
    }
  });
  lines.push(BLOCK_CLOSE);
  return lines.join("\n");
}

/**
 * `text` without a leading context block: what the person typed, for readers of the model text
 * that have no entry data (a title from the first message).
 */
export function stripPromptContext(text: string): string {
  if (!text.startsWith(`${BLOCK_OPEN}\n`)) return text;
  const end = text.indexOf(`\n${BLOCK_CLOSE}`);
  if (end < 0) return text;
  return text.slice(end + BLOCK_CLOSE.length + 1).trimStart();
}

/** The model text of `text` with `items` before it, and where the typed text starts. */
export function withPromptContext(
  text: string,
  items: readonly PromptContextItem[],
): { text: string; textOffset: number } {
  const block = renderPromptContext(items);
  return text
    ? { text: `${block}\n\n${text}`, textOffset: block.length + 2 }
    : { text: block, textOffset: block.length };
}

/**
 * An item as the transcript keeps it: the place, not the selected text. The note stays: a chip
 * names a comment as one ("Comment", against a passive reference) and reads it as its
 * accessibility value.
 */
function shownItem(item: PromptContextItem): PromptContextItem {
  const { quote: _quote, anchor: _anchor, ...shown } = item;
  return shown;
}

/** The pi-durable `InputEntry` a user input carrying `items` is placed as. */
export function userInputEntry(
  textOffset: number,
  items: readonly PromptContextItem[],
): { kind: string; data: { [key: string]: JsonValue } } {
  return {
    kind: USER_INPUT_ENTRY_KIND,
    data: { textOffset, context: items.map(shownItem) as unknown as JsonValue },
  };
}

/** The stored data of an entry, if it is a well-formed user input with context. */
export function userInputData(kind: string | undefined, data: unknown): UserInputData | undefined {
  if (kind !== USER_INPUT_ENTRY_KIND) return undefined;
  const record = asRecord(data);
  const textOffset = record?.textOffset;
  if (typeof textOffset !== "number" || !Number.isSafeInteger(textOffset) || textOffset < 0)
    return undefined;
  try {
    // Shape only: rendering the whole block to measure it on every read is the sender's check.
    const context = readItems(record?.context);
    return context ? { textOffset, context: context.map(shownItem) } : undefined;
  } catch {
    return undefined;
  }
}

/** The typed text of a user input: the model text after its context block. May be empty. */
export function userInputText(text: string, data: UserInputData): string {
  if (data.textOffset > text.length) return text;
  return text.slice(data.textOffset).trimStart();
}
