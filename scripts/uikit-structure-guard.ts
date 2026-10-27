#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { stripSwiftCommentsAndStrings } from "../server/scripts/architecture-layer-rules.mjs";

/**
 * UIKit-first ownership guard for the iOS app target (clients/apple/Oppi and
 * its Debug-only clients/apple/OppiDebugHarness).
 *
 * UIKit owns iOS app structure, modal presentation, and new views. Two rules:
 *
 *  - Navigation and presentation constructs (NavigationStack, .sheet(, ...),
 *    UIHostingController( calls, and UIHostingController<...> as a superclass
 *    or type are disallowed in every file, debug previews and harnesses
 *    included: SwiftUI reaches UIKit through HostFactory, which owns the only
 *    hosting controllers. The only exceptions are the commented entries in
 *    `allowed` below.
 *  - `import SwiftUI` is a ratchet: a file's count fails the guard when it
 *    exceeds uikit-structure-baseline.json (files absent from the baseline
 *    have baseline 0). Decreases pass.
 *  - `SettingsListStyle.pin(`, `SettingsListStyle.applyTheme(`, and a hand-built
 *    `UICollectionLayoutListConfiguration(appearance: .insetGrouped)` are a
 *    ratchet of the same kind: a settings list that pins, themes, or lays
 *    itself out carries its own copy of what `SettingsListViewController` (the
 *    settings kit's base) does. The base and `SettingsListStyle.swift` are
 *    exempt, and so are the screens in `settingsThemingExceptions`, which never
 *    subclass the base. A new settings page subclasses the base and calls
 *    none of them, so a new file has baseline 0. Limits: the layout check is
 *    the literal inset-grouped configuration in a file that also paints the
 *    theme's background itself (`palette.bg`, `themeStore.backgroundColor`) or
 *    calls `SettingsListStyle`; a list built another way (a different
 *    appearance, a layout helper) is not seen.
 *
 * Policy: dev/architecture-client.md, "UIKit and SwiftUI ownership".
 * Comments and string literals are stripped before matching.
 *
 *   bun scripts/uikit-structure-guard.ts            check against the baseline
 *   bun scripts/uikit-structure-guard.ts --update   rewrite the baseline from
 *                                                   current source (deliberate
 *                                                   regeneration only)
 */

type Construct = {
  name: string;
  pattern: RegExp;
  disallowed: boolean;
  exemptFiles?: string[];
  /** Counted only in files whose source also matches this. */
  fileMustMatch?: RegExp;
};
type Counts = Record<string, number>;
type Baseline = Record<string, Counts>;
type Hit = { file: string; line: number; construct: string };

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scanRoots = ["clients/apple/Oppi", "clients/apple/OppiDebugHarness"].map((dir) => join(repoRoot, dir));
const baselinePath = join(repoRoot, "scripts/uikit-structure-baseline.json");
const guide = "dev/architecture-client.md, section \"UIKit and SwiftUI ownership\"";
const settingsGuide = "dev/architecture-client.md, section \"Settings pages\"";
const settingsBase = "clients/apple/Oppi/Features/Settings/SettingsListViewController.swift";
const settingsStyle = "clients/apple/Oppi/Features/Settings/SettingsListStyle.swift";

/**
 * Screens that pin, theme, or lay out a list themselves and never will subclass
 * the settings base. Every entry needs a reason.
 */
const settingsThemingExceptions: { file: string; reason: string }[] = [
  {
    file: "clients/apple/Oppi/Features/Onboarding/ManualEntryViewController.swift",
    reason: "Onboarding's manual server form: text fields in a sheet, not a settings page.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Support/Sharing/ShareSessionRedactionSheet.swift",
    reason: "A sharing sheet's selection list, presented from a chat.",
  },
  {
    file: "clients/apple/Oppi/Features/Agents/AgentNativeEditViewController.swift",
    reason: "The agent editor: a draft form with text views and its own save flow.",
  },
  {
    file: "clients/apple/Oppi/Features/Settings/ThemeGalleryViewController.swift",
    reason: "A grid of theme cards with its own layout, not a list of rows.",
  },
  {
    file: "clients/apple/Oppi/Features/SSHTerminal/HerdrAgentsView.swift",
    reason: "The terminal's list of Herdr agents: a picker over a live terminal, not a settings page.",
  },
  {
    file: "clients/apple/Oppi/Features/SSHTerminal/SSHTerminalPasswordViewController.swift",
    reason: "The SSH password prompt: a small modal form.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/",
    reason: "Chat panels and pickers (model, context, extensions, review comments), not settings pages.",
  },
];
const settingsThemingExempt = [settingsBase, settingsStyle, ...settingsThemingExceptions.map((entry) => entry.file)];
/** An entry ending in `/` exempts the whole directory. */
const isSettingsThemingExempt = (file: string) =>
  settingsThemingExempt.some((entry) => (entry.endsWith("/") ? file.startsWith(entry) : file === entry));

