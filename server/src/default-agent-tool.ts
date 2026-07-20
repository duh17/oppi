import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { isHelpFlag, parseCliArgs, type ParsedCliArgs } from "./cli/args.js";
import { createCliConnectionConfig } from "./cli/connection-config.js";
import { cmdAgent } from "./cli/commands/agent.js";
import { cmdSchedule } from "./cli/commands/schedule.js";
import { cmdSession } from "./cli/commands/session.js";
import { cmdWorkspace } from "./cli/commands/workspace.js";
import { cmdWorktree } from "./cli/commands/worktree.js";
import { helpTopicToJson, resolveHelpTopic } from "./cli/help.js";
import { captureCliOutput, type CliJsonEnvelope } from "./cli/output.js";
import type { LocalApiConnection } from "./cli/local-api-client.js";
import { assertInlineDefinitionSize } from "./cli/definition-input.js";
import { tlsSchemeForConfig } from "./tls.js";

export type OppiToolCommandKind = "read" | "approved-write";

export interface OppiToolApprovalDetails {
  action: string;
  target?: { label: string; value: string };
  context?: { label: string; value: string };
  arguments: string[];
  bodies: Array<{ label: string; value: string }>;
}

export type OppiToolCommandClassification =
  | {
      ok: true;
      kind: OppiToolCommandKind;
      command: string;
      action?: string;
      args: string[];
      summary: string;
      displayCommand: string;
      approvalDetails?: OppiToolApprovalDetails;
      approvalMessage?: string;
    }
  | { ok: false; reason: string };

export interface OppiToolCommandResult {
  ok: boolean;
  exitCode: number;
  stdout: string;
  data?: unknown;
  error?: { message: string; status?: number };
}

const READ_ACTIONS: Record<string, Set<string>> = {
  workspace: new Set(["list", "get"]),
  worktree: new Set(["list", "get", "status", "preview"]),
  agent: new Set(["list", "get"]),
  session: new Set([
    "list",
    "get",
    "read",
    "events",
    "trace",
    "search",
    "inspect",
    "changes",
    "diff",
    "tool-output",
    "trace-page",
    "trace-outline",
  ]),
  schedule: new Set(["list", "get", "runs"]),
};

const WRITE_ACTIONS: Record<string, Set<string>> = {
  workspace: new Set(["create", "update"]),
  agent: new Set(["create", "update"]),
  session: new Set(["create", "send", "stop", "resume", "fork"]),
  worktree: new Set(["create", "open", "remove"]),
  schedule: new Set(["create", "update", "run", "pause", "resume"]),
};

const DESTRUCTIVE_ACTIONS: Record<string, Set<string>> = {
  workspace: new Set(["delete", "remove"]),
  worktree: new Set(["remove"]),
  agent: new Set(["archive"]),
  session: new Set(["delete"]),
  schedule: new Set(["archive"]),
};

const MAX_TOOL_OUTPUT_CHARS = 50_000;

