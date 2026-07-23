import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { isHelpFlag, parseCliArgs, type ParsedCliArgs } from "./cli/args.js";
import { cmdAgent } from "./cli/commands/agent.js";
import { cmdSchedule } from "./cli/commands/schedule.js";
import { cmdSession } from "./cli/commands/session.js";
import { cmdWorkspace } from "./cli/commands/workspace.js";
import { cmdWorktree } from "./cli/commands/worktree.js";
import { createCliConnectionConfig } from "./cli/connection-config.js";
import { assertInlineDefinitionSize } from "./cli/definition-input.js";
import { helpTopicToJson, resolveHelpTopic } from "./cli/help.js";
import type { LocalApiConnection } from "./cli/local-api-client.js";
import { captureCliOutput, type CliJsonEnvelope } from "./cli/output.js";
import { createLogger } from "./logger.js";
import type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
import { assertNotSelfTargetingSession } from "./session-caller-identity.js";
import { tlsSchemeForConfig } from "./tls.js";

export type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
export type OppiToolIdentity = "ordinary" | "control";
export type OppiToolCommandCategory =
  | "read"
  | "nonDestructiveWrite"
  | "destructiveWrite"
  | "denied";

type AllowedOppiToolCommandCategory = Exclude<OppiToolCommandCategory, "denied">;

type FlagDescriptor = Readonly<{
  kind: "boolean" | "value";
  bodyLabel?: string;
  indirectBody?: boolean;
}>;

type ApprovalTargetDescriptor = Readonly<{
  label: string;
  positionalIndex?: number;
  flag?: string;
  fallbackFlag?: string;
}>;

type CommandDescriptor = Readonly<{
  command: string;
  action?: string;
  category: AllowedOppiToolCommandCategory;
  minPositionals: number;
  maxPositionals: number;
  flags: Readonly<Record<string, FlagDescriptor>>;
  requiredFlags?: readonly string[];
  atLeastOneFlags?: readonly (readonly string[])[];
  exactlyOneFlags?: readonly (readonly string[])[];
  atMostOneFlags?: readonly (readonly string[])[];
  target?: ApprovalTargetDescriptor;
  contextFlag?: Readonly<{ flag: string; label: string }>;
}>;

export interface OppiToolApprovalDetails {
  readonly action: string;
  readonly category: AllowedOppiToolCommandCategory;
  readonly target?: Readonly<{ label: string; value: string }>;
  readonly context?: Readonly<{ label: string; value: string }>;
  readonly arguments: readonly string[];
  readonly bodies: readonly Readonly<{ label: string; value: string }>[];
}

export interface PreparedOppiCommand {
  readonly category: AllowedOppiToolCommandCategory;
  readonly callerSessionId?: string;
  readonly command: string;
  readonly action?: string;
  readonly normalizedArgs: readonly string[];
  readonly parsed: Readonly<{
    command: string;
    positional: readonly string[];
    flags: Readonly<Record<string, string>>;
  }>;
  readonly displayCommand: string;
  readonly summary: string;
  readonly approvalDetails?: OppiToolApprovalDetails;
  readonly approvalMessage?: string;
  readonly helpPath?: readonly string[];
}

export type PrepareOppiCommandResult =
  | { readonly ok: true; readonly command: PreparedOppiCommand }
  | { readonly ok: false; readonly reason: string };

export interface OppiToolCommandResult {
  ok: boolean;
  exitCode: number;
  stdout: string;
  data?: unknown;
  error?: { message: string; status?: number };
}

export type OppiToolPolicyResult =
  | { readonly kind: "executed"; readonly result: OppiToolCommandResult }
  | { readonly kind: "cancelled"; readonly reason: "declined" | "aborted" };

export const OPPI_EXTENSION_READ_ONLY_ERROR =
  "OPPI_EXTENSION_READ_ONLY: mutations are disabled by the Read only policy";
export const OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR =
  "OPPI_EXTENSION_APPROVAL_REQUIRED: this Oppi command requires UI approval";
export const OPPI_EXTENSION_APPROVAL_FAILED_ERROR =
  "OPPI_EXTENSION_APPROVAL_FAILED: approval could not be completed";

const MAX_TOOL_OUTPUT_CHARS = 50_000;
const MAX_AUDIT_DURATION_MS = 86_400_000;
const log = createLogger();
const authenticPreparedCommands = new WeakSet<object>();

const BOOLEAN_FLAG: FlagDescriptor = Object.freeze({ kind: "boolean" });
const VALUE_FLAG: FlagDescriptor = Object.freeze({ kind: "value" });
const PROMPT_FLAG: FlagDescriptor = Object.freeze({ kind: "value", bodyLabel: "Prompt" });
const TEXT_FLAG: FlagDescriptor = Object.freeze({ kind: "value", bodyLabel: "Message" });
const SYSTEM_PROMPT_FLAG: FlagDescriptor = Object.freeze({
  kind: "value",
  bodyLabel: "System prompt",
});
const DEFINITION_JSON_FLAG: FlagDescriptor = Object.freeze({
  kind: "value",
  bodyLabel: "Definition",
});
const DEFINITION_FILE_FLAG: FlagDescriptor = Object.freeze({
  kind: "value",
  indirectBody: true,
});

function commandFlags(
  flags: Record<string, FlagDescriptor> = {},
): Readonly<Record<string, FlagDescriptor>> {
  return Object.freeze({ json: BOOLEAN_FLAG, help: BOOLEAN_FLAG, h: BOOLEAN_FLAG, ...flags });
}

