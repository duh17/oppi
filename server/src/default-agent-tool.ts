import { execFileSync } from "node:child_process";

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
import type { LocalApiConnection, LocalApiHostResolvers } from "./cli/local-api-client.js";
import { tlsSchemeForConfig } from "./tls.js";

export type OppiToolCommandKind = "read" | "approved-write";

export type OppiToolCommandClassification =
  | {
      ok: true;
      kind: OppiToolCommandKind;
      command: string;
      action?: string;
      args: string[];
      summary: string;
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
    "messages",
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
        "Use oppi session messages when only the latest assistant response is needed.",
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
            [`oppi ${classification.args.join(" ")}`, "", classification.summary].join("\n"),
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
          content: [
            { type: "text" as const, text: `Running oppi ${classification.args.join(" ")}` },
          ],
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
  if (isHelpRequest(parsed)) {
    return {
      ok: true,
      kind: "read",
      command: parsed.command,
      action: parsed.positional[0],
      args,
      summary: "Read Oppi command help.",
    };
  }

  if (parsed.command === "status") {
    return {
      ok: true,
      kind: "read",
      command: parsed.command,
      args,
      summary: "Read server status.",
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
    };
  }

  if (isDestructiveCommand(parsed)) {
    return {
      ok: true,
      kind: "approved-write",
      command: parsed.command,
      action,
      args,
      summary: `Run destructive Oppi command ${parsed.command} ${action}.`,
    };
  }

  if (WRITE_ACTIONS[parsed.command]?.has(action)) {
    return {
      ok: true,
      kind: "approved-write",
      command: parsed.command,
      action,
      args,
      summary: `Create or modify Oppi state with ${parsed.command} ${action}.`,
    };
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

  const hostResolvers = buildLocalApiHostResolvers();
  const output = await captureCliJsonOutput(async () => {
    await dispatchJsonCliCommand(connection, parsed, hostResolvers, options.cwd);
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
  hostResolvers: LocalApiHostResolvers,
  cwd?: string,
): Promise<void> {
  switch (parsed.command) {
    case "workspace":
      await cmdWorkspace(
        storage,
        parsed.positional[0],
        parsed.positional.slice(1),
        parsed.flags,
        hostResolvers,
      );
      return;
    case "worktree":
      await cmdWorktree(
        storage,
        parsed.positional[0],
        parsed.positional.slice(1),
        parsed.flags,
        hostResolvers,
      );
      return;
    case "agent":
      await cmdAgent(
        storage,
        parsed.positional[0],
        parsed.positional.slice(1),
        parsed.flags,
        hostResolvers,
      );
      return;
    case "session":
      await cmdSession(
        storage,
        parsed.positional[0],
        parsed.positional.slice(1),
        parsed.flags,
        hostResolvers,
        cwd,
      );
      return;
    case "schedule":
      await cmdSchedule(
        storage,
        parsed.positional[0],
        parsed.positional.slice(1),
        parsed.flags,
        hostResolvers,
      );
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

function truncateToolOutput(output: string): string {
  if (output.length <= MAX_TOOL_OUTPUT_CHARS) return output;
  const omitted = output.length - MAX_TOOL_OUTPUT_CHARS;
  return `${output.slice(0, MAX_TOOL_OUTPUT_CHARS)}\n\n[Output truncated: omitted ${omitted} characters]`;
}

function buildLocalApiHostResolvers(): LocalApiHostResolvers {
  return {
    tailscaleHostname: () => {
      try {
        const result = execFileSync("tailscale", ["status", "--json"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        });
        const status = JSON.parse(result) as { Self?: { DNSName?: unknown } };
        return typeof status.Self?.DNSName === "string"
          ? status.Self.DNSName.replace(/\.$/, "")
          : null;
      } catch {
        return null;
      }
    },
    tailscaleIp: () => {
      try {
        return (
          execFileSync("tailscale", ["ip", "-4"], {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "ignore"],
          })
            .trim()
            .split("\n")[0] ?? null
        );
      } catch {
        return null;
      }
    },
  };
}

function isCliEnvelope(value: unknown): value is CliJsonEnvelope {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const envelope = value as { ok?: unknown; data?: unknown; error?: unknown };
  return envelope.ok === true || envelope.ok === false;
}