export function createDefaultAgentExtensionFactory(options: {
  dataDir?: string;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "oppi",
      label: "Oppi",
      description:
        "Run an allowlisted Oppi CLI command as JSON. Read commands are immediate; commands that create or modify Oppi state require explicit user approval.",
      promptSnippet:
        "Run allowlisted Oppi CLI commands as JSON for workspaces, worktrees, Agents, sessions, schedules, and status.",
      promptGuidelines: [
        "Use oppi for Oppi app state instead of shell or filesystem tools.",
        "Use oppi read commands before asking the user about discoverable workspace, Agent, session, schedule, or worktree state.",
        "Use oppi session search and oppi session inspect for past Oppi session history instead of local JSONL-reading tools.",
        "Inspect session history progressively: start with session inspect <id> --view summary, then use --view outline; stop there when previews answer the question, otherwise request messages or tools for the smallest relevant turn set.",
        "Use session trace-outline only when exact entry ids are needed, followed by trace-page --around-entry or tool-output for bounded detail.",
        "Use oppi session inspect <id> --view response when only the latest assistant response is needed.",
        "Use oppi commands that create or modify Oppi state only after the user asks for them; they will request explicit approval.",
      ],
      parameters: Type.Object({
        args: Type.Array(Type.String(), {
          description:
            "Command arguments without the leading 'oppi', for example ['workspace','list'] or ['session','create','--workspace','oppi','--prompt','Review this']. Output is always JSON.",
        }),
      }),
      executionMode: "sequential",
      async execute(_toolCallId, params, signal, onUpdate, ctx) {
        const classification = classifyOppiToolCommand(params.args);
        if (!classification.ok) {
          throw new Error(classification.reason);
        }

        if (classification.kind === "approved-write") {
          if (!ctx.hasUI) {
            throw new Error("This Oppi command requires UI approval, but no UI is available");
          }
          const approved = await ctx.ui.confirm(
            "Approve Oppi command",
            classification.approvalMessage ?? classification.summary,
          );
          if (!approved) {
            return {
              content: [{ type: "text" as const, text: "Oppi command cancelled by user." }],
              details: { args: classification.args, cancelled: true },
            };
          }
        }

        if (signal?.aborted) {
          return {
            content: [{ type: "text" as const, text: "Oppi command cancelled." }],
            details: { args: classification.args, cancelled: true },
          };
        }

        onUpdate?.({
          content: [{ type: "text" as const, text: `Running ${classification.displayCommand}` }],
          details: { args: classification.args, kind: classification.kind },
        });

        const result = await runOppiToolCommand({
          dataDir: options.dataDir,
          args: classification.args,
          cwd: typeof ctx.cwd === "string" ? ctx.cwd : undefined,
        });
        if (!result.ok) {
          throw new Error(
            result.error?.message ?? `oppi command failed with exit ${result.exitCode}`,
          );
        }

        return {
          content: [{ type: "text" as const, text: truncateToolOutput(result.stdout) }],
          details: {
            args: classification.args,
            kind: classification.kind,
            data: result.data,
          },
        };
      },
    });
  };
}

function isHelpRequest(parsed: ParsedCliArgs): boolean {
  return parsed.command === "help" || isHelpFlag(parsed.flags) || parsed.positional[0] === "help";
}

function helpPathFor(parsed: ParsedCliArgs): string[] {
  if (parsed.command === "help") return parsed.positional.filter((part) => part !== "help");
  if (parsed.positional[0] === "help") return [parsed.command, ...parsed.positional.slice(1)];
  return [parsed.command, ...parsed.positional.filter((part) => part !== "help")];
}

function isDestructiveCommand(parsed: ParsedCliArgs): boolean {
  const action = parsed.positional[0] || "list";
  return DESTRUCTIVE_ACTIONS[parsed.command]?.has(action) === true;
}

export function classifyOppiToolCommand(rawArgs: string[]): OppiToolCommandClassification {
  const args = normalizeOppiArgs(rawArgs);
  if (args.length === 0) {
    return { ok: false, reason: "oppi command args are required" };
  }

  const parsed = parseCliArgs(args);
  try {
    assertInlineDefinitionSize(parsed.flags["definition-json"]);
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : String(error) };
  }
  const displayCommand = formatCommandForDisplay(args);
  if (isHelpRequest(parsed)) {
    return {
      ok: true,
      kind: "read",
      command: parsed.command,
      action: parsed.positional[0],
      args,
      summary: "Read Oppi command help.",
      displayCommand,
    };
  }

  if (parsed.command === "status") {
    return {
      ok: true,
      kind: "read",
      command: parsed.command,
      args,
      summary: "Read server status.",
      displayCommand,
    };
  }

  const action = parsed.positional[0] || "list";
  if (READ_ACTIONS[parsed.command]?.has(action)) {
    return {
      ok: true,
      kind: "read",
      command: parsed.command,
      action,
      args,
      summary: `Read ${parsed.command} ${action}.`,
      displayCommand,
    };
  }

  const indirectBodyError = validateInspectableBody(parsed);
  if (indirectBodyError) {
    return { ok: false, reason: indirectBodyError };
  }

  if (isDestructiveCommand(parsed)) {
    return approvedWriteClassification({
      parsed,
      args,
      action,
      summary: `Run destructive Oppi command ${parsed.command} ${action}.`,
      displayCommand,
    });
  }

  if (WRITE_ACTIONS[parsed.command]?.has(action)) {
    return approvedWriteClassification({
      parsed,
      args,
      action,
      summary: `Create or modify Oppi state with ${parsed.command} ${action}.`,
      displayCommand,
    });
  }

  return {
    ok: false,
    reason: `oppi ${parsed.command}${action ? ` ${action}` : ""} is not allowed for the Default Agent`,
  };
}

