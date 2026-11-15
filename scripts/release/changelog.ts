#!/usr/bin/env bun
// Assembles the changelog fragments in changelog/<section>/*.md into CHANGELOG.md.
// Each change adds its own fragment file, so two branches with entries never edit the
// same file; the release cut moves every fragment under a new version heading and
// deletes the fragments in that commit. The format is in changelog/README.md.
import { existsSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Folder name → heading, in the order the sections appear under a release.
export const SECTIONS: ReadonlyArray<readonly [folder: string, heading: string]> = [
  ["added", "Added"],
  ["changed", "Changed"],
  ["fixed", "Fixed"],
  ["removed", "Removed"],
  ["migration-notes", "Migration notes"],
];

export type Fragment = { section: string; path: string; text: string };

const UNRELEASED_HEADING = "## [Unreleased]";

/** Reads every fragment, sections in `SECTIONS` order and files by name within a section. */
export function readFragments(dir: string): Fragment[] {
  const known = new Set(SECTIONS.map(([folder]) => folder));
  for (const entry of readdirSync(dir)) {
    if (entry === "README.md") continue;
    if (!known.has(entry) || !statSync(join(dir, entry)).isDirectory()) {
      throw new Error(
        `${join(dir, entry)}: not a changelog section folder (expected one of ${[...known].join(", ")})`,
      );
    }
  }
  const fragments: Fragment[] = [];
  for (const [folder] of SECTIONS) {
    const sectionDir = join(dir, folder);
    if (!existsSync(sectionDir)) continue;
    for (const name of readdirSync(sectionDir).sort()) {
      const path = join(sectionDir, name);
      if (!name.endsWith(".md")) throw new Error(`${path}: a fragment must be a .md file`);
      const text = readFileSync(path, "utf8").trim();
      if (!text.startsWith("- ")) throw new Error(`${path}: a fragment must hold Markdown bullets starting with "- "`);
      fragments.push({ section: folder, path, text });
    }
  }
  return fragments;
}

/** The `### Section` blocks of a release, with no empty sections, ending in one newline. */
export function assembleSections(fragments: Fragment[]): string {
  const blocks: string[] = [];
  for (const [folder, heading] of SECTIONS) {
    const bullets = fragments.filter((fragment) => fragment.section === folder).map((fragment) => fragment.text);
    if (bullets.length > 0) blocks.push(`### ${heading}\n\n${bullets.join("\n")}\n`);
  }
  return blocks.join("\n");
}

/** Inserts `## [version] - date` and the assembled sections right after the [Unreleased] block. */
export function cutChangelog(changelog: string, version: string, date: string, sections: string): string {
  if (!sections) throw new Error("no changelog fragments to release");
  if (changelog.includes(`\n## [${version}]`)) throw new Error(`CHANGELOG.md already has a [${version}] section`);
  const unreleased = changelog.indexOf(`\n${UNRELEASED_HEADING}\n`);
  if (unreleased < 0) throw new Error(`CHANGELOG.md has no "${UNRELEASED_HEADING}" heading`);
  const next = changelog.indexOf("\n## [", unreleased + 1);
  const at = next < 0 ? changelog.length : next + 1;
  const head = changelog.slice(0, at).replace(/\n*$/, "\n\n");
  return `${head}## [${version}] - ${date}\n\n${sections}\n${changelog.slice(at)}`;
}

function usage(): never {
  console.error(`Usage:
  changelog.ts preview                              Print the next release's sections from the fragments
  changelog.ts cut --version X.Y.Z [--date Y-M-D]   Move the fragments into CHANGELOG.md and delete them`);
  process.exit(2);
}

function main(argv: string[]): void {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  const fragmentsDir = join(root, "changelog");
  const changelogPath = join(root, "CHANGELOG.md");
  const [command, ...rest] = argv;
  const option = (name: string): string | undefined => {
    const index = rest.indexOf(name);
    return index < 0 ? undefined : rest[index + 1];
  };

  const fragments = readFragments(fragmentsDir);
  const sections = assembleSections(fragments);
  if (command === "preview") {
    process.stdout.write(sections);
    return;
  }
  if (command !== "cut") usage();
  const version = option("--version");
  if (!version || !/^\d+\.\d+\.\d+$/.test(version)) usage();
  const date = option("--date") ?? new Date().toLocaleDateString("en-CA");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) usage();

  writeFileSync(changelogPath, cutChangelog(readFileSync(changelogPath, "utf8"), version, date, sections));
  for (const fragment of fragments) rmSync(fragment.path);
  console.log(`CHANGELOG.md: [${version}] - ${date} from ${fragments.length} fragment(s); fragments deleted.`);
}

if (import.meta.main) main(Bun.argv.slice(2));
