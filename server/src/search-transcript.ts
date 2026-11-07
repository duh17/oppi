/**
 * Search FTS fields of a session transcript: extraction over the current branch, the newest-text
 * caps, and the merge an append or a paged read uses to match one full extraction.
 */

import { existsSync, readFileSync } from "node:fs";

import { projectAssistantContentRuns } from "./session-protocol.js";
import {
  buildEntryPath,
  extractText,
  normalizeTraceValueForMobile,
  parseSessionEntries,
  replaceUnpairedSurrogates,
  selectVisibleSessionContext,
  sessionTranscriptLeafId,
  type EntryLink,
  type SessionEntry,
} from "./trace.js";

/**
 * Search FTS field caps. Search indexes a session's whole current branch, so a long session can
 * exceed them; the newest text is kept and the oldest dropped (`tailWithinCap`).
 */
export const SEARCH_USER_MESSAGE_CAP = 50_000;
export const SEARCH_ASSISTANT_MESSAGE_CAP = 100_000;

/** Longest partial leading word `tailWithinCap` drops; a longer unbroken run keeps its cut. */
const TAIL_PARTIAL_WORD_MAX = 64;

/**
 * The newest `cap` characters of `text`. A cut inside a word (or a surrogate pair) drops that
 * partial leading word, so the index holds no fragment no query could mean. An unbroken run
 * longer than `TAIL_PARTIAL_WORD_MAX` keeps its cut: one giant token must not erase a message.
 */
function tailWithinCap(text: string, cap: number): string {
  if (text.length <= cap) return text;
  const cut = text.length - cap;
  let start = cut;
  if (!/\s/.test(text.charAt(cut - 1))) {
    const limit = Math.min(text.length, cut + TAIL_PARTIAL_WORD_MAX);
    while (start < limit && !/\s/.test(text.charAt(start))) start++;
    if (start === limit) start = cut;
  }
  return replaceUnpairedSurrogates(text.slice(start).replace(/^\s+/, ""));
}

/**
 * Inline base64 media (`data:<mime>;base64,...`), with the newline that joined
 * it to neighboring text. Base64 is never useful search text: it fills the FTS
 * vocabulary with one-off tokens and spends the field caps before real text.
 */
const INLINE_MEDIA_DATA_URI_RE = /\n?data:[a-z0-9.+-]+\/[a-z0-9.+-]+;base64,[a-z0-9+/=_-]*/gi;

/** Remove inline base64 media from text bound for the search index. */
function stripInlineMediaDataUris(text: string): string {
  return text.replace(INLINE_MEDIA_DATA_URI_RE, "");
}

export interface SearchTranscriptContent {
  userMessages: string;
  assistantMessages: string;
  toolNames: string;
}

/**
 * Extract the FTS fields search indexes from a session's current branch. Search reads the
 * whole branch (`view: "full"`), so text a compaction hid from the model stays findable; rewound
 * branches stay out. Uses the same user/assistant/tool-name sources as mobile TraceEvents,
 * without constructing thinking, tool results, custom cards, or the mobile normalization tree.
 */
interface SearchTranscriptAccum {
  userParts: string[];
  assistantParts: string[];
  toolNameSet: Set<string>;
  userLen: number;
  assistantLen: number;
}

function emptySearchTranscriptAccum(): SearchTranscriptAccum {
  return { userParts: [], assistantParts: [], toolNameSet: new Set(), userLen: 0, assistantLen: 0 };
}

/**
 * Append a text part, then drop whole oldest parts the cap no longer needs (a part still
 * overlapping the cap window stays; `tailWithinCap` trims it at the end). Memory stays bounded
 * by the cap plus one part however long the session runs.
 *
 * `length` counts each part plus its joining newline. A part goes only while the rest stays over
 * the cap: then `tailWithinCap` still cuts, at the same place it would cut the whole text. Left
 * at or just under the cap, the rest would be kept uncut, leading whitespace and all, where an
 * append (`mergeSearchTranscript`) cuts and strips it.
 */
function pushCappedPart(parts: string[], length: number, text: string, cap: number): number {
  parts.push(text);
  length += text.length + 1;
  let drop = 0;
  while (drop < parts.length - 1) {
    const oldest = (parts[drop] ?? "").length + 1;
    if (length - oldest - 1 <= cap) break;
    length -= oldest;
    drop++;
  }
  if (drop > 0) parts.splice(0, drop);
  return length;
}