export async function runOppiToolCommand(options: {
  dataDir?: string;
  args: string[];
  cwd?: string;
}): Promise<OppiToolCommandResult> {
  const classification = classifyOppiToolCommand(options.args);
  if (!classification.ok) {
    return failureResult(classification.reason, 1);
  }

  const connection = createCliConnectionConfig(options.dataDir);
  const args = ensureJsonFlag(classification.args);
  const parsed = parseCliArgs(args);

  if (isHelpRequest(parsed)) {
    return successResult(buildHelpEnvelope(parsed));
  }

  if (parsed.command === "status") {
    return successResult(buildStatusEnvelope(connection));
  }

  const output = await captureCliJsonOutput(async () => {
    await dispatchJsonCliCommand(connection, parsed, options.cwd);
  });

  const parsedOutput = parseCliJsonOutput(output.stdout, output.exitCode);
  return {
    ...parsedOutput,
    stdout: output.stdout,
    exitCode: output.exitCode,
  };
}

async function dispatchJsonCliCommand(
  storage: LocalApiConnection,
  parsed: ParsedCliArgs,
  cwd?: string,
): Promise<void> {
  switch (parsed.command) {
    case "workspace":
      await cmdWorkspace(storage, parsed.positional[0], parsed.positional.slice(1), parsed.flags);
      return;
    case "worktree":
      await cmdWorktree(storage, parsed.positional[0], parsed.positional.slice(1), parsed.flags);
      return;
    case "agent":
      await cmdAgent(storage, parsed.positional[0], parsed.positional.slice(1), parsed.flags);
      return;
    case "session":
      await cmdSession(
        storage,
        parsed.positional[0],
        parsed.positional.slice(1),
        parsed.flags,
        cwd,
      );
      return;
    case "schedule":
      await cmdSchedule(storage, parsed.positional[0], parsed.positional.slice(1), parsed.flags);
      return;
    default:
      throw new Error(`Unsupported Oppi command: ${parsed.command}`);
  }
}

async function captureCliJsonOutput(
  fn: () => Promise<void>,
): Promise<{ stdout: string; exitCode: number }> {
  const previousExitCode = process.exitCode;
  try {
    process.exitCode = undefined;
    const { stdout } = await captureCliOutput(fn);
    return { stdout, exitCode: typeof process.exitCode === "number" ? process.exitCode : 0 };
  } finally {
    process.exitCode = previousExitCode;
  }
}

