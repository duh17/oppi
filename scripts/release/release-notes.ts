#!/usr/bin/env bun
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "node:url";
import {
  nextIosReleaseBuild,
  readLastShippedIosBuild,
} from "./next-ios-build.ts";

export function defaultRepoRoot(moduleUrl = import.meta.url): string {
  return path.resolve(path.dirname(fileURLToPath(moduleUrl)), "../..");
}

const OPPI_ROOT =
  process.env.OPPI_ROOT || process.env.PIOS_ROOT || defaultRepoRoot();
const PROJECT_YML = path.join(OPPI_ROOT, "clients", "apple", "project.yml");
const RELEASE_NOTES_DIR = path.join(OPPI_ROOT, ".internal", "release-notes");
const LEGACY_INTERNAL_DIR = path.join(
  OPPI_ROOT,
  ".pi",
  "reports",
  "testflight",
);

type SectionKey =
  | "added"
  | "changed"
  | "fixed"
  | "removed"
  | "known"
  | "validation"
  | "artifact"
  | "note";

const internalHeadings: Record<SectionKey, string> = {
  added: "Added",
  changed: "Changed",
  fixed: "Fixed",
  removed: "Removed",
  known: "Known Issues",
  validation: "Validation",
  artifact: "Artifacts",
  note: "Notes",
};

// TestFlight What to Test stays deliberately separate from the changelog.
// It is a brief release summary, not an automatic copy of every changelog entry.
const publicHeadings: Partial<Record<SectionKey, string>> = {};

function usage(): never {
  console.log(`Oppi TestFlight release-note helper.

Usage:
  release-notes.ts create (--bump | --build-number N)
  release-notes.ts add (--bump | --build-number N) [--added TEXT] [--changed TEXT] [--fixed TEXT]
                       [--removed TEXT] [--known TEXT] [--validation TEXT]
                       [--artifact TEXT] [--note TEXT]
  release-notes.ts show (--bump | --build-number N)

Examples:
  release-notes.ts create --bump
  release-notes.ts add --build-number 31 --fixed "Ask-card typed answers submit to the visible question."
  release-notes.ts add --bump --validation "OppiTests/ChatInputBarTests passed"
`);
  process.exit(0);
}

function die(message: string): never {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function parseArgs(argv: string[]): {
  command: string;
  buildNumber?: string;
  bump: boolean;
  entries: Partial<Record<SectionKey, string[]>>;
} {
  if (argv.some((arg) => arg === "help" || arg === "-h" || arg === "--help"))
    usage();

  const args = [...argv];
  let command = "create";
  if (args[0] && !args[0].startsWith("-")) {
    command = args.shift()!;
  }

  if (["help", "-h", "--help"].includes(command)) usage();

  const entries: Partial<Record<SectionKey, string[]>> = {};
  let buildNumber: string | undefined;
  let bump = false;

  const flagToSection: Record<string, SectionKey> = {
    "--added": "added",
    "--feature": "added",
    "--changed": "changed",
    "--fixed": "fixed",
    "--bugfix": "fixed",
    "--removed": "removed",
    "--known": "known",
    "--known-issue": "known",
    "--validation": "validation",
    "--artifact": "artifact",
    "--note": "note",
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--bump") {
      bump = true;
      continue;
    }
    if (arg === "--build-number") {
      buildNumber = args[++index];
      continue;
    }
    if (arg.startsWith("--build-number=")) {
      buildNumber = arg.slice("--build-number=".length);
      continue;
    }

    const section = flagToSection[arg];
    if (section) {
      const value = args[++index];
      if (!value) die(`${arg} requires text`);
      entries[section] = [...(entries[section] || []), value];
      continue;
    }

    die(`Unknown argument: ${arg}`);
  }

  return { command, buildNumber, bump, entries };
}

function readCurrentBuild(): number {
  if (!fs.existsSync(PROJECT_YML)) die(`Missing project.yml: ${PROJECT_YML}`);
  const content = fs.readFileSync(PROJECT_YML, "utf-8");
  const match = content.match(/CURRENT_PROJECT_VERSION:\s*(\d+)/);
  if (!match)
    die("CURRENT_PROJECT_VERSION not found in clients/apple/project.yml");
  return Number(match[1]);
}

function resolveBuildNumber(
  explicit: string | undefined,
  bump: boolean,
): string {
  if (explicit) {
    if (!/^\d+$/.test(explicit)) die(`Invalid build number: ${explicit}`);
    return explicit;
  }
  if (bump) {
    return String(
      nextIosReleaseBuild(readCurrentBuild(), readLastShippedIosBuild(OPPI_ROOT)),
    );
  }
  die("Pass --bump or --build-number N");
}

function pathsForBuild(buildNumber: string): {
  internalPath: string;
  publicPath: string;
} {
  return {
    internalPath: path.join(
      RELEASE_NOTES_DIR,
      `testflight-build-${buildNumber}-changelog.md`,
    ),
    publicPath: path.join(
      RELEASE_NOTES_DIR,
      `testflight-build-${buildNumber}-what-to-test.md`,
    ),
  };
}

function legacyInternalPathForBuild(buildNumber: string): string {
  return path.join(LEGACY_INTERNAL_DIR, `BUILD-${buildNumber}.md`);
}

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

function createInternalTemplate(buildNumber: string): string {
  return `# TestFlight Build ${buildNumber} — ${today()}\n`;
}

