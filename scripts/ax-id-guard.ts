#!/usr/bin/env bun
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Accessibility-identifier guard for the iOS app and its UI/E2E tests.
 *
 * Two rules, one plain source scan, no simulator:
 *
 *  1. Every identifier a test references must exist in the app. A test literal
 *     that looks like an identifier (dotted, lowerCamel root; see `idShape`) must
 *     match a string literal or an interpolated template in the app sources
 *     (`Oppi`, `OppiCore`, `Shared`, `OppiDebugHarness`, the extensions). A test
 *     lookup of a removed id otherwise fails, or passes vacuously when it asserts
 *     absence, only when the test runs on a simulator. An id that is absent on
 *     purpose (the QA negative proofs) carries `// ax-id-guard: absent-on-purpose`
 *     on its line or the line above.
 *  2. A new identifier follows the naming rule (dev/testing/ios-accessibility-
 *     testability.md, "Identifier naming"): dot-joined lowerCamel segments, no
 *     hyphens. The identifiers that do not are a ratchet: each file's count may
 *     not exceed scripts/ax-id-baseline.json (files absent from it have baseline
 *     0). Decreases pass.
 *
 * It also prints, without failing, an identifier literal defined in more than
 * one app file: two controls with one id are ambiguous to a test unless a
 * container scopes the query.
 *
 * A test literal that has no dots (a flat kebab id) or a template whose literal
 * parts total fewer than 4 characters is not resolved: the scan cannot tell it
 * from text. Identifiers assembled by concatenation or from enum raw values are
 * seen only through the literals they are built from.
 *
 *   bun scripts/ax-id-guard.ts            check
 *   bun scripts/ax-id-guard.ts --update   rewrite the baseline from current
 *                                         source (deliberate regeneration only)
 */

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const apple = join(repoRoot, "clients/apple");
const appRoots = [
  "Oppi",
  "OppiCore",
  "Shared",
  "OppiDebugHarness",
  "OppiShareExtension",
  "OppiActivityExtension",
  "OppiControlWidget",
  "OppiNotificationService",
].map((dir) => join(apple, dir));
const testRoots = ["OppiUITests", "OppiE2ETests", "QAVerificationSupport"].map((dir) => join(apple, dir));
/** The identifiers the ratchet counts live in the iOS app target and its debug harness. */
const ratchetRoots = ["Oppi", "OppiDebugHarness"].map((dir) => join(apple, dir));
const baselinePath = join(repoRoot, "scripts/ax-id-baseline.json");
const guide = "dev/testing/ios-accessibility-testability.md, section \"Identifier naming\"";
const absentMarker = "ax-id-guard: absent-on-purpose";

/** An interpolation `\(…)` inside a literal, as one private-use character. */
const HOLE = "\u{E000}";

type Literal = { file: string; line: number; text: string; context: string };
type Counts = Record<string, number>;

function swiftFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const path = join(root, entry.name);
    if (entry.isDirectory()) return swiftFiles(path);
    return entry.name.endsWith(".swift") ? [path] : [];
  });
}

/**
 * The string literals of a Swift file, comments skipped. An interpolation
 * becomes `HOLE`; escapes are resolved to the character they stand for. `context`
 * is the source text from the start of the literal's line (or the line before,
 * when the literal begins its line) up to the literal.
 */
function literals(file: string, source: string): Literal[] {
  const found: Literal[] = [];
  let line = 1;
  let i = 0;
  const n = source.length;

  /** Skips an interpolation's expression, nested strings and parentheses included. */
  function skipInterpolation() {
    let depth = 1;
    while (i < n && depth > 0) {
      const ch = source[i];
      if (ch === "\n") line++;
      if (ch === "\"") {
        readString();
        continue;
      }
      if (ch === "(") depth++;
      if (ch === ")") depth--;
      i++;
    }
  }

  /** Reads the literal that starts at `i` (a quote) and returns its text. */
  function readString(): string {
    const multiline = source.startsWith("\"\"\"", i);
    i += multiline ? 3 : 1;
    let text = "";
    while (i < n) {
      const ch = source[i];
      if (multiline ? source.startsWith("\"\"\"", i) : ch === "\"") {
        i += multiline ? 3 : 1;
        return text;
      }
      if (ch === "\n") {
        if (!multiline) return text;
        line++;
      }
      if (ch === "\\") {
        const next = source[i + 1];
        if (next === "(") {
          i += 2;
          skipInterpolation();
          text += HOLE;
          continue;
        }
        text += next === "n" ? "\n" : next === "t" ? "\t" : next;
        if (next === "\n") line++;
        i += 2;
        continue;
      }
      text += ch;
      i++;
    }
    return text;
  }

  while (i < n) {
    const ch = source[i];
    if (ch === "\n") {
      line++;
      i++;
    } else if (source.startsWith("//", i)) {
      while (i < n && source[i] !== "\n") i++;
    } else if (source.startsWith("/*", i)) {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (source.startsWith("/*", i)) {
          depth++;
          i += 2;
        } else if (source.startsWith("*/", i)) {
          depth--;
          i += 2;
        } else {
          if (source[i] === "\n") line++;
          i++;
        }
      }
    } else if (ch === "\"") {
      const start = i;
      const startLine = line;
      const text = readString();
      let from = source.lastIndexOf("\n", start - 1) + 1;
      if (source.slice(from, start).trim() === "" && from > 0) {
        from = source.lastIndexOf("\n", from - 2) + 1;
      }
      found.push({ file, line: startLine, text, context: source.slice(from, start) });
    } else {
      i++;
    }
  }
  return found;
}

