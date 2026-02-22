import type { IncomingMessage, ServerResponse } from "node:http";
import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createThemeRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function themesDir(): string {
    return join(ctx.storage.getDataDir(), "themes");
  }

  /** Bundled theme files shipped with the server. */
  function bundledThemesDir(): string {
    return join(import.meta.dirname, "..", "themes");
  }

  /** Scan a directory for theme JSON files. */
  function scanThemeDir(
    dir: string,
  ): Array<{ name: string; filename: string; colorScheme: string }> {
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => {
        try {
          const content = readFileSync(join(dir, f), "utf8");
          const parsed = JSON.parse(content);
          return {
            name: (parsed.name as string) ?? f.replace(/\.json$/, ""),
            filename: f.replace(/\.json$/, ""),
            colorScheme: (parsed.colorScheme as string) ?? "dark",
          };
        } catch {
          return null;
        }
      })
      .filter((t): t is { name: string; filename: string; colorScheme: string } => t !== null);
  }

  function handleListThemes(res: ServerResponse): void {
    // Merge bundled + user themes. User themes override bundled by filename.
    const bundled = scanThemeDir(bundledThemesDir());
    const user = scanThemeDir(themesDir());
    const byFilename = new Map<string, { name: string; filename: string; colorScheme: string }>();
    for (const t of bundled) byFilename.set(t.filename, t);
    for (const t of user) byFilename.set(t.filename, t);
    helpers.json(res, { themes: [...byFilename.values()] });
  }

  function handleGetTheme(name: string, res: ServerResponse): void {
    // User themes override bundled; fall back to bundled dir.
    let filePath = join(themesDir(), `${name}.json`);
    if (!existsSync(filePath)) {
      filePath = join(bundledThemesDir(), `${name}.json`);
    }
    if (!existsSync(filePath)) {
      helpers.error(res, 404, `Theme "${name}" not found`);
      return;
    }
    try {
      const content = readFileSync(filePath, "utf8");
      const theme = JSON.parse(content);
      helpers.json(res, { theme });
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
    // Validate required color fields — all 51 pi theme tokens
    const colors = theme.colors as Record<string, string> | undefined;
    // 49 tokens — maps 1:1 with iOS ThemePalette. Stripped from pi's 51-token
    // TUI schema: border/borderAccent/borderMuted (TUI box borders),
    // customMessageBg/customMessageText/customMessageLabel (TUI hook.message,
    // not in RPC events), selectedBg (no view wired), bashMode (TUI editor).
    const requiredKeys = [
      // Base palette (13)
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
      // User message (2)
      "userMessageBg",
      "userMessageText",
      // Tool state (5)
      "toolPendingBg",
      "toolSuccessBg",
      "toolErrorBg",
      "toolTitle",
      "toolOutput",
      // Markdown (10)
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
      // Diffs (3)
      "toolDiffAdded",
      "toolDiffRemoved",
      "toolDiffContext",
      // Syntax (9)
      "syntaxComment",
      "syntaxKeyword",
      "syntaxFunction",
      "syntaxVariable",
      "syntaxString",
      "syntaxNumber",
      "syntaxType",
      "syntaxOperator",
      "syntaxPunctuation",
      // Thinking levels (6)
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
    // Validate hex format (empty string "" allowed = "use default")
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
