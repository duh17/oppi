#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { stripSwiftCommentsAndStrings } from "../server/scripts/architecture-layer-rules.mjs";

/**
 * UIKit-first ownership guard for the iOS app target (clients/apple/Oppi and
 * its Debug-only clients/apple/OppiDebugHarness).
 *
 * UIKit owns iOS app structure, modal presentation, and new views. Three rules:
 *
 *  - Navigation and presentation constructs (NavigationStack, .sheet(, ...),
 *    UIHostingController( calls, and UIHostingController<...> as a superclass
 *    or type are disallowed in every file, debug previews and harnesses
 *    included: SwiftUI never owns structure. The two framework leaves that have
 *    to be SwiftUI (Swift Charts in `UsageCharts`, RealityKit's RealityView in
 *    `USDZRealityCanvas`) host from the file that draws them and are the only
 *    entries in `allowed` below; nothing else in the app hosts SwiftUI.
 *  - `import SwiftUI` is an allow-list (`swiftUIImporters` below), and it counts
 *    `import Charts`, `import TipKit` and `import struct SwiftUI.X` too, because
 *    both frameworks re-export SwiftUI. Exactly five files of the app target
 *    may import it: the two framework leaves (`UsageCharts`,
 *    `USDZRealityCanvas`), the TipKit file (`FeatureEducationTips`), the shared
 *    `ModelColorHelpers` chart, and the Live Activity surface
 *    (`LiveActivityPresentation`). The iOS app target is UIKit everywhere else,
 *    and the debug harness is UIKit too. The theme itself is UIKit-side on iOS
 *    (`ThemeColor` is `UIColor` there; the Mac's SwiftUI face of the same
 *    tokens ships in `OppiMac/Theme/`), so no theme file imports SwiftUI, model
 *    colors included: `modelColor` and `providerIconTint` return `ThemeColor`.
 *    Any other file fails, and a new entry needs the owner's approval.
 *    `@_exported import` of any of them fails even in an allow-listed file.
 *
 *  - A hand-built `UICollectionLayoutListConfiguration(appearance: .insetGrouped)`
 *    is a ratchet of the same kind: a settings list that lays itself out carries
 *    its own copy of what `ListScreenController` (the settings kit's base) does.
 *    The base and `SettingsStyle.swift` are exempt, and so are the screens in
 *    `settingsThemingExceptions`, which never subclass the base. A new settings
 *    page subclasses the base and builds no layout, so a new file has baseline
 *    0. Limits: the check is the literal inset-grouped configuration in a file
 *    that also paints the theme's background itself (`palette.bg`,
 *    `themeStore.backgroundColor`); a list built another way (a different
 *    appearance, a layout helper) is not seen.
 *
 *  - The settings-write ratchet (same file, same baseline) counts, in
 *    `clients/apple/Oppi/Features/**`, the direct writes of a setting that
 *    bypass `SettingsStore`: `AppPreferences.*.set…(`, `UserDefaults.standard.set(`,
 *    `FontPreferences.set…(`, the `APIClient` calls that write a setting
 *    (`settingsApiWrites` below), and the plain switch rows that a declared
 *    setting replaces with `settingToggleRow`: `toggleRow(` and a direct
 *    `.settingsToggle(` accessory. A setting is declared in `SettingsCatalog`
 *    and written by the store, so each page that moves onto it lowers its count
 *    and the total only goes down. Limits: the guard sees the call by name. A
 *    write through a wrapper (a helper or model method that calls the
 *    preference or the API; `ServerSettingsModel` and `WorkspaceSettingsModel`
 *    are the known ones), a stored closure, `UserDefaults` held in a variable,
 *    or a call to an `APIClient` write not in the list is not seen; the wrapper
 *    is counted only where it calls the preference or the API itself, so moving
 *    a call into a new wrapper lowers a page's count without moving the setting
 *    onto the store. Review a new wrapper as a write.
 *
 *  - `UIAlertController(` is a ratchet of the same kind (same baseline): an
 *    error alert or a confirmation goes through `ErrorAlertPresenter` or
 *    `Confirmation` (`errorAlerts.show`, `Confirmation(...).present(from:anchor:)`),
 *    which own the replace-and-hold rules and the iPad popover anchor, and a
 *    line of text through the shared `TextPrompt` (in ConfirmationSheet.swift,
 *    exempt with the other file). What the baseline keeps is not an error alert
 *    or a confirmation: the two text-field alerts (rename session, go to line;
 *    they predate `TextPrompt`), the
 *    three choice sheets (tree navigation, resource choice, where to sign in),
 *    which anchor through `AlertAnchor.present`, and the push/Live Activity
 *    disclosure, whose third button (Privacy Policy) a `Confirmation` has no
 *    room for. A new file has baseline 0; the count only goes down.
 *
 *  - `setNavigationBarHidden(` and an `isNavigationBarHidden =` assignment are
 *    disallowed outside Router.swift (the one owner
 *    of the stack's bar) and FullScreenCodeViewController.swift (its private
 *    navigation controller). A screen that brings its own Back conforms to
 *    `NavigationBarHiding` and calls `navigationController?.updateNavigationBar(for:animated:)`.
 *
 *  - The load ratchet (same file, same baseline) counts, in a file under
 *    `clients/apple/Oppi/Features/` that declares a subclass of
 *    `ListScreenController` (directly or through
 *    `ServerResourceDetailScreenController`), the two ways a page takes over the
 *    load the kit owns: an `override func viewIsAppearing` (a page that starts
 *    its own load on the way in) and `isLoadCancellation` (a page that decides
 *    for itself whether a load failed). It is a ratchet, not a proof: it sees
 *    the call by name, so a page can still take the trigger or the outcome
 *    another way (a stored closure, a helper). The kit runs one task per page
 *    (`loadPolicy`, `loadSubject`, `load`, `setNeedsLoad`), so a page overrides
 *    those instead; the baseline holds no entry for either, so a new page and a
 *    page that adds one fail the guard, and the count only goes down.
 *    `Task {` and `Task.isCancelled` are not counted: a page needs its own task
 *    for an action (archive, run now, sign-in cancel), and the kit expects the
 *    `Task.isCancelled` check after an `await` that keeps a late answer off the
 *    screen.
 *
 *  - `UIContentUnavailableConfiguration` factory is a ratchet of the same kind: a
 *    screen's whole-screen (or list-cell) loading, empty, no-results, and failed
 *    states go through `LoadState` and `.loadState(...)`, which own the words, the
 *    theme colors, and the one Retry button. `UIContentUnavailableConfiguration.empty/loading/search(`
 *    and a bare `.empty()`/`.loading()`/`.search()` in a file that uses the type
 *    count, except in `LoadStateContent.swift`. Its baseline is empty: the count
 *    only goes down. Strings are stripped before matching, so the guard cannot see
 *    a retyped "Retry" or "Connecting…"; those live in `LoadState` only.
 *
 *  - Entity artwork is a heuristic ratchet, with `EntityIcon.swift` exempt:
 *    `providerLogoAssetName(`, `providerMonogram(`, and
 *    `resolvedBadgeIcon.symbolName` drawn elsewhere, and a menu row
 *    (`UIAction(title:`) titled with the name of a variable called server, agent,
 *    workspace, model, or provider instead of `UIAction.choice(...)`, which
 *    carries the entity's icon and the menu's own checkmark. It reads the call
 *    by name, so a name held in another variable (`let title = …;
 *    UIAction(title: title)`) or a drawing helper of a caller's own is not seen:
 *    a green run means the common shapes are gone, not that artwork is one
 *    owner's everywhere. The baseline keeps what is not artwork:
 *    `SessionRowView`'s VoiceOver label (a provider's *name*) and the badge
 *    symbols of the rail item and the pill (tinted by connection state, which
 *    `EntityIcon` does not draw). A menu that lists a thing with a name and no
 *    icon is what this catches; nothing else should add to it.
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
  /** Counted only in files whose repo-relative path matches this. */
  pathMustMatch?: RegExp;
};
type Counts = Record<string, number>;
type Baseline = Record<string, Counts>;
type Hit = { file: string; line: number; construct: string };

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
// `OppiCore/` and `Shared/` are here because the iOS app target compiles all of
// them (project.yml): a SwiftUI file there ships in the app exactly like one
// under `Oppi/`. The extension targets hold only Apple-required widget files.
const scanRoots = [
  "clients/apple/Oppi",
  "clients/apple/OppiDebugHarness",
  "clients/apple/OppiCore",
  "clients/apple/Shared",
].map((dir) => join(repoRoot, dir));
const baselinePath = join(repoRoot, "scripts/uikit-structure-baseline.json");
const guide = "dev/architecture-client.md, section \"UIKit and SwiftUI ownership\"";
const navigationBarGuide = "dev/architecture-client.md, section \"Navigation bar\"";
const loadStateGuide = "dev/architecture-client.md, section \"Load states\"";
const alertsGuide = "dev/architecture-client.md, section \"Alerts and confirmations\"";
const settingsGuide = "dev/architecture-client.md, section \"Settings pages\"";
const settingsBase = "clients/apple/Oppi/Features/Settings/ListScreenController.swift";
const settingsStyle = "clients/apple/Oppi/Features/Settings/SettingsStyle.swift";
/** The one owner of entity artwork (the guide's shared UIKit building blocks). */
const entityIconOwner = "clients/apple/Oppi/Core/Views/EntityIcon.swift";