/** `lowerCamelRoot.segment…`, at least two segments. Flat kebab ids and plain text have no dot. */
const idShape = /^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9_\u{E000}-]+)+$/u;
/** Not identifiers: reverse-DNS names, file names, version strings. */
const notIdRoots = new Set(["com", "dev", "org", "io", "net", "public", "www", "localhost", "e", "i"]);
const hostSuffixes = new Set(["com", "org", "net", "io", "dev", "edu", "gov"]);
const fileExtensions = new Set([
  "swift", "md", "json", "txt", "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "html", "css", "js", "ts", "tsx",
  "sh", "py", "yml", "yaml", "csv", "log", "mp3", "mp4", "m4a", "wav", "mov", "plist", "xcresult", "app", "zip",
  "usdz", "ttf", "otf", "sql", "toml", "lock", "env", "svg", "xml", "tsv", "gz", "tar", "patch", "diff", "rs", "go",
  "rb", "kt", "java", "c", "h", "cpp", "mjs", "cjs",
]);

function isTestId(text: string): boolean {
  if (!idShape.test(text)) return false;
  const segments = text.split(".");
  if (notIdRoots.has(segments[0])) return false;
  const last = segments[segments.length - 1];
  return !fileExtensions.has(last) && !hostSuffixes.has(last);
}

/** Literal characters of a template, holes excluded. */
function literalLength(text: string): number {
  return text.split(HOLE).join("").length;
}

/** A regular expression for a template: each interpolation matches any non-empty text. */
function templatePattern(text: string): RegExp {
  const pattern = text
    .split(HOLE)
    .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join(".+");
  return new RegExp("^" + pattern + "$", "s");
}

/**
 * What the app defines. Controls whose id is a prefix plus a model key are built as
 * `"\(prefix).\(key)"`, which has no literal to compare; the prefix is the literal
 * passed as `accessibilityPrefix:` / `identifierPrefix:`, and every id under it
 * resolves.
 */
type AppId = { exact: Set<string>; templates: RegExp[]; rendered: string[]; prefixes: string[] };

/** The label of an argument or property that names an id prefix. */
const prefixSite = /\b(?:accessibilityPrefix|identifierPrefix|idPrefix)\b\s*(?::|=)\s*$/;

function appIds(literalsOfApp: Literal[]): AppId {
  const exact = new Set<string>();
  const templates: RegExp[] = [];
  const rendered: string[] = [];
  const prefixes = new Set<string>();
  const seenTemplates = new Set<string>();
  for (const { text, context } of literalsOfApp) {
    // A single word ("chat") would resolve everything under its root: a prefix needs a surface and an area.
    if (prefixSite.test(context) && !text.includes(HOLE) && text.includes(".")) prefixes.add(text);
    if (!text.includes(HOLE)) {
      exact.add(text);
      continue;
    }
    if (literalLength(text) < 4 || seenTemplates.has(text)) continue;
    seenTemplates.add(text);
    templates.push(templatePattern(text));
    rendered.push(text.split(HOLE).join("X"));
  }
  return { exact, templates, rendered, prefixes: [...prefixes] };
}

/**
 * Whether the app defines `text`: a literal, a template, an id under a prefix
 * argument, or (for a test template, or a literal ending in ".") the beginning or
 * a match of one of those.
 */
function resolves(app: AppId, text: string): boolean {
  if (app.prefixes.some((prefix) => text.startsWith(prefix + "."))) return true;
  if (text.includes(HOLE)) {
    // A test template (`"chat.toolbar.\(name)"`) names a family; the app may set each member as its own literal.
    if (literalLength(text) < 4) return true; // too little to compare: not judged
    const probe = text.split(HOLE).join("X");
    const family = templatePattern(text);
    for (const id of app.exact) if (family.test(id)) return true;
    return app.templates.some((t) => t.test(probe)) || prefixResolves(app, probe);
  }
  if (app.exact.has(text) || app.templates.some((t) => t.test(text))) return true;
  return prefixResolves(app, text);
}

/** A test literal ending in "." is a prefix query (`identifier BEGINSWITH`). */
function prefixResolves(app: AppId, text: string): boolean {
  if (!text.endsWith(".")) return false;
  for (const id of app.exact) if (id.startsWith(text)) return true;
  return app.rendered.some((id) => id.startsWith(text));
}

