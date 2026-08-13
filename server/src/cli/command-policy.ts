import { isHelpFlag, parseCliArgs, type ParsedCliArgs } from "./args.js";
import { helpPathFor, isNestedHelpRequest, resolveHelpTopic } from "./help.js";

export type CliAgentAccess = "read" | "mutation" | "destructive" | "alwaysApprove" | "denied";

type AllowedCliAgentAccess = Exclude<CliAgentAccess, "denied">;

export type CliCommandPolicy = Readonly<{
  path: readonly string[];
  access: CliAgentAccess;
}>;

export type CliAgentClassification =
  | {
      readonly ok: true;
      readonly invocation: Readonly<{
        args: readonly string[];
        path: readonly string[];
        access: AllowedCliAgentAccess;
        isHelp: boolean;
      }>;
    }
  | {
      readonly ok: false;
      readonly access: "denied";
      readonly reason: string;
      readonly path?: readonly string[];
    };

const COMMAND_POLICIES: readonly CliCommandPolicy[] = [
  { path: ["status"], access: "read" },

  { path: ["workspace", "list"], access: "read" },
  { path: ["workspace", "get"], access: "read" },
  { path: ["workspace", "create"], access: "mutation" },
  { path: ["workspace", "update"], access: "mutation" },
  { path: ["workspace", "delete"], access: "destructive" },

  { path: ["worktree", "list"], access: "read" },
  { path: ["worktree", "get"], access: "read" },
  { path: ["worktree", "status"], access: "read" },
  { path: ["worktree", "preview"], access: "read" },
  { path: ["worktree", "create"], access: "mutation" },
  { path: ["worktree", "open"], access: "mutation" },
  { path: ["worktree", "remove"], access: "destructive" },

  { path: ["agent", "list"], access: "read" },
  { path: ["agent", "get"], access: "read" },
  { path: ["agent", "create"], access: "mutation" },
  { path: ["agent", "update"], access: "mutation" },
  { path: ["agent", "archive"], access: "destructive" },

  { path: ["session", "list"], access: "read" },
  { path: ["session", "get"], access: "read" },
  { path: ["session", "trace-outline"], access: "read" },
  { path: ["session", "read"], access: "read" },
  { path: ["session", "events"], access: "read" },
  { path: ["session", "trace"], access: "read" },
  { path: ["session", "search"], access: "read" },
  { path: ["session", "inspect"], access: "read" },
  { path: ["session", "tool-output"], access: "read" },
  { path: ["session", "trace-page"], access: "read" },
  { path: ["session", "wait"], access: "read" },
  { path: ["session", "dialogs"], access: "read" },
  { path: ["session", "create"], access: "mutation" },
  { path: ["session", "send"], access: "mutation" },
  { path: ["session", "abort"], access: "mutation" },
  { path: ["session", "respond"], access: "alwaysApprove" },
  { path: ["session", "stop"], access: "mutation" },
  { path: ["session", "resume"], access: "mutation" },
  { path: ["session", "fork"], access: "mutation" },
  { path: ["session", "delete"], access: "destructive" },

  { path: ["schedule", "list"], access: "read" },
  { path: ["schedule", "get"], access: "read" },
  { path: ["schedule", "runs"], access: "read" },
  { path: ["schedule", "create"], access: "mutation" },
  { path: ["schedule", "update"], access: "mutation" },
  { path: ["schedule", "run"], access: "mutation" },
  { path: ["schedule", "pause"], access: "mutation" },
  { path: ["schedule", "resume"], access: "mutation" },
  { path: ["schedule", "restore"], access: "mutation" },
  { path: ["schedule", "archive"], access: "destructive" },

  { path: ["config"], access: "read" },
  { path: ["config", "show"], access: "read" },
  { path: ["config", "get"], access: "read" },
  { path: ["config", "validate"], access: "read" },
  { path: ["config", "set"], access: "mutation" },

  { path: ["init"], access: "denied" },
  { path: ["serve"], access: "denied" },
  { path: ["start"], access: "denied" },
  { path: ["pair"], access: "denied" },
  { path: ["doctor"], access: "denied" },
  { path: ["server"], access: "denied" },
  { path: ["token"], access: "denied" },
  { path: ["update"], access: "denied" },
  { path: ["version"], access: "denied" },
  { path: ["wait"], access: "denied" },
  { path: ["credentials"], access: "denied" },
  { path: ["shell"], access: "denied" },
];

const POLICY_BY_KEY = new Map(COMMAND_POLICIES.map((policy) => [pathKey(policy.path), policy]));
const MUTABLE_BODY_FLAGS = new Set([
  "answers",
  "definition-json",
  "prompt",
  "system-prompt",
  "text",
]);

export function listCliAgentCommandPolicies(): readonly CliCommandPolicy[] {
  return COMMAND_POLICIES;
}

