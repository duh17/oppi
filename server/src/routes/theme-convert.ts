/**
 * Pi TUI theme → Oppi iOS theme conversion.
 *
 * Pi TUI uses 51 color tokens with variable references and 256-color integers.
 * Oppi iOS uses 49 flat #RRGGBB tokens. This module resolves vars, converts
 * color formats, and maps the token sets.
 *
 * Dropped pi tokens (TUI-only): accent, border, borderAccent, borderMuted,
 * selectedBg, customMessageBg, customMessageText, customMessageLabel, bashMode.
 *
 * Derived Oppi tokens (not in pi): bg, bgDark, bgHighlight, fg, fgDim, comment,
 * blue, cyan, green, orange, purple, red, yellow.
 */

export interface OppiTheme {
  name: string;
  colorScheme: "dark" | "light";
  colors: Record<string, string>;
  source: "pi";
}

/**
 * Convert 256-color integer to #RRGGBB hex.
 *
 * Palette layout:
 *   0-15:    basic ANSI (terminal-dependent, we use standard approximations)
 *   16-231:  6×6×6 RGB cube — index = 16 + 36R + 6G + B, channel = 0|55+40*v
 *   232-255: grayscale ramp — gray = 8 + 10*(n-232)
 */
export function color256ToHex(n: number): string {
  if (n < 0 || n > 255) return "#000000";

  if (n < 16) {
    const basic = [
      "#000000",
      "#800000",
      "#008000",
      "#808000",
      "#000080",
      "#800080",
      "#008080",
      "#c0c0c0",
      "#808080",
      "#ff0000",
      "#00ff00",
      "#ffff00",
      "#0000ff",
      "#ff00ff",
      "#00ffff",
      "#ffffff",
    ];
    return basic[n];
  }

  if (n < 232) {
    const idx = n - 16;
    const r = Math.floor(idx / 36);
    const g = Math.floor((idx % 36) / 6);
    const b = idx % 6;
    const ch = (v: number): number => (v === 0 ? 0 : 55 + v * 40);
    return (
      "#" +
      ch(r).toString(16).padStart(2, "0") +
      ch(g).toString(16).padStart(2, "0") +
      ch(b).toString(16).padStart(2, "0")
    );
  }

  const gray = 8 + (n - 232) * 10;
  const hex = gray.toString(16).padStart(2, "0");
  return `#${hex}${hex}${hex}`;
}

/** Resolve a single raw pi color value (hex, integer, or var name) to #RRGGBB. */
function resolveValue(value: string | number, vars: Record<string, string | number>): string {
  if (value === "") return "";
  if (typeof value === "number") return color256ToHex(value);
  if (value.startsWith("#")) return value;

  // Var reference — one level deep (pi spec: vars hold hex or int, not other vars)
  const varValue = vars[value];
  if (varValue === undefined) return value; // unresolved, pass through
  if (typeof varValue === "number") return color256ToHex(varValue);
  if (varValue.startsWith("#")) return varValue;
  return varValue; // unresolvable
}

/**
 * Resolve all var references in a pi theme's colors object.
 * Returns a flat map of token → #RRGGBB (or "" for default).
 */
export function resolvePiColors(
  colors: Record<string, string | number>,
  vars: Record<string, string | number> = {},
): Record<string, string> {
  const resolved: Record<string, string> = {};
  for (const [key, value] of Object.entries(colors)) {
    resolved[key] = resolveValue(value, vars);
  }
  return resolved;
}

/**
 * Resolve a single var entry to hex. Handles int, hex string, or returns null.
 */
function varToHex(v: string | number | undefined): string | null {
  if (v === undefined) return null;
  if (typeof v === "number") return color256ToHex(v);
  if (typeof v === "string" && v.startsWith("#")) return v;
  return null;
}

