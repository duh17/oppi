#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Document edit-entry guard for the iOS app target (clients/apple/Oppi and its
 * Debug-only clients/apple/OppiDebugHarness).
 *
 * Every document's edit entry has one owner, `DocumentEditOwner`
 * (`clients/apple/Oppi/Features/DocumentEditing`). It decides whether a reader
 * opens our editor (a pencil), whether it offers an Oppi session instead (a "…"
 * holding Edit with Session), and it owns the tagged read, the draft recovery,
 * and the editor page. A screen that builds its own edit machinery forks the
 * rule: two readers disagree about what is editable, or about which bar item
 * opens what.
 *
 * Two rules, one plain source scan, no simulator. Comments are stripped; string
 * literals are kept, because the pencil rule is about a symbol name.
 *
 *  1. Edit machinery stays in the owner. Outside
 *     `Features/DocumentEditing/`, `WorkspaceFileEditorViewController(`,
 *     `WorkspaceFileEditSession(`, `WorkspaceFileEditBarItems(`,
 *     `fileEditingCapability(`, and `DocumentEditLabels` are disallowed. Tests
 *     are not scanned: they build these on purpose.
 *  2. One pencil. `"pencil"` as a symbol outside `Features/DocumentEditing/`
 *     fails unless the file is in `allowed` below, so a reader with the edit
 *     entry (a file that builds `FullScreenCodeViewController(` or
 *     `FileViewerViewController(`) cannot grow a second, hand-rolled pencil.
 *     The exceptions are the form Edit buttons and the two non-edit pencils,
 *     each named with the reason it is not a document entry. A file's count is
 *     its cap, so a new pencil in an allowed file still fails.
 *
 * Policy: dev/architecture-client.md, "Document editing".
 *
 *   bun scripts/document-edit-guard.ts            check
 */

type Rule = {
  name: string;
  pattern: RegExp;
};

type Hit = { file: string; line: number; rule: string };

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scanRoots = ["clients/apple/Oppi", "clients/apple/OppiDebugHarness"].map((dir) => join(repoRoot, dir));
const ownerDirectory = "clients/apple/Oppi/Features/DocumentEditing/";
const guide = "dev/architecture-client.md, section \"Document editing\"";

