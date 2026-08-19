import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { parseCliArgs } from "./cli/args.js";
import { readFileSync } from "node:fs";
import {
  classifyCliAgentCommand,
  inlineStdinMutationBodies,
  unreviewableMutationBodyReason,
  type CliAgentAccess,
} from "./cli/command-policy.js";
import { runCli, type CliRunResult } from "./cli/runner.js";
import { redactCredentialString, redactCredentialValue } from "./credential-redaction.js";
import { createLogger } from "./logger.js";
import type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
import { assertNotSelfTargetingSession } from "./session-caller-identity.js";
import { restrictSandboxOppiCommand, type SandboxOppiScope } from "./sandbox-oppi-policy.js";

export type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
export type OppiToolIdentity = "ordinary" | "control" | "sandbox";

export type PreparedOppiCommand = Readonly<{
  access: Exclude<CliAgentAccess, "denied">;
  args: readonly string[];
  path: readonly string[];
  command: string;
  action?: string;
  isHelp: boolean;
  callerSessionId?: string;
  sandboxScope?: SandboxOppiScope;
}>;

export type PrepareOppiCommandResult =
  | { readonly ok: true; readonly command: PreparedOppiCommand }
  | { readonly ok: false; readonly reason: string };

export type OppiToolCommandResult = CliRunResult;

export type OppiToolPolicyResult =
  | { readonly kind: "executed"; readonly result: OppiToolCommandResult }
  | { readonly kind: "cancelled"; readonly reason: "declined" | "aborted" };

export const OPPI_EXTENSION_READ_ONLY_ERROR =
  "OPPI_EXTENSION_READ_ONLY: mutations are disabled by the Read only policy";
export const OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR =
  "OPPI_EXTENSION_APPROVAL_REQUIRED: this Oppi command requires UI approval";
export const OPPI_EXTENSION_APPROVAL_FAILED_ERROR =
  "OPPI_EXTENSION_APPROVAL_FAILED: approval could not be completed";

const MAX_OPPI_TOOL_ARGUMENTS = 256;
const MAX_OPPI_TOOL_ARGUMENT_CHARS = 300_000;
const MAX_MODEL_OUTPUT_CHARS = 50_000;
const MAX_AUDIT_DURATION_MS = 86_400_000;
const log = createLogger();
const authenticPreparedCommands = new WeakSet<object>();

export function prepareOppiCommand(
  rawArgs: readonly string[],
  context: Readonly<{
    callerSessionId?: string;
    readStdin?: () => string;
    sandboxScope?: SandboxOppiScope;
  }> = {},
): PrepareOppiCommandResult {
  const args = rawArgs[0] === "oppi" ? rawArgs.slice(1) : [...rawArgs];
  if (args.length === 0) return denied("oppi command args are required");
  if (args.some((arg) => typeof arg !== "string" || arg.length === 0)) {
    return denied("oppi command arguments must not be empty");
  }
  if (args.some((arg) => arg.includes("\0"))) {
    return denied("oppi command arguments must not contain NUL characters");
  }
  if (args.length > MAX_OPPI_TOOL_ARGUMENTS) {
    return denied(`oppi command accepts at most ${MAX_OPPI_TOOL_ARGUMENTS} arguments`);
  }
  const argumentChars = args.reduce((total, arg) => total + arg.length, 0);
  if (argumentChars > MAX_OPPI_TOOL_ARGUMENT_CHARS) {
    return denied(
      `oppi command arguments exceed the ${MAX_OPPI_TOOL_ARGUMENT_CHARS}-character limit`,
    );
  }

  const classified = classifyCliAgentCommand(args);
  if (!classified.ok) return denied(classified.reason);
  let invocationArgs = [...classified.invocation.args];
  if (classified.invocation.access !== "read" && !classified.invocation.isHelp) {
    const inlined = inlineStdinMutationBodies(
      invocationArgs,
      context.readStdin ?? readStdinMutationBody,
    );
    if (!inlined.ok) return denied(inlined.reason);
    invocationArgs = inlined.args;
    const inlinedChars = invocationArgs.reduce((total, arg) => total + arg.length, 0);
    if (inlinedChars > MAX_OPPI_TOOL_ARGUMENT_CHARS) {
      return denied(
        `oppi command arguments exceed the ${MAX_OPPI_TOOL_ARGUMENT_CHARS}-character limit`,
      );
    }
  }
  const bodyReason =
    classified.invocation.access === "read"
      ? undefined
      : unreviewableMutationBodyReason(invocationArgs, classified.invocation.isHelp);
  if (bodyReason) return denied(bodyReason);

  const path = Object.freeze([...classified.invocation.path]);
  if (context.sandboxScope) {
    const restricted = restrictSandboxOppiCommand({
      path,
      args: invocationArgs,
      isHelp: classified.invocation.isHelp,
      scope: context.sandboxScope,
    });
    if (!restricted.ok) return denied(restricted.reason);
    invocationArgs = [...restricted.args];
  }
  const command = Object.freeze({
    access: classified.invocation.access,
    args: Object.freeze(invocationArgs),
    path,
    command: path[0] ?? "",
    ...(path[1] !== undefined ? { action: path[1] } : {}),
    isHelp: classified.invocation.isHelp,
    ...(context.callerSessionId ? { callerSessionId: context.callerSessionId } : {}),
    ...(context.sandboxScope ? { sandboxScope: context.sandboxScope } : {}),
  }) satisfies PreparedOppiCommand;
  authenticPreparedCommands.add(command);
  return Object.freeze({ ok: true, command });
}

