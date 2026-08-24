import { describe, expect, test } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const THEMES_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "themes");

const READABLE_THEMES = [
  "tokyo-night.json",
  "tokyo-night-storm.json",
  "tokyo-night-day.json",
  "rose-pine.json",
  "rose-pine-moon.json",
  "rose-pine-dawn.json",
] as const;

const AA = 4.5;
const READ = 5.5;

const HEX = /^#[0-9a-fA-F]{6}$/;

const REQUIRED_KEYS = [
  "bg",
  "bgDark",
  "bgHighlight",
  "fg",
  "fgDim",
  "comment",
  "blue",
  "cyan",
  "green",
  "orange",
  "purple",
  "red",
  "yellow",
  "thinkingText",
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

type ThemeFile = {
  name: string;
  colorScheme: "dark" | "light";
  colors: Record<string, string>;
};

function srgbToLinear(channel: number): number {
  const s = channel / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

function relativeLuminance(hex: string): number {
  const n = Number.parseInt(hex.slice(1), 16);
  const r = srgbToLinear((n >> 16) & 0xff);
  const g = srgbToLinear((n >> 8) & 0xff);
  const b = srgbToLinear(n & 0xff);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrastRatio(fg: string, bg: string): number {
  const a = relativeLuminance(fg);
  const b = relativeLuminance(bg);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

function loadTheme(filename: string): ThemeFile {
  return JSON.parse(readFileSync(join(THEMES_DIR, filename), "utf8")) as ThemeFile;
}

const checks: Array<{ label: string; fg: string; bg: string; min: number }> = [
  { label: "fg on bg", fg: "fg", bg: "bg", min: AA },
  { label: "fg on bgDark", fg: "fg", bg: "bgDark", min: AA },
  { label: "fg on bgHighlight", fg: "fg", bg: "bgHighlight", min: AA },
  { label: "userMessageText on userMessageBg", fg: "userMessageText", bg: "userMessageBg", min: AA },
  { label: "fgDim on bg", fg: "fgDim", bg: "bg", min: READ },
  { label: "fgDim on bgDark", fg: "fgDim", bg: "bgDark", min: READ },
  { label: "comment on bg", fg: "comment", bg: "bg", min: READ },
  { label: "comment on bgDark", fg: "comment", bg: "bgDark", min: READ },
  { label: "toolOutput on bg", fg: "toolOutput", bg: "bg", min: READ },
  { label: "toolOutput on bgDark", fg: "toolOutput", bg: "bgDark", min: READ },
  { label: "toolTitle on bg", fg: "toolTitle", bg: "bg", min: AA },
  { label: "syntaxComment on bgDark", fg: "syntaxComment", bg: "bgDark", min: READ },
  { label: "syntaxKeyword on bgDark", fg: "syntaxKeyword", bg: "bgDark", min: AA },
  { label: "syntaxFunction on bgDark", fg: "syntaxFunction", bg: "bgDark", min: AA },
  { label: "syntaxString on bgDark", fg: "syntaxString", bg: "bgDark", min: AA },
  { label: "syntaxNumber on bgDark", fg: "syntaxNumber", bg: "bgDark", min: AA },
  { label: "syntaxType on bgDark", fg: "syntaxType", bg: "bgDark", min: AA },
  { label: "syntaxVariable on bgDark", fg: "syntaxVariable", bg: "bgDark", min: AA },
  { label: "syntaxOperator on bgDark", fg: "syntaxOperator", bg: "bgDark", min: AA },
  { label: "syntaxPunctuation on bgDark", fg: "syntaxPunctuation", bg: "bgDark", min: READ },
  { label: "blue on bg", fg: "blue", bg: "bg", min: AA },
  { label: "cyan on bg", fg: "cyan", bg: "bg", min: AA },
  { label: "green on bg", fg: "green", bg: "bg", min: AA },
  { label: "orange on bg", fg: "orange", bg: "bg", min: AA },
  { label: "purple on bg", fg: "purple", bg: "bg", min: AA },
  { label: "red on bg", fg: "red", bg: "bg", min: AA },
  { label: "yellow on bg", fg: "yellow", bg: "bg", min: AA },
  { label: "toolDiffAdded on bgDark", fg: "toolDiffAdded", bg: "bgDark", min: AA },
  { label: "toolDiffRemoved on bgDark", fg: "toolDiffRemoved", bg: "bgDark", min: AA },
  { label: "toolDiffContext on bgDark", fg: "toolDiffContext", bg: "bgDark", min: READ },
  { label: "mdHeading on bg", fg: "mdHeading", bg: "bg", min: AA },
  { label: "mdLink on bg", fg: "mdLink", bg: "bg", min: AA },
  { label: "mdLinkUrl on bg", fg: "mdLinkUrl", bg: "bg", min: READ },
  { label: "mdCode on bg", fg: "mdCode", bg: "bg", min: AA },
  { label: "mdCodeBlock on bgDark", fg: "mdCodeBlock", bg: "bgDark", min: AA },
  { label: "mdQuote on bg", fg: "mdQuote", bg: "bg", min: READ },
];

describe("readable bundled theme palettes", () => {
  test("readable theme files are present", () => {
    const files = new Set(readdirSync(THEMES_DIR).filter((name) => name.endsWith(".json")));
    expect([...READABLE_THEMES].filter((name) => !files.has(name))).toEqual([]);
  });

  for (const filename of READABLE_THEMES) {
    test(`${filename} keeps official hues readable on chat and code surfaces`, () => {
      const theme = loadTheme(filename);
      expect(theme.colorScheme === "dark" || theme.colorScheme === "light").toBe(true);
      expect(Object.keys(theme.colors).sort()).toEqual([...REQUIRED_KEYS].sort());

      for (const key of REQUIRED_KEYS) {
        expect(theme.colors[key], key).toMatch(HEX);
      }

      const failures = checks.flatMap((check) => {
        const fg = theme.colors[check.fg];
        const bg = theme.colors[check.bg];
        const ratio = contrastRatio(fg, bg);
        if (ratio + 1e-6 >= check.min) return [];
        return [`${check.label}: ${ratio.toFixed(2)} < ${check.min} (${fg} on ${bg})`];
      });

      expect(failures).toEqual([]);
    });
  }
});