/** A file that declares a page on the list kit: a subclass of the base, or of
 * the resource-detail base both detail pages share. */
const listPageSubclass = /\bclass\s+\w+\s*:\s*(?:\w+\.)*(?:ListScreenController|ServerResourceDetailScreenController)\s*</;

/**
 * Screens that pin, theme, or lay out a list themselves and never will subclass
 * the settings base. Every entry needs a reason.
 */
const settingsThemingExceptions: { file: string; reason: string }[] = [
  {
    file: "clients/apple/Oppi/Features/SSHTerminal/SSHTerminalOverviewViewController.swift",
    reason: "The list of Herdr agents or Rex panes: a picker over a live terminal, or a Rex host's sessions screen; not a settings page.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/ReviewComments/ReviewCommentStashContent.swift",
    reason: "The review-comment stash inside a chat's composer panel.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Support/ContextInspectorViewController.swift",
    reason: "The chat's context inspector panel: read-only usage rows beside a chat.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Support/ModelPickerViewController.swift",
    reason: "The chat's model picker: a choice list presented from the composer.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Support/SessionExtensionContextViewController.swift",
    reason: "The chat's session-extension context panel, presented from a chat.",
  },
];
const settingsThemingExempt = [settingsBase, settingsStyle, ...settingsThemingExceptions.map((entry) => entry.file)];

