import { describe, expect, test } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { color256ToHex, convertPiTheme, resolvePiColors } from "../theme-convert.js";

// All 49 Oppi tokens that a converted theme must contain.
const REQUIRED_OPPI_KEYS = [
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
];

function isValidHex(v: string): boolean {
  return v === "" || /^#[0-9a-fA-F]{6}$/.test(v);
}

function requireConvertedTheme(
  result: ReturnType<typeof convertPiTheme>,
): NonNullable<ReturnType<typeof convertPiTheme>> {
  expect(result).not.toBeNull();
  if (result === null) {
    throw new Error("Expected converted theme to be non-null");
  }
  return result;
}

describe("color256ToHex", () => {
  test("basic ANSI colors (0-15)", () => {
    expect(color256ToHex(0)).toBe("#000000");
    expect(color256ToHex(1)).toBe("#800000");
    expect(color256ToHex(9)).toBe("#ff0000");
    expect(color256ToHex(15)).toBe("#ffffff");
  });

  test("RGB cube (16-231)", () => {
    expect(color256ToHex(16)).toBe("#000000"); // 0,0,0
    expect(color256ToHex(21)).toBe("#0000ff"); // 0,0,5
    expect(color256ToHex(196)).toBe("#ff0000"); // 5,0,0
    expect(color256ToHex(226)).toBe("#ffff00"); // 5,5,0
    expect(color256ToHex(231)).toBe("#ffffff"); // 5,5,5
  });

  test("grayscale ramp (232-255)", () => {
    expect(color256ToHex(232)).toBe("#080808");
    expect(color256ToHex(242)).toBe("#6c6c6c");
    expect(color256ToHex(255)).toBe("#eeeeee");
  });

  test("out-of-range → #000000", () => {
    expect(color256ToHex(-1)).toBe("#000000");
    expect(color256ToHex(256)).toBe("#000000");
  });
});

describe("resolvePiColors", () => {
  test("resolves var references to hex", () => {
    const vars = { blue: "#0066cc", red: "#cc0000" };
    const colors = { accent: "blue", error: "red", border: "#333333" };
    const resolved = resolvePiColors(colors, vars);
    expect(resolved.accent).toBe("#0066cc");
    expect(resolved.error).toBe("#cc0000");
    expect(resolved.border).toBe("#333333");
  });

  test("resolves 256-color integers", () => {
    const resolved = resolvePiColors({ bg: 232, fg: 255 });
    expect(resolved.bg).toBe("#080808");
    expect(resolved.fg).toBe("#eeeeee");
  });

  test("resolves var pointing to integer", () => {
    const vars = { gray: 242 };
    const resolved = resolvePiColors({ dim: "gray" }, vars);
    expect(resolved.dim).toBe("#6c6c6c");
  });

  test("preserves empty string", () => {
    const resolved = resolvePiColors({ text: "" });
    expect(resolved.text).toBe("");
  });

  test("passes through unknown var names", () => {
    const resolved = resolvePiColors({ accent: "unknownVar" });
    expect(resolved.accent).toBe("unknownVar");
  });
});

