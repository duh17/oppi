#!/usr/bin/env bun

/**
 * Generate the list of Godot APIs that Oppi's device engine does not have.
 *
 *   bun server/scripts/generate-godot-deprecated-api.ts          # write the file
 *   bun server/scripts/generate-godot-deprecated-api.ts --check  # exit 1 when stale
 *
 * The device engine (engine/godot/build.sh) is built with `deprecated=no`, which compiles out
 * what Godot's class reference marks deprecated. This reads that reference at the exact commit
 * build.sh pins, from the Godot checkout build.sh uses (`OPPI_GODOT_SRC`, default
 * ~/Library/Caches/oppi-godot/src), together with the binary GDScript token layout of the same
 * commit, and writes server/src/godot/godot-deprecated-api.generated.ts. Never edit the output by
 * hand; run this again after build.sh moves to another Godot.
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { format, resolveConfig } from "prettier";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const OUTPUT = join(repoRoot, "server/src/godot/godot-deprecated-api.generated.ts");
const BUILD_SCRIPT = join(repoRoot, "engine/godot/build.sh");

function pinned(name: string): string {
  const match = readFileSync(BUILD_SCRIPT, "utf8").match(new RegExp(`^${name}="([^"]+)"`, "m"));
  if (!match?.[1]) throw new Error(`${name} not found in engine/godot/build.sh`);
  return match[1];
}

const tag = pinned("GODOT_TAG");
const commit = pinned("GODOT_COMMIT");
const src = process.env.OPPI_GODOT_SRC ?? join(homedir(), "Library/Caches/oppi-godot/src");

function git(args: string[], input?: string): string {
  return execFileSync("git", ["-C", src, ...args], {
    encoding: "utf8",
    maxBuffer: 512 * 1024 * 1024,
    ...(input !== undefined ? { input } : {}),
  });
}

try {
  git(["cat-file", "-e", `${commit}^{commit}`]);
} catch {
  console.error(
    `No Godot ${tag} (${commit}) in ${src}. Run engine/godot/build.sh once, or set OPPI_GODOT_SRC to a checkout holding that commit.`,
  );
  process.exit(2);
}

/** Every file at `commit` among `paths`, read through one `git cat-file --batch`. */
function readAt(paths: string[]): Map<string, string> {
  const out = execFileSync("git", ["-C", src, "cat-file", "--batch"], {
    input: paths.map((path) => `${commit}:${path}`).join("\n") + "\n",
    maxBuffer: 512 * 1024 * 1024,
  });
  const files = new Map<string, string>();
  let at = 0;
  for (const path of paths) {
    const end = out.indexOf(0x0a, at);
    const header = out.subarray(at, end).toString("utf8");
    const size = Number(header.split(" ")[2]);
    if (!Number.isInteger(size)) throw new Error(`git cat-file: ${header}`);
    files.set(path, out.subarray(end + 1, end + 1 + size).toString("utf8"));
    at = end + 1 + size + 1;
  }
  return files;
}

// --- Class reference ------------------------------------------------------------------------------

type Kind = "class" | "method" | "member" | "constant" | "signal";

interface Entry {
  class: string;
  name: string;
  kind: Kind;
  /** The class reference's note, as plain text: usually what to use instead. */
  note: string;
  /** No API that is not deprecated has this name, so a use without its class still counts. */
  unique: boolean;
}

const docPaths = git(["ls-tree", "-r", "--name-only", commit, "--", "doc/classes", "modules"])
  .split("\n")
  .filter((path) => /^(doc\/classes|modules\/[^/]+\/doc_classes)\/[^/]+\.xml$/.test(path));

const ENTITIES: Record<string, string> = { quot: '"', lt: "<", gt: ">", amp: "&", apos: "'" };
const attributes = (text: string): Map<string, string> =>
  new Map(
    [...text.matchAll(/([\w-]+)="([^"]*)"/g)].map((m) => [
      m[1]!,
      m[2]!.replace(/&(quot|lt|gt|amp|apos);/g, (_, e: string) => ENTITIES[e]!),
    ]),
  );

