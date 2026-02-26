import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { convertPiTheme } from "./theme-convert.js";

export function createThemeRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function themesDir(): string {
    return join(ctx.storage.getDataDir(), "themes");
  }

  function bundledThemesDir(): string {
    return join(import.meta.dirname, "..", "themes");
  }

  function piThemesDir(): string {
    return join(homedir(), ".pi", "agent", "themes");
  }

  type ThemeSource = "bundled" | "user" | "pi";
  type ThemeSummary = {
    name: string;
    filename: string;
    colorScheme: string;
    source: ThemeSource;
  };

  /** Scan a directory for Oppi-format theme JSON files. */
  function scanThemeDir(dir: string, source: "bundled" | "user"): ThemeSummary[] {
    if (!existsSync(dir)) return [];
    const results: ThemeSummary[] = [];
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      try {
        const content = readFileSync(join(dir, f), "utf8");
        const parsed = JSON.parse(content);
        results.push({
          name: (parsed.name as string) ?? f.replace(/\.json$/, ""),
          filename: f.replace(/\.json$/, ""),
          colorScheme: (parsed.colorScheme as string) ?? "dark",
          source,
        });
      } catch {
        // Skip malformed theme files
      }
    }
    return results;
  }

  /** Scan pi TUI themes directory and convert to Oppi format for listing. */
  function scanPiThemes(): ThemeSummary[] {
    const dir = piThemesDir();
    if (!existsSync(dir)) return [];
    const results: ThemeSummary[] = [];
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      try {
        const content = readFileSync(join(dir, f), "utf8");
        const parsed = JSON.parse(content);
        const converted = convertPiTheme(parsed);
        if (!converted) continue;
        results.push({
          name: converted.name,
          filename: f.replace(/\.json$/, ""),
          colorScheme: converted.colorScheme,
          source: "pi",
        });
      } catch {
        // Skip malformed pi themes
      }
    }
    return results;
  }

  function handleListThemes(res: ServerResponse): void {
    // Priority: bundled (lowest) → pi-auto → user (highest).
    const bundled = scanThemeDir(bundledThemesDir(), "bundled");
    const piAuto = scanPiThemes();
    const user = scanThemeDir(themesDir(), "user");
    const byFilename = new Map<string, ThemeSummary>();
    for (const t of bundled) byFilename.set(t.filename, t);
    for (const t of piAuto) byFilename.set(t.filename, t);
    for (const t of user) byFilename.set(t.filename, t);
    helpers.json(res, { themes: [...byFilename.values()] });
  }

  function handleGetTheme(name: string, res: ServerResponse): void {
    // Priority: user > pi-auto > bundled.
    let filePath = join(themesDir(), `${name}.json`);
    let isPiTheme = false;
    if (!existsSync(filePath)) {
      filePath = join(piThemesDir(), `${name}.json`);
      isPiTheme = existsSync(filePath);
    }
    if (!existsSync(filePath)) {
      filePath = join(bundledThemesDir(), `${name}.json`);
      isPiTheme = false;
    }
    if (!existsSync(filePath)) {
      helpers.error(res, 404, `Theme "${name}" not found`);
      return;
    }
    try {
      const content = readFileSync(filePath, "utf8");
      const parsed = JSON.parse(content);
      if (isPiTheme) {
        const converted = convertPiTheme(parsed);
        if (!converted) {
          helpers.error(res, 500, "Failed to convert pi theme");
          return;
        }
        helpers.json(res, { theme: converted });
      } else {
        helpers.json(res, { theme: parsed });
      }
    } catch {
      helpers.error(res, 500, "Failed to read theme");
    }
  }

  async function handlePutTheme(
    name: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<{ theme: Record<string, unknown> }>(req);
    const theme = body.theme;
    if (!theme || typeof theme !== "object") {
      helpers.error(res, 400, "Missing theme object in body");
      return;
    }
    const colors = theme.colors as Record<string, string> | undefined;
    const requiredKeys = [
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
    if (!colors || typeof colors !== "object") {
      helpers.error(res, 400, "Missing colors object");
      return;
    }
    const missing = requiredKeys.filter((k) => !(k in colors));
    if (missing.length > 0) {
      helpers.error(res, 400, `Missing color keys: ${missing.join(", ")}`);
      return;
    }
    for (const [key, value] of Object.entries(colors)) {
      if (typeof value !== "string") {
        helpers.error(res, 400, `Invalid color value for "${key}": expected string`);
        return;
      }
      if (value !== "" && !/^#[0-9a-fA-F]{6}$/.test(value)) {
        helpers.error(res, 400, `Invalid hex color for "${key}": ${value}`);
        return;
      }
    }
    const dir = themesDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const sanitizedName = name.replace(/[^a-zA-Z0-9_-]/g, "");
    if (!sanitizedName) {
      helpers.error(res, 400, "Invalid theme name");
      return;
    }
    const themeData = {
      name: (theme.name as string) ?? sanitizedName,
      colorScheme: (theme.colorScheme as string) ?? "dark",
      colors,
    };
    const { writeFileSync } = await import("node:fs");
    writeFileSync(join(dir, `${sanitizedName}.json`), JSON.stringify(themeData, null, 2), "utf8");
    helpers.json(res, { theme: themeData, saved: true }, 201);
  }

  function handleDeleteTheme(name: string, res: ServerResponse): void {
    const sanitizedName = name.replace(/[^a-zA-Z0-9_-]/g, "");
    const filePath = join(themesDir(), `${sanitizedName}.json`);
    if (!existsSync(filePath)) {
      helpers.error(res, 404, `Theme "${name}" not found`);
      return;
    }
    unlinkSync(filePath);
    helpers.json(res, { deleted: true });
  }

  return async ({ method, path, req, res }) => {
    if (path === "/themes" && method === "GET") {
      handleListThemes(res);
      return true;
    }

    const themeMatch = path.match(/^\/themes\/([^/]+)$/);
    if (themeMatch) {
      const themeName = decodeURIComponent(themeMatch[1]);
      if (method === "GET") {
        handleGetTheme(themeName, res);
        return true;
      }
      if (method === "PUT") {
        await handlePutTheme(themeName, req, res);
        return true;
      }
      if (method === "DELETE") {
        handleDeleteTheme(themeName, res);
        return true;
      }
    }

    return false;
  };
}
