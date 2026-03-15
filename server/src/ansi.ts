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

// ─── ANSI Stripping ───

/**
 * Regex that matches ANSI escape sequences including:
 * - CSI sequences: ESC [ ... (SGR colors, cursor movement, erase, mode sets)
 * - OSC sequences: ESC ] ... ST  (hyperlinks, window title, shell integration)
 * - Simple two-byte escapes: ESC followed by a single character
 *
 * Based on the ansi-regex package pattern, extended to handle OSC terminated
 * by both BEL (\x07) and ST (ESC \).
 */
const ANSI_ESCAPE_RE =
  // eslint-disable-next-line no-control-regex
  /\x1b\[[\d;]*m|\x1b\[[?>=!]?[\d;]*[A-Za-z]|\x1b\](?:[^\x07\x1b]|\x1b(?!\\))*(?:\x07|\x1b\\)|\x1b[()#][A-Z0-9]|\x1b[\x20-\x2f][\x40-\x5f]|\x1b[=>NMcDEHZ78]|\x9b[\d;]*[A-Za-z]/g;

/**
 * Strip all ANSI escape sequences from text.
 *
 * Tool output from bash commands may contain terminal formatting (colors,
 * cursor movement, TUI chrome) that is meaningless in the mobile client.
 * This strips it down to plain text.
 *
 * Fast path: scans for ESC (0x1b) or CSI (0x9b) bytes first. When absent,
 * returns the input string directly without regex allocation.
 */
export function stripAnsiEscapes(text: string): string {
  // Fast path: most tool outputs have no ANSI escapes.
  // Check for ESC (0x1b) or CSI (0x9b) using native indexOf (V8-optimized).
  if (text.indexOf("\x1b") === -1 && text.indexOf("\x9b") === -1) return text;

  return text.replace(ANSI_ESCAPE_RE, "");
}