/** The reference's BBCode as plain text: `[method create_empty]` reads `create_empty()`. */
function plain(note: string): string {
  return note
    .replace(/\[method ([^\]]+)\]/g, "$1()")
    .replace(/\[(?:member|constant|enum|signal|annotation|param|theme_item) ([^\]]+)\]/g, "$1")
    .replace(/\[url=[^\]]*\]([^[]*)\[\/url\]/g, "$1")
    .replace(/\[\/?(?:code|b|i|kbd|codeblock)\]/g, "")
    .replace(/\[([A-Z@][A-Za-z0-9_]*)\]/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

const entries: Entry[] = [];
const current = new Set<string>();
for (const text of readAt(docPaths).values()) {
  const head = text.match(/<class ([^>]*)>/);
  if (!head) continue;
  const classAttrs = attributes(head[1]!);
  const className = classAttrs.get("name")!;
  if (classAttrs.has("deprecated")) {
    entries.push({
      class: className,
      name: className,
      kind: "class",
      note: plain(classAttrs.get("deprecated")!),
      unique: true,
    });
  } else current.add(className);
  for (const m of text.matchAll(/<(method|member|constant|signal|annotation)\s([^>]*)>/g)) {
    const attrs = attributes(m[2]!);
    const name = attrs.get("name");
    if (!name) continue;
    if (!attrs.has("deprecated") || m[1] === "annotation") {
      current.add(name);
      continue;
    }
    entries.push({
      class: className,
      name,
      kind: m[1] as Kind,
      note: plain(attrs.get("deprecated")!),
      unique: false,
    });
  }
}
for (const entry of entries) entry.unique = entry.kind === "class" || !current.has(entry.name);
entries.sort((a, b) => a.class.localeCompare(b.class) || a.name.localeCompare(b.name));

// --- Binary GDScript tokens ------------------------------------------------------------------------

const TOKENIZER_H = "modules/gdscript/gdscript_tokenizer.h";
const BUFFER_H = "modules/gdscript/gdscript_tokenizer_buffer.h";
const tokenizerFiles = readAt([TOKENIZER_H, BUFFER_H]);
const version = tokenizerFiles.get(BUFFER_H)!.match(/TOKENIZER_VERSION = (\d+);/)?.[1];
const typeEnum = tokenizerFiles.get(TOKENIZER_H)!.match(/enum Type \{([\s\S]*?)\};/)?.[1];
if (!version || !typeEnum) throw new Error("The GDScript tokenizer's layout was not found");
const tokenTypes = typeEnum
  .split("\n")
  .map((line) => line.replace(/\/\/.*/, "").trim())
  .filter(Boolean)
  .map((line) => line.replace(/,$/, ""));
const tokenIndex = (name: string): number => {
  const index = tokenTypes.indexOf(name);
  if (index < 0) throw new Error(`No ${name} token in ${TOKENIZER_H}`);
  return index;
};

// --- Output ------------------------------------------------------------------------------------------

const source = `// Generated by server/scripts/generate-godot-deprecated-api.ts from Godot ${tag}'s class
// reference (${commit}). Do not edit; run the script again.

/** One API Godot's class reference marks deprecated, which the device engine compiles out. */
export interface GodotDeprecatedApi {
  /** The class it belongs to; for a deprecated class, the class itself. */
  class: string;
  name: string;
  kind: "class" | "method" | "member" | "constant" | "signal";
  /** The class reference's note, usually what to use instead; may be empty. */
  note: string;
  /** No API that is not deprecated has this name, so a use without its class still counts. */
  unique: boolean;
}

export const GODOT_DEPRECATED_SOURCE = ${JSON.stringify(tag)};

/**
 * Binary GDScript (\`.gdc\`) of this Godot: the tokenizer version and the token types read.
 * \`nodePath\` are the tokens before a node name (\`$Player\`, \`%Hud\`, \`$Hud/Score\`).
 */
export const GODOT_TOKENIZER = ${JSON.stringify({
  version: Number(version),
  identifier: tokenIndex("IDENTIFIER"),
  period: tokenIndex("PERIOD"),
  nodePath: [tokenIndex("DOLLAR"), tokenIndex("PERCENT"), tokenIndex("SLASH")],
})};

export const GODOT_DEPRECATED_API: readonly GodotDeprecatedApi[] = ${JSON.stringify(entries)};
`;

const formatted = await format(source, {
  ...(await resolveConfig(OUTPUT)),
  filepath: OUTPUT,
});
if (process.argv.includes("--check")) {
  let existing = "";
  try {
    existing = readFileSync(OUTPUT, "utf8");
  } catch {
    // Missing counts as stale.
  }
  if (existing !== formatted) {
    console.error(`${OUTPUT} is stale; run server/scripts/generate-godot-deprecated-api.ts`);
    process.exit(1);
  }
} else {
  writeFileSync(OUTPUT, formatted);
  console.log(`${entries.length} deprecated APIs from Godot ${tag} -> ${OUTPUT}`);
}