/**
 * An entry reduced to its place in the tree and what it adds to the search fields, in order. A
 * full read of a long file keeps these instead of parsed entries, so the file's tool output,
 * images and thinking are garbage as soon as their chunk is parsed.
 */
export interface SearchEntry extends EntryLink {
  user?: string;
  assistant?: string[];
  tools?: string[];
}

export function toSearchEntry(entry: SessionEntry): SearchEntry {
  const link: SearchEntry = { type: entry.type, id: entry.id, parentId: entry.parentId };
  const msg = entry.type === "message" ? entry.message : undefined;
  if (!msg) return link;

  if (msg.role === "user") {
    const text = stripInlineMediaDataUris(
      extractText(msg.content, { includeMediaDataURIs: false }),
    );
    if (text) link.user = replaceUnpairedSurrogates(text);
    return link;
  }

  if (msg.role !== "assistant") return link;

  const assistant: string[] = [];
  const tools: string[] = [];
  const content = msg.content;
  if (Array.isArray(content)) {
    for (const projected of projectAssistantContentRuns(msg)) {
      if (projected.kind === "text") {
        if (projected.text) {
          const normalized = replaceUnpairedSurrogates(stripInlineMediaDataUris(projected.text));
          if (normalized) assistant.push(normalized);
        }
        continue;
      }
      const block = projected.block;
      if (block.type === "toolCall") {
        const tool = (block.name as string) || "unknown";
        if (tool) tools.push(normalizeTraceValueForMobile(tool) as string);
      }
    }
  } else if (typeof content === "string" && content) {
    const normalized = replaceUnpairedSurrogates(stripInlineMediaDataUris(content));
    if (normalized) assistant.push(normalized);
  }
  if (assistant.length > 0) link.assistant = assistant;
  if (tools.length > 0) link.tools = tools;
  return link;
}

function consumeSearchEntry(accum: SearchTranscriptAccum, entry: SearchEntry): void {
  if (entry.user) {
    accum.userLen = pushCappedPart(
      accum.userParts,
      accum.userLen,
      entry.user,
      SEARCH_USER_MESSAGE_CAP,
    );
  }
  for (const text of entry.assistant ?? []) pushAssistantText(accum, text);
  for (const tool of entry.tools ?? []) accum.toolNameSet.add(tool);
}

function consumeSearchTranscriptEntry(accum: SearchTranscriptAccum, entry: SessionEntry): void {
  consumeSearchEntry(accum, toSearchEntry(entry));
}

function pushAssistantText(accum: SearchTranscriptAccum, text: string): void {
  accum.assistantLen = pushCappedPart(
    accum.assistantParts,
    accum.assistantLen,
    text,
    SEARCH_ASSISTANT_MESSAGE_CAP,
  );
}

function finishSearchTranscript(accum: SearchTranscriptAccum): SearchTranscriptContent {
  return mergeSearchTranscript(emptySearchTranscript(), finishSearchAddition(accum));
}

function emptySearchTranscript(): SearchTranscriptContent {
  return { userMessages: "", assistantMessages: "", toolNames: "" };
}

/** The accumulated text as joined, not yet cut to the caps: `mergeSearchTranscript` cuts it. */
function finishSearchAddition(accum: SearchTranscriptAccum): SearchTranscriptContent {
  return {
    userMessages: accum.userParts.join("\n"),
    assistantMessages: accum.assistantParts.join("\n"),
    toolNames: [...accum.toolNameSet].join(" "),
  };
}

function joinCapped(existing: string, addition: string, cap: number): string {
  const joined = !addition ? existing : !existing ? addition : `${existing}\n${addition}`;
  return tailWithinCap(joined, cap);
}

/**
 * Append the fields of newer entries (`extractSearchTranscriptAddition`) to the fields already
 * extracted from everything before them. The result is what one extraction over all the entries
 * yields: the addition is joined before any cut, so a long addition cannot displace text a
 * single cut would keep.
 */
export function mergeSearchTranscript(
  existing: SearchTranscriptContent,
  addition: SearchTranscriptContent,
): SearchTranscriptContent {
  const seen = new Set(existing.toolNames.split(" ").filter(Boolean));
  const extra = addition.toolNames.split(" ").filter((name) => name && !seen.has(name));
  const toolNames = [...new Set(extra)].join(" ");
  return {
    userMessages: joinCapped(existing.userMessages, addition.userMessages, SEARCH_USER_MESSAGE_CAP),
    assistantMessages: joinCapped(
      existing.assistantMessages,
      addition.assistantMessages,
      SEARCH_ASSISTANT_MESSAGE_CAP,
    ),
    toolNames:
      existing.toolNames && toolNames
        ? `${existing.toolNames} ${toolNames}`
        : existing.toolNames || toolNames,
  };
}

