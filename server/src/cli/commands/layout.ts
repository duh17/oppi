import { closeSync, existsSync, openSync, readFileSync, readSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";

import * as c from "../../ansi.js";
import {
  LAYOUT_MAX_BYTES,
  LAYOUT_VERSION,
  LAYOUTS_FOLDER,
  layoutLeafKind,
  layoutLeaves,
  validateLayoutBytes,
  type LayoutValidation,
} from "../../layout-validation.js";
import { getOppiDocsPath } from "../../oppi-docs.js";
import type { LayoutIssue, LayoutLeaf } from "../../types.js";
import {
  captureHumanCliOutput,
  type CliJsonEnvelope,
  setCapturedCliExitCode,
  writeHumanLine,
  writeJsonEnvelope,
} from "../output.js";

/**
 * `oppi layout check <file|-> [--json]` and `oppi layout guide`. Both run without a server:
 * `check` is the layout validator (`layout-validation.ts`) plus a look for the files a layout
 * names, and `guide` prints the agent's section of `docs/layouts.md`. It reads this machine's
 * files and stdin, so only the `oppi` entry point dispatches it, never the server's in-process CLI.
 */
export function cmdLayout(
  action: string | undefined,
  args: readonly string[],
  flags: Record<string, string>,
  cwd: string,
): void {
  const json = flags.json === "true";
  switch (action) {
    case "check":
      check(args, json, cwd);
      return;
    case "guide":
      guide(json);
      return;
    default:
      fail(
        json,
        action
          ? `Unknown layout command: ${action}. Use 'oppi layout check <file|->' or 'oppi layout guide'.`
          : "Use 'oppi layout check <file|->' or 'oppi layout guide'.",
      );
  }
}

/** The envelope with `--json` (and the lines only for a caller capturing both), else the lines. */
function output(json: boolean, envelope: CliJsonEnvelope, lines: readonly string[]): void {
  const print = (): void => {
    for (const line of lines) writeHumanLine(line);
  };
  if (!json) {
    print();
    return;
  }
  writeJsonEnvelope(envelope);
  captureHumanCliOutput(print);
}

function fail(json: boolean, message: string): void {
  output(json, { ok: false, error: { message } }, [c.red(`  Error: ${message}`)]);
  setCapturedCliExitCode(1);
}

function check(args: readonly string[], json: boolean, cwd: string): void {
  const target = args[0];
  if (!target || args.length > 1) {
    fail(json, "Name one layout file, or - to read the layout from stdin.");
    return;
  }

  let bytes: Uint8Array;
  let label: string;
  // Relative `file` leaves are looked up in the checkout the layout belongs to: the one whose
  // `.oppi/layouts/` holds the file, else (stdin, a draft elsewhere) the working directory.
  let checkout = cwd;
  try {
    if (target === "-") {
      bytes = readFileSync(0);
      label = "stdin";
    } else {
      const path = resolve(cwd, target);
      bytes = readBounded(path);
      label = basename(path);
      const folder = dirname(path);
      if (folder.endsWith(`${sep}${LAYOUTS_FOLDER.split("/").join(sep)}`)) {
        checkout = dirname(dirname(folder));
      }
    }
  } catch (error: unknown) {
    const code = (error as NodeJS.ErrnoException).code;
    fail(json, code === "ENOENT" ? `No such file: ${target}` : `Cannot read ${target}`);
    return;
  }

  const result = validateLayoutBytes(bytes);
  const missingFiles = result.kind === "valid" ? missingFileWarnings(result, checkout) : [];
  const warnings = result.kind === "newer" ? [] : [...result.warnings, ...missingFiles];
  const ok = result.kind === "valid";
  if (!ok) setCapturedCliExitCode(1);

  output(
    json,
    {
      ok: true,
      data: {
        valid: ok,
        ...(result.kind === "valid" ? { layout: result.layout } : {}),
        ...(result.kind === "invalid" ? { problems: result.problems } : {}),
        ...(result.kind === "newer" ? { newerVersion: result.v } : {}),
        warnings,
      },
    },
    report(label, target === "-", result, warnings),
  );
}

/** At most one byte past the limit, so a huge file is refused unread. */
function readBounded(path: string): Uint8Array {
  const descriptor = openSync(path, "r");
  try {
    const buffer = Buffer.alloc(LAYOUT_MAX_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const read = readSync(descriptor, buffer, length, buffer.length - length, null);
      if (read === 0) break;
      length += read;
    }
    return buffer.subarray(0, length);
  } finally {
    closeSync(descriptor);
  }
}

/** A relative `file` the checkout does not have yet, or an absolute one this machine lacks. */
function missingFileWarnings(
  result: Extract<LayoutValidation, { kind: "valid" }>,
  checkout: string,
): LayoutIssue[] {
  const warnings: LayoutIssue[] = [];
  forEachLeaf(result.layout.root, "root", (leaf, path) => {
    if (!("file" in leaf) || typeof leaf.file !== "string") return;
    const file = isAbsolute(leaf.file) ? leaf.file : join(checkout, leaf.file);
    if (!existsSync(file)) {
      warnings.push({
        code: "value",
        path: `${path}.file`,
        message: `${leaf.file} does not exist yet; the pane shows that until it does`,
      });
    }
  });
  return warnings;
}

function forEachLeaf(
  node: Extract<LayoutValidation, { kind: "valid" }>["layout"]["root"],
  path: string,
  visit: (leaf: LayoutLeaf, path: string) => void,
): void {
  if ("split" in node && Array.isArray(node.children)) {
    node.children.forEach((child, index) =>
      forEachLeaf(child, `${path}.children[${index}]`, visit),
    );
    return;
  }
  visit(node as LayoutLeaf, path);
}

function report(
  label: string,
  inline: boolean,
  result: LayoutValidation,
  warnings: readonly LayoutIssue[],
): string[] {
  const lines: string[] = [];
  switch (result.kind) {
    case "newer":
      lines.push(
        `${label}: needs a newer Oppi (layout version ${result.v}; this one reads version ${LAYOUT_VERSION})`,
      );
      return lines;
    case "invalid":
      lines.push(
        `${label}: ${result.problems.length} ${result.problems.length === 1 ? "problem" : "problems"}`,
      );
      for (const problem of result.problems) lines.push(`  ${issueLine(problem)}`);
      break;
    case "valid": {
      lines.push(`${label}: valid (layout version ${LAYOUT_VERSION}) · ${result.layout.title}`);
      for (const leaf of layoutLeaves(result.layout.root)) lines.push(`  ${leafLine(leaf)}`);
      break;
    }
  }
  for (const warning of warnings) lines.push(`warning: ${issueLine(warning)}`);
  if (result.kind !== "valid") return lines;
  lines.push(
    inline
      ? "This layout is valid. The app does not open layout cards yet, so an oppi-layout block in your reply changes nothing on screen."
      : "This layout is valid and saved. The app does not open layout cards yet, so nothing changes on screen; link the file when you mention it.",
  );
  return lines;
}

function issueLine(issue: LayoutIssue): string {
  return issue.path ? `${issue.path}: ${issue.message}` : issue.message;
}

function leafLine(leaf: LayoutLeaf): string {
  const [kind, detail] = describeLeaf(leaf);
  const name = leaf.name ? `  "${leaf.name}"` : "";
  return `${leaf.pane.padEnd(12)} ${kind.padEnd(9)} ${detail}${name}`;
}

function describeLeaf(validLeaf: LayoutLeaf): [string, string] {
  // Validated: each field has its checked type; this only formats it.
  const leaf = validLeaf as Record<string, unknown>;
  switch (layoutLeafKind(validLeaf)) {
    case "chat":
      return ["Chat", leaf.chat === "self" ? "this chat" : `session ${String(leaf.chat)}`];
    case "file":
      return [
        "File",
        `${String(leaf.file)}${typeof leaf.line === "number" ? `:${leaf.line}` : ""}`,
      ];
    case "panel":
      return [
        "Panel",
        `${String(leaf.panel)}${typeof leaf.session === "string" && leaf.session !== "self" ? ` of session ${leaf.session}` : ""}`,
      ];
    case "git":
      return ["Git", leaf.git === "status" ? "status" : `commit ${String(leaf.git)}`];
    case "web":
      return ["Web", new URL(String(leaf.web)).host];
    case "terminal": {
      const [kind, target] = Object.entries(leaf.terminal as Record<string, string>)[0] ?? [];
      return ["Terminal", `${kind} ${target}`];
    }
    case "godot":
      return ["Godot", `project ${String(leaf.godot)}`];
    case undefined:
      return ["Unknown", "needs a newer Oppi"];
  }
}

/** The agent's section of `docs/layouts.md`: from its first `## ` heading to the next. */
function guide(json: boolean): void {
  const docs = getOppiDocsPath();
  const page = docs ? join(docs, "layouts.md") : undefined;
  if (!page || !existsSync(page)) {
    fail(json, "The layouts guide is not installed with this server.");
    return;
  }
  const text = readFileSync(page, "utf8");
  const start = text.indexOf("\n## ");
  const end = start === -1 ? -1 : text.indexOf("\n## ", start + 1);
  const section = text.slice(start + 1, end === -1 ? undefined : end).trimEnd();
  output(json, { ok: true, data: { guide: section, page } }, [
    section,
    "",
    `The full spec: ${page}`,
  ]);
}
