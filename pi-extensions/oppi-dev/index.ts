import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "../../server/node_modules/typebox/build/index.mjs";

const OPPI_ROOT = join(homedir(), "workspace", "oppi");
const WORKFLOW_SCRIPT = join(homedir(), ".pi", "agent", "skills", "oppi-dev", "scripts", "oppi-workflow.sh");
const DEFAULT_TIMEOUT_MS = 15 * 60 * 1000;
const INSTALL_TIMEOUT_MS = 30 * 60 * 1000;
const RESTART_TIMEOUT_MS = 10 * 60 * 1000;
const MAX_OUTPUT_CHARS = 48_000;

type TextContent = { type: "text"; text: string };
type ToolResult = {
  content: TextContent[];
  details?: Record<string, unknown>;
  terminate?: boolean;
};

type ExecResult = {
  stdout: string;
  stderr: string;
  code: number;
  killed: boolean;
};

const InstallParams = Type.Object({
  mode: Type.Optional(
    Type.Union([Type.Literal("install"), Type.Literal("dev-install")], {
      description: "install = Release device install. dev-install = fast Debug active-arch install. Default: install.",
    }),
  ),
  launch: Type.Optional(Type.Boolean({ description: "Launch the app after installing. Default: true." })),
});

const ServerRestartParams = Type.Object({
  mode: Type.Optional(
    Type.Union(
      [Type.Literal("fast"), Type.Literal("default"), Type.Literal("no-build"), Type.Literal("dry-run")],
      {
        description:
          "fast = incremental dev restart. default = clean build/sync/restart. no-build = restart only. dry-run = print planned actions. Default: fast.",
      },
    ),
  ),
});

const LiveDebugParams = Type.Object({
  action: Type.Union(
    [
      Type.Literal("live-start"),
      Type.Literal("live-check"),
      Type.Literal("live-stop"),
      Type.Literal("debug-session"),
      Type.Literal("diagnostics"),
      Type.Literal("metrics"),
      Type.Literal("server-log"),
      Type.Literal("build-errors"),
      Type.Literal("tool-analysis"),
    ],
    { description: "Diagnostic lane to run through oppi-workflow.sh." },
  ),
  grep: Type.Optional(Type.String({ description: "Optional grep filter for live-check." })),
  session: Type.Optional(Type.String({ description: "Session id for debug-session. Defaults to latest." })),
  level: Type.Optional(
    Type.Union([Type.Literal("summary"), Type.Literal("events"), Type.Literal("logs"), Type.Literal("full")], {
      description: "debug-session detail level. Default: summary.",
    }),
  ),
  last: Type.Optional(Type.String({ description: "Time window for debug-session, for example 45m." })),
  since: Type.Optional(Type.String({ description: "ISO timestamp for debug-session." })),
  days: Type.Optional(Type.Integer({ description: "Days to inspect for diagnostics, metrics, logs, and analyses. Default: 1.", minimum: 1, maximum: 30 })),
  external: Type.Optional(Type.Boolean({ description: "Include external diagnostics where supported. Default: false." })),
  limit: Type.Optional(Type.Integer({ description: "Row limit for server-log. Default: 30.", minimum: 1, maximum: 500 })),
});

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function commandLine(args: string[]): string {
  return ["bash", WORKFLOW_SCRIPT, ...args].map(shellQuote).join(" ");
}

function truncateTail(value: string): { text: string; truncated: boolean; omittedChars: number } {
  if (value.length <= MAX_OUTPUT_CHARS) {
    return { text: value, truncated: false, omittedChars: 0 };
  }
  const omittedChars = value.length - MAX_OUTPUT_CHARS;
  return {
    text: `[Output truncated: omitted ${omittedChars.toLocaleString()} leading chars]\n${value.slice(-MAX_OUTPUT_CHARS)}`,
    truncated: true,
    omittedChars,
  };
}

function combinedOutput(result: ExecResult): string {
  const parts: string[] = [];
  if (result.stdout.trim()) parts.push(result.stdout.trimEnd());
  if (result.stderr.trim()) parts.push(`[stderr]\n${result.stderr.trimEnd()}`);
  return parts.join("\n\n");
}

function successLabel(result: ExecResult): string {
  if (result.killed) return "KILLED";
  return result.code === 0 ? "PASS" : "FAIL";
}