// This is the single authority for allowed actions, categories, positional bounds,
// flags, inline bodies, and approval presentation. Anything absent is denied.
const COMMAND_DESCRIPTORS: readonly CommandDescriptor[] = Object.freeze([
  {
    command: "status",
    category: "read",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags(),
  },
  {
    command: "workspace",
    action: "list",
    category: "read",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags(),
  },
  {
    command: "workspace",
    action: "get",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags(),
    target: { label: "Workspace", positionalIndex: 0 },
  },
  {
    command: "workspace",
    action: "create",
    category: "nonDestructiveWrite",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({
      name: VALUE_FLAG,
      "host-mount": VALUE_FLAG,
      description: VALUE_FLAG,
      icon: VALUE_FLAG,
      "system-prompt": SYSTEM_PROMPT_FLAG,
      "default-model": VALUE_FLAG,
      runtime: VALUE_FLAG,
      definition: DEFINITION_FILE_FLAG,
    }),
    requiredFlags: ["name"],
    target: { label: "Workspace", flag: "name" },
  },
  {
    command: "workspace",
    action: "update",
    category: "nonDestructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({
      name: VALUE_FLAG,
      "host-mount": VALUE_FLAG,
      description: VALUE_FLAG,
      icon: VALUE_FLAG,
      "system-prompt": SYSTEM_PROMPT_FLAG,
      "default-model": VALUE_FLAG,
      runtime: VALUE_FLAG,
      definition: DEFINITION_FILE_FLAG,
    }),
    atLeastOneFlags: [
      [
        "name",
        "host-mount",
        "description",
        "icon",
        "system-prompt",
        "default-model",
        "runtime",
        "definition",
      ],
    ],
    target: { label: "Workspace", positionalIndex: 0 },
  },
  ...["delete", "remove"].map(
    (action): CommandDescriptor => ({
      command: "workspace",
      action,
      category: "destructiveWrite",
      minPositionals: 1,
      maxPositionals: 1,
      flags: commandFlags(),
      target: { label: "Workspace", positionalIndex: 0 },
    }),
  ),
  {
    command: "worktree",
    action: "list",
    category: "read",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({ workspace: VALUE_FLAG }),
    requiredFlags: ["workspace"],
    target: { label: "Workspace", flag: "workspace" },
  },
  ...["get", "status"].map(
    (action): CommandDescriptor => ({
      command: "worktree",
      action,
      category: "read",
      minPositionals: 1,
      maxPositionals: 1,
      flags: commandFlags({ workspace: VALUE_FLAG }),
      requiredFlags: ["workspace"],
      target: { label: "Worktree", positionalIndex: 0 },
      contextFlag: { flag: "workspace", label: "Workspace" },
    }),
  ),
  {
    command: "worktree",
    action: "preview",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ workspace: VALUE_FLAG, into: VALUE_FLAG, mode: VALUE_FLAG }),
    requiredFlags: ["workspace", "into"],
    target: { label: "Worktree", positionalIndex: 0 },
    contextFlag: { flag: "workspace", label: "Workspace" },
  },
  {
    command: "worktree",
    action: "create",
    category: "nonDestructiveWrite",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({
      workspace: VALUE_FLAG,
      branch: VALUE_FLAG,
      base: VALUE_FLAG,
      path: VALUE_FLAG,
    }),
    requiredFlags: ["workspace", "branch"],
    target: { label: "Workspace", flag: "workspace" },
  },
  {
    command: "worktree",
    action: "open",
    category: "nonDestructiveWrite",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({ workspace: VALUE_FLAG, branch: VALUE_FLAG, path: VALUE_FLAG }),
    requiredFlags: ["workspace"],
    exactlyOneFlags: [["branch", "path"]],
    target: { label: "Workspace", flag: "workspace" },
  },
  {
    command: "worktree",
    action: "remove",
    category: "destructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ workspace: VALUE_FLAG, force: BOOLEAN_FLAG }),
    requiredFlags: ["workspace"],
    target: { label: "Worktree", positionalIndex: 0 },
    contextFlag: { flag: "workspace", label: "Workspace" },
  },
  {
    command: "agent",
    action: "list",
    category: "read",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags(),
  },
  {
    command: "agent",
    action: "get",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags(),
    target: { label: "Agent", positionalIndex: 0 },
  },
  {
    command: "agent",
    action: "create",
    category: "nonDestructiveWrite",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({
      name: VALUE_FLAG,
      definition: DEFINITION_FILE_FLAG,
      "definition-json": DEFINITION_JSON_FLAG,
    }),
    atLeastOneFlags: [["name", "definition", "definition-json"]],
    exactlyOneFlags: [["definition", "definition-json"]],
    target: { label: "Agent", flag: "name" },
  },
  {
    command: "agent",
    action: "update",
    category: "nonDestructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({
      definition: DEFINITION_FILE_FLAG,
      "definition-json": DEFINITION_JSON_FLAG,
    }),
    exactlyOneFlags: [["definition", "definition-json"]],
    target: { label: "Agent", positionalIndex: 0 },
  },
  {
    command: "agent",
    action: "archive",
    category: "destructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags(),
    target: { label: "Agent", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "list",
    category: "read",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({
      agent: VALUE_FLAG,
      limit: VALUE_FLAG,
      status: VALUE_FLAG,
      workspace: VALUE_FLAG,
      worktree: VALUE_FLAG,
    }),
  },
  ...["get", "changes", "trace-outline"].map(
    (action): CommandDescriptor => ({
      command: "session",
      action,
      category: "read",
      minPositionals: 1,
      maxPositionals: 1,
      flags: commandFlags(),
      target: { label: "Session", positionalIndex: 0 },
    }),
  ),
  {
    command: "session",
    action: "read",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ tail: VALUE_FLAG }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "events",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ since: VALUE_FLAG }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "trace",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ include: VALUE_FLAG }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "search",
    category: "read",
    minPositionals: 0,
    maxPositionals: Number.POSITIVE_INFINITY,
    flags: commandFlags({
      all: BOOLEAN_FLAG,
      limit: VALUE_FLAG,
      query: VALUE_FLAG,
      since: VALUE_FLAG,
      until: VALUE_FLAG,
      workspace: VALUE_FLAG,
    }),
  },
  {
    command: "session",
    action: "inspect",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ turns: VALUE_FLAG, view: VALUE_FLAG }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "diff",
    category: "read",
    minPositionals: 1,
    maxPositionals: 2,
    flags: commandFlags({ path: VALUE_FLAG }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "tool-output",
    category: "read",
    minPositionals: 2,
    maxPositionals: 2,
    flags: commandFlags(),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "trace-page",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({
      "around-entry": VALUE_FLAG,
      cursor: VALUE_FLAG,
      "preview-bytes": VALUE_FLAG,
      "target-events": VALUE_FLAG,
    }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "wait",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ for: VALUE_FLAG, poll: VALUE_FLAG, timeout: VALUE_FLAG }),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "create",
    category: "nonDestructiveWrite",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({
      agent: VALUE_FLAG,
      "allow-nested-delegation": BOOLEAN_FLAG,
      "idempotency-key": VALUE_FLAG,
      model: VALUE_FLAG,
      name: VALUE_FLAG,
      prompt: PROMPT_FLAG,
      thinking: VALUE_FLAG,
      workspace: VALUE_FLAG,
      worktree: VALUE_FLAG,
    }),
    requiredFlags: ["workspace", "prompt"],
    target: { label: "Workspace", flag: "workspace" },
  },
  {
    command: "session",
    action: "send",
    category: "nonDestructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ "follow-up": BOOLEAN_FLAG, steer: BOOLEAN_FLAG, text: TEXT_FLAG }),
    requiredFlags: ["text"],
    atMostOneFlags: [["follow-up", "steer"]],
    target: { label: "Session", positionalIndex: 0 },
  },
  ...["stop", "resume"].map(
    (action): CommandDescriptor => ({
      command: "session",
      action,
      category: "nonDestructiveWrite",
      minPositionals: 1,
      maxPositionals: 1,
      flags: commandFlags(),
      target: { label: "Session", positionalIndex: 0 },
    }),
  ),
  {
    command: "session",
    action: "fork",
    category: "nonDestructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ entry: VALUE_FLAG, name: VALUE_FLAG }),
    requiredFlags: ["entry"],
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "session",
    action: "delete",
    category: "destructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags(),
    target: { label: "Session", positionalIndex: 0 },
  },
  {
    command: "schedule",
    action: "list",
    category: "read",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({ agent: VALUE_FLAG, session: VALUE_FLAG, workspace: VALUE_FLAG }),
  },
  {
    command: "schedule",
    action: "get",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags(),
    target: { label: "Schedule", positionalIndex: 0 },
  },
  {
    command: "schedule",
    action: "runs",
    category: "read",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ limit: VALUE_FLAG }),
    target: { label: "Schedule", positionalIndex: 0 },
  },
  {
    command: "schedule",
    action: "create",
    category: "nonDestructiveWrite",
    minPositionals: 0,
    maxPositionals: 0,
    flags: commandFlags({
      agent: VALUE_FLAG,
      at: VALUE_FLAG,
      cron: VALUE_FLAG,
      every: VALUE_FLAG,
      model: VALUE_FLAG,
      name: VALUE_FLAG,
      prompt: PROMPT_FLAG,
      session: VALUE_FLAG,
      tz: VALUE_FLAG,
      workspace: VALUE_FLAG,
      worktree: VALUE_FLAG,
    }),
    requiredFlags: ["prompt"],
    exactlyOneFlags: [
      ["workspace", "session"],
      ["at", "every", "cron"],
    ],
    target: { label: "Workspace", flag: "workspace", fallbackFlag: "session" },
  },
  {
    command: "schedule",
    action: "update",
    category: "nonDestructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({
      definition: DEFINITION_FILE_FLAG,
      "definition-json": DEFINITION_JSON_FLAG,
    }),
    exactlyOneFlags: [["definition", "definition-json"]],
    target: { label: "Schedule", positionalIndex: 0 },
  },
  {
    command: "schedule",
    action: "run",
    category: "nonDestructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags({ "request-id": VALUE_FLAG }),
    target: { label: "Schedule", positionalIndex: 0 },
  },
  ...["pause", "resume"].map(
    (action): CommandDescriptor => ({
      command: "schedule",
      action,
      category: "nonDestructiveWrite",
      minPositionals: 1,
      maxPositionals: 1,
      flags: commandFlags(),
      target: { label: "Schedule", positionalIndex: 0 },
    }),
  ),
  {
    command: "schedule",
    action: "archive",
    category: "destructiveWrite",
    minPositionals: 1,
    maxPositionals: 1,
    flags: commandFlags(),
    target: { label: "Schedule", positionalIndex: 0 },
  },
]);

