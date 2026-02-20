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
import { join, dirname as pathDirname } from "node:path";
import type { LearnedRule } from "./rules.js";
import type {
  PolicyConfig as DeclarativePolicyConfig,
  PolicyPermission as DeclarativePolicyPermission,
} from "./types.js";

// ─── Types ───

export type PolicyAction = "allow" | "ask" | "deny";

export interface PolicyRule {
  tool?: string; // "bash" | "write" | "edit" | "read" | "*"
  exec?: string; // For bash: executable name ("git", "rm", "sudo")
  pattern?: string; // Glob against command or path
  pathWithin?: string; // Path must be inside this directory
  domain?: string; // Browser domain match (for nav.js)
  action: PolicyAction;
  label?: string;
}

/** Resolved heuristic actions (false = disabled). */
interface ResolvedHeuristics {
  pipeToShell: PolicyAction | false;
  dataEgress: PolicyAction | false;
  secretEnvInUrl: PolicyAction | false;
  secretFileAccess: PolicyAction | false;
  browserUnknownDomain: PolicyAction | false;
  browserEval: PolicyAction | false;
}

interface CompiledPolicy {
  name: string;
  hardDeny: PolicyRule[];
  rules: PolicyRule[];
  defaultAction: PolicyAction;
  heuristics: ResolvedHeuristics;
}

