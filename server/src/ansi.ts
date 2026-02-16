/**
 * Minimal terminal colors. Replaces chalk — zero deps.
 * Each function wraps text in ANSI escape codes with reset.
 */
const esc = (code: string) => (s: string) => `\x1b[${code}m${s}\x1b[0m`;

export const bold = esc("1");
export const dim = esc("2");
export const red = esc("31");
export const green = esc("32");
export const yellow = esc("33");
export const cyan = esc("36");
export const magenta = esc("35");
export const boldMagenta = (s: string) => `\x1b[1;35m${s}\x1b[0m`;