const DESCRIPTORS_BY_KEY = new Map(
  COMMAND_DESCRIPTORS.map((descriptor) => [
    descriptorKey(descriptor.command, descriptor.action),
    descriptor,
  ]),
);

function descriptorKey(command: string, action: string | undefined): string {
  return action === undefined ? command : `${command}\u0000${action}`;
}

export function prepareOppiCommand(
  rawArgs: readonly string[],
  context: Readonly<{ callerSessionId?: string }> = {},
): PrepareOppiCommandResult {
  const normalizedArgs = [...rawArgs];
  if (normalizedArgs[0] === "oppi") normalizedArgs.shift();
  if (normalizedArgs.length === 0) return denied("oppi command args are required");
  if (normalizedArgs.some((arg) => arg.length === 0)) {
    return denied("oppi command arguments must not be empty");
  }
  const assignment = normalizedArgs.find((arg) => arg.startsWith("--") && arg.includes("="));
  if (assignment) {
    return denied(`Assignment-style flags are not supported: ${boundedInputName(assignment)}`);
  }

  let mutableParsed: ParsedCliArgs;
  try {
    mutableParsed = parseCliArgs(normalizedArgs);
  } catch (error) {
    return denied(errorMessage(error));
  }

  const helpPath = helpPathFor(mutableParsed);
  if (helpPath) {
    const topic = resolveHelpTopic(helpPath);
    if (!topic) return denied(`No allowlisted help topic for ${boundedHelpPath(helpPath)}`);
    const helpDescriptor = descriptorForParsed(mutableParsed);
    const flagError = validateHelpFlags(mutableParsed, helpDescriptor);
    if (flagError) return denied(flagError);
    return preparedResult({
      category: "read",
      command: mutableParsed.command,
      action: helpPath[1] ?? helpPath[0],
      normalizedArgs,
      parsed: mutableParsed,
      displayCommand: formatCommandForDisplay(normalizedArgs, helpDescriptor),
      summary: "Read Oppi command help.",
      helpPath,
      callerSessionId: context.callerSessionId,
    });
  }

  const descriptor = descriptorForParsed(mutableParsed);
  if (!descriptor) {
    return denied("This Oppi command or subcommand is not allowlisted");
  }
  const validationError = validateParsedCommand(mutableParsed, descriptor);
  if (validationError) return denied(validationError);

  const approvalDetails =
    descriptor.category === "read"
      ? undefined
      : buildOppiToolApprovalDetails(mutableParsed, descriptor);
  const summary = commandSummary(descriptor);
  return preparedResult({
    category: descriptor.category,
    command: descriptor.command,
    action: descriptor.action,
    normalizedArgs,
    parsed: mutableParsed,
    displayCommand: formatCommandForDisplay(normalizedArgs, descriptor),
    summary,
    ...(approvalDetails
      ? {
          approvalDetails,
          approvalMessage: formatOppiToolApprovalMessage(summary, approvalDetails),
        }
      : {}),
    callerSessionId: context.callerSessionId,
  });
}

