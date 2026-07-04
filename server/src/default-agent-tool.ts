import { execFileSync } from "node:child_process";

import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { Storage } from "./storage.js";
import { parseCliArgs, type ParsedCliArgs } from "./cli/args.js";
import { cmdAgent } from "./cli/commands/agent.js";
import { cmdSchedule } from "./cli/commands/schedule.js";
import { cmdSession } from "./cli/commands/session.js";
import { cmdWorkspace } from "./cli/commands/workspace.js";
import { cmdWorktree } from "./cli/commands/worktree.js";
import { captureCliOutput, type CliJsonEnvelope } from "./cli/output.js";
import type { LocalApiHostResolvers } from "./cli/local-api-client.js";
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
  worktree: new Set(["list", "get"]),
  agent: new Set(["list", "get"]),
  session: new Set(["list", "get", "read", "events", "trace"]),
  schedule: new Set(["list", "get", "runs"]),
};

const APPROVED_WRITE_ACTIONS: Record<string, Set<string>> = {
  session: new Set(["create"]),
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
        "Run an allowlisted Oppi CLI command as JSON. Read commands are immediate; session creation requires explicit user approval.",
      promptSnippet:
        "Run allowlisted Oppi CLI commands as JSON for workspaces, worktrees, Agents, sessions, schedules, and status.",
      promptGuidelines: [
        "Use oppi for Oppi app state instead of shell or filesystem tools.",
        "Use oppi read commands before asking the user about discoverable workspace, Agent, session, schedule, or worktree state.",
        "Use oppi session create only after the user has asked to start work in a workspace; the tool will request explicit approval before creating the session.",
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

export function classifyOppiToolCommand(rawArgs: string[]): OppiToolCommandClassification {
  const args = normalizeOppiArgs(rawArgs);
  if (args.length === 0) {
    return { ok: false, reason: "oppi command args are required" };
  }

  const parsed = parseCliArgs(args);
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

  if (APPROVED_WRITE_ACTIONS[parsed.command]?.has(action)) {
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
}): Promise<OppiToolCommandResult> {
  const classification = classifyOppiToolCommand(options.args);
  if (!classification.ok) {
    return failureResult(classification.reason, 1);
  }

  const storage = new Storage(options.dataDir);
  const args = ensureJsonFlag(classification.args);
  const parsed = parseCliArgs(args);

  if (parsed.command === "status") {
    return successResult(buildStatusEnvelope(storage));
  }

  const hostResolvers = buildLocalApiHostResolvers();
  const output = await captureCliJsonOutput(async () => {
    await dispatchJsonCliCommand(storage, parsed, hostResolvers);
  });

  const parsedOutput = parseCliJsonOutput(output.stdout, output.exitCode);
  return {
    ...parsedOutput,
    stdout: output.stdout,
    exitCode: output.exitCode,
  };
}

async function dispatchJsonCliCommand(
  storage: Storage,
  parsed: ParsedCliArgs,
  hostResolvers: LocalApiHostResolvers,
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

function buildStatusEnvelope(storage: Storage): CliJsonEnvelope {
  const config = storage.getConfig();
  const sessions = storage.listSessions();
  return {
    ok: true,
    data: {
      status: {
        paired: storage.isPaired(),
        sessionCount: sessions.length,
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