function readStdinMutationBody(): string {
  return readFileSync(0, "utf-8");
}

export async function executePreparedOppiCommand(options: {
  prepared: PreparedOppiCommand;
  dataDir?: string;
  cwd?: string;
  signal?: AbortSignal;
}): Promise<OppiToolCommandResult> {
  if (!authenticPreparedCommands.has(options.prepared)) {
    throw new Error("Unrecognized prepared Oppi command");
  }
  assertNotSelfTargetingSession(sessionTargets(options.prepared), options.prepared.callerSessionId);

  return runCli(options.prepared.args, {
    ...(options.dataDir !== undefined ? { dataDir: options.dataDir } : {}),
    ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
    ...(options.prepared.callerSessionId
      ? { callerSessionId: options.prepared.callerSessionId }
      : {}),
    ...(options.prepared.sandboxScope ? { sandboxScope: options.prepared.sandboxScope } : {}),
    captureHuman: true,
    forceJson: true,
    ...(options.signal ? { signal: options.signal } : {}),
  });
}

export async function applyOppiToolPolicy(options: {
  prepared: PreparedOppiCommand;
  policy: OppiApprovalPolicy;
  identity: OppiToolIdentity;
  signal?: AbortSignal;
  approvalMessage?: string;
  approve?: (message: string) => Promise<boolean>;
  execute?: (prepared: PreparedOppiCommand, signal?: AbortSignal) => Promise<OppiToolCommandResult>;
}): Promise<OppiToolPolicyResult> {
  const startedAt = Date.now();
  const { prepared } = options;
  if (!authenticPreparedCommands.has(prepared)) {
    audit(options.identity, "denied", options.policy, "denied", "denied", "denied", startedAt);
    throw new Error("Unrecognized prepared Oppi command");
  }

  if (options.signal?.aborted) {
    auditPrepared(options, "aborted", "denied", startedAt);
    return { kind: "cancelled", reason: "aborted" };
  }
  if (options.policy === "readOnly" && prepared.access !== "read") {
    auditPrepared(options, "not-required", "read-only", startedAt);
    throw new Error(OPPI_EXTENSION_READ_ONLY_ERROR);
  }

  const approvalRequired = commandRequiresApproval(prepared, options.policy);
  let approvalOutcome = "not-required";
  if (approvalRequired) {
    if (!options.approve) {
      auditPrepared(options, "missing-ui", "denied", startedAt);
      throw new Error(OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR);
    }

    let approved: boolean;
    try {
      approved = await options.approve(
        options.approvalMessage ?? "Run the requested Oppi CLI command?",
      );
    } catch {
      auditPrepared(options, "approval-error", "denied", startedAt);
      throw new Error(OPPI_EXTENSION_APPROVAL_FAILED_ERROR);
    }
    if (options.signal?.aborted) {
      auditPrepared(options, "aborted", "denied", startedAt);
      return { kind: "cancelled", reason: "aborted" };
    }
    if (!approved) {
      auditPrepared(options, "declined", "denied", startedAt);
      return { kind: "cancelled", reason: "declined" };
    }
    approvalOutcome = "approved";
  }

  const execute =
    options.execute ??
    ((command, signal) => executePreparedOppiCommand({ prepared: command, signal }));
  try {
    const result = await execute(prepared, options.signal);
    if (options.signal?.aborted) {
      auditPrepared(options, "aborted", "denied", startedAt);
      return { kind: "cancelled", reason: "aborted" };
    }
    auditPrepared(options, approvalOutcome, result.ok ? "success" : "error", startedAt);
    return { kind: "executed", result };
  } catch (error) {
    if (options.signal?.aborted) {
      auditPrepared(options, "aborted", "denied", startedAt);
      return { kind: "cancelled", reason: "aborted" };
    }
    auditPrepared(options, approvalOutcome, "error", startedAt);
    throw error;
  }
}

