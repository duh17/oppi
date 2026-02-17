/**
 * Policy engine — evaluates tool calls against user rules.
 *
 * Layered evaluation order:
 * 1. Hard denies (immutable, can't be overridden)
 * 2. Workspace boundary checks
 * 3. User rules (evaluated in order)
 * 4. Default action
 */

import { globMatch } from "./glob.js";
import { readFileSync, writeFileSync, statSync, appendFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname as pathDirname, resolve as pathResolve } from "node:path";
import type { LearnedRule } from "./rules.js";

// ─── Types ───

export type PolicyAction = "allow" | "ask" | "deny";
export type RiskLevel = "low" | "medium" | "high" | "critical";

export interface PolicyRule {
  tool?: string; // "bash" | "write" | "edit" | "read" | "*"
  exec?: string; // For bash: executable name ("git", "rm", "sudo")
  pattern?: string; // Glob against command or path
  pathWithin?: string; // Path must be inside this directory
  action: PolicyAction;
  label?: string;
  risk?: RiskLevel;
}

export interface PolicyPreset {
  name: string;
  hardDeny: PolicyRule[];
  rules: PolicyRule[];
  defaultAction: PolicyAction;
}

export interface PolicyDecision {
  action: PolicyAction;
  reason: string;
  risk: RiskLevel;
  layer:
    | "hard_deny"
    | "learned_deny"
    | "session_rule"
    | "workspace_rule"
    | "global_rule"
    | "rule"
    | "default";
  ruleLabel?: string;
  ruleId?: string; // ID of the learned rule that matched (if any)
}

export interface ResolutionOptions {
  allowSession: boolean;
  allowAlways: boolean;
  alwaysDescription?: string;
  denyAlways: boolean;
}

export interface GateRequest {
  tool: string;
  input: Record<string, unknown>;
  toolCallId: string;
}

// ─── Bash Command Parsing ───

export interface ParsedCommand {
  executable: string;
  args: string[];
  raw: string;
  hasPipe: boolean;
  hasRedirect: boolean;
  hasSubshell: boolean;
}

/**
 * Parse a bash command string into structured form.
 * Not a full shell parser — handles the common cases for policy matching.
 */