export interface PolicyDecision {
  action: PolicyAction;
  reason: string;
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

// ─── Default Policy Config ───

/**
 * Default policy configuration for new servers.
 *
 * Philosophy: allow most local dev work, ask for external/destructive actions,
 * block credential exfiltration and privilege escalation.
 *
 * Structural heuristics (pipe-to-shell, data egress, browser domain checks)
 * are always active in evaluate() regardless of this config.
 */
export function defaultPolicy(): DeclarativePolicyConfig {
  return {
    schemaVersion: 1,
    mode: "default",
    description: "Developer-friendly defaults: allow local work, ask for external/destructive actions, block credential exfiltration.",
    fallback: "allow",
    guardrails: [
      // ── Privilege escalation ──
      {
        id: "block-sudo",
        decision: "block",
        label: "Block sudo",
        reason: "Prevents privilege escalation",
        immutable: true,
        match: { tool: "bash", executable: "sudo" },
      },
      {
        id: "block-doas",
        decision: "block",
        label: "Block doas",
        reason: "Prevents privilege escalation",
        immutable: true,
        match: { tool: "bash", executable: "doas" },
      },
      {
        id: "block-su-root",
        decision: "block",
        label: "Block su root",
        reason: "Prevents privilege escalation",
        immutable: true,
        match: { tool: "bash", commandMatches: "su -*root*" },
      },

      // ── Credential exfiltration ──
      {
        id: "block-auth-json-bash",
        decision: "block",
        label: "Protect API keys (bash)",
        reason: "Prevents reading auth.json via bash",
        immutable: true,
        match: { tool: "bash", commandMatches: "*auth.json*" },
      },
      {
        id: "block-auth-json-read",
        decision: "block",
        label: "Protect API keys (read)",
        reason: "Prevents reading auth.json via read tool",
        immutable: true,
        match: { tool: "read", pathMatches: "**/agent/auth.json" },
      },
      {
        id: "block-printenv-key",
        decision: "block",
        label: "Protect env secrets (_KEY)",
        reason: "Prevents leaking API keys from env",
        immutable: true,
        match: { tool: "bash", commandMatches: "*printenv*_KEY*" },
      },
      {
        id: "block-printenv-secret",
        decision: "block",
        label: "Protect env secrets (_SECRET)",
        reason: "Prevents leaking secrets from env",
        immutable: true,
        match: { tool: "bash", commandMatches: "*printenv*_SECRET*" },
      },
      {
        id: "block-printenv-token",
        decision: "block",
        label: "Protect env secrets (_TOKEN)",
        reason: "Prevents leaking tokens from env",
        immutable: true,
        match: { tool: "bash", commandMatches: "*printenv*_TOKEN*" },
      },
      {
        id: "block-ssh-keys",
        decision: "block",
        label: "Block SSH private key reads",
        reason: "Prevents reading SSH private keys",
        immutable: true,
        match: { tool: "read", pathMatches: "**/.ssh/id_*" },
      },

      // ── Catastrophic operations ──
      {
        id: "block-root-rm",
        decision: "block",
        label: "Block destructive root delete",
        reason: "Prevents catastrophic filesystem deletion",
        immutable: true,
        match: { tool: "bash", executable: "rm", commandMatches: "rm -rf /*" },
      },
      {
        id: "block-fork-bomb",
        decision: "block",
        label: "Block fork bomb",
        reason: "Prevents fork bomb denial of service",
        immutable: true,
        match: { tool: "bash", commandMatches: "*:(){ :|:& };*" },
      },
    ],
    permissions: [
      // ── Destructive local operations → ask ──
      {
        id: "ask-rm-recursive",
        decision: "ask",
        label: "Recursive delete",
        match: { tool: "bash", executable: "rm", commandMatches: "rm *-*r*" },
      },
      {
        id: "ask-rm-force",
        decision: "ask",
        label: "Force delete",
        match: { tool: "bash", executable: "rm", commandMatches: "rm *-*f*" },
      },

      // ── Git external operations → ask ──
      {
        id: "ask-git-push",
        decision: "ask",
        label: "Git push",
        match: { tool: "bash", executable: "git", commandMatches: "git push*" },
      },

      // ── Package publishing → ask ──
      {
        id: "ask-npm-publish",
        decision: "ask",
        label: "npm publish",
        match: { tool: "bash", executable: "npm", commandMatches: "npm publish*" },
      },
      {
        id: "ask-yarn-publish",
        decision: "ask",
        label: "yarn publish",
        match: { tool: "bash", executable: "yarn", commandMatches: "yarn publish*" },
      },
      {
        id: "ask-pypi-upload",
        decision: "ask",
        label: "PyPI upload",
        match: { tool: "bash", executable: "twine", commandMatches: "twine upload*" },
      },

      // ── Remote access → ask ──
      {
        id: "ask-ssh",
        decision: "ask",
        label: "SSH connection",
        match: { tool: "bash", executable: "ssh" },
      },
      {
        id: "ask-scp",
        decision: "ask",
        label: "SCP transfer",
        match: { tool: "bash", executable: "scp" },
      },
      {
        id: "ask-sftp",
        decision: "ask",
        label: "SFTP transfer",
        match: { tool: "bash", executable: "sftp" },
      },

      // ── Raw sockets → ask ──
      {
        id: "ask-nc",
        decision: "ask",
        label: "Netcat connection",
        match: { tool: "bash", executable: "nc" },
      },
      {
        id: "ask-ncat",
        decision: "ask",
        label: "Netcat connection",
        match: { tool: "bash", executable: "ncat" },
      },
      {
        id: "ask-socat",
        decision: "ask",
        label: "Socket relay",
        match: { tool: "bash", executable: "socat" },
      },
      {
        id: "ask-telnet",
        decision: "ask",
        label: "Telnet connection",
        match: { tool: "bash", executable: "telnet" },
      },

      // ── Local machine control → ask ──
      {
        id: "ask-build-install",
        decision: "ask",
        label: "Reinstall iOS app",
        match: { tool: "bash", commandMatches: "*scripts/build-install.sh*" },
      },
      {
        id: "ask-xcrun-install",
        decision: "ask",
        label: "Install app on physical device",
        match: { tool: "bash", executable: "xcrun", commandMatches: "xcrun devicectl device install app*" },
      },
      {
        id: "ask-ios-dev-up",
        decision: "ask",
        label: "Restart server and deploy app",
        match: { tool: "bash", commandMatches: "*scripts/ios-dev-up.sh*" },
      },
    ],
    heuristics: {
      pipeToShell: "ask",
      dataEgress: "ask",
      secretEnvInUrl: "ask",
      secretFileAccess: "block",
      browserUnknownDomain: "ask",
      browserEval: "ask",
    },
  };
}

/** Default heuristic settings (used when heuristics field is omitted from config). */
const DEFAULT_HEURISTICS: ResolvedHeuristics = {
  pipeToShell: "ask",
  dataEgress: "ask",
  secretEnvInUrl: "ask",
  secretFileAccess: "deny",
  browserUnknownDomain: "ask",
  browserEval: "ask",
};

// ── Legacy: kept only for test compatibility ──
const BUILTIN_CONTAINER_POLICY: CompiledPolicy = {
  name: "container",
  hardDeny: [
    // Privilege escalation — can't escape container, but deny on principle
    { tool: "bash", exec: "sudo", action: "deny", label: "No sudo" },
    { tool: "bash", exec: "doas", action: "deny", label: "No doas" },
    { tool: "bash", pattern: "su -*root*", action: "deny", label: "No su root" },

    // Credential exfiltration — API keys are synced into ~/.pi/agent/auth.json
    {
      tool: "bash",
      pattern: "*auth.json*",
      action: "deny",
      label: "Protect API keys",
    },
    {
      tool: "read",
      pattern: "**/agent/auth.json",
      action: "deny",
      label: "Protect API keys",
    },
    {
      tool: "bash",
      pattern: "*printenv*_KEY*",
      action: "deny",
      label: "Protect env secrets",
    },
    {
      tool: "bash",
      pattern: "*printenv*_SECRET*",
      action: "deny",
      label: "Protect env secrets",
    },
    {
      tool: "bash",
      pattern: "*printenv*_TOKEN*",
      action: "deny",
      label: "Protect env secrets",
    },

    // Fork bomb
    {
      tool: "bash",
      pattern: "*:(){ :|:& };*",
      action: "deny",
      label: "Fork bomb",
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
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git remote *add*",
      action: "ask",
      label: "Add git remote",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git remote *set-url*",
      action: "ask",
      label: "Change git remote",
    },

    // Package publishing
    {
      tool: "bash",
      exec: "npm",
      pattern: "npm publish*",
      action: "ask",
      label: "npm publish",
    },
    {
      tool: "bash",
      exec: "npx",
      pattern: "npx *publish*",
      action: "ask",
      label: "npm publish",
    },
    {
      tool: "bash",
      exec: "yarn",
      pattern: "yarn publish*",
      action: "ask",
      label: "yarn publish",
    },
    {
      tool: "bash",
      exec: "pip",
      pattern: "pip *upload*",
      action: "ask",
      label: "pip upload",
    },
    {
      tool: "bash",
      exec: "twine",
      pattern: "twine upload*",
      action: "ask",
      label: "PyPI upload",
    },

    // Remote access (always external)
    { tool: "bash", exec: "ssh", action: "ask", label: "SSH connection" },
    { tool: "bash", exec: "scp", action: "ask", label: "SCP transfer" },
    { tool: "bash", exec: "sftp", action: "ask", label: "SFTP transfer" },
    { tool: "bash", exec: "rsync", action: "ask", label: "rsync transfer" },

    // Raw sockets
    { tool: "bash", exec: "nc", action: "ask", label: "Netcat connection" },
    { tool: "bash", exec: "ncat", action: "ask", label: "Netcat connection" },
    { tool: "bash", exec: "socat", action: "ask", label: "Socket relay" },

    // ── Destructive operations → ask ──
    // These can damage bind-mounted workspace data

    // rm with force/recursive flags
    {
      tool: "bash",
      exec: "rm",
      pattern: "rm *-*r*",
      action: "ask",
      label: "Recursive delete",
    },
    {
      tool: "bash",
      exec: "rm",
      pattern: "rm *-*f*",
      action: "ask",
      label: "Force delete",
    },

    // Git destructive operations
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*--force*",
      action: "ask",
      label: "Force push",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git push*-f*",
      action: "ask",
      label: "Force push",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git reset --hard*",
      action: "ask",
      label: "Hard reset",
    },
    {
      tool: "bash",
      exec: "git",
      pattern: "git clean*-*f*",
      action: "ask",
      label: "Git clean",
    },
  ],
  // Legacy preset default behavior
  defaultAction: "allow",
  heuristics: DEFAULT_HEURISTICS,
};

