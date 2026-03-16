/**
 * Minimal terminal colors. Replaces chalk — zero deps.
 * Each function wraps text in ANSI escape codes with reset.
 */
const esc =
  (code: string): ((s: string) => string) =>
  (s: string): string =>
    `\x1b[${code}m${s}\x1b[0m`;

export const bold = esc("1");
export const dim = esc("2");
export const red = esc("31");
export const green = esc("32");
export const yellow = esc("33");
export const cyan = esc("36");
export const boldMagenta = (s: string): string => `\x1b[1;35m${s}\x1b[0m`;

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