export function classifyCliAgentCommand(rawArgs: readonly string[]): CliAgentClassification {
  const normalized = normalizeAgentArgs(rawArgs);
  if (!normalized.ok) return normalized;

  let parsed: ParsedCliArgs;
  try {
    parsed = parseCliArgs([...normalized.args]);
  } catch (error) {
    return denied(errorMessage(error));
  }

  const isHelp = isNestedHelpRequest(parsed.command, parsed.positional, parsed.flags);
  const path = isHelp
    ? canonicalPath(helpPathFor(parsed.command, parsed.positional))
    : canonicalPath(commandPath(parsed));
  if (!isHelp && path[0] === "config" && path[1] === "validate") {
    if (Object.hasOwn(parsed.flags, "config-file")) {
      return denied(
        "Agent config validate cannot target an explicit --config-file; validate the active config instead",
        path,
      );
    }
  }
  const policy = policyFor(path, isHelp);
  if (!policy || policy.access === "denied") {
    return denied("This Oppi command is not exposed to agents", path);
  }
  if (isHelp && !resolveHelpTopic(path)) {
    return denied("This Oppi help topic is not exposed to agents", path);
  }

  return {
    ok: true,
    invocation: {
      args: Object.freeze([...normalized.args]),
      path: Object.freeze([...path]),
      access: policy.access,
      isHelp,
    },
  };
}

export function unreviewableMutationBodyReason(
  args: readonly string[],
  isHelp = false,
): string | undefined {
  if (isHelp) return undefined;

  for (let index = 0; index < args.length; index += 1) {
    const value = args[index] ?? "";
    if (value === "--definition") {
      return "Mutation bodies must be supplied inline; file-backed --definition input is not allowed";
    }
    if (!value.startsWith("--")) continue;

    const separator = value.indexOf("=");
    const flag = separator === -1 ? value.slice(2) : value.slice(2, separator);
    if (!MUTABLE_BODY_FLAGS.has(flag)) continue;
    const body = separator === -1 ? args[index + 1] : value.slice(separator + 1);
    if (body === "@-") {
      return `Mutation bodies must be supplied inline; --${flag} @- is not allowed`;
    }
  }
  return undefined;
}

function normalizeAgentArgs(
  rawArgs: readonly string[],
):
  | { readonly ok: true; readonly args: readonly string[] }
  | { readonly ok: false; readonly access: "denied"; readonly reason: string } {
  const args = rawArgs[0] === "oppi" ? rawArgs.slice(1) : [...rawArgs];
  if (args[0] !== "session" || args[1] !== "watch") {
    return { ok: true, args };
  }

  let parsed: ParsedCliArgs;
  try {
    parsed = parseCliArgs(args);
  } catch (error) {
    return normalizationDenied(errorMessage(error));
  }

  const help = isHelpFlag(parsed.flags) || parsed.positional[0] === "help";
  const sessionIds = parsed.positional.slice(1);
  if (!help && sessionIds.length !== 1) {
    return normalizationDenied("Only one session may use the bounded session watch alias");
  }
  if (parsed.flags.all === "true") {
    return normalizationDenied("Streaming session watch is not exposed to agents");
  }
  if (parsed.flags.until?.trim().toLowerCase() === "any-change") {
    return normalizationDenied("Streaming session watch is not exposed to agents");
  }
  if (Object.hasOwn(parsed.flags, "until") && Object.hasOwn(parsed.flags, "for")) {
    return normalizationDenied("Conflicting flags: --until and --for");
  }
  if (Object.hasOwn(parsed.flags, "interval") && Object.hasOwn(parsed.flags, "poll")) {
    return normalizationDenied("Conflicting flags: --interval and --poll");
  }

  const normalized = args.map((arg, index) => {
    if (index === 1) return "wait";
    if (arg === "--until") return "--for";
    if (arg === "--interval") return "--poll";
    return arg;
  });
  return { ok: true, args: normalized };
}

function normalizationDenied(reason: string): {
  readonly ok: false;
  readonly access: "denied";
  readonly reason: string;
} {
  return { ok: false, access: "denied", reason };
}

function commandPath(parsed: ParsedCliArgs): string[] {
  if (parsed.command === "status") return ["status"];
  return parsed.positional[0] ? [parsed.command, parsed.positional[0]] : [parsed.command];
}

function canonicalPath(path: readonly string[]): string[] {
  const normalized = path.map((part) => part.toLowerCase());
  if (normalized[0] === "workspace" && normalized[1] === "remove") {
    normalized[1] = "delete";
  }
  if (normalized[0] === "session" && normalized[1] === "watch") {
    normalized[1] = "wait";
  }
  return normalized;
}

function policyFor(path: readonly string[], isHelp: boolean): CliCommandPolicy | undefined {
  const exact = POLICY_BY_KEY.get(pathKey(path));
  if (exact) return isHelp && exact.access !== "denied" ? { path, access: "read" } : exact;
  if (!isHelp || path.length !== 1) return POLICY_BY_KEY.get(pathKey(path));

  const first = path[0];
  if (!first) return undefined;
  const rootPolicies = COMMAND_POLICIES.filter(
    (policy) => policy.path[0] === first && policy.access !== "denied",
  );
  return rootPolicies.length > 0
    ? { path: [first], access: "read" }
    : POLICY_BY_KEY.get(pathKey(path));
}

function pathKey(path: readonly string[]): string {
  return path.join("\u0000");
}

function denied(reason: string, path?: readonly string[]): CliAgentClassification {
  return {
    ok: false,
    access: "denied",
    reason,
    ...(path ? { path: Object.freeze([...path]) } : {}),
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