export function createOppiToolExtensionFactory(options: {
  dataDir?: string;
  policySnapshot: Readonly<{ approvalPolicy: OppiApprovalPolicy }>;
  identity: OppiToolIdentity;
  callerSessionId: string;
  sandboxScope?: SandboxOppiScope;
}): ExtensionFactory {
  const policy = options.policySnapshot.approvalPolicy;
  const dataDir = options.dataDir;
  const identity = options.identity;
  const callerSessionId = options.callerSessionId;
  const sandboxScope = options.sandboxScope;
  const sandboxScoped = identity === "sandbox" || sandboxScope !== undefined;

  return (pi) => {
    pi.registerTool({
      name: "oppi",
      label: "Oppi",
      description: sandboxScoped
        ? "Run sandbox-scoped Oppi CLI commands for this sandbox workspace only."
        : "Run one exposed Oppi CLI command as JSON under the configured server approval policy.",
      promptSnippet: sandboxScoped
        ? "Create, send, inspect, wait, and stop sessions in this sandbox workspace only. Cannot create host workspaces, edit Agents, or touch schedules or config."
        : "Run exposed Oppi CLI commands as JSON for workspaces, worktrees, Agents, Skills, sessions, schedules, status, models, and provider quota.",
      promptGuidelines: [
        "Use oppi for Oppi app state instead of shell or filesystem tools, and use read commands before asking about discoverable state.",
        "Route session questions by intent and take the smallest sufficient step: orientation uses session list; current progress uses session inspect <id> --view summary; latest response uses session inspect <id> --view response directly, without summary or outline first.",
        "For historical investigation, use session search or session inspect <id> --view outline first, then request only bounded session messages or tools; use trace-outline only when exact entry ids are needed, followed by trace-page or tool-output for the smallest range.",
        "Use session wait for bounded monitoring of one or more sessions; pass --all to require every id. Default poll is 2s; --poll/--interval and --summary-every override, and --summary-every 0 disables heartbeats.",
        sandboxScoped
          ? "Only session list/get/inspect/wait/create/send/abort/stop, agent list/get, workspace get, quota, and models are available. Children stay in this sandbox workspace. Do not pass --allow-nested-delegation or --all."
          : "Use Oppi mutation commands only after the user asks for them; read the current state first and let the configured policy control approval.",
        ...(sandboxScoped
          ? []
          : [
              "To edit a saved Agent, run 'oppi agent get <agent>' first, then patch only the changed fields with 'oppi agent update <agent> --definition-json'. Update is a PATCH: omitted fields stay, nested resources/sessionDefaults/launchConstraints merge, and JSON null clears a field or nested key. Allowed top-level keys are name, icon, description, instructions, resources, sessionDefaults, launchConstraints; launch-only keys (target, workspaceId, worktreeId, cwd, schedule, attachments, images) are rejected. sessionDefaults.tools must name real tools available at launch; unavailable names are dropped from the session with a warning.",
            ]),
      ],
      parameters: Type.Object({
        args: Type.Array(Type.String(), {
          maxItems: MAX_OPPI_TOOL_ARGUMENTS,
          description:
            "Command arguments without the leading 'oppi'. Output is the canonical CLI JSON envelope.",
        }),
      }),
      prepareArguments: (raw) => ({
        args:
          typeof raw === "object" &&
          raw !== null &&
          "args" in raw &&
          Array.isArray(raw.args) &&
          raw.args.every((value): value is string => typeof value === "string")
            ? raw.args
            : [],
      }),
      executionMode: "sequential",
      async execute(_toolCallId, params, signal, _onUpdate, ctx) {
        if (
          !Array.isArray(params.args) ||
          !params.args.every((value): value is string => typeof value === "string")
        ) {
          throw new Error("oppi args must be an array of strings");
        }

        const classified = prepareOppiCommand(params.args, {
          callerSessionId,
          ...(sandboxScope ? { sandboxScope } : {}),
        });
        if (!classified.ok) {
          audit(identity, "denied", policy, "denied", "denied", "denied", Date.now());
          throw new Error(redactCredentialString(classified.reason));
        }

        const prepared = classified.command;
        assertNotSelfTargetingSession(sessionTargets(prepared), callerSessionId);
        const approvalRequired = commandRequiresApproval(prepared, policy);
        const confirm =
          ctx.hasUI && typeof ctx.ui.confirm === "function"
            ? (message: string) => ctx.ui.confirm("Approve Oppi command", message)
            : undefined;
        const cwd = typeof ctx.cwd === "string" ? ctx.cwd : undefined;
        const resolvedApprovalMessage =
          approvalRequired && confirm
            ? await resolveApprovalMessage({
                prepared,
                ...(dataDir !== undefined ? { dataDir } : {}),
                ...(cwd !== undefined ? { cwd } : {}),
                ...(signal ? { signal } : {}),
              })
            : undefined;
        const policyResult = await applyOppiToolPolicy({
          prepared,
          policy,
          identity,
          ...(signal ? { signal } : {}),
          ...(resolvedApprovalMessage ? { approvalMessage: resolvedApprovalMessage } : {}),
          ...(confirm ? { approve: confirm } : {}),
          execute: async (approvedCommand, approvedSignal) =>
            executePreparedOppiCommand({
              prepared: approvedCommand,
              ...(dataDir !== undefined ? { dataDir } : {}),
              ...(cwd !== undefined ? { cwd } : {}),
              ...(approvedSignal ? { signal: approvedSignal } : {}),
            }),
        });

        const displayArgs = displayArgsForOppiCommand(prepared);
        if (policyResult.kind === "cancelled") {
          return {
            content: [
              {
                type: "text" as const,
                text:
                  policyResult.reason === "aborted"
                    ? "Oppi command cancelled."
                    : "Oppi command cancelled by user.",
              },
            ],
            details: {
              args: displayArgs,
              outcome: "cancelled" as const,
              cancelled: true,
              reason: policyResult.reason,
            },
          };
        }

        const result = policyResult.result;
        const mapped = {
          content: [{ type: "text" as const, text: boundModelOutput(result.stdout) }],
          details: {
            args: displayArgs,
            outcome: result.ok ? ("result" as const) : ("error" as const),
            ...(result.json?.ok ? { data: result.json.data } : {}),
            expandedText: terminalTranscript(displayArgs, result.humanOutput),
            presentationFormat: "terminal" as const,
            exitCode: result.exitCode,
          },
        };
        return result.ok ? mapped : { ...mapped, isError: true };
      },
    });
  };
}