/**
 * Joins the additions of consecutive ranges of entries (`extractSearchTranscriptAddition`) read
 * one range at a time, dropping whole oldest ranges once the caps no longer need them, so memory
 * stays at a cap however long the history. `result()` is uncut, for `mergeSearchTranscript` to
 * cut (a cut made here would leave the final cut one it could not reproduce).
 */
export class SearchAdditionJoiner {
  private user: string[] = [];
  private userLen = 0;
  private assistant: string[] = [];
  private assistantLen = 0;
  private toolNames = new Set<string>();

  add(addition: SearchTranscriptContent): void {
    if (addition.userMessages) {
      this.userLen = pushCappedPart(
        this.user,
        this.userLen,
        addition.userMessages,
        SEARCH_USER_MESSAGE_CAP,
      );
    }
    if (addition.assistantMessages) {
      this.assistantLen = pushCappedPart(
        this.assistant,
        this.assistantLen,
        addition.assistantMessages,
        SEARCH_ASSISTANT_MESSAGE_CAP,
      );
    }
    for (const name of addition.toolNames.split(" ")) if (name) this.toolNames.add(name);
  }

  result(): SearchTranscriptContent {
    return {
      userMessages: this.user.join("\n"),
      assistantMessages: this.assistant.join("\n"),
      toolNames: [...this.toolNames].join(" "),
    };
  }
}

/**
 * True when a tool name holds whitespace: names are stored space-joined, so such a name cannot
 * be merged into an existing field by splitting it back apart. The caller extracts in full.
 */
export function hasUnsafeSearchToolName(entries: SessionEntry[]): boolean {
  for (const entry of entries) {
    const content = entry.message?.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (!block || typeof block !== "object") continue;
      const record = block as { type?: unknown; name?: unknown };
      if (record.type === "toolCall" && typeof record.name === "string" && /\s/.test(record.name)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * Fields of entries that follow ones already extracted, for `mergeSearchTranscript`. Same
 * extraction as `extractSearchTranscriptFromEntries`, without the final cut.
 */
export function extractSearchTranscriptAddition(entries: SessionEntry[]): SearchTranscriptContent {
  const { path } = selectVisibleSessionContext(entries, { view: "full" });
  const accum = emptySearchTranscriptAccum();
  for (const entry of path) consumeSearchTranscriptEntry(accum, entry);
  return finishSearchAddition(accum);
}

export function extractSearchTranscriptFromEntries(
  entries: SessionEntry[],
): SearchTranscriptContent {
  const { path } = selectVisibleSessionContext(entries, { view: "full" });
  const accum = emptySearchTranscriptAccum();
  for (const entry of path) consumeSearchTranscriptEntry(accum, entry);
  return finishSearchTranscript(accum);
}

/**
 * Same extraction as extractSearchTranscriptFromEntries over entries `toSearchEntry` reduced,
 * yielding every `yieldEvery` entries so a large file cannot stall one event-loop turn.
 * Returns null when `shouldStop` fires between slices.
 */
export async function extractSearchTranscriptYielding(
  entries: SearchEntry[],
  yieldEvery: number,
  shouldStop: () => boolean = () => false,
): Promise<SearchTranscriptContent | null> {
  const path = buildEntryPath(entries);
  const accum = emptySearchTranscriptAccum();
  for (let i = 0; i < path.length; i++) {
    if (i > 0 && i % yieldEvery === 0) {
      await new Promise<void>((resolve) => setImmediate(resolve));
      if (shouldStop()) return null;
    }
    const entry = path[i];
    if (entry) consumeSearchEntry(accum, entry);
  }
  return finishSearchTranscript(accum);
}

/**
 * Read a JSONL session file and extract search transcript fields plus the
 * leaf id those fields were walked from. Whole-file I/O; live turn-end
 * indexing does not use this.
 */
export function readSearchTranscriptFile(jsonlPath: string): {
  transcript: SearchTranscriptContent;
  leafId: string | null;
} | null {
  if (!existsSync(jsonlPath)) return null;
  try {
    const content = readFileSync(jsonlPath, "utf-8");
    const entries = parseSessionEntries(content);
    return {
      transcript: extractSearchTranscriptFromEntries(entries),
      leafId: sessionTranscriptLeafId(entries),
    };
  } catch {
    return null;
  }
}
