#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Theme surface guardrails for the themed iOS app target (clients/apple/Oppi
 * and its Debug-only clients/apple/OppiDebugHarness).
 *
 * The Oppi iOS app resolves all UI colors through the runtime theme: a token is
 * a `UIColor` (`UIColor.theme*` accessors, `palette.ui.*`, and `ThemeSurfaceStyle`
 * roles). This guard fails when app code bypasses that system:
 *
 *  1. System materials in .background()/.presentationBackground() — system
 *     materials ignore the active theme palette.
 *  2. Color.accentColor — resolves from the asset catalog, not the theme.
 *  3. foregroundStyle(.primary/.secondary/.blue/.white/.red) — system
 *     semantic or fixed colors instead of theme foregrounds.
 *  4. Fixed black/white SwiftUI backgrounds — common escape hatches that fail
 *     under light themes.
 *
 * The theme is UIKit-side on iOS: `Color.theme*`, the `.theme*` `ShapeStyle`
 * shorthand, and the themed-surface modifiers ship in `OppiMac` only, so no iOS
 * file can spell them and no check reads them here. The Mac's SwiftUI face is
 * out of scope.
 *
 * Preview/screenshot harnesses are allowlisted: they intentionally freeze
 * styling for marketing shots and stress fixtures.
 *
 * OppiMac and the Live Activity/widget extensions are out of scope: they have
 * no theme runtime and deliberately use system styling.
 */

type GuardCheck = {
  id: string;
  title: string;
  pattern: string;
  fix: string;
};

type GuardViolation = {
  check: GuardCheck;
  matches: string[];
};

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const appleRoot = join(repoRoot, "clients/apple");
const scanPaths = ["Oppi", "OppiDebugHarness"];

// Preview and harness fixtures freeze system styling on purpose.
const previewAllowlistGlobs = [
  "**/ExtensionDockStressPreview.swift",
  "**/*Preview.swift",
  "**/*HarnessView.swift",
];

const checks: GuardCheck[] = [
  {
    id: "system-material-background",
    title: "System material in background/presentationBackground",
    pattern:
      String.raw`\.(background|presentationBackground)\(\s*(Material\.|\.(ultraThin|thin|regular|thick|ultraThick)Material)`,
    fix: "Use UIColor.themeSurfaceFill(role) or a UIColor.theme* background — system materials ignore the theme palette",
  },
  {
    id: "accent-color",
    title: "Color.accentColor usage",
    pattern: String.raw`Color\.accentColor|\(\.accentColor\b`,
    fix: "Use a theme accent (UIColor.themeBlue/.themeCyan) — accentColor bypasses the runtime theme",
  },
  {
    id: "system-foreground-style",
    title: "System foregroundStyle color",
    pattern: String.raw`\.foregroundStyle\(\s*\.(primary|secondary|blue|white|red)\s*\)`,
    fix: "Use a theme foreground: UIColor.themeFg/.themeFgDim/.themeComment/.themeBlue/.themeRed/.themeOnBlue",
  },
  {
    id: "fixed-monochrome-background",
    title: "Fixed black/white background",
    pattern: String.raw`\.background\(\s*Color\.(black|white)(\.opacity\([^)]*\))?\s*\)`,
    fix: "Use UIColor.themeBg/themeBgDark for content canvases or a ThemeSurfaceRole for floating chrome",
  },
];

function ripgrep(check: GuardCheck): string[] {
  const args = ["-n", "--type", "swift", check.pattern, ...scanPaths];
  for (const glob of previewAllowlistGlobs) {
    args.push("-g", `!${glob}`);
  }

  const result = spawnSync("rg", args, { cwd: appleRoot, encoding: "utf8" });
  if (result.error) {
    throw result.error;
  }
  // rg exits 1 when nothing matches, 2 on real errors.
  if (result.status === 1) {
    return [];
  }
  if (result.status !== 0) {
    throw new Error(
      `rg failed for ${check.id} with exit ${result.status}\n${result.stdout}\n${result.stderr}`,
    );
  }
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

const violations: GuardViolation[] = [];
for (const check of checks) {
  const matches = ripgrep(check);
  if (matches.length > 0) {
    violations.push({ check, matches });
  }
}

if (violations.length === 0) {
  console.log(`Theme surface guard: passed (${checks.length} checks over clients/apple/${scanPaths.join(", ")}).`);
  process.exit(0);
}

console.error(`Theme surface guard: ${violations.length} check(s) failed.`);
for (const violation of violations) {
  console.error("");
  console.error(`ERROR: ${violation.check.title} (${violation.matches.length} hit(s))`);
  console.error(`  FIX: ${violation.check.fix}`);
  for (const match of violation.matches) {
    console.error(`  clients/apple/${match}`);
  }
}
process.exit(1);