/**
 * The `APIClient` calls that write a setting. A page does not call them: the
 * setting is declared in `SettingsCatalog` and `SettingsStore` writes it
 * through its server adapter (`APIClient+SettingsTransport.swift`).
 */
const settingsApiWrites = [
  "setMobileOutputGuideConfiguration",
  "setServerMetricsEnabled",
  "saveDurableSessionsSettings",
  "setServerSkillEnabled",
  "setServerExtensionEnabled",
  "setPiResourceEnabled",
  "setPiDefaultTools",
  "setPiDefaultModel",
  "saveDictationDictionary",
  "updateWorkspace",
];
const featuresOnly = /^clients\/apple\/Oppi\/Features\//;

/** The files that may set a navigation controller's bar state. */
const navigationBarOwners = [
  // The owner: `applyNavigationBar(forIncoming:)` and `updateNavigationBar(for:animated:)`.
  "clients/apple/Oppi/App/Router.swift",
  // Hides the bar of its own private navigation controller, which never sits in a shared stack.
  "clients/apple/Oppi/Core/Views/FullScreenCodeViewController.swift",
];

/**
 * The files that may import SwiftUI, each with a reason. `Charts` and `TipKit`
 * re-export SwiftUI, and a framework-qualified `import struct SwiftUI.X` is the
 * same dependency, so all three count as importing SwiftUI: the iOS app is UIKit
 * everywhere except the surfaces Apple requires in SwiftUI, and the files here
 * say which one and why. Every other file fails the guard, and a new entry needs
 * the owner's approval.
 */