/** `surface.area[.element][.key]`: lowerCamel segments joined by dots; a whole-segment interpolation is a key. */
const conforming = /^(?:[a-z][A-Za-z0-9]*|\u{E000})(?:\.(?:[a-z0-9][A-Za-z0-9]*|\u{E000}))+$/u;
/** An identifier assignment, modifier, or argument label directly before the literal. */
const identifierSite = /\b(?:accessibilityIdentifier|accessibilityPrefix|identifier)\b\s*(?:=|:|\()\s*(?:[^"\n]*[?:]\s*)?$/;

function readSources(roots: string[]): Literal[] {
  return roots.flatMap(swiftFiles).flatMap((file) => literals(relative(repoRoot, file), readFileSync(file, "utf8")));
}

const app = readSources(appRoots);
const tests = readSources(testRoots);
const appId = appIds(app);
const failures: string[] = [];

// 1. Test references resolve.
const stale: Literal[] = [];
const testSources = new Map<string, string[]>();
for (const literal of tests) {
  if (!isTestId(literal.text) || resolves(appId, literal.text)) continue;
  let lines = testSources.get(literal.file);
  if (!lines) {
    lines = readFileSync(join(repoRoot, literal.file), "utf8").split("\n");
    testSources.set(literal.file, lines);
  }
  const here = lines[literal.line - 1] ?? "";
  const above = lines[literal.line - 2] ?? "";
  if (here.includes(absentMarker) || above.includes(absentMarker)) continue;
  stale.push(literal);
}
for (const literal of stale) {
  failures.push(`- ${literal.file}:${literal.line}: "${literal.text.split(HOLE).join("\\(…)")}" is not an identifier the app defines`);
}

// 2. The naming ratchet.
const offenders = new Map<string, Literal[]>();
for (const literal of readSources(ratchetRoots)) {
  if (!identifierSite.test(literal.context)) continue;
  if (!literal.text.includes(".") && !literal.text.includes("-")) continue; // plain words are not ids
  if (conforming.test(literal.text)) continue;
  const list = offenders.get(literal.file) ?? [];
  list.push(literal);
  offenders.set(literal.file, list);
}
const current: Record<string, number> = {};
for (const [file, list] of offenders) current[file] = list.length;

if (process.argv.includes("--update")) {
  const files = Object.fromEntries(Object.entries(current).sort(([a], [b]) => a.localeCompare(b)));
  writeFileSync(baselinePath, `${JSON.stringify({ version: 1, files }, null, 2)}\n`);
  console.log(`AX id guard: baseline rewritten (${Object.keys(files).length} files, ${Object.values(files).reduce((a, b) => a + b, 0)} identifiers).`);
  process.exit(0);
}

const baseline: Counts = existsSync(baselinePath)
  ? (JSON.parse(readFileSync(baselinePath, "utf8")) as { files: Counts }).files
  : {};
const ratchet: string[] = [];
for (const [file, count] of Object.entries(current)) {
  const limit = baseline[file] ?? 0;
  if (count <= limit) continue;
  ratchet.push(`- ${file}: ${count} identifiers break the naming rule, baseline ${limit}`);
  for (const literal of offenders.get(file) ?? []) {
    ratchet.push(`    ${literal.file}:${literal.line}: "${literal.text.split(HOLE).join("\\(…)")}"`);
  }
}

// 3. Report only: one literal defined by several app files.
const definedIn = new Map<string, Set<string>>();
for (const literal of readSources(ratchetRoots)) {
  if (!identifierSite.test(literal.context) || literal.text.includes(HOLE) || !conforming.test(literal.text)) continue;
  const files = definedIn.get(literal.text) ?? new Set<string>();
  files.add(literal.file);
  definedIn.set(literal.text, files);
}
const shared = [...definedIn].filter(([, files]) => files.size > 1);
if (shared.length > 0 && process.argv.includes("--collisions")) {
  console.log(`AX id guard: ${shared.length} identifiers are set in more than one file (scope a query that uses one):`);
  for (const [id, files] of shared.sort(([a], [b]) => a.localeCompare(b))) {
    console.log(`  ${id}: ${[...files].join(", ")}`);
  }
}

if (failures.length === 0 && ratchet.length === 0) {
  console.log(
    `AX id guard: PASS — every test identifier resolves to the app; ${Object.values(current).reduce((a, b) => a + b, 0)} non-conforming identifiers within baseline.`,
  );
  process.exit(0);
}

console.log("AX id guard: FAIL\n");
if (failures.length > 0) {
  console.log("Test identifiers the app does not define:");
  for (const line of failures) console.log(line);
  console.log(`
A test that looks up an identifier the app no longer sets fails on a simulator,
and one that asserts it absent passes whatever the app does: delete the check, or
point it at the control's current id. An id that is missing on purpose (a QA
negative proof) carries \`// ${absentMarker}\` on its line or the line above.
`);
}
if (ratchet.length > 0) {
  console.log("Identifiers that break the naming rule beyond the baseline:");
  for (const line of ratchet) console.log(line);
  console.log(`
Name a new identifier surface.area[.element][.key]: lowerCamel segments joined
by dots, no hyphens, and a stable model key (never an index or rendered text) on a
repeated element. See ${guide}. The count only goes down:
\`bun scripts/ax-id-guard.ts --update\` lowers the baseline after a rename.`);
}
process.exit(1);
