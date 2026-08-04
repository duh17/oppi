import { AsyncLocalStorage } from "node:async_hooks";

import type { ExtensionUITextSpan } from "./types.js";

/**
 * Minimal terminal colors. Replaces chalk — zero deps.
 *
 * Normal CLI output follows stdout's TTY/NO_COLOR policy. Captured human output
 * for the mobile terminal renderer opts into ANSI explicitly because it is not
 * written to a TTY, while NO_COLOR still wins in every context.
 */
const ansiCapture = new AsyncLocalStorage<boolean>();

export function withAnsiCapture<T>(fn: () => T): T {
  return ansiCapture.run(true, fn);
}

function ansiEnabled(): boolean {
  return (
    process.env.NO_COLOR === undefined &&
    (Boolean(process.stdout.isTTY) || ansiCapture.getStore() === true)
  );
}

const esc =
  (code: string): ((s: string) => string) =>
  (s: string): string =>
    ansiEnabled() ? `\x1b[${code}m${s}\x1b[0m` : s;

export const bold = esc("1");
export const dim = esc("2");
export const red = esc("31");
export const green = esc("32");
export const yellow = esc("33");
export const cyan = esc("36");

// ─── ANSI Sanitization ───

/**
 * Regex that matches non-SGR ANSI escape sequences — everything except
 * color/attribute codes (`ESC [ ... m`). Preserved SGR codes are rendered
 * by the iOS ANSIParser into styled NSAttributedString.
 *
 * Stripped:
 * - CSI non-SGR: cursor movement, erase, mode set/reset (ESC [ ... A-Za-ln-z)
 * - OSC sequences: hyperlinks, window title, shell integration (ESC ] ... BEL|ST)
 * - Character set designation: ESC ( A, ESC ) 0, etc.
 * - Two-byte C1 escapes: ESC =, ESC >, ESC N, ESC M, etc.
 * - 8-bit CSI (0x9b) variants
 *
 * Preserved: SGR — `ESC [ <digits;...> m` (colors, bold, dim, italic, underline, reset).
 */
