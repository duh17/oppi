import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { parseCliArgs } from "./cli/args.js";
import {
  classifyCliAgentCommand,
  unreviewableMutationBodyReason,
  type CliAgentAccess,
} from "./cli/command-policy.js";
import { runCli, type CliRunResult } from "./cli/runner.js";
import { redactCredentialString } from "./credential-redaction.js";
import { createLogger } from "./logger.js";
import type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
import { assertNotSelfTargetingSession } from "./session-caller-identity.js";

export type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
export type OppiToolIdentity = "ordinary" | "control";

export type PreparedOppiCommand = Readonly<{
  access: Exclude<CliAgentAccess, "denied">;
  args: readonly string[];
  path: readonly string[];
  command: string;
  action?: string;
  isHelp: boolean;
  callerSessionId?: string;
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
  context: Readonly<{ callerSessionId?: string }> = {},
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
  const bodyReason =
    classified.invocation.access === "read"
      ? undefined
      : unreviewableMutationBodyReason(args, classified.invocation.isHelp);
  if (bodyReason) return denied(bodyReason);

  const path = Object.freeze([...classified.invocation.path]);
  const command = Object.freeze({
    access: classified.invocation.access,
    args: Object.freeze([...classified.invocation.args]),
    path,
    command: path[0] ?? "",
    ...(path[1] !== undefined ? { action: path[1] } : {}),
    isHelp: classified.invocation.isHelp,
    ...(context.callerSessionId ? { callerSessionId: context.callerSessionId } : {}),
  }) satisfies PreparedOppiCommand;
  authenticPreparedCommands.add(command);
  return Object.freeze({ ok: true, command });
}

export async function executePreparedOppiCommand(options: {
  prepared: PreparedOppiCommand;
  dataDir?: string;
  cwd?: string;
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
    captureHuman: true,
    forceJson: true,
  });
}

export async function applyOppiToolPolicy(options: {
  prepared: PreparedOppiCommand;
  policy: OppiApprovalPolicy;
  identity: OppiToolIdentity;
  signal?: AbortSignal;
  approvalMessage?: string;
  approve?: (message: string) => Promise<boolean>;
  execute?: (prepared: PreparedOppiCommand) => Promise<OppiToolCommandResult>;
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
    options.execute ?? ((command) => executePreparedOppiCommand({ prepared: command }));
  try {
    const result = await execute(prepared);
    auditPrepared(options, approvalOutcome, result.ok ? "success" : "error", startedAt);
    return { kind: "executed", result };
  } catch (error) {
    auditPrepared(options, approvalOutcome, "error", startedAt);
    throw error;
  }
}

export function createOppiToolExtensionFactory(options: {
  dataDir?: string;
  policySnapshot: Readonly<{ approvalPolicy: OppiApprovalPolicy }>;
  identity: OppiToolIdentity;
  callerSessionId: string;
}): ExtensionFactory {
  const policy = options.policySnapshot.approvalPolicy;
  const dataDir = options.dataDir;
  const identity = options.identity;
  const callerSessionId = options.callerSessionId;

  return (pi) => {
    pi.registerTool({
      name: "oppi",
      label: "Oppi",
      description:
        "Run one exposed Oppi CLI command as JSON under the configured server approval policy.",
      promptSnippet:
        "Run exposed Oppi CLI commands as JSON for workspaces, worktrees, Agents, Skills, sessions, schedules, and status.",
      promptGuidelines: [
        "Use oppi for Oppi app state instead of shell or filesystem tools.",
        "Use oppi read commands before asking the user about discoverable workspace, Agent, Skill, session, schedule, or worktree state.",
        "Use oppi session search and oppi session inspect for past Oppi session history instead of local JSONL-reading tools.",
        "Inspect session history progressively: start with session inspect <id> --view summary, then use --view outline; stop there when previews answer the question, otherwise request messages or tools for the smallest relevant turn set.",
        "Use session trace-outline only when exact entry ids are needed, followed by trace-page --around-entry or tool-output for bounded detail.",
        "Use oppi session inspect <id> --view response when only the latest assistant response is needed.",
        "Use Oppi mutation commands only after the user asks for them; the configured policy controls approval.",
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

        const classified = prepareOppiCommand(params.args, { callerSessionId });
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
        const policyResult = await applyOppiToolPolicy({
          prepared,
          policy,
          identity,
          ...(signal ? { signal } : {}),
          ...(approvalRequired ? { approvalMessage: approvalMessage(prepared) } : {}),
          ...(confirm ? { approve: confirm } : {}),
          execute: async (approvedCommand) =>
            executePreparedOppiCommand({
              prepared: approvedCommand,
              ...(dataDir !== undefined ? { dataDir } : {}),
              ...(typeof ctx.cwd === "string" ? { cwd: ctx.cwd } : {}),
            }),
        });

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
              args: [...prepared.args],
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
            args: [...prepared.args],
            outcome: result.ok ? ("result" as const) : ("error" as const),
            ...(result.json?.ok ? { data: result.json.data } : {}),
            expandedText: terminalTranscript(prepared.args, result.humanOutput),
            presentationFormat: "terminal" as const,
            exitCode: result.exitCode,
          },
        };
        return result.ok ? mapped : { ...mapped, isError: true };
      },
    });
  };
}

function commandRequiresApproval(
  prepared: PreparedOppiCommand,
  policy: OppiApprovalPolicy,
): boolean {
  return (
    policy !== "readOnly" &&
    prepared.access !== "read" &&
    (prepared.access === "alwaysApprove" ||
      policy === "confirmAllChanges" ||
      prepared.access === "destructive")
  );
}

function approvalMessage(prepared: PreparedOppiCommand): string {
  return redactCredentialString(`Run Oppi command: ${prepared.path.join(" ")}`);
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
      "dialogs",
      "respond",
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