describe("convertPiTheme", () => {
  test("returns null for non-objects", () => {
    expect(convertPiTheme(null)).toBeNull();
    expect(convertPiTheme(undefined)).toBeNull();
    expect(convertPiTheme("string")).toBeNull();
    expect(convertPiTheme(42)).toBeNull();
  });

  test("converts minimal pi theme with correct bg derivation", () => {
    const pi = {
      name: "Test",
      vars: { bg: "#1a1b26", bgDark: "#16161e", blue: "#0066cc" },
      colors: {
        text: "",
        thinkingText: "#999999",
        userMessageBg: "#222233",
        userMessageText: "",
        toolPendingBg: "#181820",
        toolSuccessBg: "#001100",
        toolErrorBg: "#110000",
        toolTitle: "blue",
        toolOutput: "#cccccc",
        muted: "#888888",
        dim: "#555555",
        error: "#cc0000",
        warning: "#cccc00",
        success: "#00cc00",
        mdHeading: "blue",
        mdLink: "blue",
        mdLinkUrl: "#666666",
        mdCode: "blue",
        mdCodeBlock: "",
        mdCodeBlockBorder: "#333333",
        mdQuote: "#999999",
        mdQuoteBorder: "#333333",
        mdHr: "#333333",
        mdListBullet: "blue",
        toolDiffAdded: "#00cc00",
        toolDiffRemoved: "#cc0000",
        toolDiffContext: "#999999",
        syntaxComment: "#666666",
        syntaxKeyword: "#cc00cc",
        syntaxFunction: "blue",
        syntaxVariable: "",
        syntaxString: "#00cc00",
        syntaxNumber: "#cc6600",
        syntaxType: "#00cccc",
        syntaxOperator: "#999999",
        syntaxPunctuation: "#999999",
        thinkingOff: "#333333",
        thinkingMinimal: "#444444",
        thinkingLow: "#555555",
        thinkingMedium: "#666666",
        thinkingHigh: "#777777",
        thinkingXhigh: "#888888",
      },
    };

    const result = convertPiTheme(pi);
    const theme = requireConvertedTheme(result);
    expect(theme.name).toBe("Test");
    expect(theme.colorScheme).toBe("dark");
    expect(theme.source).toBe("pi");

    // bg should come from vars.bg, not toolPendingBg
    expect(theme.colors.bg).toBe("#16161e"); // darkest bg-like var
    expect(theme.colors.blue).toBe("#0066cc");
    expect(theme.colors.fg).toBe("#c0c4ce"); // default for dark theme with text=""
    expect(theme.colors.toolTitle).toBe("#0066cc"); // resolved from var
  });

  test("picks darkest bg-like var for bg", () => {
    // ember-style: void is darkest, onyx next, obsidian lighter
    const pi = {
      name: "Ember",
      vars: {
        void: "#0c0d12",
        onyx: "#13141b",
        obsidian: "#1a1c25",
        charcoal: "#24262f",
        amber: "#e5a44a",
      },
      colors: {
        text: "",
        thinkingText: "#484c5a",
        userMessageBg: "#1a1c25",
        userMessageText: "",
        toolPendingBg: "#13141b",
        toolSuccessBg: "#141e14",
        toolErrorBg: "#1e1414",
        toolTitle: "amber",
        toolOutput: "#6e7282",
        muted: "#6e7282",
        dim: "#484c5a",
        error: "#d86070",
        warning: "#dab850",
        success: "#7cc07c",
        mdHeading: "amber",
        mdLink: "#5ab0ca",
        mdLinkUrl: "#484c5a",
        mdCode: "#c89838",
        mdCodeBlock: "",
        mdCodeBlockBorder: "#383b4a",
        mdQuote: "#6e7282",
        mdQuoteBorder: "#383b4a",
        mdHr: "#383b4a",
        mdListBullet: "#c89838",
        toolDiffAdded: "#7cc07c",
        toolDiffRemoved: "#d86070",
        toolDiffContext: "#6e7282",
        syntaxComment: "#505468",
        syntaxKeyword: "#aa72c4",
        syntaxFunction: "amber",
        syntaxVariable: "",
        syntaxString: "#7cc07c",
        syntaxNumber: "#cc8850",
        syntaxType: "#5ab0ca",
        syntaxOperator: "#6e7282",
        syntaxPunctuation: "#484c5a",
        thinkingOff: "#484c5a",
        thinkingMinimal: "#383b4a",
        thinkingLow: "#5a88c0",
        thinkingMedium: "#e5a44a",
        thinkingHigh: "#5ab0ca",
        thinkingXhigh: "#e060a0",
      },
    };

    const result = convertPiTheme(pi);
    const theme = requireConvertedTheme(result);
    // void (#0c0d12) is darkest — should be bg
    expect(theme.colors.bg).toBe("#0c0d12");
    // onyx (#13141b) is next — should be bgDark
    expect(theme.colors.bgDark).toBe("#13141b");
  });

  test("detects light theme", () => {
    const pi = {
      name: "Light",
      vars: { bg: "#f5f5f5", bgDark: "#e0e0e0" },
      colors: {
        text: "#1a1a1a",
        thinkingText: "#666666",
        toolPendingBg: "#e8e8e8",
        userMessageBg: "#f0f0f0",
        userMessageText: "#000000",
        toolSuccessBg: "#e0ffe0",
        toolErrorBg: "#ffe0e0",
        toolTitle: "#0066cc",
        toolOutput: "#333333",
        muted: "#888888",
        dim: "#aaaaaa",
        error: "#cc0000",
        warning: "#aa8800",
        success: "#008800",
        mdHeading: "#0066cc",
        mdLink: "#0066cc",
        mdLinkUrl: "#666666",
        mdCode: "#0066cc",
        mdCodeBlock: "#000000",
        mdCodeBlockBorder: "#cccccc",
        mdQuote: "#666666",
        mdQuoteBorder: "#cccccc",
        mdHr: "#cccccc",
        mdListBullet: "#0066cc",
        toolDiffAdded: "#00aa00",
        toolDiffRemoved: "#aa0000",
        toolDiffContext: "#666666",
        syntaxComment: "#999999",
        syntaxKeyword: "#aa00aa",
        syntaxFunction: "#0066cc",
        syntaxVariable: "#000000",
        syntaxString: "#00aa00",
        syntaxNumber: "#aa6600",
        syntaxType: "#00aaaa",
        syntaxOperator: "#666666",
        syntaxPunctuation: "#666666",
        thinkingOff: "#cccccc",
        thinkingMinimal: "#bbbbbb",
        thinkingLow: "#aaaaaa",
        thinkingMedium: "#999999",
        thinkingHigh: "#888888",
        thinkingXhigh: "#777777",
      },
    };

    const result = convertPiTheme(pi);
    const theme = requireConvertedTheme(result);
    expect(theme.colorScheme).toBe("light");
    expect(theme.colors.fg).toBe("#1a1a1a"); // explicit text, not default
  });

  test("handles theme with missing colors (fallbacks)", () => {
    const pi = {
      name: "Sparse",
      vars: {},
      colors: {
        text: "#ffffff",
        thinkingText: "#999999",
      },
    };

    const result = convertPiTheme(pi);
    const theme = requireConvertedTheme(result);
    // Should have fallback values
    expect(theme.colors.bg).toBeTruthy();
    expect(theme.colors.blue).toBeTruthy();
  });

  test("all output values are valid hex or empty", () => {
    const pi = {
      name: "Validation",
      vars: { bg: "#1a1b26", gray: 242, blue: "#0066cc" },
      colors: {
        text: "",
        thinkingText: "gray",
        muted: "gray",
        dim: "gray",
        error: "#cc0000",
        warning: "#cccc00",
        success: "#00cc00",
        userMessageBg: "bg",
        userMessageText: "",
        toolPendingBg: "bg",
        toolSuccessBg: "#002200",
        toolErrorBg: "#220000",
        toolTitle: "blue",
        toolOutput: "gray",
        mdHeading: "blue",
        mdLink: "blue",
        mdLinkUrl: "gray",
        mdCode: "blue",
        mdCodeBlock: "",
        mdCodeBlockBorder: "gray",
        mdQuote: "gray",
        mdQuoteBorder: "gray",
        mdHr: "gray",
        mdListBullet: "blue",
        toolDiffAdded: "#00cc00",
        toolDiffRemoved: "#cc0000",
        toolDiffContext: "gray",
        syntaxComment: "gray",
        syntaxKeyword: "#cc00cc",
        syntaxFunction: "blue",
        syntaxVariable: "",
        syntaxString: "#00cc00",
        syntaxNumber: "#cc6600",
        syntaxType: "#00cccc",
        syntaxOperator: "gray",
        syntaxPunctuation: "gray",
        thinkingOff: "gray",
        thinkingMinimal: "gray",
        thinkingLow: "blue",
        thinkingMedium: "blue",
        thinkingHigh: "#cc00cc",
        thinkingXhigh: "#cc0000",
      },
    };

    const result = convertPiTheme(pi);
    const theme = requireConvertedTheme(result);
    for (const [key, value] of Object.entries(theme.colors)) {
      expect(isValidHex(value), `${key}="${value}" is not valid hex`).toBe(true);
    }
  });

  // Integration test: convert the actual ember pi theme if present
  test("converts real ember.json from ~/.pi/agent/themes/", () => {
    const emberPath = join(homedir(), ".pi", "agent", "themes", "ember.json");
    if (!existsSync(emberPath)) {
      // Skip if ember theme not installed
      return;
    }

    const content = readFileSync(emberPath, "utf8");
    const piTheme = JSON.parse(content);
    const result = convertPiTheme(piTheme);
    const theme = requireConvertedTheme(result);

    expect(theme.name).toBe("ember");
    expect(theme.colorScheme).toBe("dark");
    expect(theme.source).toBe("pi");

    // All 49 tokens present and valid
    for (const key of REQUIRED_OPPI_KEYS) {
      expect(theme.colors, `missing key: ${key}`).toHaveProperty(key);
      expect(isValidHex(theme.colors[key]), `${key}="${theme.colors[key]}" invalid`).toBe(true);
    }

    // Verify bg comes from darkest var (void=#0c0d12), not toolPendingBg
    expect(theme.colors.bg).toBe("#0c0d12");
  });
});