/** The owner and everything it is allowed to build. */
const rules: Rule[] = [
  {
    name: "WorkspaceFileEditorViewController(",
    pattern: /\bWorkspaceFileEditorViewController\s*\(/g,
  },
  {
    name: "WorkspaceFileEditSession(",
    pattern: /\bWorkspaceFileEditSession\s*\(/g,
  },
  {
    name: "WorkspaceFileEditBarItems(",
    pattern: /\bWorkspaceFileEditBarItems\s*\(/g,
  },
  {
    name: "fileEditingCapability(",
    pattern: /\bfileEditingCapability\s*\(/g,
  },
  {
    name: "DocumentEditLabels",
    pattern: /\bDocumentEditLabels\b/g,
  },
  {
    name: "\"pencil\" symbol",
    pattern: /"pencil"/g,
  },
];

/**
 * Pencils and machinery that are not a document edit entry, per file with a cap
 * and a reason. The cap is that file's count: a new pencil in a listed file
 * still fails. An entry nobody needs is deleted.
 */
const allowed: { file: string; rule: string; count: number; reason: string }[] = [
  {
    file: "clients/apple/Oppi/Core/Networking/APIClient.swift",
    rule: "fileEditingCapability(",
    count: 3,
    reason: "The transport implements and checks the server's editing capability; the owner decides whether a document is editable.",
  },
  {
    file: "clients/apple/Oppi/Features/Agents/AgentDetailViewController.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "The Agent form's Edit button opens the editing form, not a document.",
  },
  {
    file: "clients/apple/Oppi/Features/Schedules/ScheduleDetailViewController.swift",
    rule: "\"pencil\" symbol",
    count: 2,
    reason: "The schedule form's Edit button (image and action open the same form), not a document.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/ChatViewController+Bars.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "Rename Session opens the title form.",
  },
  {
    file: "clients/apple/Oppi/Features/SSHTerminal/SSHTerminalViewController.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "Edit Host opens the host form.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/ReviewComments/ReviewCommentStashContent.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "Edit review comment edits the staged comment, not a file.",
  },
  {
    file: "clients/apple/Oppi/Features/Chat/Timeline/QuietTimelineProjection.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "The write tool's own SF Symbol, drawn as a tool icon.",
  },
  {
    file: "clients/apple/Oppi/Features/FileBrowser/Editing/WorkspaceFileEditChrome.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "The conflict review's Keep Editing button closes the sheet; its diff reader is not an edit entry.",
  },
  {
    file: "clients/apple/OppiDebugHarness/FullScreenReviewCommentHarnessView.swift",
    rule: "\"pencil\" symbol",
    count: 1,
    reason: "The reader harness's stand-in edit item; the harness hosts the reader without a document.",
  },
];

/**
 * The file with its comments blanked and its line breaks kept, so line numbers
 * still point at the source. String literals survive: the pencil rule reads one.
 */
function stripSwiftComments(source: string): string {
  let output = "";
  let index = 0;
  let state: "code" | "line-comment" | "block-comment" | "string" | "multiline-string" = "code";
  let blockCommentDepth = 0;

  while (index < source.length) {
    const char = source[index];
    const next = source[index + 1] ?? "";
    const nextTwo = source[index + 2] ?? "";

    if (state === "line-comment") {
      if (char === "\n") {
        output += "\n";
        state = "code";
      } else {
        output += " ";
      }
      index += 1;
      continue;
    }

    if (state === "block-comment") {
      if (char === "/" && next === "*") {
        blockCommentDepth += 1;
        output += "  ";
        index += 2;
        continue;
      }
      if (char === "*" && next === "/") {
        blockCommentDepth -= 1;
        output += "  ";
        index += 2;
        if (blockCommentDepth === 0) state = "code";
        continue;
      }
      output += char === "\n" ? "\n" : " ";
      index += 1;
      continue;
    }

    if (state === "multiline-string") {
      output += char === "\n" ? "\n" : char;
      if (char === '"' && next === '"' && nextTwo === '"') {
        output += '""';
        index += 3;
        state = "code";
        continue;
      }
      index += 1;
      continue;
    }

    if (state === "string") {
      output += char;
      if (char === "\\") {
        output += next;
        index += 2;
        continue;
      }
      if (char === '"') state = "code";
      index += 1;
      continue;
    }

    if (char === "/" && next === "/") {
      output += "  ";
      index += 2;
      state = "line-comment";
      continue;
    }
    if (char === "/" && next === "*") {
      output += "  ";
      index += 2;
      state = "block-comment";
      blockCommentDepth = 1;
      continue;
    }
    if (char === '"' && next === '"' && nextTwo === '"') {
      output += '"""';
      index += 3;
      state = "multiline-string";
      continue;
    }
    if (char === '"') {
      output += char;
      index += 1;
      state = "string";
      continue;
    }

    output += char;
    index += 1;
  }

  return output;
}

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
  for (const absolute of scanRoots.flatMap(walkSwiftFiles)) {
    const file = relative(repoRoot, absolute);
    if (file.startsWith(ownerDirectory)) continue;
    const source = stripSwiftComments(readFileSync(absolute, "utf8"));
    for (const { name, pattern } of rules) {
      for (const match of source.matchAll(pattern)) {
        const line = source.slice(0, match.index).split("\n").length;
        hits.push({ file, line, rule: name });
      }
    }
  }
  return hits;
}

const hits = scan();
const failures: string[] = [];

const cap = (file: string, rule: string) =>
  allowed.find((entry) => entry.file === file && entry.rule === rule)?.count ?? 0;

for (const hit of hits) {
  if (cap(hit.file, hit.rule) === 0) {
    failures.push(
      `- ${hit.file}:${hit.line}: ${hit.rule} outside DocumentEditOwner (${guide}). `
        + "A reader's edit entry is the owner's pencil; a form's Edit button needs an entry in the guard's allowed list.",
    );
  }
}

for (const entry of allowed) {
  const fileHits = hits.filter((hit) => hit.file === entry.file && hit.rule === entry.rule);
  if (fileHits.length > entry.count) {
    failures.push(
      `- ${entry.file}: ${entry.rule} count ${fileHits.length} exceeds the allowed ${entry.count} — `
        + `${entry.reason} A new one belongs to DocumentEditOwner.`,
    );
    for (const hit of fileHits) failures.push(`    ${entry.file}:${hit.line}: ${entry.rule}`);
  }
}

if (failures.length === 0) {
  console.log(
    "Document edit guard: PASS — one owner for every edit entry; no session, editor, bar items, capability read, labels, or stray pencil outside Features/DocumentEditing.",
  );
  process.exit(0);
}

console.log("Document edit guard: FAIL — edit machinery outside the owner.\n");
for (const line of failures) console.log(line);
console.log(`
DocumentEditOwner (clients/apple/Oppi/Features/DocumentEditing) is the one owner
of a document's edit entry: whether the reader shows a pencil (our editor) or a
"…" holding Edit with Session, the tagged read and draft recovery behind the
bytes, ans the editor page with its bar items. A reader hands the owner a
DocumentEditSubject and shows owner.barItems; it never builds an edit session,
reads the editing capability, or makes its own pencil. See ${guide}.
`);
process.exit(1);