function createPublicTemplate(): string {
  return `What's changed
- Draft: briefly name the changed areas and required server version.
`;
}

function ensureFiles(buildNumber: string): {
  internalPath: string;
  publicPath: string;
} {
  const paths = pathsForBuild(buildNumber);
  fs.mkdirSync(path.dirname(paths.internalPath), { recursive: true });
  fs.mkdirSync(path.dirname(paths.publicPath), { recursive: true });

  if (!fs.existsSync(paths.internalPath)) {
    const legacyInternalPath = legacyInternalPathForBuild(buildNumber);
    if (fs.existsSync(legacyInternalPath)) {
      fs.copyFileSync(legacyInternalPath, paths.internalPath);
    } else {
      fs.writeFileSync(paths.internalPath, createInternalTemplate(buildNumber));
    }
  }
  if (!fs.existsSync(paths.publicPath)) {
    fs.writeFileSync(paths.publicPath, createPublicTemplate());
  }
  return paths;
}

function bulletFor(section: SectionKey, text: string): string {
  const trimmed = text.trim();
  if (!trimmed) die(`Empty ${section} entry`);
  if (section === "validation" && /^\[[ xX]\]/.test(trimmed))
    return `- ${trimmed}`;
  if (trimmed.startsWith("- ")) return trimmed;
  return `- ${trimmed}`;
}

function removePlaceholders(lines: string[]): string[] {
  return lines.filter((line) => {
    const trimmed = line.trim();
    if (trimmed === "-") return false;
    if (trimmed === "-") return false;
    if (trimmed === "- None.") return false;
    if (trimmed.startsWith("- Draft:")) return false;
    return true;
  });
}

function appendToSection(
  content: string,
  heading: string,
  bullet: string,
  headingPrefix: "## " | "",
): string {
  const lines = content.split("\n");
  const headingLine = `${headingPrefix}${heading}`;
  let start = lines.findIndex((line) => line.trim() === headingLine);

  if (start === -1) {
    const prefix = content.endsWith("\n") ? "" : "\n";
    return `${content}${prefix}\n${headingLine}\n${bullet}\n`;
  }

  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (
      headingPrefix === "## "
        ? line.startsWith("## ")
        : /^[A-Za-z][A-Za-z ]+$/.test(line.trim())
    ) {
      end = index;
      break;
    }
  }

  let sectionLines = removePlaceholders(lines.slice(start + 1, end));
  if (sectionLines.some((line) => line.trim() === bullet.trim()))
    return content;

  while (
    sectionLines.length > 0 &&
    sectionLines[sectionLines.length - 1].trim() === ""
  ) {
    sectionLines.pop();
  }
  sectionLines.push(bullet);
  sectionLines.push("");

  const nextLines = lines.slice(end);
  return [...lines.slice(0, start + 1), ...sectionLines, ...nextLines]
    .join("\n")
    .replace(/\n{4,}/g, "\n\n\n");
}

function addEntries(
  buildNumber: string,
  entries: Partial<Record<SectionKey, string[]>>,
): void {
  const { internalPath, publicPath } = ensureFiles(buildNumber);
  let internal = fs.readFileSync(internalPath, "utf-8");
  let publicNotes = fs.readFileSync(publicPath, "utf-8");

  for (const [section, values] of Object.entries(entries) as [
    SectionKey,
    string[],
  ][]) {
    for (const value of values) {
      const bullet = bulletFor(section, value);
      internal = appendToSection(
        internal,
        internalHeadings[section],
        bullet,
        "## ",
      );

      const publicHeading = publicHeadings[section];
      if (publicHeading) {
        publicNotes = appendToSection(publicNotes, publicHeading, bullet, "");
      }
    }
  }

  fs.writeFileSync(internalPath, internal);
  fs.writeFileSync(publicPath, publicNotes);
  printPaths(buildNumber, internalPath, publicPath);
}

function printPaths(
  buildNumber: string,
  internalPath: string,
  publicPath: string,
): void {
  console.log(`==> TestFlight release notes (build ${buildNumber})`);
  console.log(`Internal changelog: ${internalPath}`);
  console.log(`What to Test:       ${publicPath}`);
}

function show(buildNumber: string): void {
  const { internalPath, publicPath } = ensureFiles(buildNumber);
  printPaths(buildNumber, internalPath, publicPath);
  console.log("\n--- Internal changelog ---");
  console.log(fs.readFileSync(internalPath, "utf-8").trimEnd());
  console.log("\n--- What to Test ---");
  console.log(fs.readFileSync(publicPath, "utf-8").trimEnd());
}

function main(): void {
  const parsed = parseArgs(Bun.argv.slice(2));
  const buildNumber = resolveBuildNumber(parsed.buildNumber, parsed.bump);

  switch (parsed.command) {
    case "create": {
      const { internalPath, publicPath } = ensureFiles(buildNumber);
      printPaths(buildNumber, internalPath, publicPath);
      break;
    }
    case "add": {
      const entryCount = Object.values(parsed.entries).reduce(
        (sum, values) => sum + (values?.length || 0),
        0,
      );
      if (entryCount === 0)
        die('add requires at least one entry flag, e.g. --fixed "text"');
      addEntries(buildNumber, parsed.entries);
      break;
    }
    case "show":
      show(buildNumber);
      break;
    default:
      die(`Unknown command: ${parsed.command}`);
  }
}

if (import.meta.main) main();