function descriptorForParsed(parsed: ParsedCliArgs): CommandDescriptor | undefined {
  if (parsed.command === "status")
    return DESCRIPTORS_BY_KEY.get(descriptorKey("status", undefined));
  return DESCRIPTORS_BY_KEY.get(descriptorKey(parsed.command, parsed.positional[0]));
}

function validateHelpFlags(
  parsed: ParsedCliArgs,
  descriptor: CommandDescriptor | undefined,
): string | undefined {
  const rootFlags = commandFlags();
  for (const [flag, value] of Object.entries(parsed.flags)) {
    const flagDescriptor = descriptor?.flags[flag] ?? rootFlags[flag];
    if (!flagDescriptor) return `Unsupported flag for help: --${boundedInputName(flag)}`;
    const error = validateFlagValue(flag, value, flagDescriptor);
    if (error) return error;
  }
  return undefined;
}

function validateParsedCommand(
  parsed: ParsedCliArgs,
  descriptor: CommandDescriptor,
): string | undefined {
  const positional = descriptor.action ? parsed.positional.slice(1) : parsed.positional;
  if (
    positional.length < descriptor.minPositionals ||
    positional.length > descriptor.maxPositionals
  ) {
    return `Invalid positional argument count for oppi ${descriptor.command}${descriptor.action ? ` ${descriptor.action}` : ""}`;
  }
  if (positional.some((value) => value.trim().length === 0)) {
    return "Positional arguments must not be empty";
  }

  for (const [flag, value] of Object.entries(parsed.flags)) {
    const flagDescriptor = descriptor.flags[flag];
    if (!flagDescriptor) {
      return `Unsupported flag for oppi ${descriptor.command}${descriptor.action ? ` ${descriptor.action}` : ""}: --${boundedInputName(flag)}`;
    }
    const error = validateFlagValue(flag, value, flagDescriptor);
    if (error) return error;
    if (flagDescriptor.indirectBody) {
      return `--${flag} is not allowed because approval requires the complete body inline`;
    }
    if (flagDescriptor.bodyLabel && value === "@-") {
      return `--${flag} @- is not allowed because approval requires the complete body inline`;
    }
  }

  for (const flag of descriptor.requiredFlags ?? []) {
    if (!Object.hasOwn(parsed.flags, flag)) return `--${flag} is required`;
  }
  for (const group of descriptor.atLeastOneFlags ?? []) {
    if (!group.some((flag) => Object.hasOwn(parsed.flags, flag))) {
      return `At least one of ${group.map((flag) => `--${flag}`).join(", ")} is required`;
    }
  }
  for (const group of descriptor.exactlyOneFlags ?? []) {
    const present = group.filter((flag) => Object.hasOwn(parsed.flags, flag));
    // Agent create may omit both definition inputs when --name is present; all
    // other exactly-one groups are required by the command contract.
    const optionalDefinitionGroup =
      descriptor.command === "agent" &&
      descriptor.action === "create" &&
      group.includes("definition");
    if (present.length !== 1 && !(optionalDefinitionGroup && present.length === 0)) {
      return `Exactly one of ${group.map((flag) => `--${flag}`).join(", ")} is required`;
    }
  }
  for (const group of descriptor.atMostOneFlags ?? []) {
    const present = group.filter((flag) => Object.hasOwn(parsed.flags, flag));
    if (present.length > 1) {
      return `At most one of ${group.map((flag) => `--${flag}`).join(", ")} is allowed`;
    }
  }

  const inlineDefinition = parsed.flags["definition-json"];
  if (inlineDefinition !== undefined) {
    try {
      assertInlineDefinitionSize(inlineDefinition);
      const value = JSON.parse(inlineDefinition) as unknown;
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        return "--definition-json must be a JSON object";
      }
      if (
        (descriptor.command === "agent" || descriptor.command === "schedule") &&
        descriptor.action === "update" &&
        Object.keys(value).length === 0
      ) {
        return "--definition-json update must not be empty";
      }
    } catch (error) {
      return errorMessage(error).startsWith("--definition-json")
        ? errorMessage(error)
        : `--definition-json must be valid JSON: ${errorMessage(error)}`;
    }
  }
  return undefined;
}

function validateFlagValue(
  flag: string,
  value: string,
  descriptor: FlagDescriptor,
): string | undefined {
  if (descriptor.kind === "boolean") {
    return value === "true" ? undefined : `--${flag} does not accept a value`;
  }
  return value === "true" || value.trim().length === 0 ? `--${flag} requires a value` : undefined;
}

function preparedResult(input: {
  category: AllowedOppiToolCommandCategory;
  command: string;
  action?: string;
  normalizedArgs: string[];
  parsed: ParsedCliArgs;
  displayCommand: string;
  summary: string;
  approvalDetails?: OppiToolApprovalDetails;
  approvalMessage?: string;
  helpPath?: string[];
  callerSessionId?: string;
}): PrepareOppiCommandResult {
  const flags = Object.freeze(
    Object.assign(Object.create(null) as Record<string, string>, input.parsed.flags),
  );
  const parsed = Object.freeze({
    command: input.parsed.command,
    positional: Object.freeze([...input.parsed.positional]),
    flags,
  });
  const command = Object.freeze({
    category: input.category,
    ...(input.callerSessionId ? { callerSessionId: input.callerSessionId } : {}),
    command: input.command,
    ...(input.action !== undefined ? { action: input.action } : {}),
    normalizedArgs: Object.freeze([...input.normalizedArgs]),
    parsed,
    displayCommand: input.displayCommand,
    summary: input.summary,
    ...(input.approvalDetails
      ? { approvalDetails: freezeApprovalDetails(input.approvalDetails) }
      : {}),
    ...(input.approvalMessage ? { approvalMessage: input.approvalMessage } : {}),
    ...(input.helpPath ? { helpPath: Object.freeze([...input.helpPath]) } : {}),
  }) satisfies PreparedOppiCommand;
  authenticPreparedCommands.add(command);
  return Object.freeze({ ok: true, command });
}

function freezeApprovalDetails(details: OppiToolApprovalDetails): OppiToolApprovalDetails {
  return Object.freeze({
    action: details.action,
    category: details.category,
    ...(details.target ? { target: Object.freeze({ ...details.target }) } : {}),
    ...(details.context ? { context: Object.freeze({ ...details.context }) } : {}),
    arguments: Object.freeze([...details.arguments]),
    bodies: Object.freeze(details.bodies.map((body) => Object.freeze({ ...body }))),
  });
}

function denied(reason: string): PrepareOppiCommandResult {
  return Object.freeze({ ok: false, reason });
}