/** Display-only args for tool details/transcripts. Never mutate execution args. */
export function displayArgsForOppiCommand(prepared: PreparedOppiCommand): string[] {
  const args = [...prepared.args];
  if (prepared.path[0] !== "config" || prepared.path[1] !== "set" || prepared.isHelp) {
    return args;
  }
  const positions = configSetKeyValuePositions(args);
  const key = positions ? args[positions.keyIndex] : undefined;
  if (positions && key !== undefined && args[positions.valueIndex] !== undefined) {
    args[positions.valueIndex] = redactConfigSetDisplayValue(
      key,
      args[positions.valueIndex] as string,
    );
  }
  return args;
}

/**
 * Raw-array positions of the config key and value for a `config set` command,
 * mirroring parseCliArgs so accepted flags anywhere in the array cannot shift
 * the positional value out from under redaction.
 */
function configSetKeyValuePositions(
  args: readonly string[],
): { keyIndex: number; valueIndex: number } | undefined {
  let parseFlags = true;
  const positionalIndices: number[] = [];
  for (let i = 1; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg) continue;
    if (parseFlags && arg === "--") {
      parseFlags = false;
      continue;
    }
    if (parseFlags && (arg === "-h" || arg.startsWith("--"))) {
      if (arg === "-h") continue;
      const separator = arg.indexOf("=");
      if (separator === -1) {
        const next = args[i + 1];
        if (next && next !== "--" && !next.startsWith("--")) i += 1; // skip flag value
      }
      continue;
    }
    positionalIndices.push(i);
  }
  // positional[0] is the action ("set"), positional[1] the key, positional[2] the value.
  if (positionalIndices.length < 3) return undefined;
  return { keyIndex: positionalIndices[1], valueIndex: positionalIndices[2] };
}