export function parseBashCommand(command: string): ParsedCommand {
  const raw = command.trim();
  const hasPipe = /(?<![\\])\|/.test(raw);
  const hasRedirect = /(?<![\\])[><]/.test(raw);
  const hasSubshell = /\$\(/.test(raw) || /`[^`]+`/.test(raw);

  // Split on first whitespace to get executable
  // Handle leading env vars (VAR=val cmd ...) and command prefixes
  let cmdPart = raw;

  // Strip leading env assignments (FOO=bar BAZ=qux cmd ...)
  while (/^\w+=\S+\s/.test(cmdPart)) {
    cmdPart = cmdPart.replace(/^\w+=\S+\s+/, "");
  }

  // Handle common prefixes. Some (nice, env) take their own flags
  // before the actual command, so strip those too.
  const simplePrefixes = ["command", "builtin", "nohup", "time"];
  for (const prefix of simplePrefixes) {
    if (cmdPart.startsWith(prefix + " ")) {
      cmdPart = cmdPart.slice(prefix.length).trimStart();
    }
  }

  // env can have VAR=val or flags before the command
  if (cmdPart.startsWith("env ")) {
    cmdPart = cmdPart.slice(4).trimStart();
    // Strip env's own flags and VAR=val assignments
    while (/^(-\S+\s+|\w+=\S+\s+)/.test(cmdPart)) {
      cmdPart = cmdPart.replace(/^(-\S+\s+|\w+=\S+\s+)/, "").trimStart();
    }
  }

  // nice takes optional -n <priority> before the command
  if (cmdPart.startsWith("nice ")) {
    cmdPart = cmdPart.slice(5).trimStart();
    // Strip -n <num> or --adjustment=<num>
    cmdPart = cmdPart.replace(/^(-n\s+\S+\s+|--adjustment=\S+\s+|-\d+\s+)/, "").trimStart();
  }

  // Split into tokens (basic: split on whitespace, respect quotes)
  const tokens = tokenize(cmdPart);
  const executable = tokens[0] || raw;
  const args = tokens.slice(1);

  return { executable, args, raw, hasPipe, hasRedirect, hasSubshell };
}

/**
 * Match a bash command string against a glob-like pattern.
 *
 * Unlike minimatch (designed for file paths where '*' doesn't cross '/'),
 * this treats the command as a flat string where '*' matches any characters
 * including '/'. This ensures 'rm *-*r*' matches 'rm -rf /tmp/foo'.
 *
 * Supports: '*' (match anything), literal characters.
 * Does NOT support: '?', '**', character classes.
 */
export function matchBashPattern(command: string, pattern: string): boolean {
  // Simple glob matching without regex — avoids ReDoS entirely.
  // Splits the pattern on '*' into literal segments and checks that
  // they appear in order within the command string.
  //
  // Example: "rm *-*r*" splits into ["rm ", "-", "r", ""]
  // Then checks: command starts with "rm ", then "-" appears after,
  // then "r" appears after that.

  if (command.length > 10000) {
    // Safety: extremely long commands get a simple prefix check
    return command.startsWith(pattern.split("*")[0]);
  }

  const segments = pattern.split("*");
  let pos = 0;

  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i];
    if (seg === "") continue;

    if (i === 0) {
      // First segment must match at the start
      if (!command.startsWith(seg)) return false;
      pos = seg.length;
    } else if (i === segments.length - 1) {
      // Last segment must match at the end
      if (!command.endsWith(seg)) return false;
      // Also ensure it's after current position
      const lastIdx = command.lastIndexOf(seg);
      if (lastIdx < pos) return false;
    } else {
      // Middle segments must appear in order
      const idx = command.indexOf(seg, pos);
      if (idx === -1) return false;
      pos = idx + seg.length;
    }
  }

  return true;
}

/**
 * Basic shell tokenizer — splits on whitespace, respects single/double quotes.
 */
function tokenize(input: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;

  for (const ch of input) {
    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      escaped = true;
      continue;
    }
    if (ch === "'" && !inDouble) {
      inSingle = !inSingle;
      continue;
    }
    if (ch === '"' && !inSingle) {
      inDouble = !inDouble;
      continue;
    }
    if ((ch === " " || ch === "\t") && !inSingle && !inDouble) {
      if (current) {
        tokens.push(current);
        current = "";
      }
      continue;
    }
    current += ch;
  }
  if (current) tokens.push(current);
  return tokens;
}

/**
 * Split a shell command chain into top-level segments.
 *
 * Handles separators outside of quotes:
 *   - &&
 *   - ||
 *   - ;
 *   - newlines
 *
 * Keeps quoted/escaped separators intact.
 */
export function splitBashCommandChain(command: string): string[] {
  const segments: string[] = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;

  const pushCurrent = () => {
    const trimmed = current.trim();
    if (trimmed) segments.push(trimmed);
    current = "";
  };

  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    const next = command[i + 1];

    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      current += ch;
      escaped = true;
      continue;
    }

    if (ch === "'" && !inDouble) {
      inSingle = !inSingle;
      current += ch;
      continue;
    }

    if (ch === '"' && !inSingle) {
      inDouble = !inDouble;
      current += ch;
      continue;
    }

    if (!inSingle && !inDouble) {
      if (ch === "&" && next === "&") {
        pushCurrent();
        i += 1;
        continue;
      }

      if (ch === "|" && next === "|") {
        pushCurrent();
        i += 1;
        continue;
      }

      if (ch === ";" || ch === "\n") {
        pushCurrent();
        continue;
      }
    }

    current += ch;
  }

  pushCurrent();

  return segments.length > 0 ? segments : [command.trim()].filter(Boolean);
}

const CHAIN_HELPER_EXECUTABLES = new Set(["cd", "echo", "pwd", "true", "false", ":"]);

const HOST_SAFE_READ_ONLY_EXECUTABLES = new Set([
  "ls",
  "cat",
  "head",
  "tail",
  "grep",
  "rg",
  "find",
  "wc",
  "diff",
  "tree",
  "jq",
  "sort",
  "uniq",
  "cut",
  "stat",
  "file",
]);

const HOST_SAFE_GIT_SUBCOMMANDS = new Set([
  "status",
  "log",
  "diff",
  "show",
  "branch",
  "blame",
  "rev-parse",
]);

// ─── Data Egress Detection ───

/**
 * Flags on curl/wget that indicate outbound data transfer.
 * Matches short flags (-d, -F, -T) and long flags (--data, --form, etc.).
 */
const CURL_DATA_FLAGS = new Set([
  "-d",
  "--data",
  "--data-raw",
  "--data-binary",
  "--data-urlencode",
  "-F",
  "--form",
  "--form-string",
  "-T",
  "--upload-file",
  "--json",
]);

const CURL_WRITE_METHODS = new Set(["POST", "PUT", "DELETE", "PATCH"]);

const WGET_DATA_FLAGS = new Set(["--post-data", "--post-file"]);

const SECRET_ENV_HINTS = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH"];

const SECRET_FILE_READ_EXECUTABLES = new Set([
  "cat",
  "head",
  "tail",
  "less",
  "more",
  "grep",
  "rg",
  "awk",
  "sed",
]);

/**
 * Split a command segment into pipeline stages.
 *
 * Handles unescaped `|` outside quotes. Keeps quoted/escaped pipes intact.
 */
export function splitPipelineStages(segment: string): string[] {
  const stages: string[] = [];
  let current = "";
  let inSingle = false;
  let inDouble = false;
  let escaped = false;

  const pushCurrent = () => {
    const trimmed = current.trim();
    if (trimmed) stages.push(trimmed);
    current = "";
  };

  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    const next = segment[i + 1];

    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      current += ch;
      escaped = true;
      continue;
    }

    if (ch === "'" && !inDouble) {
      inSingle = !inSingle;
      current += ch;
      continue;
    }

    if (ch === '"' && !inSingle) {
      inDouble = !inDouble;
      current += ch;
      continue;
    }

    if (!inSingle && !inDouble && ch === "|" && next !== "|") {
      pushCurrent();
      continue;
    }

    current += ch;
  }

  pushCurrent();
  return stages.length > 0 ? stages : [segment.trim()].filter(Boolean);
}

function isLikelySecretEnvName(envName: string): boolean {
  const upper = envName.toUpperCase();
  return SECRET_ENV_HINTS.some((hint) => upper.includes(hint));
}

/**
 * Detect likely secret env expansion in curl/wget URL arguments.
 *
 * Example: curl "https://x.test/?token=$OPENAI_API_KEY"
 */
export function hasSecretEnvExpansionInUrl(parsed: ParsedCommand): boolean {
  if (parsed.executable !== "curl" && parsed.executable !== "wget") return false;

  const envRef = /\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))/g;

  for (const arg of parsed.args) {
    const lowerArg = arg.toLowerCase();
    if (!lowerArg.includes("http://") && !lowerArg.includes("https://")) continue;

    let match: RegExpExecArray | null;
    while ((match = envRef.exec(arg)) !== null) {
      const envName = match[1] || match[2];
      if (envName && isLikelySecretEnvName(envName)) {
        return true;
      }
    }
  }

  return false;
}

/**
 * Directories that always contain secret material.
 * Matches both absolute paths (/.ssh/) and home-relative (~/.ssh/).
 */
const SECRET_DIRS = ["ssh", "aws", "gnupg", "docker", "kube", "azure"];

/**
 * Config subdirectories that contain secret material.
 * Matched under ~/.config/NAME/ or PATH/.config/NAME/
 */
const SECRET_CONFIG_DIRS = [
  "gh", // GitHub CLI tokens (hosts.yml)
  "gcloud", // GCP credentials
];

/**
 * Specific dotfiles in the home directory that contain credentials.
 * Matched as exact filenames at the end of a path.
 */
const SECRET_DOTFILES = [
  ".npmrc", // npm auth tokens
  ".netrc", // login credentials for curl/wget/ftp
  ".pypirc", // PyPI upload tokens
];

function isSecretPath(pathCandidate: string): boolean {
  const normalized = pathCandidate
    .trim()
    .replace(/^['"]|['"]$/g, "")
    .toLowerCase();

  if (!normalized || normalized === "-" || normalized.startsWith("-")) return false;

  // Secret directories: ~/.ssh/, ~/.aws/, ~/.docker/, etc.
  for (const dir of SECRET_DIRS) {
    if (
      normalized.includes(`/.${dir}/`) ||
      normalized.startsWith(`~/.${dir}/`) ||
      normalized.endsWith(`/.${dir}`) ||
      normalized === `~/.${dir}`
    ) {
      return true;
    }
  }

  // Secret config subdirectories: ~/.config/gh/, ~/.config/gcloud/, etc.
  for (const dir of SECRET_CONFIG_DIRS) {
    if (
      normalized.includes(`/.config/${dir}/`) ||
      normalized.startsWith(`~/.config/${dir}/`) ||
      normalized.endsWith(`/.config/${dir}`) ||
      normalized === `~/.config/${dir}`
    ) {
      return true;
    }
  }

  // Secret dotfiles: ~/.npmrc, ~/.netrc, ~/.pypirc
  for (const file of SECRET_DOTFILES) {
    if (normalized.endsWith(`/${file}`) || normalized === `~/${file}` || normalized === file) {
      return true;
    }
  }

  // .env files (various patterns)
  return (
    normalized === ".env" ||
    normalized.startsWith(".env.") ||
    normalized.endsWith("/.env") ||
    normalized.includes("/.env.")
  );
}

/**
 * Extract command substitution contents from a command string.
 *
 * Matches both $(cmd) and `cmd` forms. Not recursive — extracts
 * the outermost substitutions only.
 */
export function extractCommandSubstitutions(command: string): string[] {
  const subs: string[] = [];

  // Match $(...) — handle nested parens with a simple depth counter
  let i = 0;
  while (i < command.length) {
    if (command[i] === "$" && command[i + 1] === "(") {
      let depth = 1;
      const start = i + 2;
      let j = start;
      while (j < command.length && depth > 0) {
        if (command[j] === "(") depth++;
        else if (command[j] === ")") depth--;
        j++;
      }
      if (depth === 0) {
        subs.push(command.slice(start, j - 1));
      }
      i = j;
    } else {
      i++;
    }
  }

  // Match `cmd` (backtick form)
  const backtickRe = /`([^`]+)`/g;
  let m: RegExpExecArray | null;
  while ((m = backtickRe.exec(command)) !== null) {
    subs.push(m[1]);
  }

  return subs;
}

/**
 * Check if a raw command string (including embedded substitutions)
 * references secret file paths.
 *
 * Scans both the command arguments directly and any $() / `` contents.
 */
export function hasSecretFileReference(command: string): boolean {
  // Direct check: scan for secret paths anywhere in the command text.
  // This catches both top-level args and embedded substitutions.
  const subs = extractCommandSubstitutions(command);

  for (const sub of subs) {
    // Parse the substitution as a command and check for secret file reads
    const stages = splitPipelineStages(sub);
    for (const stage of stages) {
      const parsed = parseBashCommand(stage);
      if (isSecretFileRead(parsed)) return true;
    }
  }

  return false;
}

/**
 * Detect direct secret-file reads via common file-reading commands.
 */
export function isSecretFileRead(parsed: ParsedCommand): boolean {
  const executable = parsed.executable.includes("/")
    ? parsed.executable.split("/").pop() || parsed.executable
    : parsed.executable;

  if (!SECRET_FILE_READ_EXECUTABLES.has(executable)) return false;

  return parsed.args.some((arg) => isSecretPath(arg));
}

/**
 * Detect if a parsed command sends data to an external service.
 *
 * Checks for curl/wget with data-sending flags or explicit write methods.
 * Does NOT flag simple GET requests (curl https://example.com) — those
 * are reads, not external actions on the user's behalf.
 */
export function isDataEgress(parsed: ParsedCommand): boolean {
  if (parsed.executable === "curl") {
    for (let i = 0; i < parsed.args.length; i++) {
      const arg = parsed.args[i];

      // Exact flag match: -d, --data, -F, --json, etc.
      if (CURL_DATA_FLAGS.has(arg)) return true;

      // Long flag with = : --data=value, --json=value
      const eqIdx = arg.indexOf("=");
      if (eqIdx > 0 && CURL_DATA_FLAGS.has(arg.slice(0, eqIdx))) return true;

      // Explicit write method: -X POST, --request PUT, -XPOST (no space)
      if (arg === "-X" || arg === "--request") {
        const next = parsed.args[i + 1]?.toUpperCase();
        if (next && CURL_WRITE_METHODS.has(next)) return true;
      }
      // Compact form: -XPOST, -XPUT, etc.
      if (arg.startsWith("-X") && arg.length > 2) {
        const method = arg.slice(2).toUpperCase();
        if (CURL_WRITE_METHODS.has(method)) return true;
      }
    }
    return false;
  }

  if (parsed.executable === "wget") {
    for (const arg of parsed.args) {
      if (WGET_DATA_FLAGS.has(arg)) return true;
      const eqIdx = arg.indexOf("=");
      if (eqIdx > 0 && WGET_DATA_FLAGS.has(arg.slice(0, eqIdx))) return true;
    }
    return false;
  }

  return false;
}

// ─── Web Browser Skill Detection ───

/**
 * Recognized web-browser skill scripts.
 * Commands look like: cd /.../.pi/agent/skills/web-browser && ./scripts/nav.js "https://..."
 */
const BROWSER_SCRIPTS = new Set([
  "nav.js",
  "eval.js",
  "screenshot.js",
  "start.js",
  "dismiss-cookies.js",
  "pick.js",
  "watch.js",
  "logs-tail.js",
  "net-summary.js",
]);

/** Read-only browser scripts that never need approval. */
const BROWSER_READ_ONLY = new Set(["screenshot.js", "logs-tail.js", "net-summary.js", "watch.js"]);

export interface ParsedBrowserCommand {
  script: string; // "nav.js", "eval.js", etc.
  url?: string; // Extracted URL for nav.js
  domain?: string; // Extracted domain from URL
  jsCode?: string; // Extracted JS for eval.js
  flags?: string[]; // Additional flags (--new, --reject, etc.)
}

/**
 * Parse a bash command that invokes a web-browser skill script.
 *
 * Handles the common patterns:
 *   cd /.../.pi/agent/skills/web-browser && ./scripts/nav.js "https://..." 2>&1
 *   cd /.../.pi/agent/skills/web-browser && ./scripts/eval.js 'document.title' 2>&1
 *   cd /.../.pi/agent/skills/web-browser && sleep 3 && ./scripts/screenshot.js 2>&1
 *
 * Returns null if the command isn't a web-browser skill invocation.
 */
export function parseBrowserCommand(command: string): ParsedBrowserCommand | null {
  // Must contain a web-browser skill path indicator
  if (
    !command.includes("web-browser") &&
    !command.includes("scripts/nav.js") &&
    !command.includes("scripts/eval.js")
  ) {
    return null;
  }

  // Split on && to find the script invocation part(s)
  const parts = command.split(/\s*&&\s*/);
  let scriptPart: string | null = null;

  for (const part of parts) {
    const trimmed = part.trim();
    // Skip cd, sleep, and redirect suffixes
    if (trimmed.startsWith("cd ") || trimmed.startsWith("sleep ")) continue;
    // Check if this part invokes a browser script
    const scriptMatch = trimmed.match(/\.\/scripts\/(\S+\.js)/);
    if (scriptMatch && BROWSER_SCRIPTS.has(scriptMatch[1])) {
      scriptPart = trimmed;
      break;
    }
  }

  // Also check for chained scripts: nav.js "url" 2>&1 && ./scripts/eval.js '...' 2>&1
  // Take the first recognized script as the primary
  if (!scriptPart) {
    for (const part of parts) {
      const trimmed = part.trim();
      const scriptMatch = trimmed.match(/\.\/scripts\/(\S+\.js)/);
      if (scriptMatch && BROWSER_SCRIPTS.has(scriptMatch[1])) {
        scriptPart = trimmed;
        break;
      }
    }
  }

  if (!scriptPart) return null;

  const scriptMatch = scriptPart.match(/\.\/scripts\/(\S+\.js)/);
  if (!scriptMatch) return null;

  const script = scriptMatch[1];
  const result: ParsedBrowserCommand = { script };

  // Strip 2>&1 suffix for cleaner parsing
  const cleaned = scriptPart.replace(/\s*2>&1\s*$/, "").trim();
  // Everything after the script name
  const argsStr = cleaned.slice(cleaned.indexOf(script) + script.length).trim();

  if (script === "nav.js") {
    // Extract URL — may be quoted or unquoted
    const urlMatch = argsStr.match(/["']?(https?:\/\/[^\s"']+)["']?/);
    if (urlMatch) {
      result.url = urlMatch[1];
      try {
        result.domain = new URL(urlMatch[1]).hostname;
      } catch {
        /* malformed URL */
      }
    }
    // Check for --new flag
    if (argsStr.includes("--new")) {
      result.flags = ["--new"];
    }
  } else if (script === "eval.js") {
    // Extract JS code — typically in single or double quotes
    const jsMatch = argsStr.match(/['"](.+)['"]\s*$/s);
    if (jsMatch) {
      result.jsCode = jsMatch[1];
    } else {
      // Unquoted JS (rare but possible)
      result.jsCode = argsStr || undefined;
    }
  } else if (script === "dismiss-cookies.js") {
    if (argsStr.includes("--reject")) {
      result.flags = ["--reject"];
    }
  }

  return result;
}

// ─── Shared Domain Allowlist ───

/**
 * Path to the fetch skill's domain allowlist.
 * Shared between fetch (Python) and web-browser policy (TypeScript).
 *
 * Format: one domain per line. Supports:
 *   example.com              — exact domain + subdomains
 *   github.com/org           — github.com scoped to org (ignored here, treated as github.com)
 *   github.com/owner/repo    — scoped (ignored here, treated as github.com)
 *   # comments and blank lines
 */
const FETCH_ALLOWLIST_PATH = join(homedir(), ".config", "fetch", "allowed_domains.txt");

/** Cached allowlist. Loaded once at module init, reloaded on PolicyEngine construction. */
let _cachedAllowedDomains: Set<string> | null = null;
let _cachedAllowlistMtime: number = 0;

/**
 * Load the shared fetch domain allowlist.
 *
 * Extracts bare domains from entries like "github.com/org/repo" → "github.com".
 * Returns a Set of lowercase domains.
 */
export function loadFetchAllowlist(overridePath?: string): Set<string> {
  const filePath = overridePath || FETCH_ALLOWLIST_PATH;
  try {
    // Only use cache for the default path
    if (!overridePath) {
      const { mtimeMs } = statSync(filePath);
      if (_cachedAllowedDomains && mtimeMs === _cachedAllowlistMtime) {
        return _cachedAllowedDomains;
      }
    }

    const content = readFileSync(filePath, "utf-8");
    const domains = new Set<string>();

    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;

      // Extract the domain part (strip path components like /org/repo)
      // "github.com/anthropics" → "github.com"
      // "docs.python.org" → "docs.python.org"
      const slashIdx = trimmed.indexOf("/");
      const domain = slashIdx > 0 ? trimmed.slice(0, slashIdx) : trimmed;
      domains.add(domain.toLowerCase());
    }

    if (!overridePath) {
      const { mtimeMs } = statSync(filePath);
      _cachedAllowedDomains = domains;
      _cachedAllowlistMtime = mtimeMs;
    }
    return domains;
  } catch {
    // File doesn't exist or unreadable — empty allowlist
    return new Set();
  }
}

/**
 * Check if a hostname is in the shared fetch allowlist.
 * Matches exact domain or parent domain (docs.python.org matches "python.org" entry too,
 * and "mail.google.com" matches "google.com" entry).
 */
function isInFetchAllowlist(hostname: string): boolean {
  const allowlist = loadFetchAllowlist();
  const lower = hostname.toLowerCase();

  // Exact match
  if (allowlist.has(lower)) return true;

  // Check parent domains: "sub.example.com" matches "example.com"
  const parts = lower.split(".");
  for (let i = 1; i < parts.length - 1; i++) {
    const parent = parts.slice(i).join(".");
    if (allowlist.has(parent)) return true;
  }

  return false;
}

// ─── Domain Allowlist Management ───

/**
 * Add a domain to the shared fetch allowlist.
 * No-op if the domain is already present.
 * Invalidates the in-memory cache.
 */
export function addDomainToAllowlist(domain: string, allowlistPath?: string): void {
  const path = allowlistPath || FETCH_ALLOWLIST_PATH;
  const lower = domain.toLowerCase().trim();
  if (!lower) return;

  // Check if already present
  const existing = loadFetchAllowlist(path);
  if (existing.has(lower)) return;

  // Append to file
  try {
    const content = existsSync(path) ? readFileSync(path, "utf-8") : "";
    const needsNewline = content.length > 0 && !content.endsWith("\n");
    appendFileSync(path, (needsNewline ? "\n" : "") + lower + "\n", { mode: 0o644 });

    // Invalidate cache
    _cachedAllowedDomains = null;
    _cachedAllowlistMtime = 0;
  } catch (err) {
    console.error(`[policy] Failed to add domain to allowlist: ${err}`);
  }
}

/**
 * Remove a domain from the shared fetch allowlist.
 * Preserves comments and blank lines.
 * Invalidates the in-memory cache.
 */
export function removeDomainFromAllowlist(domain: string, allowlistPath?: string): void {
  const path = allowlistPath || FETCH_ALLOWLIST_PATH;
  const lower = domain.toLowerCase().trim();
  if (!lower) return;

  if (!existsSync(path)) return;

  try {
    const content = readFileSync(path, "utf-8");
    const lines = content.split("\n");
    const filtered = lines.filter((line) => {
      const trimmed = line.trim().toLowerCase();
      // Preserve comments and blanks
      if (!trimmed || trimmed.startsWith("#")) return true;
      // Remove exact match (strip /path suffix for comparison)
      const slashIdx = trimmed.indexOf("/");
      const lineDomain = slashIdx > 0 ? trimmed.slice(0, slashIdx) : trimmed;
      return lineDomain !== lower;
    });
    writeFileSync(path, filtered.join("\n"), { mode: 0o644 });

    // Invalidate cache
    _cachedAllowedDomains = null;
    _cachedAllowlistMtime = 0;
  } catch (err) {
    console.error(`[policy] Failed to remove domain from allowlist: ${err}`);
  }
}

/**
 * List all domains in the shared fetch allowlist.
 * Returns sorted unique domains (strips path suffixes).
 */
export function listAllowlistDomains(allowlistPath?: string): string[] {
  const domains = loadFetchAllowlist(allowlistPath);
  return Array.from(domains).sort();
}

// ─── Presets ───

/**
 * Container preset — the default for oppi-server.
 *
 * Philosophy: the Apple container IS the security boundary.
 * The policy only gates things the container can't protect against:
 * - Credential exfiltration (API keys synced into container)
 * - Destructive operations on bind-mounted workspace data
 * - Escape attempts (sudo, privilege escalation)
 *
 * Everything else flows through. This mirrors how pi's permission-gate
 * works on the dev machine (regex-matched dangerous patterns only), but even
 * more permissive because there's no host system to damage.
 */
export const PRESET_CONTAINER: PolicyPreset = {
  name: "container",
  hardDeny: [
    // Privilege escalation — can't escape container, but deny on principle
    { tool: "bash", exec: "sudo", action: "deny", label: "No sudo", risk: "critical" },
    { tool: "bash", exec: "doas", action: "deny", label: "No doas", risk: "critical" },
    { tool: "bash", pattern: "su -*root*", action: "deny", label: "No su root", risk: "critical" },

    // Credential exfiltration — API keys are synced into ~/.pi/agent/auth.json
    {
      tool: "bash",
      pattern: "*auth.json*",
      action: "deny",
      label: "Protect API keys",
      risk: "critical",
    },
    {
      tool: "read",
      pattern: "**/agent/auth.json",
      action: "deny",
      label: "Protect API keys",
      risk: "critical",
    },
    {
      tool: "bash",
      pattern: "*printenv*_KEY*",
      action: "deny",
      label: "Protect env secrets",
      risk: "critical",
    },
    {
      tool: "bash",
      pattern: "*printenv*_SECRET*",
      action: "deny",
      label: "Protect env secrets",
      risk: "critical",
    },
    {
      tool: "bash",
      pattern: "*printenv*_TOKEN*",
      action: "deny",
      label: "Protect env secrets",
      risk: "critical",
    },

    // Fork bomb
    {
      tool: "bash",
      pattern: "*:(){ :|:& };*",
      action: "deny",
      label: "Fork bomb",
      risk: "critical",
    },
  ],
  rules: [
    // ── External actions → ask ──
    // Anything that acts on the user's behalf on external services.
    // The user sees these on their phone and approves/denies.
    //
    // Data egress (curl/wget with data flags) is matched structurally
    // in evaluate(), not here. Same for pipe-to-shell.

    // Git write operations (push to remotes)
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*",
      action: "ask",
      label: "Git push",
      risk: "medium",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git remote *add*",
      action: "ask",
      label: "Add git remote",
      risk: "medium",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git remote *set-url*",
      action: "ask",
      label: "Change git remote",
      risk: "medium",
    },

    // Package publishing
    {
      tool: "bash",
      exec: "npm",
      pattern: "npm publish*",
      action: "ask",
      label: "npm publish",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "npx",
      pattern: "npx *publish*",
      action: "ask",
      label: "npm publish",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "yarn",
      pattern: "yarn publish*",
      action: "ask",
      label: "yarn publish",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "pip",
      pattern: "pip *upload*",
      action: "ask",
      label: "pip upload",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "twine",
      pattern: "twine upload*",
      action: "ask",
      label: "PyPI upload",
      risk: "high",
    },

    // Remote access (always external)
    { tool: "bash", exec: "ssh", action: "ask", label: "SSH connection", risk: "high" },
    { tool: "bash", exec: "scp", action: "ask", label: "SCP transfer", risk: "high" },
    { tool: "bash", exec: "sftp", action: "ask", label: "SFTP transfer", risk: "high" },
    { tool: "bash", exec: "rsync", action: "ask", label: "rsync transfer", risk: "medium" },

    // Raw sockets
    { tool: "bash", exec: "nc", action: "ask", label: "Netcat connection", risk: "high" },
    { tool: "bash", exec: "ncat", action: "ask", label: "Netcat connection", risk: "high" },
    { tool: "bash", exec: "socat", action: "ask", label: "Socket relay", risk: "high" },

    // ── Destructive operations → ask ──
    // These can damage bind-mounted workspace data

    // rm with force/recursive flags
    {
      tool: "bash",
      exec: "rm",
      pattern: "rm *-*r*",
      action: "ask",
      label: "Recursive delete",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "rm",
      pattern: "rm *-*f*",
      action: "ask",
      label: "Force delete",
      risk: "high",
    },

    // Git destructive operations
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*--force*",
      action: "ask",
      label: "Force push",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*-f*",
      action: "ask",
      label: "Force push",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git reset --hard*",
      action: "ask",
      label: "Hard reset",
      risk: "high",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git clean*-*f*",
      action: "ask",
      label: "Git clean",
      risk: "high",
    },
  ],
  // Container provides isolation — allow by default
  defaultAction: "allow",
};

const HOST_HARD_DENY: PolicyRule[] = [
  // Credential exfiltration
  {
    tool: "bash",
    pattern: "*auth.json*",
    action: "deny",
    label: "Protect API keys",
    risk: "critical",
  },
  {
    tool: "read",
    pattern: "**/agent/auth.json",
    action: "deny",
    label: "Protect API keys",
    risk: "critical",
  },
  {
    tool: "bash",
    pattern: "*printenv*_KEY*",
    action: "deny",
    label: "Protect env secrets",
    risk: "critical",
  },
  {
    tool: "bash",
    pattern: "*printenv*_SECRET*",
    action: "deny",
    label: "Protect env secrets",
    risk: "critical",
  },
  {
    tool: "bash",
    pattern: "*printenv*_TOKEN*",
    action: "deny",
    label: "Protect env secrets",
    risk: "critical",
  },

  // Fork bomb
  {
    tool: "bash",
    pattern: "*:(){ :|:& };*",
    action: "deny",
    label: "Fork bomb",
    risk: "critical",
  },
];

const HOST_EXTERNAL_ASK_RULES: PolicyRule[] = [
  // ── Destructive local operations → ask ──
  // Irreversible actions that can damage local data.

  // rm with force/recursive flags
  {
    tool: "bash",
    exec: "rm",
    pattern: "rm *-*r*",
    action: "ask",
    label: "Recursive delete",
    risk: "high",
  },
  {
    tool: "bash",
    exec: "rm",
    pattern: "rm *-*f*",
    action: "ask",
    label: "Force delete",
    risk: "high",
  },

  // ── External actions → ask ──
  // Only gate things that act on the user's behalf on external systems.

  // Git push (writes to remotes)
  {
    tool: "bash",
    exec: "git",
    pattern: "git push*",
    action: "ask",
    label: "Git push",
    risk: "medium",
  },

  // Package publishing
  {
    tool: "bash",
    exec: "npm",
    pattern: "npm publish*",
    action: "ask",
    label: "npm publish",
    risk: "high",
  },
  {
    tool: "bash",
    exec: "yarn",
    pattern: "yarn publish*",
    action: "ask",
    label: "yarn publish",
    risk: "high",
  },
  {
    tool: "bash",
    exec: "twine",
    pattern: "twine upload*",
    action: "ask",
    label: "PyPI upload",
    risk: "high",
  },

  // Remote access
  { tool: "bash", exec: "ssh", action: "ask", label: "SSH connection", risk: "high" },
  { tool: "bash", exec: "scp", action: "ask", label: "SCP transfer", risk: "high" },
  { tool: "bash", exec: "sftp", action: "ask", label: "SFTP transfer", risk: "high" },

  // Raw sockets (can exfiltrate data to arbitrary endpoints)
  { tool: "bash", exec: "nc", action: "ask", label: "Netcat connection", risk: "high" },
  { tool: "bash", exec: "ncat", action: "ask", label: "Netcat connection", risk: "high" },
  { tool: "bash", exec: "socat", action: "ask", label: "Socket relay", risk: "high" },
  { tool: "bash", exec: "telnet", action: "ask", label: "Telnet connection", risk: "high" },

  // Local host-control flows (explicit approval required in host mode)
  {
    tool: "bash",
    pattern: "*ios/scripts/build-install.sh*",
    action: "ask",
    label: "Reinstall iOS app",
    risk: "high",
  },
  {
    tool: "bash",
    exec: "xcrun",
    pattern: "xcrun devicectl device install app*",
    action: "ask",
    label: "Install app on physical device",
    risk: "high",
  },
  {
    tool: "bash",
    pattern: "*scripts/ios-dev-up.sh*",
    action: "ask",
    label: "Restart oppi-server server and deploy app",
    risk: "high",
  },
  {
    tool: "bash",
    exec: "npx",
    pattern: "npx tsx src/cli.ts serve*",
    action: "ask",
    label: "Start/restart oppi-server server",
    risk: "high",
  },
  {
    tool: "bash",
    exec: "tsx",
    pattern: "tsx src/cli.ts serve*",
    action: "ask",
    label: "Start/restart oppi-server server",
    risk: "high",
  },
];

/**
 * Host preset (developer trust mode) — for pi running directly on the Mac.
 *
 * Philosophy: behave like pi CLI. Tools are mostly free-flowing.
 * The gate asks only for external/high-impact actions and denies secret exfil.
 */
export const PRESET_HOST: PolicyPreset = {
  name: "host",
  hardDeny: HOST_HARD_DENY,
  rules: HOST_EXTERNAL_ASK_RULES,
  defaultAction: "allow",
};

/**
 * Host preset (standard mode) — approval-first on host runtime.
 *
 * Philosophy: safer defaults for non-technical users.
 * - read-only actions in workspace bounds auto-allow
 * - external/high-impact actions ask
 * - everything else asks by default
 */
export const PRESET_HOST_STANDARD: PolicyPreset = {
  name: "host_standard",
  hardDeny: HOST_HARD_DENY,
  rules: HOST_EXTERNAL_ASK_RULES,
  defaultAction: "ask",
};

/**
 * Host preset (locked mode) — deny unknowns on host runtime.
 *
 * Philosophy: high-control environment.
 * - read-only actions in workspace bounds auto-allow
 * - known tools ask for explicit user approval
 * - unknown tools are denied by default
 */
export const PRESET_HOST_LOCKED: PolicyPreset = {
  name: "host_locked",
  hardDeny: HOST_HARD_DENY,
  rules: [
    ...HOST_EXTERNAL_ASK_RULES,
    { tool: "read", action: "ask", label: "Read file", risk: "medium" },
    { tool: "find", action: "ask", label: "Find files", risk: "medium" },
    { tool: "ls", action: "ask", label: "List directory", risk: "medium" },
    { tool: "write", action: "ask", label: "Write file", risk: "high" },
    { tool: "edit", action: "ask", label: "Edit file", risk: "high" },
    { tool: "bash", action: "ask", label: "Command execution", risk: "high" },
  ],
  defaultAction: "deny",
};

export const PRESETS: Record<string, PolicyPreset> = {
  container: PRESET_CONTAINER,
  host: PRESET_HOST,
  host_standard: PRESET_HOST_STANDARD,
  host_locked: PRESET_HOST_LOCKED,
};

// ─── Per-Session Config ───

export interface PathAccess {
  path: string; // Directory path (resolved, no ~ )
  access: "read" | "readwrite";
}

/**
 * Per-session policy configuration, derived from workspace settings.
 * Controls which directories are accessible and at what level.
 */
export interface PolicyConfig {
  /** Directories the session may access. Order doesn't matter. */
  allowedPaths: PathAccess[];

  /**
   * Extra executables to auto-allow on host.
   * Use for dev runtimes (node, python3, make, cargo, etc.) that need
   * to run in a specific workspace but CAN execute arbitrary code.
   *
   * These are NOT in the global read-only list because they're code executors.
   * A workspace for a Node.js project might add ["node", "npx", "npm"].
   * A workspace for a Python project might add ["python3", "uv", "pip"].
   */
  allowedExecutables?: string[];
}

// Host standard/locked presets reuse the same policy engine with extra
// constrained-host heuristics (safe read-only bash + workspace path bounds)
// implemented in evaluate().

// ─── Policy Engine ───

export class PolicyEngine {
  private preset: PolicyPreset;
  private config: PolicyConfig;

  constructor(presetName: string = "container", config?: PolicyConfig) {
    const preset = PRESETS[presetName];
    if (!preset) {
      throw new Error(
        `Unknown policy preset: ${presetName}. Available: ${Object.keys(PRESETS).join(", ")}`,
      );
    }
    this.preset = preset;
    this.config = config || { allowedPaths: [] };
  }

  /**
   * Evaluate a tool call against the policy.
   *
   * Layered evaluation:
   * 1. Hard denies (immutable — credential exfiltration, privilege escalation)
   * 2. Rules (destructive operations on workspace data)
   * 3. Default action (allow for container preset)
   *
   * Pipes and subshells are NOT auto-escalated. The container is the
   * security boundary — `grep foo | wc -l` shouldn't need phone approval.
   */
  evaluate(req: GateRequest): PolicyDecision {
    const { tool, input } = req;

    // Layer 1: Hard denies (immutable)
    for (const rule of this.preset.hardDeny) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: "deny",
          reason: rule.label || "Blocked by hard deny rule",
          risk: rule.risk || "critical",
          layer: "hard_deny",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 1.1: Structural hard denies (immutable)
    const structuralHardDeny = this.evaluateStructuralHardDeny(tool, input);
    if (structuralHardDeny) {
      return structuralHardDeny;
    }

    // Layer 1.25: Constrained host auto-allow (safe read-only commands)
    // Applies only to host_standard / host_locked presets.
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      if (this.isConstrainedHostPreset() && this.isSafeReadOnlyHostBash(command)) {
        return {
          action: "allow",
          reason: "Host read-only command",
          risk: "low",
          layer: "rule",
          ruleLabel: "Host safe read-only",
        };
      }
    }

    // Layer 1.3: Constrained host path bounds (file tools)
    // Auto-allows reads/writes only when inside configured workspace paths.
    const constrainedPathDecision = this.evaluateConstrainedHostPathAccess(tool, input);
    if (constrainedPathDecision) {
      return constrainedPathDecision;
    }

    // Layer 1.5: Structural heuristics (not glob-based)
    // These catch patterns that glob rules can't express reliably.
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const segments = splitBashCommandChain(command);

      for (const segment of segments) {
        // Pipe to shell — ANY content piped to sh/bash is arbitrary code execution.
        // This catches curl|sh, base64 -d|bash, echo|sh, cat script.sh|bash, etc.
        if (/\|\s*(ba)?sh\b/.test(segment)) {
          return {
            action: "ask",
            reason: "Pipe to shell (arbitrary code execution)",
            risk: "high",
            layer: "rule",
            ruleLabel: "Pipe to shell",
          };
        }

        const stages = splitPipelineStages(segment);
        for (const stage of stages) {
          const parsed = parseBashCommand(stage);

          // Data egress — curl/wget with flags that send data externally.
          // Catches: curl -d, curl --data, curl -F, curl --upload-file,
          //          curl -X POST/PUT/DELETE/PATCH, wget --post-data, etc.
          if (isDataEgress(parsed)) {
            return {
              action: "ask",
              reason: "Outbound data transfer",
              risk: "medium",
              layer: "rule",
              ruleLabel: "Data egress",
            };
          }

          if (hasSecretEnvExpansionInUrl(parsed)) {
            return {
              action: "ask",
              reason: "Possible secret env exfiltration in URL",
              risk: "high",
              layer: "rule",
              ruleLabel: "Secret env expansion in URL",
            };
          }
        }
      }
    }

    // Layer 1.6: Web-browser skill commands
    // Recognize browser skill invocations and apply domain-based policy.
    // Works on BOTH container and host presets.
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const browser = parseBrowserCommand(command);
      if (browser) {
        // Read-only scripts (screenshot, logs) — always allow
        if (BROWSER_READ_ONLY.has(browser.script)) {
          return {
            action: "allow",
            reason: `Browser read-only: ${browser.script}`,
            risk: "low",
            layer: "rule",
            ruleLabel: "Browser read-only",
          };
        }

        // start.js — launching Chrome. Low risk but notable.
        if (browser.script === "start.js") {
          return {
            action: "allow",
            reason: "Launch browser",
            risk: "low",
            layer: "rule",
            ruleLabel: "Browser start",
          };
        }

        // nav.js — check shared fetch domain allowlist (~/.config/fetch/allowed_domains.txt)
        if (browser.script === "nav.js" && browser.domain) {
          if (isInFetchAllowlist(browser.domain)) {
            return {
              action: "allow",
              reason: `Allowed domain: ${browser.domain}`,
              risk: "low",
              layer: "rule",
              ruleLabel: "Browser domain allowlist",
            };
          }
          // Domain not in allowlist — ask
          return {
            action: "ask",
            reason: `Browser navigation to unlisted domain: ${browser.domain}`,
            risk: "medium",
            layer: "rule",
            ruleLabel: "Browser unknown domain",
          };
        }

        // eval.js — executing arbitrary JS in the browser. Always ask.
        if (browser.script === "eval.js") {
          return {
            action: "ask",
            reason: "Browser JS execution",
            risk: "medium",
            layer: "rule",
            ruleLabel: "Browser eval",
          };
        }

        // dismiss-cookies.js, pick.js — low risk but interactive
        if (browser.script === "dismiss-cookies.js" || browser.script === "pick.js") {
          return {
            action: "allow",
            reason: `Browser interaction: ${browser.script}`,
            risk: "low",
            layer: "rule",
            ruleLabel: "Browser interaction",
          };
        }
      }
    }

    // Layer 2: Rules (external actions, destructive operations)
    for (const rule of this.preset.rules) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: rule.action,
          reason: rule.label || `Matched rule for ${tool}`,
          risk: rule.risk || "medium",
          layer: "rule",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 2.5: Workspace configured executable allowlist (constrained host presets)
    const configuredExecDecision = this.evaluateConfiguredExecutableAllow(tool, input);
    if (configuredExecDecision) {
      return configuredExecDecision;
    }

    // Layer 3: Default
    return {
      action: this.preset.defaultAction,
      reason: "No matching rule — using default",
      risk: "low",
      layer: "default",
    };
  }

  /**
   * Get a human-readable summary of a tool call for display on phone.
   *
   * Browser commands get smart parsing: "Navigate: github.com/user/repo"
   * instead of "cd /home/pi/.pi/agent/skills/web-browser && ./scripts/nav.js ..."
   */
  formatDisplaySummary(req: GateRequest): string {
    const { tool, input } = req;

    switch (tool) {
      case "bash": {
        const command = (input as { command?: string }).command || "";

        // Try browser skill parsing first
        const browser = parseBrowserCommand(command);
        if (browser) {
          return this.formatBrowserSummary(browser, command);
        }

        return command || "bash (unknown command)";
      }
      case "read":
        return `Read ${(input as { path?: string }).path || "unknown file"}`;
      case "write":
        return `Write ${(input as { path?: string }).path || "unknown file"}`;
      case "edit":
        return `Edit ${(input as { path?: string }).path || "unknown file"}`;
      case "grep":
        return `Grep for "${(input as { pattern?: string }).pattern || "?"}"`;
      case "find":
        return `Find in ${(input as { path?: string }).path || "."}`;
      case "ls":
        return `List ${(input as { path?: string }).path || "."}`;
      default:
        return `${tool}(${JSON.stringify(input).slice(0, 100)})`;
    }
  }

  /**
   * Format a browser skill command into a clean summary.
   *
   * nav.js  → "Navigate: github.com/user/repo"
   * eval.js → "JS: document.title"
   * screenshot.js → "Screenshot"
   * start.js → "Start Chrome"
   * dismiss-cookies.js → "Dismiss cookies"
   */
  private formatBrowserSummary(browser: ParsedBrowserCommand, _raw: string): string {
    switch (browser.script) {
      case "nav.js":
        if (browser.url) {
          // Show domain + path, strip protocol for brevity
          const clean = browser.url.replace(/^https?:\/\//, "");
          // Truncate very long URLs
          const display = clean.length > 80 ? clean.slice(0, 77) + "..." : clean;
          const flag = browser.flags?.includes("--new") ? " (new tab)" : "";
          return `Navigate: ${display}${flag}`;
        }
        return "Navigate (no URL)";
      case "eval.js":
        if (browser.jsCode) {
          const code =
            browser.jsCode.length > 120 ? browser.jsCode.slice(0, 117) + "..." : browser.jsCode;
          return `JS: ${code}`;
        }
        return "JS: (eval)";
      case "screenshot.js":
        return "Screenshot";
      case "start.js":
        return "Start Chrome";
      case "dismiss-cookies.js": {
        const action = browser.flags?.includes("--reject") ? "reject" : "accept";
        return `Dismiss cookies (${action})`;
      }
      case "pick.js":
        return "Pick element";
      default:
        return `Browser: ${browser.script}`;
    }
  }

  // ─── v2: Evaluate with learned rules ───

  /**
   * Evaluate a tool call with learned rules layered in.
   *
   * Evaluation order:
   *   1. Hard denies (immutable, from preset)
   *   2. Learned/manual deny rules (explicit deny wins)
   *   3. Session allow rules
   *   4. Workspace allow rules
   *   5. Global allow rules
   *   6. Structural heuristics (pipe-to-shell, data egress, browser)
   *   7. Preset rules + domain allowlist
   *   8. Preset default
   */
  evaluateWithRules(
    req: GateRequest,
    rules: LearnedRule[],
    sessionId: string,
    workspaceId: string,
  ): PolicyDecision {
    const { tool, input } = req;

    // Parse context for matching
    const parsed = this.parseRequestContext(req);

    // Layer 1: Hard denies (immutable, same as evaluate())
    for (const rule of this.preset.hardDeny) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: "deny",
          reason: rule.label || "Blocked by hard deny rule",
          risk: rule.risk || "critical",
          layer: "hard_deny",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 1.1: Structural hard denies (immutable)
    const structuralHardDeny = this.evaluateStructuralHardDeny(tool, input);
    if (structuralHardDeny) {
      return structuralHardDeny;
    }

    // Layer 2: Learned deny rules (explicit deny always wins, but respects scope)
    // Deny rules are checked in the same scope order as allow rules:
    //   session denies (only for this session) → workspace denies → global denies
    const denyRules = rules.filter((r) => r.effect === "deny");
    const scopedDenies = denyRules.filter((r) => {
      if (r.scope === "session") return r.sessionId === sessionId;
      if (r.scope === "workspace") return r.workspaceId === workspaceId;
      return r.scope === "global";
    });
    for (const rule of scopedDenies) {
      if (this.matchesLearnedRule(rule, tool, input, parsed)) {
        return {
          action: "deny",
          reason: rule.description,
          risk: rule.risk,
          layer: "learned_deny",
          ruleLabel: rule.description,
          ruleId: rule.id,
        };
      }
    }

    // Layer 3-5: Allow rules by scope (session → workspace → global)
    const allowRules = rules.filter((r) => r.effect === "allow");

    // Session rules first
    const sessionRules = allowRules.filter(
      (r) => r.scope === "session" && r.sessionId === sessionId,
    );
    for (const rule of sessionRules) {
      if (this.matchesLearnedRule(rule, tool, input, parsed)) {
        return {
          action: "allow",
          reason: rule.description,
          risk: rule.risk,
          layer: "session_rule",
          ruleLabel: rule.description,
          ruleId: rule.id,
        };
      }
    }

    // Workspace rules
    const wsRules = allowRules.filter(
      (r) => r.scope === "workspace" && r.workspaceId === workspaceId,
    );
    for (const rule of wsRules) {
      if (this.matchesLearnedRule(rule, tool, input, parsed)) {
        return {
          action: "allow",
          reason: rule.description,
          risk: rule.risk,
          layer: "workspace_rule",
          ruleLabel: rule.description,
          ruleId: rule.id,
        };
      }
    }

    // Global rules
    const globalRules = allowRules.filter((r) => r.scope === "global");
    for (const rule of globalRules) {
      if (this.matchesLearnedRule(rule, tool, input, parsed)) {
        return {
          action: "allow",
          reason: rule.description,
          risk: rule.risk,
          layer: "global_rule",
          ruleLabel: rule.description,
          ruleId: rule.id,
        };
      }
    }

    // Layer 6+: Fall through to existing evaluate() for heuristics, preset rules, default
    return this.evaluate(req);
  }

  // ─── v2: Resolution options ───

  /**
   * Determine which resolution scopes to offer the phone user.
   *
   * Called when evaluate() returns "ask". Tells the phone what buttons to show.
   */
  getResolutionOptions(req: GateRequest, decision: PolicyDecision): ResolutionOptions {
    const parsed = this.parseRequestContext(req);

    // Critical risk: no permanent allow (too dangerous to auto-allow forever)
    if (decision.risk === "critical") {
      return {
        allowSession: true,
        allowAlways: false,
        denyAlways: true,
      };
    }

    // eval.js: session only (code changes every time, can't generalize)
    if (parsed.browserScript === "eval.js") {
      return {
        allowSession: true,
        allowAlways: false,
        denyAlways: true,
      };
    }

    // Browser nav with a domain: offer "always allow" with domain description
    if (parsed.browserScript === "nav.js" && parsed.domain) {
      return {
        allowSession: true,
        allowAlways: true,
        alwaysDescription: `Add ${parsed.domain} to domain allowlist`,
        denyAlways: true,
      };
    }

    // Regular bash with recognizable executable.
    // High-impact external actions stay session-scoped to avoid over-broad
    // learned rules like "allow all git" from a single git push approval.
    if (req.tool === "bash" && parsed.executable) {
      if (this.requiresCommandScopedApproval(parsed.command || "", parsed.executable)) {
        return {
          allowSession: true,
          allowAlways: false,
          denyAlways: true,
        };
      }

      return {
        allowSession: true,
        allowAlways: true,
        alwaysDescription: `Allow all ${parsed.executable} commands`,
        denyAlways: true,
      };
    }

    // File operations
    if (["write", "edit"].includes(req.tool) && parsed.path) {
      const dir = pathDirname(parsed.path);
      return {
        allowSession: true,
        allowAlways: true,
        alwaysDescription: `Allow ${req.tool} in ${dir}`,
        denyAlways: true,
      };
    }

    // Fallback: session + deny always, no permanent allow
    return {
      allowSession: true,
      allowAlways: false,
      denyAlways: true,
    };
  }

  // ─── v2: Smart rule suggestion ───

  /**
   * Generate a learned rule from a user's approval.
   *
   * Generalizes the specific request into a reusable rule:
   *   git push origin main → { executable: "git", commandPattern: "git push*" }
   *   nav.js github.com/x  → { domain: "github.com" }
   *   write /workspace/x   → { pathPattern: "/workspace/**" }
   *
   * Returns null for requests that shouldn't be generalized (e.g., eval.js).
   */
  suggestRule(
    req: GateRequest,
    scope: "session" | "workspace" | "global",
    context: { sessionId: string; workspaceId: string; risk: RiskLevel },
  ): Omit<LearnedRule, "id" | "createdAt"> | null {
    const parsed = this.parseRequestContext(req);

    // eval.js — not generalizable
    if (parsed.browserScript === "eval.js") {
      return null;
    }

    // Browser nav with domain
    if (parsed.browserScript === "nav.js" && parsed.domain) {
      return {
        effect: "allow",
        tool: "bash",
        match: { domain: parsed.domain },
        scope,
        ...(scope === "session" ? { sessionId: context.sessionId } : {}),
        ...(scope === "workspace" ? { workspaceId: context.workspaceId } : {}),
        source: "learned",
        description: `Allow browser navigation to ${parsed.domain}`,
        risk: context.risk,
        createdBy: "server",
      };
    }

    // Bash with recognizable executable
    if (req.tool === "bash" && parsed.executable) {
      const match = this.suggestBashMatch(parsed.command || "", parsed.executable);
      const commandScoped = Boolean(match.commandPattern);
      return {
        effect: "allow",
        tool: "bash",
        match,
        scope,
        ...(scope === "session" ? { sessionId: context.sessionId } : {}),
        ...(scope === "workspace" ? { workspaceId: context.workspaceId } : {}),
        source: "learned",
        description: commandScoped
          ? `Allow ${parsed.executable} command pattern ${match.commandPattern}`
          : `Allow ${parsed.executable} operations`,
        risk: context.risk,
        createdBy: "server",
      };
    }

    // File operations — generalize to directory
    if (["write", "edit"].includes(req.tool) && parsed.path) {
      // Find the workspace/project root (first 2-3 path components)
      const parts = parsed.path.split("/").filter(Boolean);
      const dirParts = parts.length > 2 ? parts.slice(0, 2) : parts.slice(0, -1);
      const pattern = "/" + dirParts.join("/") + "/**";

      return {
        effect: "allow",
        tool: req.tool,
        match: { pathPattern: pattern },
        scope,
        ...(scope === "session" ? { sessionId: context.sessionId } : {}),
        ...(scope === "workspace" ? { workspaceId: context.workspaceId } : {}),
        source: "learned",
        description: `Allow ${req.tool} in ${pattern}`,
        risk: context.risk,
        createdBy: "server",
      };
    }

    // Can't generalize — return null
    return null;
  }

  /**
   * Suggest a deny rule from a user's denial.
   */
  suggestDenyRule(
    req: GateRequest,
    scope: "session" | "workspace" | "global",
    context: { sessionId: string; workspaceId: string; risk: RiskLevel },
  ): Omit<LearnedRule, "id" | "createdAt"> | null {
    const parsed = this.parseRequestContext(req);

    // Browser nav with domain
    if (parsed.browserScript === "nav.js" && parsed.domain) {
      return {
        effect: "deny",
        tool: "bash",
        match: { domain: parsed.domain },
        scope,
        ...(scope === "session" ? { sessionId: context.sessionId } : {}),
        ...(scope === "workspace" ? { workspaceId: context.workspaceId } : {}),
        source: "learned",
        description: `Deny browser navigation to ${parsed.domain}`,
        risk: context.risk,
        createdBy: "server",
      };
    }

    // Bash executable
    if (req.tool === "bash" && parsed.executable) {
      return {
        effect: "deny",
        tool: "bash",
        match: { executable: parsed.executable },
        scope,
        ...(scope === "session" ? { sessionId: context.sessionId } : {}),
        ...(scope === "workspace" ? { workspaceId: context.workspaceId } : {}),
        source: "learned",
        description: `Deny ${parsed.executable} operations`,
        risk: context.risk,
        createdBy: "server",
      };
    }

    return null;
  }

  // ─── v2: Request context parsing (shared helper) ───

  private parseRequestContext(req: GateRequest): {
    executable?: string;
    domain?: string;
    browserScript?: string;
    path?: string;
    command?: string;
  } {
    const { tool, input } = req;

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const browser = parseBrowserCommand(command);
      if (browser) {
        return {
          browserScript: browser.script,
          domain: browser.domain,
          executable: browser.script,
          command,
        };
      }

      const segments = splitBashCommandChain(command);
      const parsedSegments = segments
        .map((segment) => parseBashCommand(segment))
        .filter((parsed) => parsed.executable.length > 0);

      const primary =
        parsedSegments.find((parsed) => !CHAIN_HELPER_EXECUTABLES.has(parsed.executable)) ||
        parsedSegments[0];

      return { executable: primary?.executable, command };
    }

    if (["read", "write", "edit", "find", "ls"].includes(tool)) {
      return { path: (input as { path?: string }).path };
    }

    return {};
  }

  private parseGitIntent(command: string): { subcommand?: string; remoteAction?: string } {
    const tokens = command.trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0 || tokens[0].toLowerCase() !== "git") return {};

    let i = 1;
    while (i < tokens.length) {
      const token = tokens[i];
      if (!token.startsWith("-")) break;

      // Git global options that consume a value.
      if (["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"].includes(token)) {
        i += 2;
        continue;
      }

      i += 1;
    }

    const subcommand = tokens[i]?.toLowerCase();
    const remoteAction = subcommand === "remote" ? tokens[i + 1]?.toLowerCase() : undefined;
    return { subcommand, remoteAction };
  }

  private suggestBashMatch(command: string, executable: string): { executable: string; commandPattern?: string } {
    const normalized = command.trim().toLowerCase();
    const exec = executable.toLowerCase();

    if (exec === "git") {
      const intent = this.parseGitIntent(command);
      if (intent.subcommand === "push") {
        return { executable, commandPattern: "git push*" };
      }
      if (intent.subcommand === "remote" && ["add", "set-url"].includes(intent.remoteAction || "")) {
        return { executable, commandPattern: "git remote *" };
      }
    }

    if (exec === "npm" && normalized.startsWith("npm publish")) {
      return { executable, commandPattern: "npm publish*" };
    }
    if (exec === "yarn" && normalized.startsWith("yarn publish")) {
      return { executable, commandPattern: "yarn publish*" };
    }
    if (exec === "twine" && normalized.startsWith("twine upload")) {
      return { executable, commandPattern: "twine upload*" };
    }

    // Default: executable-level allow for non-sensitive command families.
    return { executable };
  }

  private requiresCommandScopedApproval(command: string, executable?: string): boolean {
    if (!executable) return false;
    const normalized = command.trim().toLowerCase();
    const exec = executable.toLowerCase();

    if (exec === "git") {
      const intent = this.parseGitIntent(command);
      if (intent.subcommand === "push") return true;
      if (intent.subcommand === "remote" && ["add", "set-url"].includes(intent.remoteAction || "")) {
        return true;
      }
    }

    if ((exec === "npm" && normalized.startsWith("npm publish")) ||
        (exec === "yarn" && normalized.startsWith("yarn publish")) ||
        (exec === "twine" && normalized.startsWith("twine upload"))) {
      return true;
    }

    if (["ssh", "scp", "sftp", "rsync", "nc", "ncat", "socat", "telnet"].includes(exec)) {
      return true;
    }

    if (normalized.includes("ios/scripts/build-install.sh") ||
        normalized.includes("scripts/ios-dev-up.sh") ||
        normalized.startsWith("xcrun devicectl device install app") ||
        normalized.startsWith("npx tsx src/cli.ts serve") ||
        normalized.startsWith("tsx src/cli.ts serve")) {
      return true;
    }

    return false;
  }

  private evaluateStructuralHardDeny(
    tool: string,
    input: Record<string, unknown>,
  ): PolicyDecision | null {
    if (tool === "read") {
      const path = (input as { path?: string }).path;
      if (path && isSecretPath(path)) {
        return {
          action: "deny",
          reason: "Blocked access to secret credential files",
          risk: "critical",
          layer: "hard_deny",
          ruleLabel: "Protect secret files",
        };
      }
    }

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const segments = splitBashCommandChain(command);

      for (const segment of segments) {
        // Check for secret file reads in pipeline stages
        const stages = splitPipelineStages(segment);
        for (const stage of stages) {
          const parsed = parseBashCommand(stage);
          if (isSecretFileRead(parsed)) {
            return {
              action: "deny",
              reason: "Blocked access to secret credential files",
              risk: "critical",
              layer: "hard_deny",
              ruleLabel: "Protect secret files",
            };
          }
        }

        // Check for secret file references inside command substitutions
        if (hasSecretFileReference(segment)) {
          return {
            action: "deny",
            reason: "Blocked secret file access via command substitution",
            risk: "critical",
            layer: "hard_deny",
            ruleLabel: "Protect secret files",
          };
        }
      }
    }

    return null;
  }

  /**
   * Check if a learned rule matches the current request.
   */
  private matchesLearnedRule(
    rule: LearnedRule,
    tool: string,
    input: Record<string, unknown>,
    parsed: { executable?: string; domain?: string; browserScript?: string; path?: string },
  ): boolean {
    // Skip expired rules
    if (rule.expiresAt && rule.expiresAt < Date.now()) return false;

    // Tool must match
    if (rule.tool && rule.tool !== "*" && rule.tool !== tool) return false;

    // Match conditions — ALL non-null fields must match
    if (rule.match) {
      if (rule.match.executable && parsed.executable !== rule.match.executable) return false;
      if (rule.match.domain && parsed.domain !== rule.match.domain) return false;

      if (rule.match.pathPattern && parsed.path) {
        const pattern = rule.match.pathPattern;
        if (pattern.endsWith("/**")) {
          const prefix = pattern.slice(0, -3);
          if (!parsed.path.startsWith(prefix)) return false;
        } else if (pattern !== parsed.path) {
          return false;
        }
      } else if (rule.match.pathPattern && !parsed.path) {
        return false;
      }

      if (rule.match.commandPattern) {
        const command = (input as { command?: string }).command || "";
        const re = new RegExp("^" + rule.match.commandPattern.replace(/\*/g, ".*") + "$");

        if (tool === "bash") {
          const segments = splitBashCommandChain(command);
          const matched = segments.some((segment) => re.test(segment));
          if (!matched) return false;
        } else if (!re.test(command)) {
          return false;
        }
      }
    }

    return true;
  }

  private isConstrainedHostPreset(): boolean {
    return this.preset.name === "host_standard" || this.preset.name === "host_locked";
  }

  private normalizeExecutable(exec: string): string {
    return exec.includes("/") ? exec.split("/").pop() || exec : exec;
  }

  private isPathWithinRoot(path: string, root: string): boolean {
    const normalizedPath = pathResolve(path);
    const normalizedRoot = pathResolve(root);
    return normalizedPath === normalizedRoot || normalizedPath.startsWith(normalizedRoot + "/");
  }

  /**
   * Constrained host profile: auto-allow file tools only within configured paths.
   */
  private evaluateConstrainedHostPathAccess(
    tool: string,
    input: Record<string, unknown>,
  ): PolicyDecision | null {
    if (!this.isConstrainedHostPreset()) return null;
    if (!["read", "write", "edit", "find", "ls"].includes(tool)) {
      return null;
    }

    const path = (input as { path?: string }).path;
    if (!path || !path.startsWith("/")) {
      return null;
    }

    const needsWrite = tool === "write" || tool === "edit";
    const allowed = this.config.allowedPaths.some((entry) => {
      if (!this.isPathWithinRoot(path, entry.path)) return false;
      if (!needsWrite) return true;
      return entry.access === "readwrite";
    });

    if (!allowed) return null;

    return {
      action: "allow",
      reason: "Within workspace path bounds",
      risk: "low",
      layer: "rule",
      ruleLabel: "Path bounds",
    };
  }

  /**
   * Constrained host profile: auto-allow plain read-only bash commands.
   *
   * Safety requirements:
   * - every command segment must be read-only
   * - no pipes, redirects, or subshells
   * - git limited to read-only subcommands
   */
  private isSafeReadOnlyHostBash(command: string): boolean {
    const segments = splitBashCommandChain(command);
    if (segments.length === 0) return false;

    for (const segment of segments) {
      // Split pipelines so `grep ... | head -10` is evaluated per-stage
      // instead of bailing on the pipe character.
      const stages = splitPipelineStages(segment);

      for (const stage of stages) {
        const parsed = parseBashCommand(stage);
        const exec = this.normalizeExecutable(parsed.executable);
        if (!exec) return false;

        // Helpers are always safe for chaining.
        if (CHAIN_HELPER_EXECUTABLES.has(exec)) continue;

        // Redirects and subshells are not considered read-only-safe.
        if (parsed.hasRedirect || parsed.hasSubshell) {
          return false;
        }

        if (HOST_SAFE_READ_ONLY_EXECUTABLES.has(exec)) continue;

        if (exec === "git") {
          const subcommand = parsed.args[0] || "";
          if (HOST_SAFE_GIT_SUBCOMMANDS.has(subcommand)) continue;
        }

        return false;
      }
    }

    return true;
  }

  /**
   * Workspace-level executable allowlist for constrained host presets.
   *
   * Only applies to simple, single-segment commands. This keeps
   * allowlist semantics predictable and avoids hidden chain escalation.
   */
  private evaluateConfiguredExecutableAllow(
    tool: string,
    input: Record<string, unknown>,
  ): PolicyDecision | null {
    if (!this.isConstrainedHostPreset()) return null;
    if (tool !== "bash") return null;

    const allowedExecs = this.config.allowedExecutables;
    if (!allowedExecs || allowedExecs.length === 0) return null;

    const command = (input as { command?: string }).command || "";
    const segments = splitBashCommandChain(command);
    if (segments.length !== 1) return null;

    const parsed = parseBashCommand(segments[0]);
    const exec = this.normalizeExecutable(parsed.executable);
    if (!exec) return null;

    if (parsed.hasPipe || parsed.hasRedirect || parsed.hasSubshell) {
      return null;
    }

    if (!allowedExecs.includes(exec)) return null;

    return {
      action: "allow",
      reason: `Workspace allowlist: ${exec}`,
      risk: "low",
      layer: "rule",
      ruleLabel: "Workspace executable allowlist",
    };
  }

  getPresetName(): string {
    return this.preset.name;
  }

  // ─── Internal ───

  private matchesRule(rule: PolicyRule, tool: string, input: Record<string, unknown>): boolean {
    // Check tool name
    if (rule.tool && rule.tool !== "*" && rule.tool !== tool) {
      return false;
    }

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const segments = splitBashCommandChain(command);

      for (const segment of segments) {
        if (this.matchesBashRuleSegment(rule, segment)) {
          return true;
        }
      }

      return false;
    }

    // exec field only applies to bash
    if (rule.exec) {
      return false;
    }

    // Check pattern against the match target.
    if (rule.pattern) {
      const target = this.getMatchTarget(tool, input);

      // For file-path tools (read, write, edit), glob match against path.
      if (!globMatch(target, rule.pattern)) {
        return false;
      }
    }

    // Check pathWithin (path confinement)
    if (rule.pathWithin) {
      const prefix = rule.pathWithin;
      const paths = this.extractPaths(tool, input);
      if (paths.length > 0) {
        const confined = paths.every((p) => p.startsWith(prefix));
        if (!confined) return false;
      }
    }

    return true;
  }

  private matchesBashRuleSegment(rule: PolicyRule, segment: string): boolean {
    if (rule.exec) {
      const parsed = parseBashCommand(segment);
      // Match both bare name ("sudo") and absolute path ("/usr/bin/sudo").
      // Extract basename from absolute paths for comparison.
      const execName = parsed.executable.includes("/")
        ? parsed.executable.split("/").pop() || parsed.executable
        : parsed.executable;
      if (execName !== rule.exec) {
        return false;
      }
    }

    if (rule.pattern) {
      // Bash commands are strings, not file paths. minimatch treats '/' as
      // a path separator so '*' won't cross it — 'rm *-*r*' fails to match
      // 'rm -rf /tmp/foo'. Use flat string glob matching.
      if (!matchBashPattern(segment, rule.pattern)) {
        return false;
      }
    }

    return true;
  }

  private getMatchTarget(tool: string, input: Record<string, unknown>): string {
    switch (tool) {
      case "bash":
        return (input as { command?: string }).command || "";
      case "grep":
        return (input as { pattern?: string }).pattern || "";
      case "read":
      case "write":
      case "edit":
      case "find":
      case "ls":
        return (input as { path?: string }).path || "";
      default:
        return JSON.stringify(input);
    }
  }

  private extractPaths(tool: string, input: Record<string, unknown>): string[] {
    switch (tool) {
      case "read":
      case "write":
      case "edit":
      case "find":
      case "ls": {
        const path = (input as { path?: string }).path;
        return path ? [path] : [];
      }
      case "bash":
        // For v1, skip path confinement on bash (covered by exec matching)
        return [];
      default:
        return [];
    }
  }
}