export async function executePreparedOppiCommand(options: {
  prepared: PreparedOppiCommand;
  dataDir?: string;
  cwd?: string;
}): Promise<OppiToolCommandResult> {
  if (!authenticPreparedCommands.has(options.prepared)) {
    return failureResult("Unrecognized prepared Oppi command", 1);
  }
  const prepared = options.prepared;
  assertNotSelfTargetingSession(preparedSessionTargets(prepared), prepared.callerSessionId);
  const connection = createCliConnectionConfig(options.dataDir);

  if (prepared.helpPath) return successResult(buildHelpEnvelope(prepared.helpPath));
  if (prepared.command === "status") return successResult(buildStatusEnvelope(connection));

  const parsed = prepared.parsed;
  const output = await captureCliOutput(async () => {
    await dispatchJsonCliCommand(
      connection,
      prepared.command,
      prepared.action,
      [...parsed.positional.slice(prepared.action ? 1 : 0)],
      { ...parsed.flags, json: "true" },
      options.cwd,
      prepared.callerSessionId,
    );
  });
  const parsedOutput = parseCliJsonOutput(output.stdout, output.exitCode);
  return { ...parsedOutput, stdout: output.stdout, exitCode: output.exitCode };
}

export async function runOppiToolCommand(options: {
  dataDir?: string;
  args: readonly string[];
  cwd?: string;
}): Promise<OppiToolCommandResult> {
  const result = prepareOppiCommand(options.args);
  if (!result.ok) return failureResult(result.reason, 1);
  return executePreparedOppiCommand({
    prepared: result.command,
    ...(options.dataDir !== undefined ? { dataDir: options.dataDir } : {}),
    ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
  });
}

async function dispatchJsonCliCommand(
  storage: LocalApiConnection,
  command: string,
  action: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  cwd?: string,
  callerSessionId?: string,
): Promise<void> {
  switch (command) {
    case "workspace":
      await cmdWorkspace(storage, action, positional, flags);
      return;
    case "worktree":
      await cmdWorktree(storage, action, positional, flags);
      return;
    case "agent":
      await cmdAgent(storage, action, positional, flags);
      return;
    case "session":
      await cmdSession(storage, action, positional, flags, cwd, { callerSessionId });
      return;
    case "schedule":
      await cmdSchedule(storage, action, positional, flags);
      return;
    default:
      throw new Error("Unsupported prepared Oppi command");
  }
}