const swiftUIImporters: { file: string; reason: string }[] = [
  // The two framework leaves: SwiftUI only because the framework is.
  {
    file: "clients/apple/Oppi/Features/Server/UsageCharts.swift",
    reason: "Swift Charts is SwiftUI-only: the three Usage chart leaves and the one UIHostingController that hosts them.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Timeline/Assistant/USDZRealityCanvas.swift",
    reason: "RealityKit's RealityView is SwiftUI-only: the USDZ canvas and the one UIHostingController that hosts it.",
  },
  // The theme is UIKit-side on iOS: a token is `ThemeColor` (`UIColor`), and the
  // Mac's SwiftUI face of the same tokens ships in `OppiMac/Theme/`. No theme
  // file imports SwiftUI, so none is named here.
  // TipKit: the framework re-exports SwiftUI (`Text` and `Image` inside a tip),
  // so the tips' definitions and their display live in this one file.
  {
    file: "clients/apple/Oppi/Features/FeatureEducation/FeatureEducationTips.swift",
    reason: "TipKit re-exports SwiftUI; the tip definitions, their TipKit state, and the presenter every other file asks.",
  },
  // Shared/ files the iOS target compiles.
  {
    file: "clients/apple/Shared/Theme/ModelColorHelpers.swift",
    reason: "`import Charts`: the shared `StatsDailyChart` (whose tooltip draws `ProviderGlyph`), the model colors, and the contrast rules the chart labels use.",
  },
  {
    file: "clients/apple/Shared/Activity/LiveActivityPresentation.swift",
    reason: "The Live Activity surface (Apple requires it in SwiftUI); shared with the widget extension.",
  },
];
const swiftUIImporterFiles = swiftUIImporters.map((entry) => entry.file);
const sharedImporterCount = swiftUIImporterFiles.filter((file) => file.includes("/Shared/")).length;

/**
 * SwiftUI in `Shared/` that the iOS target excludes (the same path is in
 * `project.yml`'s `Oppi` sources): the Mac's own view. It ships in `OppiMac`
 * only, so it is not an app importer, but the guard scans the folder and must
 * know it. Keep this list and `project.yml` in step.
 */