const NON_SGR_ESCAPE_RE =
  // eslint-disable-next-line no-control-regex
  /\x1b\[[?>=!][\d;]*[A-Za-z]|\x1b\[[\d;]*[A-Za-ln-z]|\x1b\](?:[^\x07\x1b]|\x1b(?!\\))*(?:\x07|\x1b\\)|\x1b[()#][A-Z0-9]|\x1b[\x20-\x2f][\x40-\x5f]|\x1b[=>NMcDEHZ78]|\x9b[\d;]*[A-Za-z]/g;

/**
 * Strip non-SGR ANSI escape sequences from text, preserving colors.
 *
 * Tool output from bash commands may contain cursor movement, TUI chrome,
 * OSC hyperlinks, and shell integration marks that render as garbage in the
 * mobile client. SGR color codes (ESC[...m) are preserved — the iOS
 * ANSIParser renders them as styled attributed strings.
 *
 * Fast path: scans for ESC (0x1b) or CSI (0x9b) bytes first. When absent,
 * returns the input string directly without regex allocation.
 */
export function stripAnsiEscapes(text: string): string {
  // Fast path: most tool outputs have no ANSI escapes.
  // Check for ESC (0x1b) or CSI (0x9b) using native indexOf (V8-optimized).
  if (text.indexOf("\x1b") === -1 && text.indexOf("\x9b") === -1) return text;

  return text.replace(NON_SGR_ESCAPE_RE, "");
}

/** Strip every ANSI sequence, including SGR styling, from untrusted values. */
export function stripAllAnsiEscapes(text: string): string {
  // eslint-disable-next-line no-control-regex
  return stripAnsiEscapes(text).replace(/\x1b\[[\d;]*m/g, "");
}

interface TerminalSpanStyle {
  role?: ExtensionUITextSpan["role"];
  traits: Set<NonNullable<ExtensionUITextSpan["traits"]>[number]>;
}

const ESC = "\x1b";
const BEL = "\x07";
const CSI_8BIT = "\x9b";

function cloneStyle(style: TerminalSpanStyle): TerminalSpanStyle {
  return { role: style.role, traits: new Set(style.traits) };
}

function normalizedTraits(style: TerminalSpanStyle): ExtensionUITextSpan["traits"] | undefined {
  const traits = [...style.traits].sort();
  return traits.length > 0 ? traits : undefined;
}

function sameSpanMetadata(
  span: ExtensionUITextSpan,
  style: TerminalSpanStyle,
  link: string | undefined,
): boolean {
  const spanTraits = [...(span.traits ?? [])].sort();
  const styleTraits = [...style.traits].sort();
  return (
    span.role === style.role &&
    span.link === link &&
    spanTraits.length === styleTraits.length &&
    spanTraits.every((trait, index) => trait === styleTraits[index])
  );
}

function appendTerminalSpan(
  spans: ExtensionUITextSpan[],
  text: string,
  style: TerminalSpanStyle,
  link: string | undefined,
): void {
  if (!text) return;

  const last = spans.at(-1);
  if (last && sameSpanMetadata(last, style, link)) {
    last.text += text;
    return;
  }

  const span: ExtensionUITextSpan = { text };
  if (style.role) span.role = style.role;
  const traits = normalizedTraits(style);
  if (traits) span.traits = traits;
  if (link) span.link = link;
  spans.push(span);
}

function parseOsc(
  input: string,
  index: number,
): { content: string; nextIndex: number } | undefined {
  const start = index + 2;
  let belIndex = input.indexOf(BEL, start);
  if (belIndex === -1) belIndex = Number.POSITIVE_INFINITY;

  const stIndex = input.indexOf(`${ESC}\\`, start);
  const resolvedStIndex = stIndex === -1 ? Number.POSITIVE_INFINITY : stIndex;
  const end = Math.min(belIndex, resolvedStIndex);
  if (!Number.isFinite(end)) return undefined;

  return {
    content: input.slice(start, end),
    nextIndex: end + (end === resolvedStIndex ? 2 : 1),
  };
}

function parseCsi(
  input: string,
  index: number,
): { command: string; nextIndex: number } | undefined {
  let cursor = input[index] === CSI_8BIT ? index + 1 : index + 2;
  while (cursor < input.length) {
    const code = input.charCodeAt(cursor);
    if (code >= 0x40 && code <= 0x7e) {
      return {
        command: input.slice(index + (input[index] === CSI_8BIT ? 1 : 2), cursor + 1),
        nextIndex: cursor + 1,
      };
    }
    cursor += 1;
  }
  return undefined;
}

function applySgr(command: string, style: TerminalSpanStyle): TerminalSpanStyle {
  if (!command.endsWith("m")) return style;
  const body = command.slice(0, -1);
  const codes = body.length === 0 ? [0] : body.split(";").map((part) => Number(part || "0"));
  const next = cloneStyle(style);

  for (let index = 0; index < codes.length; index += 1) {
    const code = codes[index];
    switch (code) {
      case 0:
        next.role = undefined;
        next.traits.clear();
        break;
      case 1:
        next.traits.add("bold");
        break;
      case 2:
        next.role = "muted";
        break;
      case 3:
        next.traits.add("italic");
        break;
      case 4:
        next.traits.add("underline");
        break;
      case 9:
        next.traits.add("strikethrough");
        break;
      case 22:
        next.traits.delete("bold");
        if (next.role === "muted") next.role = undefined;
        break;
      case 23:
        next.traits.delete("italic");
        break;
      case 24:
        next.traits.delete("underline");
        break;
      case 29:
        next.traits.delete("strikethrough");
        break;
      case 31:
      case 91:
        next.role = "danger";
        break;
      case 32:
      case 92:
        next.role = "success";
        break;
      case 33:
      case 93:
        next.role = "warning";
        break;
      case 34:
      case 35:
      case 36:
      case 94:
      case 95:
      case 96:
        next.role = "accent";
        break;
      case 37:
      case 39:
        next.role = undefined;
        break;
      case 38:
      case 48:
        if (codes[index + 1] === 5) index += 2;
        else if (codes[index + 1] === 2) index += 4;
        break;
      default:
        break;
    }
  }

  return next;
}

function osc8Link(content: string): string | undefined | null {
  if (!content.startsWith("8;")) return null;
  const uriSeparator = content.indexOf(";", 2);
  if (uriSeparator === -1) return null;
  const uri = content.slice(uriSeparator + 1);
  return uri.length > 0 ? uri : undefined;
}

/**
 * Parse one terminal-rendered line into semantic text spans for native fallback
 * cards. OSC-8 hyperlinks are preserved as `span.link`; other terminal control
 * sequences are stripped. A small SGR subset maps to semantic roles/traits.
 */
export function terminalLineToTextSpans(input: string): ExtensionUITextSpan[] {
  if (input.length === 0) return [];

  const spans: ExtensionUITextSpan[] = [];
  let style: TerminalSpanStyle = { traits: new Set() };
  let activeLink: string | undefined;
  let buffer = "";

  const flush = (): void => {
    appendTerminalSpan(spans, buffer, style, activeLink);
    buffer = "";
  };

  for (let index = 0; index < input.length; ) {
    const char = input[index];

    if (char === ESC && input[index + 1] === "]") {
      const osc = parseOsc(input, index);
      if (!osc) {
        index += 1;
        continue;
      }

      const link = osc8Link(osc.content);
      if (link !== null) {
        flush();
        activeLink = link;
      }
      index = osc.nextIndex;
      continue;
    }

    if ((char === ESC && input[index + 1] === "[") || char === CSI_8BIT) {
      const csi = parseCsi(input, index);
      if (!csi) {
        index += 1;
        continue;
      }
      flush();
      style = applySgr(csi.command, style);
      index = csi.nextIndex;
      continue;
    }

    if (char === ESC) {
      flush();
      index += 2;
      continue;
    }

    buffer += char;
    index += 1;
  }

  flush();
  return spans;
}

export function terminalLineVisibleText(input: string): string {
  return terminalLineToTextSpans(input)
    .map((span) => span.text)
    .join("");
}
