#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { stripSwiftCommentsAndStrings } from "../server/scripts/architecture-layer-rules.mjs";

/**
 * Document edit-entry guard for the iOS app target (clients/apple/Oppi and its
 * Debug-only clients/apple/OppiDebugHarness).
 *
 * Every document's edit entry has one owner, `DocumentEditOwner`
 * (`clients/apple/Oppi/Features/DocumentEditing`). Outside that folder this scan
 * fails on the machinery of an edit entry — the session, editor, page, bar
 * items, recovery, conflict review, banner, labels, the capability and the
 * editor's read — and on a pencil symbol (`pencil`, `pencil.circle`,
 * `square.and.pencil`, `systemItem: .edit`) that no `allowed` entry names with
 * its reason. A file's count is its cap, so a new pencil in an allowed file
 * still fails. Tests are not scanned: they build these on purpose.
 *
 * Policy: dev/architecture-client.md, "Document editing".
 */

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const ownerDirectory = "clients/apple/Oppi/Features/DocumentEditing/";
const scanRoots = ["clients/apple/Oppi", "clients/apple/OppiDebugHarness"].map((dir) => join(repoRoot, dir));
const guide = "dev/architecture-client.md, section \"Document editing\"";

/** Rule name, matcher, and whether the symbol lives in a string (raw lines). */
const rules: [name: string, pattern: RegExp, rawLines?: boolean][] = [
  ["WorkspaceFileEditorViewController(", /\bWorkspaceFileEditorViewController\s*\(/g],
  ["WorkspaceFileEditSession(", /\bWorkspaceFileEditSession\s*\(/g],
  ["WorkspaceFileEditBarItems(", /\bWorkspaceFileEditBarItems\s*\(/g],
  ["WorkspaceFileEditRecovery", /\bWorkspaceFileEditRecovery\b/g],
  ["WorkspaceFileConflictReviewViewController(", /\bWorkspaceFileConflictReviewViewController\s*\(/g],
  ["WorkspaceFileEditBannerView(", /\bWorkspaceFileEditBannerView\s*\(/g],
  ["DocumentEditLabels", /\bDocumentEditLabels\b/g],
  ["fileEditingCapability(", /\bfileEditingCapability\s*\(/g],
  ["readFileForEditing(", /\breadFileForEditing\s*\(/g],
  ["edit pencil", /"pencil|"square\.and\.pencil|\beditButtonItem\b/, true],
];

const O = "clients/apple/Oppi/";
/**
 * Machinery and pencils that are not a document's edit entry, per file with a
 * cap and a reason. The cap is that file's count; an entry nobody needs goes.
 */
const allowed: [file: string, rule: string, count: number, reason: string][] = [
  [O + "Core/Networking/APIClient.swift", "fileEditingCapability(", 3,
    "The transport implements and checks the capability."],
  [O + "Core/Networking/APIClient.swift", "readFileForEditing(", 2,
    "The transport's own editor read, which the owner reaches through its backend."],
  [O + "Features/Agents/AgentDetailViewController.swift", "edit pencil", 1,
    "The Agent form's Edit button opens the editing form, not a document."],
  [O + "Features/Schedules/ScheduleDetailViewController.swift", "edit pencil", 2,
    "The schedule form's Edit button (image and action): a form, not a document."],
  [O + "Features/Chat/ChatViewController+Bars.swift", "edit pencil", 1,
    "Rename Session opens the title form."],
  [O + "Features/SSHTerminal/SSHTerminalViewController.swift", "edit pencil", 1,
    "Edit Host opens the host form."],
  [O + "Features/Chat/ReviewComments/ReviewCommentStashContent.swift", "edit pencil", 1,
    "Edit review comment edits the staged comment, not a file."],
  [O + "Features/Chat/Timeline/QuietTimelineProjection.swift", "edit pencil", 1,
    "The write tool's own SF Symbol, drawn as a tool icon."],
  [O + "Features/Chat/Support/WorkspaceContextBar.swift", "edit pencil", 1,
    "New Session's compose icon beside the selection count."],
  [O + "Features/Sessions/SessionListCollection.swift", "edit pencil", 1,
    "The Message capsule's compose icon."],
  [O + "Features/Review/WorkspaceReviewFileDetailViewController.swift", "edit pencil", 1,
    "New Session's compose icon; the file's own entry comes from the viewer."],
  [O + "Core/Views/PaperMarkupCanvasSession.swift", "edit pencil", 2,
    "Visual Markup's drawing-tool symbols, not document edit controls."],
  [O + "Features/Settings/QuickCommentEditorViewController.swift", "edit pencil", 1,
    "A quick-comment template's symbol choice, not a document."],
  [O + "Features/Settings/QuickCommentsViewController.swift", "edit pencil", 2,
    "UIKit's editButtonItem on the template list plus its identifier."],
  [O + "Features/FileBrowser/Editing/WorkspaceFileEditChrome.swift", "edit pencil", 2,
    "The save status glyph and the conflict review's Keep Editing button."],
];

function walkSwiftFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return walkSwiftFiles(path);
    return entry.isFile() && entry.name.endsWith(".swift") ? [path] : [];
  });
}

function scan(): { file: string; line: number; rule: string }[] {
  const hits: { file: string; line: number; rule: string }[] = [];
  for (const absolute of scanRoots.flatMap(walkSwiftFiles)) {
    const file = relative(repoRoot, absolute);
    if (file.startsWith(ownerDirectory)) continue;
    const source = readFileSync(absolute, "utf8");
    const stripped = stripSwiftCommentsAndStrings(source);
    for (const [name, pattern, rawLines] of rules) {
      if (rawLines) {
        // A symbol lives in a string literal, which the stripper blanks: read
        // the raw lines and skip the ones that are comment.
        source.split("\n").forEach((text, index) => {
          const code = text.trim();
          const comment = code.startsWith("//") || code.startsWith("*") || code.startsWith("/*");
          if (!comment && text.match(pattern)) hits.push({ file, line: index + 1, rule: name });
        });
        continue;
      }
      for (const match of stripped.matchAll(pattern)) {
        hits.push({ file, line: stripped.slice(0, match.index).split("\n").length, rule: name });
      }
    }
  }
  return hits;
}

const hits = scan();
const cap = (file: string, rule: string) =>
  allowed.find(([entryFile, entryRule]) => entryFile === file && entryRule === rule)?.[2] ?? 0;
const failures = hits
  .filter((hit) => cap(hit.file, hit.rule) === 0)
  .map((hit) =>
    `- ${hit.file}:${hit.line}: ${hit.rule} outside DocumentEditOwner (${guide}). `
      + "A reader's edit entry is the owner's; a form's Edit button needs an allowed entry with its reason.");
for (const [file, rule, count, reason] of allowed) {
  const found = hits.filter((hit) => hit.file === file && hit.rule === rule);
  if (found.length <= count) continue;
  failures.push(`- ${file}: ${rule} count ${found.length} exceeds ${count} — ${reason}`);
  for (const hit of found) failures.push(`    ${file}:${hit.line}: ${rule}`);
}

if (failures.length === 0) {
  console.log("Document edit guard: PASS — one owner for every edit entry; no session, editor, page, sheet, read, label, or stray pencil outside Features/DocumentEditing.");
  process.exit(0);
}

console.log(`Document edit guard: FAIL — edit machinery outside the owner.\n\n${failures.join("\n")}`);
console.log(`\nDocumentEditOwner is the one owner of a document's edit entry, from the tagged read to the page's sheets. A screen that decides editability itself — ServerSkillFilePresentation when it builds a Skill's subject — says so there. See ${guide}.`);
process.exit(1);