const HOST_HARD_DENY: PolicyRule[] = [
  // Credential exfiltration
  {
    tool: "bash",
    pattern: "*auth.json*",
    action: "deny",
    label: "Protect API keys",
  },
  {
    tool: "read",
    pattern: "**/agent/auth.json",
    action: "deny",
    label: "Protect API keys",
  },
  {
    tool: "bash",
    pattern: "*printenv*_KEY*",
    action: "deny",
    label: "Protect env secrets",
  },
  {
    tool: "bash",
    pattern: "*printenv*_SECRET*",
    action: "deny",
    label: "Protect env secrets",
  },
  {
    tool: "bash",
    pattern: "*printenv*_TOKEN*",
    action: "deny",
    label: "Protect env secrets",
  },

  // Fork bomb
  {
    tool: "bash",
    pattern: "*:(){ :|:& };*",
    action: "deny",
    label: "Fork bomb",
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
  },
  {
    tool: "bash",
    exec: "rm",
    pattern: "rm *-*f*",
    action: "ask",
    label: "Force delete",
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
  },

  // Package publishing
  {
    tool: "bash",
    exec: "npm",
    pattern: "npm publish*",
    action: "ask",
    label: "npm publish",
  },
  {
    tool: "bash",
    exec: "yarn",
    pattern: "yarn publish*",
    action: "ask",
    label: "yarn publish",
  },
  {
    tool: "bash",
    exec: "twine",
    pattern: "twine upload*",
    action: "ask",
    label: "PyPI upload",
  },

  // Remote access
  { tool: "bash", exec: "ssh", action: "ask", label: "SSH connection" },
  { tool: "bash", exec: "scp", action: "ask", label: "SCP transfer" },
  { tool: "bash", exec: "sftp", action: "ask", label: "SFTP transfer" },

  // Raw sockets (can exfiltrate data to arbitrary endpoints)
  { tool: "bash", exec: "nc", action: "ask", label: "Netcat connection" },
  { tool: "bash", exec: "ncat", action: "ask", label: "Netcat connection" },
  { tool: "bash", exec: "socat", action: "ask", label: "Socket relay" },
  { tool: "bash", exec: "telnet", action: "ask", label: "Telnet connection" },

  // Local machine control flows (explicit approval required)
  {
    tool: "bash",
    pattern: "*scripts/build-install.sh*",
    action: "ask",
    label: "Reinstall iOS app",
  },
  {
    tool: "bash",
    exec: "xcrun",
    pattern: "xcrun devicectl device install app*",
    action: "ask",
    label: "Install app on physical device",
  },
  {
    tool: "bash",
    pattern: "*scripts/ios-dev-up.sh*",
    action: "ask",
    label: "Restart oppi-server server and deploy app",
  },
  {
    tool: "bash",
    exec: "npx",
    pattern: "npx tsx src/cli.ts serve*",
    action: "ask",
    label: "Start/restart oppi-server server",
  },
  {
    tool: "bash",
    exec: "tsx",
    pattern: "tsx src/cli.ts serve*",
    action: "ask",
    label: "Start/restart oppi-server server",
  },
];