function redactConfigSetDisplayValue(key: string, value: string): string {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith("{") && trimmed.endsWith("}")) ||
    (trimmed.startsWith("[") && trimmed.endsWith("]"))
  ) {
    try {
      return JSON.stringify(redactCredentialValue(JSON.parse(trimmed) as unknown));
    } catch {
      // Fall through to key-aware scalar redaction.
    }
  }
  const leaf =
    key
      .split(".")
      .filter((part) => part.length > 0)
      .at(-1) ?? key;
  const redacted = redactCredentialValue(value, leaf);
  return typeof redacted === "string" ? redacted : JSON.stringify(redacted);
}

function commandRequiresApproval(
  prepared: PreparedOppiCommand,
  policy: OppiApprovalPolicy,
): boolean {
  return (
    policy !== "readOnly" &&
    prepared.access !== "read" &&
    (policy === "confirmAllChanges" || prepared.access === "destructive")
  );
}

async function resolveApprovalMessage(options: {
  prepared: PreparedOppiCommand;
  dataDir?: string;
  cwd?: string;
  signal?: AbortSignal;
}): Promise<string> {
  const { prepared } = options;
  if (prepared.path[0] === "worktree" && prepared.path[1] === "remove" && !prepared.isHelp) {
    return redactCredentialString(await worktreeRemoveApprovalMessage(options));
  }
  return redactCredentialString(`Run Oppi command: ${prepared.path.join(" ")}`);
}

async function worktreeRemoveApprovalMessage(options: {
  prepared: PreparedOppiCommand;
  dataDir?: string;
  cwd?: string;
  signal?: AbortSignal;
}): Promise<string> {
  const parsed = parseCliArgs([...options.prepared.args]);
  const worktreeId = parsed.positional[1]?.trim();
  const workspace = parsed.flags.workspace?.trim();
  const lookup = worktreeId
    ? await lookupWorktreeForApproval(options, worktreeId, workspace)
    : undefined;
  const name = firstNonEmpty(lookup?.name, lookup?.branch, worktreeId);
  const id = firstNonEmpty(lookup?.id, worktreeId);
  const workspaceLabel = firstNonEmpty(lookup?.workspaceId, workspace);
  const lines = ["Remove this worktree?"];
  if (name) lines.push(`Name: ${name}`);
  if (id && id !== name) lines.push(`ID: ${id}`);
  if (workspaceLabel) lines.push(`Workspace: ${workspaceLabel}`);
  if (lookup?.branch && lookup.branch !== name) lines.push(`Branch: ${lookup.branch}`);
  return lines.join("\n");
}

async function lookupWorktreeForApproval(
  options: {
    prepared: PreparedOppiCommand;
    dataDir?: string;
    cwd?: string;
    signal?: AbortSignal;
  },
  worktreeId: string,
  workspace?: string,
): Promise<
  | {
      id?: string;
      name?: string;
      branch?: string;
      workspaceId?: string;
    }
  | undefined
> {
  const lookup = prepareOppiCommand([
    "worktree",
    "get",
    worktreeId,
    ...(workspace ? ["--workspace", workspace] : []),
  ]);
  if (!lookup.ok) return undefined;
  try {
    const result = await executePreparedOppiCommand({
      prepared: lookup.command,
      ...(options.dataDir !== undefined ? { dataDir: options.dataDir } : {}),
      ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
      ...(options.signal ? { signal: options.signal } : {}),
    });
    if (!result.ok || !result.json?.ok) return undefined;
    const data = result.json.data;
    const worktree = isRecord(data.worktree) ? data.worktree : undefined;
    return {
      ...(stringField(worktree?.id) ? { id: stringField(worktree?.id) } : {}),
      ...(stringField(worktree?.name) ? { name: stringField(worktree?.name) } : {}),
      ...(stringField(worktree?.branch) ? { branch: stringField(worktree?.branch) } : {}),
      ...(stringField(data.workspaceId) ? { workspaceId: stringField(data.workspaceId) } : {}),
    };
  } catch {
    return undefined;
  }
}