export async function applyOppiToolPolicy(options: {
  prepared: PreparedOppiCommand;
  policy: OppiApprovalPolicy;
  identity: OppiToolIdentity;
  signal?: AbortSignal;
  approve?: (message: string) => Promise<boolean>;
  execute?: (prepared: PreparedOppiCommand) => Promise<OppiToolCommandResult>;
}): Promise<OppiToolPolicyResult> {
  const startedAt = Date.now();
  const prepared = options.prepared;
  if (!authenticPreparedCommands.has(prepared)) {
    audit(
      options.identity,
      "denied",
      options.policy,
      "denied",
      "not-required",
      "denied",
      startedAt,
    );
    throw new Error("Unrecognized prepared Oppi command");
  }

  if (options.signal?.aborted) {
    auditPrepared(options, "aborted", "denied", startedAt);
    return { kind: "cancelled", reason: "aborted" };
  }
  if (options.policy === "readOnly" && prepared.category !== "read") {
    auditPrepared(options, "not-required", "read-only", startedAt);
    throw new Error(OPPI_EXTENSION_READ_ONLY_ERROR);
  }

  const approvalRequired =
    prepared.category !== "read" &&
    (options.policy === "confirmAllChanges" || prepared.category === "destructiveWrite");
  let approvalOutcome = "not-required";
  if (approvalRequired) {
    if (!options.approve) {
      auditPrepared(options, "missing-ui", "denied", startedAt);
      throw new Error(OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR);
    }
    let approved: boolean;
    try {
      approved = await options.approve(prepared.approvalMessage ?? prepared.summary);
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

function auditPrepared(
  options: {
    prepared: PreparedOppiCommand;
    policy: OppiApprovalPolicy;
    identity: OppiToolIdentity;
  },
  outcome: string,
  result: string,
  startedAt: number,
): void {
  audit(
    options.identity,
    options.prepared.category,
    options.policy,
    normalizedAction(options.prepared),
    outcome,
    result,
    startedAt,
  );
}

function audit(
  identity: OppiToolIdentity,
  category: OppiToolCommandCategory,
  policy: OppiApprovalPolicy,
  action: string,
  outcome: string,
  result: string,
  startedAt: number,
): void {
  log.info("oppi_tool.audit", {
    identity,
    category,
    policy,
    action,
    outcome,
    result,
    duration: Math.min(MAX_AUDIT_DURATION_MS, Math.max(0, Date.now() - startedAt)),
  });
}

export function createOppiToolExtensionFactory(options: {
  dataDir?: string;
  policySnapshot: Readonly<{ approvalPolicy: OppiApprovalPolicy }>;
  identity: OppiToolIdentity;
  callerSessionId: string;
}): ExtensionFactory {
  const policy = options.policySnapshot.approvalPolicy;
  const identity = options.identity;
  const dataDir = options.dataDir;
  const callerSessionId = options.callerSessionId;
  return (pi) => {
    pi.registerTool({
      name: "oppi",
      label: "Oppi",
      description:
        "Run an allowlisted Oppi CLI command as JSON under the configured server approval policy.",
      promptSnippet:
        "Run allowlisted Oppi CLI commands as JSON for workspaces, worktrees, Agents, sessions, schedules, and status.",
      promptGuidelines: [
        "Use oppi for Oppi app state instead of shell or filesystem tools.",
        "Use oppi read commands before asking the user about discoverable workspace, Agent, session, schedule, or worktree state.",
        "Use oppi session search and oppi session inspect for past Oppi session history instead of local JSONL-reading tools.",
        "Inspect session history progressively: start with session inspect <id> --view summary, then use --view outline; stop there when previews answer the question, otherwise request messages or tools for the smallest relevant turn set.",
        "Use session trace-outline only when exact entry ids are needed, followed by trace-page --around-entry or tool-output for bounded detail.",
        "Use oppi session inspect <id> --view response when only the latest assistant response is needed.",
        "Use Oppi mutation commands only after the user asks for them; the configured policy controls approval.",
      ],
      parameters: Type.Object({
        args: Type.Array(Type.String(), {
          description:
            "Command arguments without the leading 'oppi', for example ['workspace','list'] or ['session','create','--workspace','oppi','--prompt','Review this']. Output is always JSON.",
        }),
      }),
      executionMode: "sequential",
      async execute(_toolCallId, params, signal, onUpdate, ctx) {
        const preparedResultValue = prepareOppiCommand(params.args, { callerSessionId });
        if (!preparedResultValue.ok) {
          const startedAt = Date.now();
          audit(identity, "denied", policy, "denied", "not-required", "denied", startedAt);
          throw new Error(preparedResultValue.reason);
        }
        const prepared = preparedResultValue.command;
        const hasConfirm =
          ctx.hasUI && typeof (ctx.ui as { confirm?: unknown }).confirm === "function";
        const policyResult = await applyOppiToolPolicy({
          prepared,
          policy,
          identity,
          ...(signal ? { signal } : {}),
          ...(hasConfirm
            ? {
                approve: (message: string) => ctx.ui.confirm("Approve Oppi command", message),
              }
            : {}),
          execute: async (approvedCommand) => {
            onUpdate?.({
              content: [
                { type: "text" as const, text: `Running ${approvedCommand.displayCommand}` },
              ],
              details: { category: approvedCommand.category },
            });
            return executePreparedOppiCommand({
              prepared: approvedCommand,
              ...(dataDir !== undefined ? { dataDir } : {}),
              ...(typeof ctx.cwd === "string" ? { cwd: ctx.cwd } : {}),
            });
          },
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
            details: { cancelled: true, reason: policyResult.reason },
          };
        }
        if (!policyResult.result.ok) {
          throw new Error(
            policyResult.result.error?.message ??
              `oppi command failed with exit ${policyResult.result.exitCode}`,
          );
        }
        return {
          content: [
            { type: "text" as const, text: truncateToolOutput(policyResult.result.stdout) },
          ],
          details: buildOppiToolResultDetails(prepared, policyResult.result.data),
        };
      },
    });
  };
}

export type OppiToolCommandKind = "read" | "approved-write";
export type OppiToolCommandClassification =
  | ({
      readonly ok: true;
      readonly kind: OppiToolCommandKind;
      readonly args: readonly string[];
    } & PreparedOppiCommand)
  | { readonly ok: false; readonly reason: string };

export function classifyOppiToolCommand(rawArgs: readonly string[]): OppiToolCommandClassification {
  const result = prepareOppiCommand(rawArgs);
  if (!result.ok) return result;
  return Object.freeze({
    ok: true,
    ...result.command,
    kind: result.command.category === "read" ? "read" : "approved-write",
    args: result.command.normalizedArgs,
  });
}

export function buildOppiToolResultDetails(
  command: PreparedOppiCommand | Extract<OppiToolCommandClassification, { ok: true }>,
  data: unknown,
): Record<string, unknown> {
  return {
    args: [...command.normalizedArgs],
    kind: command.category === "read" ? "read" : "approved-write",
    category: command.category,
    data,
    expandedText: truncateToolOutput(formatOppiToolExpandedText(command, data)),
    presentationFormat: "markdown",
  };
}

export function formatOppiToolExpandedText(
  command: PreparedOppiCommand | Extract<OppiToolCommandClassification, { ok: true }>,
  data: unknown,
): string {
  const titleParts = ["Oppi", command.command, command.action].filter(Boolean);
  const sections = [
    `# ${titleParts.map((part) => escapeMarkdownInline(part ?? "")).join(" ")}`,
    "## Command",
    markdownInlineCode(command.displayCommand),
  ];
  const descriptor = DESCRIPTORS_BY_KEY.get(descriptorKey(command.command, command.action));
  if (descriptor) {
    const request = buildOppiToolApprovalDetails(command.parsed, descriptor);
    const requestRows: string[] = [];
    if (request.target) {
      requestRows.push(
        `- **${escapeMarkdownInline(request.target.label)}:** ${markdownRequestValue(request.target.value)}`,
      );
    }
    if (request.context) {
      requestRows.push(
        `- **${escapeMarkdownInline(request.context.label)}:** ${markdownRequestValue(request.context.value)}`,
      );
    }
    if (request.arguments.length > 0) {
      requestRows.push(`- **Arguments:** ${markdownRequestValue(request.arguments.join(" "))}`);
    }
    if (requestRows.length > 0) sections.push("## Request", requestRows.join("\n"));
    for (const body of request.bodies) {
      sections.push(`## ${escapeMarkdownInline(body.label)}`, formatOppiToolBody(body));
    }
  }
  if (command.command === "session" && command.action === "search") {
    sections.push(formatSessionSearchResult(data));
  } else if (command.command === "session" && command.action === "send") {
    const delivery = formatSessionSendResult(data);
    if (delivery) sections.push(delivery);
    else sections.push("## Result", formatHumanValue(data));
  } else {
    sections.push("## Result", formatHumanValue(data));
  }
  return sections.join("\n\n");
}

function formatOppiToolBody(body: Readonly<{ label: string; value: string }>): string {
  const value = sanitizeDisplayText(body.value);
  if (body.label !== "Definition") {
    return value
      .split("\n")
      .map((line) => `> ${line}`)
      .join("\n");
  }
  try {
    return `\`\`\`json\n${JSON.stringify(JSON.parse(value) as unknown, null, 2)}\n\`\`\``;
  } catch {
    return fencedText(value);
  }
}

function markdownRequestValue(value: string): string {
  const oneLine = singleLineDisplayString(value);
  return oneLine.includes("`") ? escapeMarkdownInline(oneLine) : markdownInlineCode(oneLine);
}

function commandSummary(descriptor: CommandDescriptor): string {
  const action = normalizedDescriptorAction(descriptor);
  switch (descriptor.category) {
    case "read":
      return `Read Oppi state with ${action}.`;
    case "nonDestructiveWrite":
      return `Create or modify Oppi state with ${action}.`;
    case "destructiveWrite":
      return `Run destructive Oppi command ${action}.`;
  }
}

function buildOppiToolApprovalDetails(
  parsed: Readonly<{
    command: string;
    positional: readonly string[];
    flags: Readonly<Record<string, string>>;
  }>,
  descriptor: CommandDescriptor,
): OppiToolApprovalDetails {
  const action = normalizedDescriptorAction(descriptor);
  const targetValue = resolveTargetValue(parsed, descriptor.target);
  const target =
    descriptor.target && targetValue !== undefined
      ? { label: targetLabelForValue(descriptor.target, parsed), value: targetValue }
      : undefined;
  const contextValue = descriptor.contextFlag
    ? parsed.flags[descriptor.contextFlag.flag]
    : undefined;
  const context =
    descriptor.contextFlag && contextValue !== undefined
      ? { label: descriptor.contextFlag.label, value: contextValue }
      : undefined;
  const bodies = Object.entries(descriptor.flags).flatMap(([flag, flagDescriptor]) =>
    flagDescriptor.bodyLabel && Object.hasOwn(parsed.flags, flag)
      ? [{ label: flagDescriptor.bodyLabel, value: parsed.flags[flag] ?? "" }]
      : [],
  );

  const consumedPositional = new Set<number>();
  if (descriptor.target?.positionalIndex !== undefined) {
    consumedPositional.add(descriptor.target.positionalIndex);
  }
  const actionOffset = descriptor.action ? 1 : 0;
  const remainingArguments = parsed.positional
    .slice(actionOffset)
    .flatMap((value, index) =>
      consumedPositional.has(index) ? [] : [shellQuoteForDisplay(value)],
    );
  const excludedFlags = new Set([
    "json",
    "help",
    "h",
    ...(descriptor.target?.flag ? [descriptor.target.flag] : []),
    ...(descriptor.target?.fallbackFlag ? [descriptor.target.fallbackFlag] : []),
    ...(descriptor.contextFlag ? [descriptor.contextFlag.flag] : []),
    ...Object.entries(descriptor.flags).flatMap(([flag, value]) => (value.bodyLabel ? [flag] : [])),
  ]);
  for (const [flag, value] of Object.entries(parsed.flags)) {
    if (excludedFlags.has(flag)) continue;
    remainingArguments.push(`--${flag}`);
    if (value !== "true") remainingArguments.push(shellQuoteForDisplay(value));
  }
  return {
    action,
    category: descriptor.category,
    target,
    context,
    arguments: remainingArguments,
    bodies,
  };
}

function resolveTargetValue(
  parsed: Readonly<{
    command: string;
    positional: readonly string[];
    flags: Readonly<Record<string, string>>;
  }>,
  target: ApprovalTargetDescriptor | undefined,
): string | undefined {
  if (!target) return undefined;
  if (target.positionalIndex !== undefined) {
    return parsed.positional[(parsed.command === "status" ? 0 : 1) + target.positionalIndex];
  }
  if (target.flag && parsed.flags[target.flag] !== undefined) return parsed.flags[target.flag];
  return target.fallbackFlag ? parsed.flags[target.fallbackFlag] : undefined;
}

function targetLabelForValue(
  target: ApprovalTargetDescriptor,
  parsed: Readonly<{ flags: Readonly<Record<string, string>> }>,
): string {
  return target.fallbackFlag && parsed.flags[target.flag ?? ""] === undefined
    ? target.fallbackFlag === "session"
      ? "Session"
      : target.label
    : target.label;
}

function formatOppiToolApprovalMessage(summary: string, details: OppiToolApprovalDetails): string {
  const sections = [
    summary,
    "## Category",
    categoryLabel(details.category),
    "## Command",
    fencedText(details.action),
  ];
  if (details.target) sections.push(`## ${details.target.label}`, fencedText(details.target.value));
  if (details.context) {
    sections.push(`## ${details.context.label}`, fencedText(details.context.value));
  }
  if (details.arguments.length > 0) {
    sections.push("## Arguments", fencedText(details.arguments.join(" ")));
  }
  for (const body of details.bodies) sections.push(`## ${body.label}`, fencedText(body.value));
  return sections.join("\n\n");
}

function categoryLabel(category: AllowedOppiToolCommandCategory): string {
  switch (category) {
    case "read":
      return "Read";
    case "nonDestructiveWrite":
      return "Non-destructive write";
    case "destructiveWrite":
      return "Destructive write";
  }
}

function helpPathFor(parsed: ParsedCliArgs): string[] | undefined {
  if (parsed.command === "help") return parsed.positional.filter((part) => part !== "help");
  if (parsed.positional[0] === "help") return [parsed.command, ...parsed.positional.slice(1)];
  if (isHelpFlag(parsed.flags)) return [parsed.command, ...parsed.positional];
  return undefined;
}

function buildHelpEnvelope(path: readonly string[]): CliJsonEnvelope {
  const topic = resolveHelpTopic(path);
  if (!topic) throw new Error("Prepared help topic is unavailable");
  return { ok: true, data: { help: helpTopicToJson(topic) } };
}

function buildStatusEnvelope(storage: LocalApiConnection): CliJsonEnvelope {
  const config = storage.getConfig();
  return {
    ok: true,
    data: {
      status: {
        paired: !!storage.getToken(),
        dataDir: storage.getDataDir(),
        server: {
          host: config.host,
          port: config.port,
          transport: tlsSchemeForConfig(config),
          tlsMode: config.tls?.mode ?? "disabled",
        },
      },
    },
  };
}

function parseCliJsonOutput(stdout: string, exitCode: number): OppiToolCommandResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout || "{}");
  } catch {
    return failureResult("Invalid JSON output from Oppi CLI command", exitCode || 1, stdout);
  }
  if (isCliEnvelope(parsed)) {
    if (parsed.ok) return { ok: true, exitCode, stdout, data: parsed.data };
    return { ok: false, exitCode: exitCode || 1, stdout, error: parsed.error };
  }
  return { ok: exitCode === 0, exitCode, stdout, data: parsed };
}