/**
 * Default local policy mode (developer trust).
 *
 * Philosophy: behave like pi CLI. Tools are mostly free-flowing.
 * The gate asks only for external/high-impact actions and denies secret exfil.
 */
const BUILTIN_HOST_POLICY: CompiledPolicy = {
  name: "default",
  hardDeny: HOST_HARD_DENY,
  rules: HOST_EXTERNAL_ASK_RULES,
  defaultAction: "allow",
  heuristics: DEFAULT_HEURISTICS,
};

function resolveBuiltInPolicy(mode: string): CompiledPolicy | undefined {
  switch (mode) {
    case "default":
      return BUILTIN_HOST_POLICY;
    case "container":
      return BUILTIN_CONTAINER_POLICY;
    case "host":
      return BUILTIN_HOST_POLICY;
    default:
      return undefined;
  }
}

function mapDecisionToAction(decision: "allow" | "ask" | "block"): PolicyAction {
  if (decision === "block") return "deny";
  return decision;
}

function mapPermissionToRule(permission: DeclarativePolicyPermission): PolicyRule {
  const match = permission.match;

  return {
    tool: match.tool,
    exec: match.executable,
    pattern: match.commandMatches || match.pathMatches,
    pathWithin: match.pathWithin,
    domain: match.domain,
    action: mapDecisionToAction(permission.decision),
    label: permission.label || permission.reason,
  };
}

function resolveHeuristics(h?: import("./types.js").PolicyHeuristics): ResolvedHeuristics {
  if (!h) return { ...DEFAULT_HEURISTICS };
  return {
    pipeToShell: h.pipeToShell === false ? false : mapDecisionToAction(h.pipeToShell || "ask"),
    dataEgress: h.dataEgress === false ? false : mapDecisionToAction(h.dataEgress || "ask"),
    secretEnvInUrl: h.secretEnvInUrl === false ? false : mapDecisionToAction(h.secretEnvInUrl || "ask"),
    secretFileAccess: h.secretFileAccess === false ? false : mapDecisionToAction(h.secretFileAccess || "block"),
    browserUnknownDomain: h.browserUnknownDomain === false ? false : mapDecisionToAction(h.browserUnknownDomain || "ask"),
    browserEval: h.browserEval === false ? false : mapDecisionToAction(h.browserEval || "ask"),
  };
}

