#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Theme surface guardrails for the themed iOS app target (clients/apple/Oppi).
 *
 * The Oppi iOS app resolves all UI colors through the runtime theme
 * (Color.theme* accessors and ThemeSurfaceStyle roles). This guard fails when
 * app code bypasses that system:
 *
 *  1. System materials in .background()/.presentationBackground() — system
 *     materials ignore the active theme palette.
 *  2. Color.accentColor — resolves from the asset catalog, not the theme.
 *  3. foregroundStyle(.primary/.secondary/.blue/.white/.red) — system
 *     semantic or fixed colors instead of theme foregrounds.
 *  4. themeBg/themeBgDark.opacity(...) outside Color+Theme.swift — ad-hoc
 *     surface opacity; use a ThemeSurfaceRole via View.themedSurface(_:in:)
 *     or add a semantic accessor in Color+Theme.swift.
 *  5. Fixed black/white SwiftUI backgrounds and UIKit theme-background alpha
 *     re-derivations — common escape hatches that fail under light themes.
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
  excludeGlobs?: string[];
};

type GuardViolation = {
  check: GuardCheck;
  matches: string[];
};

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const appleRoot = join(repoRoot, "clients/apple");
const scanPaths = ["Oppi"];

// Preview and harness fixtures freeze system styling on purpose.
const previewAllowlistGlobs = [
  "**/ScreenshotPreviewView.swift",
  "**/ExtensionDockStressPreview.swift",
  "**/StreamingFlickerPreviewView.swift",
  "**/FeatureEducationP0TipPreview.swift",
  "**/*HarnessView.swift",
];

const checks: GuardCheck[] = [
  {
    id: "system-material-background",
    title: "System material in background/presentationBackground",
    pattern:
      String.raw`\.(background|presentationBackground)\(\s*(Material\.|\.(ultraThin|thin|regular|thick|ultraThick)Material)`,
    fix: "Use View.themedSurface(_:in:), Color.themeSurfaceFill(_:), or a Color.theme* background — system materials ignore the theme palette",
  },
  {
    id: "accent-color",
    title: "Color.accentColor usage",
    pattern: String.raw`Color\.accentColor|\(\.accentColor\b`,
    fix: "Use a theme accent (Color.themeBlue/.themeCyan) — accentColor bypasses the runtime theme",
  },
  {
    id: "system-foreground-style",
    title: "System foregroundStyle color",
    pattern: String.raw`\.foregroundStyle\(\s*\.(primary|secondary|blue|white|red)\s*\)`,
    fix: "Use theme foregrounds: .themeFg/.themeFgDim/.themeComment/.themeBlue/.themeRed/.themeOnBlue",
  },
  {
    id: "ad-hoc-surface-opacity",
    title: "Ad-hoc themeBg/themeBgDark opacity",
    pattern: String.raw`themeBg(Dark)?\.opacity\(`,
    fix: "Pick a ThemeSurfaceRole via View.themedSurface(_:in:) or add a semantic accessor in Color+Theme.swift — surface opacity math lives in ThemeSurfaceStyle.resolve",
    excludeGlobs: ["**/Core/Extensions/Color+Theme.swift"],
  },
  {
    id: "fixed-monochrome-background",
    title: "Fixed black/white background",
    pattern: String.raw`\.background\(\s*Color\.(black|white)(\.opacity\([^)]*\))?\s*\)`,
    fix: "Use Color.themeBg/themeBgDark for content canvases or a ThemeSurfaceRole for floating chrome",
  },
  {
    id: "uikit-ad-hoc-theme-surface-opacity",
    title: "UIKit theme surface alpha re-derived at the call site",
    pattern: String.raw`UIColor\(\s*(Color\.)?themeBg(Dark|Highlight)?\s*\)\.withAlphaComponent\(`,
    fix: "Use UIColor(ThemeSurfaceStyle.resolve(role).fill) or an opaque semantic theme color",
  },
];

function ripgrep(check: GuardCheck): string[] {
  const args = ["-n", "--type", "swift", check.pattern, ...scanPaths];
  for (const glob of [...previewAllowlistGlobs, ...(check.excludeGlobs ?? [])]) {
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
  console.log(`Theme surface guard: passed (${checks.length} checks over clients/apple/Oppi).`);
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
