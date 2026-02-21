import type { ParsedCommand } from "./policy-types.js";

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

  const pushCurrent = (): void => {
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

  const pushCurrent = (): void => {
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