function compileDeclarativePolicy(policy: DeclarativePolicyConfig): CompiledPolicy {
  return {
    name: policy.mode || "declarative",
    hardDeny: policy.guardrails
      .filter((rule) => rule.immutable || rule.decision === "block")
      .map(mapPermissionToRule)
      .map((rule) => ({ ...rule, action: "deny" as const })),
    rules: policy.permissions.map(mapPermissionToRule),
    defaultAction: mapDecisionToAction(policy.fallback),
    heuristics: resolveHeuristics(policy.heuristics),
  };
}

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
   * Extra executables to auto-allow for this workspace.
   * Use for dev runtimes (node, python3, make, cargo, etc.) that need
   * to run in a specific workspace but CAN execute arbitrary code.
   *
   * These are NOT in the global read-only list because they're code executors.
   * A workspace for a Node.js project might add ["node", "npx", "npm"].
   * A workspace for a Python project might add ["python3", "uv", "pip"].
   */
  allowedExecutables?: string[];
}

// ─── Policy Engine ───

export class PolicyEngine {
  private policy: CompiledPolicy;
  private config: PolicyConfig;

  constructor(policyOrMode: string | DeclarativePolicyConfig = "default", config?: PolicyConfig) {
    if (typeof policyOrMode === "string") {
      // Legacy string modes — resolve to built-in compiled policy for test compat.
      // Production always passes DeclarativePolicyConfig from JSON.
      const builtInPolicy = resolveBuiltInPolicy(policyOrMode);
      if (!builtInPolicy) {
        // Unknown mode: fall back to compiling the default policy config
        this.policy = compileDeclarativePolicy(defaultPolicy());
      } else {
        this.policy = builtInPolicy;
      }
    } else {
      this.policy = compileDeclarativePolicy(policyOrMode);
    }

    this.config = config || { allowedPaths: [] };
  }

  /**
   * Evaluate a tool call against the policy.
   *
   * Layered evaluation:
   * 1. Hard denies (immutable — credential exfiltration, privilege escalation)
   * 2. Rules (destructive operations on workspace data)
   * 3. Default action (allow for built-in presets)
   *
   * Pipes and subshells are NOT auto-escalated. Read-only command composition
   * like `grep foo | wc -l` should not require phone approval.
   */
  evaluate(req: GateRequest): PolicyDecision {
    const { tool, input } = req;

    // Layer 1: Hard denies (immutable)
    for (const rule of this.policy.hardDeny) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: "deny",
          reason: rule.label || "Blocked by hard deny rule",
          layer: "hard_deny",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 1.1: Secret file access heuristic (configurable)
    if (this.policy.heuristics.secretFileAccess !== false) {
      const secretDeny = this.evaluateSecretFileAccess(tool, input);
      if (secretDeny) {
        secretDeny.action = this.policy.heuristics.secretFileAccess;
        return secretDeny;
      }
    }

    // Layer 1.5: Structural heuristics (configurable via policy.heuristics)
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const segments = splitBashCommandChain(command);

      for (const segment of segments) {
        // Pipe to shell
        if (this.policy.heuristics.pipeToShell !== false && /\|\s*(ba)?sh\b/.test(segment)) {
          return {
            action: this.policy.heuristics.pipeToShell,
            reason: "Pipe to shell (arbitrary code execution)",
            layer: "rule",
            ruleLabel: "Pipe to shell",
          };
        }

        const stages = splitPipelineStages(segment);
        for (const stage of stages) {
          const parsed = parseBashCommand(stage);

          // Data egress
          if (this.policy.heuristics.dataEgress !== false && isDataEgress(parsed)) {
            return {
              action: this.policy.heuristics.dataEgress,
              reason: "Outbound data transfer",
              layer: "rule",
              ruleLabel: "Data egress",
            };
          }

          // Secret env expansion in URLs
          if (this.policy.heuristics.secretEnvInUrl !== false && hasSecretEnvExpansionInUrl(parsed)) {
            return {
              action: this.policy.heuristics.secretEnvInUrl,
              reason: "Possible secret env exfiltration in URL",
              layer: "rule",
              ruleLabel: "Secret env expansion in URL",
            };
          }
        }
      }
    }