function successResult(envelope: CliJsonEnvelope): OppiToolCommandResult {
  return {
    ok: true,
    exitCode: 0,
    stdout: `${JSON.stringify(envelope, null, 2)}\n`,
    data: envelope.ok ? envelope.data : undefined,
  };
}

function failureResult(message: string, exitCode: number, stdout = ""): OppiToolCommandResult {
  return { ok: false, exitCode, stdout, error: { message } };
}

function preparedSessionTargets(prepared: PreparedOppiCommand): string[] {
  const guardedActions = new Set([
    "get",
    "send",
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
  ]);
  if (
    prepared.command !== "session" ||
    prepared.action === undefined ||
    !guardedActions.has(prepared.action)
  ) {
    return [];
  }
  const target = prepared.parsed.positional[1]?.trim();
  if (!target) return [];
  return [target];
}

function normalizedDescriptorAction(descriptor: CommandDescriptor): string {
  return `oppi ${descriptor.command}${descriptor.action ? ` ${descriptor.action}` : ""}`;
}

function normalizedAction(prepared: PreparedOppiCommand): string {
  return `oppi ${prepared.command}${prepared.action ? ` ${prepared.action}` : ""}`;
}

function formatCommandForDisplay(
  args: readonly string[],
  descriptor: CommandDescriptor | undefined,
): string {
  const displayed: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    displayed.push(arg.length > 160 ? `[${arg.length} chars]` : arg);
    const flag = arg.startsWith("--") ? arg.slice(2) : "";
    if (!descriptor?.flags[flag]?.bodyLabel) continue;
    const body = args[index + 1];
    if (body === undefined) continue;
    displayed.push(`[${body.length} chars]`);
    index += 1;
  }
  return `oppi ${displayed.join(" ")}`;
}