const sharedMacOnlySwiftUI: { file: string; reason: string }[] = [
  {
    file: "clients/apple/Shared/Renderers/Orbs/ThinkingOrbAcknowledgmentsView.swift",
    reason: "The Mac's orb acknowledgments page; iOS has none. Excluded from the Oppi target.",
  },
  {
    file: "clients/apple/Shared/Renderers/Orbs/OrbView.swift",
    reason: "The Mac's SwiftUI wrapper around `OrbMetalView`; iOS draws the same view in UIKit. Excluded from the Oppi target.",
  },
];
const swiftUIExemptFiles = [...swiftUIImporterFiles, ...sharedMacOnlySwiftUI.map((entry) => entry.file)];

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
  // The navigation bar's hidden state follows the screen in front through one owner: see "Navigation bar" in the guide.
  {
    name: "setNavigationBarHidden(",
    pattern: /\bsetNavigationBarHidden\s*\(/g,
    disallowed: true,
    exemptFiles: navigationBarOwners,
  },
  {
    name: "isNavigationBarHidden =",
    // An assignment, not a read or a comparison (`==`, `!=`, `<=`, `>=`).
    pattern: /\bisNavigationBarHidden\s*=(?!=)/g,
    disallowed: true,
    exemptFiles: navigationBarOwners,
  },
  {
    name: "SwiftUI import (SwiftUI, Charts, or TipKit)",
    // `Charts` and `TipKit` re-export SwiftUI, and `import struct SwiftUI.X` is
    // the same dependency by another spelling. A Swift 6 access-level import
    // (`public import`) and `@_spi(…)` bind SwiftUI just the same, so the
    // attribute prefix and the access modifier are part of the match.
    pattern:
      /^[ \t]*(?:@[A-Za-z_]\w*(?:\([^)]*\))?[ \t]+)*(?:(?:public|internal|package|fileprivate|private)[ \t]+)?import[ \t]+(?:(?:struct|enum|class|protocol|typealias|var|let|func)[ \t]+)?(?:SwiftUI|Charts|TipKit)\b(?:[ \t]*\.[A-Za-z_]\w*)?/gm,
    disallowed: true,
    exemptFiles: swiftUIExemptFiles,
  },
  {
    // `@_exported import SwiftUI` puts SwiftUI in the module's public interface
    // for every file in the target, so it is disallowed even in an allow-listed
    // file: the allow-list is per file, and an export is not.
    name: "exported SwiftUI import",
    pattern:
      /^[ \t]*(?:@[A-Za-z_]\w*(?:\([^)]*\))?[ \t]+)*@_exported[ \t]+(?:(?:public|internal|package|fileprivate|private)[ \t]+)?import[ \t]+(?:(?:struct|enum|class|protocol|typealias|var|let|func)[ \t]+)?(?:SwiftUI|Charts|TipKit)\b/gm,
    disallowed: true,
  },
  // Alerts outside the shared presenters: see "Alerts" in the guide.
  {
    name: "UIAlertController(",
    pattern: /\bUIAlertController\s*\(/g,
    disallowed: false,
    exemptFiles: [
      "clients/apple/Oppi/Core/Views/ErrorAlertPresenter.swift",
      "clients/apple/Oppi/Core/Views/ConfirmationSheet.swift",
    ],
  },
  // Whole-screen and in-list load states outside `LoadState`: see "Load states" in the guide.
  {
    name: "UIContentUnavailableConfiguration factory",
    // `UIContentUnavailableConfiguration.empty(`, and a bare `.empty()` / `.loading()` /
    // `.search()` after `=`, `:`, `(`, `{`, `return`, or `Self.` (an initializer, an
    // argument, a closure body, a returned value, a static member).
    pattern: /\bUIContentUnavailableConfiguration\s*\.\s*(?:empty|loading|search)\s*\(|(?:=|:|\{|\breturn\b|\bSelf|\()\s*\.(?:empty|loading|search)\(\)/g,
    disallowed: false,
    exemptFiles: ["clients/apple/Oppi/Core/Views/LoadStateContent.swift"],
    // `.empty()` and friends are common words; only a file that uses the type is read.
    fileMustMatch: /UIContentUnavailable/,
  },
  // A settings list laid out by hand outside the kit's base: see "Settings pages" in the guide.
  {
    name: "UICollectionLayoutListConfiguration(appearance: .insetGrouped)",
    pattern: /\bUICollectionLayoutListConfiguration\s*\(\s*appearance:\s*\.insetGrouped\s*\)/g,
    disallowed: false,
    exemptFiles: settingsThemingExempt,
    // An inset-grouped list that also paints the theme's background itself.
    fileMustMatch: /\bpalette\.bg\b|\bthemeStore\.backgroundColor\b/,
  },
  // Settings written outside `SettingsStore`: see "Settings pages" in the guide.
  {
    name: "AppPreferences.*.set",
    pattern: /\bAppPreferences\s*\.\s*\w+(?:\s*\.\s*\w+)*?\s*\.\s*set\w*\s*\(/g,
    disallowed: false,
    pathMustMatch: featuresOnly,
  },
  {
    name: "UserDefaults.standard.set(",
    pattern: /\bUserDefaults\s*\.\s*standard\s*\.\s*set\s*\(/g,
    disallowed: false,
    pathMustMatch: featuresOnly,
  },
  {
    name: "FontPreferences.set",
    pattern: /\bFontPreferences\s*\.\s*set\w*\s*\(/g,
    disallowed: false,
    pathMustMatch: featuresOnly,
  },
  {
    name: "APIClient settings write",
    pattern: new RegExp(`\\.\\s*(?:${settingsApiWrites.join("|")})\\s*\\(`, "g"),
    disallowed: false,
    pathMustMatch: featuresOnly,
  },
  {
    name: "toggleRow(",
    // The base's own definition is `func toggleRow(`; a declared setting calls `settingToggleRow(`.
    pattern: /(?<![\w.])(?<!func\s)toggleRow\s*\(/g,
    disallowed: false,
    pathMustMatch: featuresOnly,
  },
  {
    name: ".settingsToggle(",
    // A switch accessory built by hand. The base's `toggleRow` and the declared rows call it for the kit.
    pattern: /\.settingsToggle\s*\(/g,
    disallowed: false,
    exemptFiles: [settingsBase, "clients/apple/Oppi/Features/Settings/SettingsDeclaredRows.swift"],
    pathMustMatch: featuresOnly,
  },
  // A page that owns its load the kit gives it: see "Settings pages" in the guide.
  {
    name: "page isLoadCancellation",
    pattern: /\bisLoadCancellation\b/g,
    disallowed: false,
    pathMustMatch: featuresOnly,
    fileMustMatch: listPageSubclass,
  },
  {
    name: "page viewIsAppearing",
    pattern: /\boverride\s+func\s+viewIsAppearing\s*\(/g,
    disallowed: false,
    pathMustMatch: featuresOnly,
    fileMustMatch: listPageSubclass,
  },
  // Entity artwork outside `EntityIcon`: see the guide's shared building blocks.
  {
    name: "providerLogoAssetName(",
    pattern: /\bproviderLogoAssetName\s*\(/g,
    disallowed: false,
    exemptFiles: [entityIconOwner],
  },
  {
    name: "providerMonogram(",
    pattern: /\bproviderMonogram\s*\(/g,
    disallowed: false,
    exemptFiles: [entityIconOwner],
  },
  {
    // A badge's symbol drawn by the caller, rather than through `EntityIcon`.
    name: "resolvedBadgeIcon.symbolName",
    pattern: /\bresolvedBadgeIcon\s*\.\s*symbolName\b/g,
    disallowed: false,
    exemptFiles: [entityIconOwner],
  },
  {
    // A menu row that titles a server, Agent, workspace, model, or provider by
    // its own name: its artwork goes with the title (`UIAction.choice`).
    name: "UIAction(title: entity name",
    pattern: /\bUIAction\s*\(\s*title:\s*(?:\w+\.)*(?:server|agent|workspace|model|provider)\w*\.\s*(?:name|displayName|title)\b/g,
    disallowed: false,
    exemptFiles: [entityIconOwner],
  },
];

/**
 * Disallowed constructs that may stay, per file: the construct and how many
 * uses. Every entry needs a reason; an entry nobody needs is deleted.
 */
const allowed: { file: string; construct: string; count: number; reason: string }[] = [
  {
    file: "clients/apple/Oppi/Features/Server/UsageCharts.swift",
    construct: "UIHostingController<",
    count: 1,
    reason: "UsageChartLeafHost is the Swift-Charts leaf's own UIKit host; a chart cannot be UIKit.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Timeline/Assistant/USDZRealityCanvas.swift",
    construct: "UIHostingController<",
    count: 1,
    reason: "USDZRealityCanvasHost is the RealityKit canvas's own UIKit host; RealityView cannot be UIKit.",
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
    for (const { name, pattern, exemptFiles, fileMustMatch, pathMustMatch } of constructs) {
      if (exemptFiles?.includes(file)) continue;
      if (pathMustMatch && !pathMustMatch.test(file)) continue;
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
  console.log("UIKit structure guard: PASS — no disallowed SwiftUI structure constructs; import SwiftUI restricted to the allowed files; settings-list theming and settings writes within baseline.");
  process.exit(0);
}

console.log("UIKit structure guard: FAIL — SwiftUI structure constructs the guard disallows, a SwiftUI import outside the allowed files, or a baseline exceeded.\n");
for (const line of failures) console.log(line);
console.log(`
UIKit owns iOS app structure, modal presentation, and new views, previews and
harnesses included. Present and push through the router (Router.present,
Router.push, and a RouterModalPresenter slot; previews that are their own window
root host through PreviewHost.screenStack). SwiftUI survives only in the files
\`swiftUIImporters\` names: the two framework leaves (\`UsageCharts\`,
\`USDZRealityCanvas\`), the TipKit file (\`FeatureEducationTips\`), and the
${sharedImporterCount} \`Shared/\` files the app target compiles (the
\`ModelColorHelpers\` chart and \`LiveActivityPresentation\`). See ${guide}.
NavigationStack, NavigationSplitView, NavigationLink, .navigationDestination(,
.sheet(, .fullScreenCover(, .popover(, .inspector(, UIHostingController(, and
UIHostingController< (a subclass or stored type) have no baseline: an exception needs the owner's approval and a commented entry in
the guard's allowed list. A new \`import SwiftUI\` fails too: the file needs
approval and an entry in \`swiftUIImporters\`, with a reason. \`bun
scripts/uikit-structure-guard.ts --update\` lowers the other ratchets after a
migration. After a rename or move, --update is fine when the
baseline diff only moves entries.

Settings lists subclass ListScreenController, which pins the list, paints it in
the theme, and lays out its rows. A hand-built
UICollectionLayoutListConfiguration(appearance: .insetGrouped) in a file that
paints the theme's background itself means a settings list is laying itself out;
see ${settingsGuide}. A page that lays out one non-list section (a grid) through
layoutSection(for:environment:) is a page on the base. A screen that will never
be a settings page goes in settingsThemingExceptions with a reason.

UIAlertController( outside ErrorAlertPresenter.swift and ConfirmationSheet.swift
means a screen builds its own error alert or confirmation. Tell the person an
error with \`errorAlerts.show(...)\` (or \`errorAlerts.sync(...)\` for an error held
in state), and ask with \`Confirmation(...).present(from:anchor:)\`; a choice
sheet anchors through \`AlertAnchor.present\`. See ${alertsGuide}.

setNavigationBarHidden( or an isNavigationBarHidden = assignment outside Router.swift means a screen decides the stack's bar
itself and can race the stack. Conform to NavigationBarHiding, answer
hidesNavigationBar, and call navigationController?.updateNavigationBar(for:animated:)
when the answer changes; see ${navigationBarGuide}.

UIContentUnavailableConfiguration.empty(/.loading(/.search( outside LoadStateContent.swift
means a screen builds its own loading, empty, or failed state. Show a \`LoadState\` with
\`contentUnavailableConfiguration = UIContentUnavailableConfiguration.loadState(state, palette:, background:)\`
(or \`UIContentUnavailableView(loadState:)\` for a region); see ${loadStateGuide}.

providerLogoAssetName(, providerMonogram(, and resolvedBadgeIcon.symbolName outside
EntityIcon.swift, and a UIAction(title:) that names a server, Agent, workspace,
model, or provider variable, mean a screen probably draws an entity's artwork
itself. Draw it with EntityIcon.image(.agent/.workspace/.provider/.model/.server,
size:, assets:) in a row, or build a menu row with UIAction.choice(title, entity,
selected:, assets:), which carries the icon and the menu's own checkmark; see
the shared UIKit building blocks in dev/architecture-client.md. This is a
heuristic: it reads the call by name. The baseline keeps a provider's VoiceOver
name and the rail item's and pill's state-tinted badge symbols.

AppPreferences.*.set, UserDefaults.standard.set(, FontPreferences.set, an APIClient
call that writes a setting, and toggleRow( or .settingsToggle( in Features are settings written outside
SettingsStore. Declare the setting in SettingsCatalog and read and write it through
SettingsStore (settingToggleRow, settingChoiceRow on the settings base); see
${settingsGuide}. The count only goes down: \`bun scripts/uikit-structure-guard.ts --update\`
lowers the baseline after a page moves.

A page on ListScreenController that writes isLoadCancellation or an override
func viewIsAppearing takes over the trigger or the outcome of the load the kit
owns. This is a ratchet, not a proof: it reads the call by name. Say loadPolicy,
loadSubject(), and load() (subjectDidChange() too when the page drops what the
old subject showed), and ask for a load with setNeedsLoad(); see
${settingsGuide}. A page's own task for an action is fine. The count only goes
down.`);
process.exit(1);