/** Perceived brightness 0-255 using sRGB luminance weights. */
function brightness(hex: string): number {
  if (!hex.startsWith("#") || hex.length !== 7) return 0;
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

/**
 * Find the darkest hex color among resolved vars, filtering by name hints.
 * Used to infer background colors from arbitrary var names.
 */
function findDarkestVar(vars: Record<string, string | number>, hints: string[]): string | null {
  let darkest: string | null = null;
  let minBright = 256;

  for (const hint of hints) {
    for (const [name, value] of Object.entries(vars)) {
      if (!name.toLowerCase().includes(hint)) continue;
      const hex = varToHex(value);
      if (!hex) continue;
      const b = brightness(hex);
      if (b < minBright) {
        minBright = b;
        darkest = hex;
      }
    }
    // Return first hint group that matches — prefer "bg" vars over random ones
    if (darkest) return darkest;
  }
  return darkest;
}

// Tokens shared 1:1 between pi TUI and Oppi (35 tokens).
const SHARED_TOKENS = [
  "userMessageBg",
  "userMessageText",
  "toolPendingBg",
  "toolSuccessBg",
  "toolErrorBg",
  "toolTitle",
  "toolOutput",
  "mdHeading",
  "mdLink",
  "mdLinkUrl",
  "mdCode",
  "mdCodeBlock",
  "mdCodeBlockBorder",
  "mdQuote",
  "mdQuoteBorder",
  "mdHr",
  "mdListBullet",
  "toolDiffAdded",
  "toolDiffRemoved",
  "toolDiffContext",
  "syntaxComment",
  "syntaxKeyword",
  "syntaxFunction",
  "syntaxVariable",
  "syntaxString",
  "syntaxNumber",
  "syntaxType",
  "syntaxOperator",
  "syntaxPunctuation",
  "thinkingOff",
  "thinkingMinimal",
  "thinkingLow",
  "thinkingMedium",
  "thinkingHigh",
  "thinkingXhigh",
] as const;

/**
 * Convert a pi TUI theme (51 tokens + vars) to an Oppi iOS theme (49 flat tokens).
 *
 * Derivation strategy for the 13 Oppi base colors not in pi's token set:
 *
 * - bg:      darkest var with bg/background/void/base in its name → fallback #1a1b26
 * - bgDark:  next-darkest bg-like var, or darken bg → fallback #16161e
 * - bgHighlight: pi selectedBg or userMessageBg → fallback #292e42
 * - fg:      pi text (if non-empty), else light/dark default
 * - fgDim:   pi muted
 * - comment: pi dim
 * - blue:    vars.blue or syntaxFunction
 * - cyan:    vars.cyan or syntaxType
 * - green:   vars.green or syntaxString or success
 * - orange:  vars.orange or syntaxNumber
 * - purple:  vars.purple or syntaxKeyword
 * - red:     vars.red or error
 * - yellow:  vars.yellow or warning
 */
export function convertPiTheme(piTheme: unknown): OppiTheme | null {
  if (!piTheme || typeof piTheme !== "object") return null;
  const theme = piTheme as Record<string, unknown>;

  const name = typeof theme.name === "string" ? theme.name : "Untitled";
  const vars = (theme.vars as Record<string, string | number>) ?? {};
  const piColors = (theme.colors as Record<string, string | number>) ?? {};
  const resolved = resolvePiColors(piColors, vars);

  // --- Derive bg from vars ---
  // Look for var names suggesting "background", picking the darkest.
  const bgHints = ["bg", "void", "base", "background"];
  const bgFromVars = findDarkestVar(vars, bgHints);
  const bg = bgFromVars ?? "#1a1b26";

  const isDark = brightness(bg) < 128;
  const colorScheme: "dark" | "light" = isDark ? "dark" : "light";
  const defaultText = isDark ? "#c0c4ce" : "#1a1a2e";

  // bgDark: find a var slightly darker or same tier as bg.
  // Strategy: collect all bg-like vars, sort by brightness, pick second-darkest
  // or use toolPendingBg (which pi themes often set to a near-bg shade).
  const bgDark = (() => {
    const candidates: { hex: string; bright: number }[] = [];
    for (const [vname, vval] of Object.entries(vars)) {
      const lower = vname.toLowerCase();
      if (
        bgHints.some((h) => lower.includes(h)) ||
        lower.includes("dark") ||
        lower.includes("onyx")
      ) {
        const hex = varToHex(vval);
        if (hex) candidates.push({ hex, bright: brightness(hex) });
      }
    }
    candidates.sort((a, b) => a.bright - b.bright);
    // Pick second-darkest if available, else fallback to toolPendingBg
    if (candidates.length >= 2) return candidates[1].hex;
    if (resolved.toolPendingBg?.startsWith("#")) return resolved.toolPendingBg;
    return "#16161e";
  })();

  // bgHighlight: elevated surface (selected, user messages)
  const bgHighlight = (() => {
    const sel = resolved.selectedBg;
    if (sel && sel.startsWith("#")) return sel;
    const umBg = resolved.userMessageBg;
    if (umBg && umBg.startsWith("#")) return umBg;
    // Try a lighter bg-like var
    const candidates: { hex: string; bright: number }[] = [];
    for (const [vname, vval] of Object.entries(vars)) {
      if (bgHints.some((h) => vname.toLowerCase().includes(h))) {
        const hex = varToHex(vval);
        if (hex) candidates.push({ hex, bright: brightness(hex) });
      }
    }
    candidates.sort((a, b) => b.bright - a.bright);
    if (candidates.length > 0 && candidates[0].hex !== bg) return candidates[0].hex;
    return "#292e42";
  })();

  // Helper: first valid hex from a list of candidates
  const pick = (...candidates: (string | number | undefined | null)[]): string => {
    for (const c of candidates) {
      const hex = varToHex(c as string | number | undefined);
      if (hex) return hex;
    }
    return defaultText;
  };

  const oppiColors: Record<string, string> = {
    bg,
    bgDark,
    bgHighlight,
    fg: resolved.text && resolved.text !== "" ? resolved.text : defaultText,
    fgDim: resolved.muted?.startsWith("#")
      ? resolved.muted
      : pick(vars.muted, vars.fgDim, vars.fgDark) || "#a9b1d6",
    comment: resolved.dim?.startsWith("#")
      ? resolved.dim
      : pick(vars.dim, vars.comment, vars.dark5) || "#565f89",
    blue: pick(vars.blue, vars.blue0) || resolved.syntaxFunction || "#7aa2f7",
    cyan: pick(vars.cyan, vars.teal) || resolved.syntaxType || "#7dcfff",
    green: pick(vars.green, vars.green1) || resolved.success || resolved.syntaxString || "#9ece6a",
    orange: pick(vars.orange) || resolved.syntaxNumber || "#ff9e64",
    purple: pick(vars.purple, vars.magenta) || resolved.syntaxKeyword || "#bb9af7",
    red: pick(vars.red) || resolved.error || "#f7768e",
    yellow: pick(vars.yellow) || resolved.warning || "#e0af68",
    thinkingText: resolved.thinkingText?.startsWith("#")
      ? resolved.thinkingText
      : pick(vars.dim, vars.comment) || "#a9b1d6",
  };

  // Copy shared tokens 1:1
  for (const key of SHARED_TOKENS) {
    if (key in resolved && resolved[key] !== undefined) {
      oppiColors[key] = resolved[key];
    }
  }

  // Final validation: every value must be "" or #RRGGBB
  for (const [key, value] of Object.entries(oppiColors)) {
    if (value === "") continue;
    if (value.startsWith("#") && /^#[0-9a-fA-F]{6}$/.test(value)) continue;

    // Last-resort: try resolving as a var ref that slipped through
    const hex = varToHex(vars[value]);
    if (hex) {
      oppiColors[key] = hex;
      continue;
    }
    return null; // Unresolvable color — bail
  }

  return { name, colorScheme, colors: oppiColors, source: "pi" };
}