function formatSessionSendResult(data: unknown): string | undefined {
  const payload = asDisplayRecord(data);
  const sessionId = displayString(payload?.session_id);
  const command = displayString(payload?.command);
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId) || !["prompt", "steer", "follow_up"].includes(command)) {
    return undefined;
  }

  const status = command === "follow_up" ? "Queued" : "Sent";
  const handling =
    command === "follow_up"
      ? "After the current turn"
      : command === "steer"
        ? "Redirects the active turn"
        : "Starts an idle session or redirects the active turn";
  const sessionLink = `oppi://session/${encodeURIComponent(sessionId)}`;
  return [
    "## Delivery",
    `- **Status:** ${status}`,
    `- **Handling:** ${handling}`,
    `- **Session:** [Open ${markdownInlineCode(sessionId)}](${sessionLink})`,
  ].join("\n");
}

function formatSessionSearchResult(data: unknown): string {
  const payload = asDisplayRecord(data);
  const rows = Array.isArray(payload?.results) ? payload.results : [];
  const total = typeof payload?.total_results === "number" ? payload.total_results : rows.length;
  if (rows.length === 0) return `## Search results (${total})\n\nNo matching sessions.`;
  const renderedRows = rows.map((value, index) => {
    const row = asDisplayRecord(value) ?? {};
    const title = singleLineDisplayString(row.title) || `Result ${index + 1}`;
    const snippet = displayString(row.snippet);
    const metadata: string[] = [];
    const sessionId = displayString(row.session_id);
    const workspaceId = displayString(row.workspace_id);
    const rank = typeof row.rank === "number" ? row.rank : undefined;
    if (sessionId) metadata.push(markdownInlineCode(sessionId));
    if (workspaceId) metadata.push(`workspace ${markdownInlineCode(workspaceId)}`);
    if (rank !== undefined) metadata.push(`rank ${rank.toFixed(2)}`);
    return [
      `### ${escapeMarkdownInline(title)}`,
      snippet ? escapeMarkdownText(snippet) : undefined,
      metadata.length > 0 ? metadata.join(" · ") : undefined,
    ]
      .filter(Boolean)
      .join("\n\n");
  });
  return [`## Search results (${total})`, ...renderedRows].join("\n\n");
}

function formatHumanValue(value: unknown, depth = 0): string {
  if (value === undefined || value === null) return "No result data.";
  if (typeof value === "string") return escapeMarkdownText(value);
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") {
    return String(value);
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return "No rows.";
    return value
      .map((item) => `- ${formatHumanValue(item, depth + 1).replaceAll("\n", "\n  ")}`)
      .join("\n");
  }
  const record = asDisplayRecord(value);
  if (!record) return escapeMarkdownText(String(value));
  const entries = Object.entries(record);
  if (entries.length === 0) return "No details returned.";
  if (depth >= 3) return markdownInlineCode(JSON.stringify(record));
  return entries
    .map(([key, item]) => {
      const label = escapeMarkdownInline(humanizeDisplayKey(key));
      const rendered = formatHumanValue(item, depth + 1);
      return `- **${label}:** ${rendered.replaceAll("\n", "\n  ")}`;
    })
    .join("\n");
}

function asDisplayRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function displayString(value: unknown): string {
  return typeof value === "string" ? sanitizeDisplayText(value).trim() : "";
}

function singleLineDisplayString(value: unknown): string {
  return displayString(value).replace(/\s+/g, " ");
}

function humanizeDisplayKey(key: string): string {
  const words = singleLineDisplayString(key)
    .replaceAll("_", " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2");
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function escapeMarkdownText(value: string): string {
  return escapeMarkdownInline(value)
    .split("\n")
    .map((line) => (line.length > 0 ? `\u2060${line}` : line))
    .join("\n");
}

function escapeMarkdownInline(value: string): string {
  return sanitizeDisplayText(value).replace(/([\\`*_{}[\]<>|])/g, "\\$1");
}

function sanitizeDisplayText(value: string): string {
  return Array.from(value.replaceAll("\r\n", "\n").replaceAll("\r", "\n"))
    .filter((character) => {
      const codePoint = character.codePointAt(0) ?? 0;
      return character === "\n" || character === "\t" || codePoint >= 0x20;
    })
    .join("");
}

function markdownInlineCode(value: string): string {
  return value.includes("`") ? fencedText(value) : `\`${value}\``;
}

function fencedText(value: string): string {
  const longestBacktickRun = longestCharacterRun(value, "`");
  if (longestBacktickRun < 3) return `\`\`\`text\n${value}\n\`\`\``;
  const longestTildeRun = longestCharacterRun(value, "~");
  if (longestTildeRun < 3) return `~~~text\n${value}\n~~~`;
  return value
    .split("\n")
    .map((line) => `    ${line}`)
    .join("\n");
}

function longestCharacterRun(value: string, character: "`" | "~"): number {
  const pattern = character === "`" ? /`+/g : /~+/g;
  return Math.max(0, ...Array.from(value.matchAll(pattern), (match) => match[0].length));
}

function shellQuoteForDisplay(value: string): string {
  return /^[A-Za-z0-9_@%+=:,./-]+$/.test(value) ? value : `'${value.replaceAll("'", `'\\''`)}'`;
}

function truncateToolOutput(output: string): string {
  if (output.length <= MAX_TOOL_OUTPUT_CHARS) return output;
  const omitted = output.length - MAX_TOOL_OUTPUT_CHARS;
  return `${output.slice(0, MAX_TOOL_OUTPUT_CHARS)}\n\n[Output truncated: omitted ${omitted} characters]`;
}

function boundedInputName(value: string): string {
  return value.slice(0, 80);
}

function boundedHelpPath(path: readonly string[]): string {
  return path.map(boundedInputName).join(" ").slice(0, 160) || "help";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isCliEnvelope(value: unknown): value is CliJsonEnvelope {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const envelope = value as { ok?: unknown };
  return envelope.ok === true || envelope.ok === false;
}