function firstNonEmpty(...values: Array<string | undefined>): string | undefined {
  for (const value of values) {
    const trimmed = value?.trim();
    if (trimmed) return trimmed;
  }
  return undefined;
}

function stringField(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function terminalTranscript(args: readonly string[], humanOutput: string): string {
  const command = ["oppi", ...args].map(shellQuote).join(" ");
  return humanOutput ? `$ ${command}\n\n${humanOutput}` : `$ ${command}\n`;
}

function shellQuote(value: string): string {
  if (value.length === 0) return "''";
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(value)) return value;
  if (containsTerminalControl(value)) return `$'${bashAnsiCString(value)}'`;
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function containsTerminalControl(value: string): boolean {
  return Array.from(value).some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return (
      codePoint < 0x20 ||
      (codePoint >= 0x7f && codePoint <= 0x9f) ||
      codePoint === 0x061c ||
      codePoint === 0x200e ||
      codePoint === 0x200f ||
      (codePoint >= 0x2028 && codePoint <= 0x202e) ||
      (codePoint >= 0x2066 && codePoint <= 0x2069)
    );
  });
}

function bashAnsiCString(value: string): string {
  return Array.from(value)
    .map((character) => {
      const codePoint = character.codePointAt(0) ?? 0;
      switch (character) {
        case "\\":
          return "\\\\";
        case "'":
          return "\\'";
        case "\n":
          return "\\n";
        case "\r":
          return "\\r";
        case "\t":
          return "\\t";
        case "\b":
          return "\\b";
        case "\f":
          return "\\f";
        case "\v":
          return "\\v";
        case "\0":
          return "\\x00";
        default:
          if (codePoint < 0x20 || codePoint === 0x7f) {
            return `\\x${codePoint.toString(16).padStart(2, "0")}`;
          }
          if (
            (codePoint >= 0x80 && codePoint <= 0x9f) ||
            codePoint === 0x061c ||
            codePoint === 0x200e ||
            codePoint === 0x200f ||
            (codePoint >= 0x2028 && codePoint <= 0x202e) ||
            (codePoint >= 0x2066 && codePoint <= 0x2069)
          ) {
            return Array.from(
              Buffer.from(character, "utf8"),
              (byte) => `\\x${byte.toString(16).padStart(2, "0")}`,
            ).join("");
          }
          return character;
      }
    })
    .join("");
}

function boundModelOutput(output: string): string {
  if (output.length <= MAX_MODEL_OUTPUT_CHARS) return output;
  const omitted = output.length - MAX_MODEL_OUTPUT_CHARS;
  return `${output.slice(0, MAX_MODEL_OUTPUT_CHARS)}\n\n[Output truncated: omitted ${omitted} characters]`;
}

function sessionTargets(prepared: PreparedOppiCommand): string[] {
  if (prepared.path[0] !== "session" || !prepared.action) return [];
  if (
    ![
      "get",
      "send",
      "abort",
      "wait",
      "read",
      "events",
      "trace",
      "inspect",
      "stop",
      "delete",
      "resume",
      "fork",
      "changes",
      "diff",
      "tool-output",
      "trace-page",
      "trace-outline",
    ].includes(prepared.action)
  ) {
    return [];
  }
  const target = parseCliArgs([...prepared.args]).positional[1]?.trim();
  return target ? [target] : [];
}

function auditPrepared(
  options: Pick<Parameters<typeof applyOppiToolPolicy>[0], "prepared" | "policy" | "identity">,
  outcome: string,
  result: string,
  startedAt: number,
): void {
  audit(
    options.identity,
    options.prepared.access,
    options.policy,
    options.prepared.path.join(" "),
    outcome,
    result,
    startedAt,
  );
}

function audit(
  identity: OppiToolIdentity,
  access: CliAgentAccess,
  policy: OppiApprovalPolicy,
  action: string,
  outcome: string,
  result: string,
  startedAt: number,
): void {
  log.info("oppi_tool.audit", {
    identity,
    access,
    policy,
    action,
    outcome,
    result,
    duration: Math.min(MAX_AUDIT_DURATION_MS, Math.max(0, Date.now() - startedAt)),
  });
}

function denied(reason: string): PrepareOppiCommandResult {
  return Object.freeze({ ok: false, reason: redactCredentialString(reason) });
}