function cancellationResult(label: string, args: string[]): ToolResult {
  return {
    content: [
      {
        type: "text",
        text: `${label} cancelled by user.\ncommand: ${commandLine(args)}`,
      },
    ],
    details: {
      approved: false,
      command: "bash",
      args: [WORKFLOW_SCRIPT, ...args],
    },
    terminate: true,
  };
}

async function requireApproval(ctx: any, label: string, args: string[], reason: string): Promise<boolean> {
  if (!ctx.hasUI) {
    throw new Error(`${label} requires extension UI approval, but no UI is available.`);
  }

  return ctx.ui.confirm(
    `Approve ${label}?`,
    [reason, "", "Command:", commandLine(args), "", "Run this Oppi development lane now?"].join("\n"),
  );
}

async function runWorkflow(
  pi: ExtensionAPI,
  ctx: any,
  label: string,
  args: string[],
  reason: string,
  timeoutMs: number,
  signal: AbortSignal | undefined,
  onUpdate: ((result: { content: TextContent[]; details?: Record<string, unknown> }) => void) | undefined,
): Promise<ToolResult> {
  onUpdate?.({
    content: [{ type: "text", text: `Waiting for approval: ${label}\n${commandLine(args)}` }],
    details: { status: "awaiting_approval", command: "bash", args: [WORKFLOW_SCRIPT, ...args] },
  });

  const approved = await requireApproval(ctx, label, args, reason);
  if (!approved) return cancellationResult(label, args);

  ctx.ui.setStatus?.("oppi-dev", `running ${label}`);
  onUpdate?.({
    content: [{ type: "text", text: `Running ${label}…\n${commandLine(args)}` }],
    details: { status: "running", command: "bash", args: [WORKFLOW_SCRIPT, ...args] },
  });

  try {
    const result = (await pi.exec("bash", [WORKFLOW_SCRIPT, ...args], {
      cwd: OPPI_ROOT,
      signal,
      timeout: timeoutMs,
    })) as ExecResult;
    const output = truncateTail(combinedOutput(result) || "(no output)");
    const status = successLabel(result);
    const text = [
      `${label} ${status}`,
      `command: ${commandLine(args)}`,
      `exit code: ${result.code}${result.killed ? " (killed)" : ""}`,
      `cwd: ${OPPI_ROOT}`,
      "",
      output.text,
    ].join("\n");

    return {
      content: [{ type: "text", text }],
      details: {
        approved: true,
        status,
        command: "bash",
        args: [WORKFLOW_SCRIPT, ...args],
        cwd: OPPI_ROOT,
        exitCode: result.code,
        killed: result.killed,
        outputTruncated: output.truncated,
        omittedChars: output.omittedChars,
      },
    };
  } finally {
    ctx.ui.setStatus?.("oppi-dev", undefined);
  }
}

function installArgs(params: { mode?: string; launch?: boolean }): string[] {
  const mode = params.mode ?? "install";
  const launch = params.launch !== false;
  if (mode === "dev-install") {
    return launch ? ["dev-install"] : ["install", "--fast", "--no-launch"];
  }
  return launch ? ["install"] : ["install", "--no-launch"];
}

function restartArgs(params: { mode?: string }): string[] {
  switch (params.mode ?? "fast") {
    case "default":
      return ["server-restart"];
    case "no-build":
      return ["server-restart", "--no-build"];
    case "dry-run":
      return ["server-restart", "--dry-run"];
    case "fast":
    default:
      return ["server-restart", "--fast"];
  }
}

function liveDebugArgs(params: {
  action: string;
  grep?: string;
  session?: string;
  level?: string;
  last?: string;
  since?: string;
  days?: number;
  external?: boolean;
  limit?: number;
}): string[] {
  const days = String(params.days ?? 1);
  switch (params.action) {
    case "live-start":
      return ["live", "start"];
    case "live-check":
      return params.grep?.trim() ? ["live", "check", "--grep", params.grep.trim()] : ["live", "check"];
    case "live-stop":
      return ["live", "stop"];
    case "debug-session": {
      const args = ["debug"];
      if (params.last?.trim()) args.push("--last", params.last.trim());
      else args.push("--session", params.session?.trim() || "latest");
      if (params.since?.trim()) args.push("--since", params.since.trim());
      args.push("--level", params.level ?? "summary");
      return args;
    }
    case "diagnostics":
      return params.external ? ["diagnostics", "--days", days, "--external"] : ["diagnostics", "--days", days];
    case "metrics":
      return ["metrics", "--days", days];
    case "server-log":
      return ["server-log", "--days", days, "--limit", String(params.limit ?? 30)];
    case "build-errors":
      return ["build-errors", "--days", days];
    case "tool-analysis":
      return ["tool-analysis", "--days", days];
    default:
      throw new Error(`Unsupported Oppi live debug action: ${params.action}`);
  }
}

