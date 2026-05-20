import type { ServerResponse } from "node:http";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import { convertPiTheme } from "./theme-convert.js";

export function createThemeRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function themesDir(): string {
    return join(ctx.storage.getDataDir(), "themes");
  }

  function bundledThemesDir(): string {
    // Source: src/routes/themes.ts → compiled: dist/src/routes/themes.js
    // import.meta.dirname = dist/src/routes/, so go up three levels to reach server/themes/
    // (tsc does not copy JSON files to dist/)
    return join(import.meta.dirname, "..", "..", "..", "themes");
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

  return async ({ method, path, res }) => {
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
    }

    return false;
  };
}