const constructs: Construct[] = [
  { name: "NavigationStack", pattern: /\bNavigationStack\b/g, disallowed: true },
  { name: "NavigationSplitView", pattern: /\bNavigationSplitView\b/g, disallowed: true },
  { name: "NavigationLink", pattern: /\bNavigationLink\b/g, disallowed: true },
  { name: ".navigationDestination(", pattern: /\.navigationDestination\s*\(/g, disallowed: true },
  { name: ".sheet(", pattern: /\.sheet\s*\(/g, disallowed: true },
  { name: ".fullScreenCover(", pattern: /\.fullScreenCover\s*\(/g, disallowed: true },
  { name: ".popover(", pattern: /\.popover\s*\(/g, disallowed: true },
  { name: ".inspector(", pattern: /\.inspector\s*\(/g, disallowed: true },
  { name: "UIHostingController(", pattern: /\bUIHostingController\s*(?:<[^>(]*>)?\s*\(/g, disallowed: true },
  // A subclass or stored type reaches a hosting controller without the call form.
  { name: "UIHostingController<", pattern: /\bUIHostingController\s*</g, disallowed: true },
  { name: "import SwiftUI", pattern: /^[ \t]*(?:@\w+[ \t]+)*import[ \t]+SwiftUI\b/gm, disallowed: false },
  // Settings-list theming outside the kit's base: see "Settings pages" in the guide.
  {
    name: "SettingsListStyle.pin(",
    pattern: /\bSettingsListStyle\s*\.\s*pin\s*\(/g,
    disallowed: false,
    exemptFiles: settingsThemingExempt,
  },
  {
    name: "SettingsListStyle.applyTheme(",
    pattern: /\bSettingsListStyle\s*\.\s*applyTheme\s*\(/g,
    disallowed: false,
    exemptFiles: settingsThemingExempt,
  },
  {
    name: "UICollectionLayoutListConfiguration(appearance: .insetGrouped)",
    pattern: /\bUICollectionLayoutListConfiguration\s*\(\s*appearance:\s*\.insetGrouped\s*\)/g,
    disallowed: false,
    exemptFiles: settingsThemingExempt,
    // An inset-grouped list that also paints the theme's background itself.
    fileMustMatch: /\bpalette\.bg\b|\bthemeStore\.backgroundColor\b|\bSettingsListStyle\./,
  },
];

/**
 * Disallowed constructs that may stay, per file: the construct and how many
 * uses. Every entry needs a reason; an entry nobody needs is deleted.
 */
const allowed: { file: string; construct: string; count: number; reason: string }[] = [
  {
    file: "clients/apple/Oppi/App/HostFactory.swift",
    construct: "UIHostingController<",
    count: 2,
    reason: "HostedScreenController and HostedContentController are the hosting seam every other file goes through.",
  },
];

function walkSwiftFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  const files: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkSwiftFiles(path));
    } else if (entry.isFile() && entry.name.endsWith(".swift")) {
      files.push(path);
    }
  }
  return files;
}

function scan(): Hit[] {
  const hits: Hit[] = [];
  for (const absFile of scanRoots.flatMap(walkSwiftFiles)) {
    const file = relative(repoRoot, absFile);
    const stripped = stripSwiftCommentsAndStrings(readFileSync(absFile, "utf8"));
    for (const { name, pattern, exemptFiles, fileMustMatch } of constructs) {
      if (exemptFiles && exemptFiles === settingsThemingExempt ? isSettingsThemingExempt(file) : exemptFiles?.includes(file)) continue;
      if (fileMustMatch && !fileMustMatch.test(stripped)) continue;
      for (const match of stripped.matchAll(pattern)) {
        const start = match.index + (match[0].length - match[0].trimStart().length);
        const line = stripped.slice(0, start).split("\n").length;
        hits.push({ file, line, construct: name });
      }
    }
  }
  return hits;
}

function countByFile(hits: Hit[]): Baseline {
  const result: Baseline = {};
  for (const hit of hits) {
    const counts = (result[hit.file] ??= {});
    counts[hit.construct] = (counts[hit.construct] ?? 0) + 1;
  }
  // Stable ordering keeps baseline diffs reviewable.
  const sorted: Baseline = {};
  for (const file of Object.keys(result).sort()) {
    const counts: Counts = {};
    for (const { name } of constructs) {
      if (result[file][name]) counts[name] = result[file][name];
    }
    sorted[file] = counts;
  }
  return sorted;
}

function loadBaseline(): Baseline {
  if (!existsSync(baselinePath)) {
    console.error(`UIKit structure guard: missing baseline ${relative(repoRoot, baselinePath)}.`);
    process.exit(1);
  }
  return JSON.parse(readFileSync(baselinePath, "utf8")).files as Baseline;
}

const ratcheted = new Set(constructs.filter((c) => !c.disallowed).map((c) => c.name));
const hits = scan();

if (process.argv.includes("--update")) {
  const files = countByFile(hits.filter((hit) => ratcheted.has(hit.construct)));
  writeFileSync(baselinePath, `${JSON.stringify({ version: 1, files }, null, 2)}\n`);
  console.log(`UIKit structure guard: baseline rewritten (${Object.keys(files).length} files).`);
  process.exit(0);
}

const baseline = loadBaseline();
const current = countByFile(hits);
const failures: string[] = [];

for (const [file, counts] of Object.entries(current)) {
  for (const [construct, count] of Object.entries(counts)) {
    const limit = ratcheted.has(construct)
      ? (baseline[file]?.[construct] ?? 0)
      : (allowed.find((entry) => entry.file === file && entry.construct === construct)?.count ?? 0);
    if (count <= limit) continue;
    const rule = ratcheted.has(construct) ? "baseline" : "allowed";
    failures.push(`- ${file}: ${construct} count ${count} exceeds ${rule} ${limit}`);
    for (const hit of hits) {
      if (hit.file === file && hit.construct === construct) {
        failures.push(`    ${file}:${hit.line}: ${construct}`);
      }
    }
  }
}

if (failures.length === 0) {
  console.log("UIKit structure guard: PASS — no disallowed SwiftUI structure constructs, import SwiftUI and settings-list theming within baseline.");
  process.exit(0);
}

console.log("UIKit structure guard: FAIL — SwiftUI structure constructs the guard disallows or the import baseline exceeds.\n");
for (const line of failures) console.log(line);
console.log(`
UIKit owns iOS app structure, modal presentation, and new views, previews and
harnesses included. Present and push through the router (routerModal,
ScreenNavigator push/finish; previews host with RouterPreviewStack or
RouterPreviewNavigation) and host SwiftUI only through HostFactory. See ${guide}.
NavigationStack, NavigationSplitView, NavigationLink, .navigationDestination(,
.sheet(, .fullScreenCover(, .popover(, .inspector(, UIHostingController(, and
UIHostingController< (a subclass or stored type) have no baseline: an exception needs Chen's approval and a commented entry in
the guard's allowed list. A new \`import SwiftUI\` raises that file's baseline,
which also needs approval; \`bun scripts/uikit-structure-guard.ts --update\`
lowers it after a migration. After a rename or move, --update is fine when the
baseline diff only moves entries.

SettingsListStyle.pin(, SettingsListStyle.applyTheme(, and a hand-built
UICollectionLayoutListConfiguration(appearance: .insetGrouped) outside the
settings base mean a settings list is theming or laying itself out. Subclass
SettingsListViewController instead (or, for a list that cannot, use
SettingsListStyle.layoutConfiguration); see ${settingsGuide}. A screen that
will never be a settings page goes in settingsThemingExceptions with a reason.`);
process.exit(1);