function parseCliJsonOutput(stdout: string, exitCode: number): OppiToolCommandResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout || "{}");
  } catch {
    return failureResult("Invalid JSON output from Oppi CLI command", exitCode || 1, stdout);
  }

  if (isCliEnvelope(parsed)) {
    if (parsed.ok) {
      return { ok: true, exitCode, stdout, data: parsed.data };
    }
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

function buildHelpEnvelope(parsed: ParsedCliArgs): CliJsonEnvelope {
  const path = helpPathFor(parsed);
  const topic = resolveHelpTopic(path);
  if (!topic) throw new Error(`No help topic for ${path.join(" ") || "help"}`);
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

function normalizeOppiArgs(rawArgs: string[]): string[] {
  const args = rawArgs.map((arg) => arg.trim()).filter((arg) => arg.length > 0);
  return args[0] === "oppi" ? args.slice(1) : args;
}

function ensureJsonFlag(args: string[]): string[] {
  return args.includes("--json") ? args : [...args, "--json"];
}

function approvedWriteClassification(options: {
  parsed: ParsedCliArgs;
  args: string[];
  action: string;
  summary: string;
  displayCommand: string;
}): Extract<OppiToolCommandClassification, { ok: true }> {
  const approvalDetails = buildOppiToolApprovalDetails(options.parsed, options.action);
  return {
    ok: true,
    kind: "approved-write",
    command: options.parsed.command,
    action: options.action,
    args: options.args,
    summary: options.summary,
    displayCommand: options.displayCommand,
    approvalDetails,
    approvalMessage: formatOppiToolApprovalMessage(options.summary, approvalDetails),
  };
}

const APPROVAL_BODY_FLAGS: Record<string, { label: string }> = {
  prompt: { label: "Prompt" },
  text: { label: "Message" },
  "definition-json": { label: "Definition" },
  "system-prompt": { label: "System prompt" },
};

function validateInspectableBody(parsed: ParsedCliArgs): string | undefined {
  if (Object.hasOwn(parsed.flags, "definition")) {
    return "--definition is not allowed for approval because file contents can change; pass the complete body inline with --definition-json";
  }
  for (const flag of ["prompt", "text"] as const) {
    if (parsed.flags[flag] === "@-") {
      return `--${flag} @- is not allowed for approval; pass the complete body inline with --${flag}`;
    }
  }
  return undefined;
}

function buildOppiToolApprovalDetails(
  parsed: ParsedCliArgs,
  action: string,
): OppiToolApprovalDetails {
  const bodies = Object.entries(APPROVAL_BODY_FLAGS).flatMap(([flag, presentation]) =>
    Object.hasOwn(parsed.flags, flag)
      ? [{ label: presentation.label, value: parsed.flags[flag] ?? "" }]
      : [],
  );

  const workspace = parsed.flags.workspace;
  const positionalTarget = parsed.positional[1];
  const flaggedTarget =
    parsed.command === "schedule" && action === "create" ? parsed.flags.session : undefined;
  const target = positionalTarget
    ? { label: targetLabel(parsed.command), value: positionalTarget }
    : flaggedTarget
      ? { label: "Session", value: flaggedTarget }
      : workspace
        ? { label: "Workspace", value: workspace }
        : undefined;
  const context =
    workspace && target?.label !== "Workspace"
      ? { label: "Workspace", value: workspace }
      : undefined;

  const remainingArguments: string[] = [];
  const remainingPositional = positionalTarget
    ? parsed.positional.slice(2)
    : parsed.positional.slice(1);
  remainingArguments.push(...remainingPositional.map(shellQuoteForDisplay));

  for (const [flag, value] of Object.entries(parsed.flags)) {
    if (
      flag === "json" ||
      flag === "workspace" ||
      (flag === "session" && flaggedTarget !== undefined) ||
      Object.hasOwn(APPROVAL_BODY_FLAGS, flag)
    ) {
      continue;
    }
    remainingArguments.push(`--${flag}`);
    if (value !== "true") {
      remainingArguments.push(shellQuoteForDisplay(value));
    }
  }

  return {
    action: `oppi ${shellQuoteForDisplay(parsed.command)} ${shellQuoteForDisplay(action)}`,
    target,
    context,
    arguments: remainingArguments,
    bodies,
  };
}

function targetLabel(command: string): string {
  switch (command) {
    case "agent":
      return "Agent";
    case "schedule":
      return "Schedule";
    case "session":
      return "Session";
    case "workspace":
      return "Workspace";
    case "worktree":
      return "Worktree";
    default:
      return "Target";
  }
}

function formatOppiToolApprovalMessage(summary: string, details: OppiToolApprovalDetails): string {
  const sections = [summary, "## Command", fencedText(details.action)];
  if (details.target) {
    sections.push(`## ${details.target.label}`, fencedText(details.target.value));
  }
  if (details.context) {
    sections.push(`## ${details.context.label}`, fencedText(details.context.value));
  }
  if (details.arguments.length > 0) {
    sections.push("## Arguments", fencedText(details.arguments.join(" ")));
  }
  for (const body of details.bodies) {
    sections.push(`## ${body.label}`, fencedText(body.value));
  }
  return sections.join("\n\n");
}

function fencedText(value: string): string {
  const longestBacktickRun = longestCharacterRun(value, "`");
  if (longestBacktickRun < 3) {
    return `\`\`\`text\n${value}\n\`\`\``;
  }

  const longestTildeRun = longestCharacterRun(value, "~");
  if (longestTildeRun < 3) {
    return `~~~text\n${value}\n~~~`;
  }

  // Oppi's Markdown parser performs compatibility cleanup on 4+ character
  // fences. Indented code avoids that path when untrusted content contains
  // both fence styles, preserving every displayed line as inert code.
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
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(value)) return value;
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function formatCommandForDisplay(args: string[]): string {
  const displayed = args.map((arg) => (arg.length > 160 ? `[${arg.length} chars]` : arg));
  return `oppi ${displayed.join(" ")}`;
}

function truncateToolOutput(output: string): string {
  if (output.length <= MAX_TOOL_OUTPUT_CHARS) return output;
  const omitted = output.length - MAX_TOOL_OUTPUT_CHARS;
  return `${output.slice(0, MAX_TOOL_OUTPUT_CHARS)}\n\n[Output truncated: omitted ${omitted} characters]`;
}

function isCliEnvelope(value: unknown): value is CliJsonEnvelope {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const envelope = value as { ok?: unknown; data?: unknown; error?: unknown };
  return envelope.ok === true || envelope.ok === false;
}