    // Layer 1.6: Web-browser skill commands
    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const browser = parseBrowserCommand(command);
      if (browser) {
        // Read-only scripts (screenshot, logs) — always allow
        if (BROWSER_READ_ONLY.has(browser.script)) {
          return {
            action: "allow",
            reason: `Browser read-only: ${browser.script}`,
            layer: "rule",
            ruleLabel: "Browser read-only",
          };
        }

        // start.js — launching Chrome. Low risk but notable.
        if (browser.script === "start.js") {
          return {
            action: "allow",
            reason: "Launch browser",
            layer: "rule",
            ruleLabel: "Browser start",
          };
        }

        // nav.js — check shared fetch domain allowlist
        if (browser.script === "nav.js" && browser.domain) {
          if (isInFetchAllowlist(browser.domain)) {
            return {
              action: "allow",
              reason: `Allowed domain: ${browser.domain}`,
              layer: "rule",
              ruleLabel: "Browser domain allowlist",
            };
          }
          // Domain not in allowlist
          if (this.policy.heuristics.browserUnknownDomain !== false) {
            return {
              action: this.policy.heuristics.browserUnknownDomain,
              reason: `Browser navigation to unlisted domain: ${browser.domain}`,
              layer: "rule",
              ruleLabel: "Browser unknown domain",
            };
          }
        }

        // eval.js — arbitrary JS execution
        if (browser.script === "eval.js" && this.policy.heuristics.browserEval !== false) {
          return {
            action: this.policy.heuristics.browserEval,
            reason: "Browser JS execution",
            layer: "rule",
            ruleLabel: "Browser eval",
          };
        }

        // dismiss-cookies.js, pick.js — low risk but interactive
        if (browser.script === "dismiss-cookies.js" || browser.script === "pick.js") {
          return {
            action: "allow",
            reason: `Browser interaction: ${browser.script}`,
            layer: "rule",
            ruleLabel: "Browser interaction",
          };
        }
      }
    }

    // Layer 2: Rules (external actions, destructive operations)
    for (const rule of this.policy.rules) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: rule.action,
          reason: rule.label || `Matched rule for ${tool}`,
          layer: "rule",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 3: Default
    return {
      action: this.policy.defaultAction,
      reason: "No matching rule — using default",
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
   *   1. Hard denies (immutable, from policy mode)
   *   2. Learned/manual deny rules (explicit deny wins)
   *   3. Session allow rules
   *   4. Workspace allow rules
   *   5. Global allow rules
   *   6. Structural heuristics (pipe-to-shell, data egress, browser)
   *   7. Built-in/declarative rules + domain allowlist
   *   8. Policy fallback default
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
    for (const rule of this.policy.hardDeny) {
      if (this.matchesRule(rule, tool, input)) {
        return {
          action: "deny",
          reason: rule.label || "Blocked by hard deny rule",
          layer: "hard_deny",
          ruleLabel: rule.label,
        };
      }
    }

    // Layer 1.1: Secret file access heuristic
    if (this.policy.heuristics.secretFileAccess !== false) {
      const secretDeny = this.evaluateSecretFileAccess(tool, input);
      if (secretDeny) {
        secretDeny.action = this.policy.heuristics.secretFileAccess;
        return secretDeny;
      }
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
          layer: "global_rule",
          ruleLabel: rule.description,
          ruleId: rule.id,
        };
      }
    }

    // Layer 6+: Fall through to existing evaluate() for heuristics, rules, and default fallback
    return this.evaluate(req);
  }

  // ─── v2: Resolution options ───

  /**
   * Determine which resolution scopes to offer the phone user.
   *
   * Called when evaluate() returns "ask". Tells the phone what buttons to show.
   */
  getResolutionOptions(req: GateRequest, _decision: PolicyDecision): ResolutionOptions {
    const parsed = this.parseRequestContext(req);

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
    context: { sessionId: string; workspaceId: string },
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
    context: { sessionId: string; workspaceId: string },
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
        normalized.includes("scripts/build-install.sh") ||
        normalized.includes("scripts/ios-dev-up.sh") ||
        normalized.startsWith("xcrun devicectl device install app") ||
        normalized.startsWith("npx tsx src/cli.ts serve") ||
        normalized.startsWith("tsx src/cli.ts serve")) {
      return true;
    }

    return false;
  }

  private evaluateSecretFileAccess(
    tool: string,
    input: Record<string, unknown>,
  ): PolicyDecision | null {
    if (tool === "read") {
      const path = (input as { path?: string }).path;
      if (path && isSecretPath(path)) {
        return {
          action: "deny",
          reason: "Blocked access to secret credential files",
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

  getPolicyMode(): string {
    return this.policy.name;
  }

  // ─── Internal ───

  private matchesRule(rule: PolicyRule, tool: string, input: Record<string, unknown>): boolean {
    // Check tool name
    if (rule.tool && rule.tool !== "*" && rule.tool !== tool) {
      return false;
    }

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";

      if (rule.domain) {
        const browser = parseBrowserCommand(command);
        if (!browser?.domain || browser.domain !== rule.domain) {
          return false;
        }
      }

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