function isOppiInstallOrRestartCommand(command: string): boolean {
  return /\boppi-workflow\.sh\s+(?:install|dev-install|server-restart)\b/i.test(command) ||
    /\boppi-dev\/scripts\/(?:install|server-restart)\.sh\b/i.test(command);
}

export default function oppiDevExtension(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "oppi_install",
    label: "Oppi Install",
    description: "Install and optionally launch the Oppi iOS app on Duh Ifone through the approved Oppi workflow.",
    promptSnippet: "Install or fast-install the Oppi iOS app with extension UI approval",
    promptGuidelines: [
      "Use oppi_install instead of bash when the user asks to install, reinstall, or launch the Oppi iOS app.",
      "oppi_install asks the user for extension UI approval before running the device install lane.",
    ],
    parameters: InstallParams,
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const args = installArgs(params);
      const reason = params.mode === "dev-install"
        ? "Fast Debug device install changes the app installed on Duh Ifone."
        : "Release device install changes the app installed on Duh Ifone.";
      return runWorkflow(pi, ctx, "Oppi install", args, reason, INSTALL_TIMEOUT_MS, signal, onUpdate);
    },
  });

  pi.registerTool({
    name: "oppi_server_restart",
    label: "Oppi Server Restart",
    description: "Build/sync/restart the local Oppi server runtime through the approved Oppi workflow.",
    promptSnippet: "Restart the Oppi dev server with extension UI approval",
    promptGuidelines: [
      "Use oppi_server_restart instead of bash when the user asks to restart the Oppi server or dev server.",
      "oppi_server_restart asks the user for extension UI approval before changing the running server.",
      "Use oppi_server_restart mode=fast for normal local iteration, mode=default for a clean server build, and mode=no-build only when the user asked for restart-only.",
    ],
    parameters: ServerRestartParams,
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const args = restartArgs(params);
      return runWorkflow(
        pi,
        ctx,
        "Oppi server restart",
        args,
        "Restarting the Oppi server can interrupt active app sessions and changes the local runtime.",
        RESTART_TIMEOUT_MS,
        signal,
        onUpdate,
      );
    },
  });

  pi.registerTool({
    name: "oppi_live_debug",
    label: "Oppi Live Debug",
    description: "Run approved Oppi live debugging, diagnostics, metrics, and session inspection lanes.",
    promptSnippet: "Run Oppi live diagnostics or focused session debugging with extension UI approval",
    promptGuidelines: [
      "Use oppi_live_debug for Oppi live debug, diagnostics, metrics, server-log, build-errors, and tool-analysis lanes instead of manually composing oppi-workflow.sh commands.",
      "oppi_live_debug asks the user for extension UI approval before running live diagnostics commands.",
    ],
    parameters: LiveDebugParams,
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const args = liveDebugArgs(params);
      return runWorkflow(
        pi,
        ctx,
        "Oppi live debug",
        args,
        "This reads live Oppi diagnostics/logs or starts/stops the live triage helper.",
        DEFAULT_TIMEOUT_MS,
        signal,
        onUpdate,
      );
    },
  });

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return undefined;
    const command = typeof event.input.command === "string" ? event.input.command : "";
    if (!isOppiInstallOrRestartCommand(command)) return undefined;

    if (!ctx.hasUI) {
      return {
        block: true,
        reason: "Oppi install/server restart requires extension UI approval; use oppi_install or oppi_server_restart.",
      };
    }

    const approved = await ctx.ui.confirm(
      "Approve direct Oppi workflow command?",
      [
        "This command installs the app or restarts the Oppi server.",
        "Prefer oppi_install or oppi_server_restart for this workflow.",
        "",
        "Command:",
        command,
        "",
        "Run it anyway?",
      ].join("\n"),
    );

    if (!approved) {
      return {
        block: true,
        reason: "Blocked by user. Use oppi_install or oppi_server_restart when approval is needed.",
      };
    }
    return undefined;
  });
}
