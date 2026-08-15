import * as c from "../ansi.js";
import { safeErrorMessage } from "../log-utils.js";
import { parseCliArgs } from "./args.js";
import { cmdAgent } from "./commands/agent.js";
import { cmdConfig } from "./commands/config.js";
import { cmdSchedule } from "./commands/schedule.js";
import { cmdSession } from "./commands/session.js";
import { cmdWait } from "./commands/wait.js";
import { createAbortError, throwIfAborted } from "./local-api-client.js";
import { cmdWorkspace } from "./commands/workspace.js";
import { cmdWorktree } from "./commands/worktree.js";
import { createCliConfigStorage, createCliConnectionConfig } from "./connection-config.js";
import { helpPathFor, isNestedHelpRequest, resolveHelpTopic, writeCliHelpOutput } from "./help.js";
import { cmdQuota } from "./quota.js";
import {
  captureCliOutput,
  captureHumanCliOutput,
  setCapturedCliExitCode,
  type CliJsonEnvelope,
  writeHumanLine,
  writeJsonEnvelope,
} from "./output.js";
import { cmdStatus } from "./status.js";

export type CliRunOptions = Readonly<{
  dataDir?: string;
  cwd?: string;
  callerSessionId?: string;
  captureHuman?: boolean;
  forceJson?: boolean;
  signal?: AbortSignal;
}>;

export type CliRunResult = Readonly<{
  ok: boolean;
  exitCode: number;
  stdout: string;
  humanOutput: string;
  json?: CliJsonEnvelope;
  error?: { message: string; status?: number };
}>;

export async function runCli(
  args: readonly string[],
  options: CliRunOptions = {},
): Promise<CliRunResult> {
  throwIfAborted(options.signal);
  const invocationArgs = options.forceJson ? ensureJsonFlag(args) : [...args];
  if (!options.captureHuman) {
    await executeCliCommand(invocationArgs, options);
    throwIfAborted(options.signal);
    return { ok: true, exitCode: 0, stdout: "", humanOutput: "" };
  }

  const captured = await captureCliOutput(
    async () => {
      try {
        await executeCliCommand(invocationArgs, options);
        throwIfAborted(options.signal);
      } catch (error: unknown) {
        if (options.signal?.aborted) throw createAbortError(options.signal);
        const message = safeErrorMessage(error);
        writeJsonEnvelope({ ok: false, error: { message } });
        setCapturedCliExitCode(1);
        captureHumanCliOutput(() => writeHumanLine(c.red(`  Error: ${message}`)));
      }
    },
    { includeHuman: true },
  );
  const json = parseCliJsonEnvelope(captured.stdout);
  if (!json) {
    const error = { message: "CLI command did not produce a valid JSON envelope" };
    return {
      ok: false,
      exitCode: captured.exitCode || 1,
      stdout: `${JSON.stringify({ ok: false, error }, null, 2)}\n`,
      humanOutput: captured.humanStdout || renderCapturedError(error.message),
      error,
    };
  }

  const error = json.ok ? undefined : json.error;
  return {
    ok: captured.exitCode === 0 && json.ok,
    exitCode: error ? captured.exitCode || 1 : captured.exitCode,
    stdout: captured.stdout,
    humanOutput:
      captured.humanStdout || (error ? renderCapturedError(error.message) : captured.humanStdout),
    json,
    ...(error ? { error } : {}),
  };
}

async function executeCliCommand(args: readonly string[], options: CliRunOptions): Promise<void> {
  const { command, flags, positional } = parseCliArgs([...args]);
  if (isNestedHelpRequest(command, positional, flags)) {
    const topic = resolveHelpTopic(helpPathFor(command, positional));
    if (!topic) {
      writeJsonEnvelope({
        ok: false,
        error: { message: "No help topic for the requested command" },
      });
      setCapturedCliExitCode(1);
      captureHumanCliOutput(() => writeHumanLine(c.red("No help topic for the requested command")));
      return;
    }
    writeCliHelpOutput(topic, flags.json === "true");
    return;
  }

  const dataDir = options.dataDir ?? process.env.OPPI_DATA_DIR ?? undefined;
  const connection = createCliConnectionConfig(dataDir);
  switch (command) {
    case "status":
      cmdStatus(connection, flags.json === "true");
      return;
    case "quota":
      await cmdQuota(connection, flags.json === "true", options.signal);
      return;
    case "agent":
      await cmdAgent(connection, positional[0], positional.slice(1), flags);
      return;
    case "workspace":
      await cmdWorkspace(connection, positional[0], positional.slice(1), flags);
      return;
    case "worktree":
      await cmdWorktree(connection, positional[0], positional.slice(1), flags);
      return;
    case "session":
      await cmdSession(
        connection,
        positional[0],
        positional.slice(1),
        flags,
        options.cwd ?? process.cwd(),
        options.callerSessionId || options.signal
          ? {
              ...(options.callerSessionId ? { callerSessionId: options.callerSessionId } : {}),
              ...(options.signal ? { signal: options.signal } : {}),
            }
          : undefined,
      );
      return;
    case "schedule":
      await cmdSchedule(connection, positional[0], positional.slice(1), flags);
      return;
    case "wait":
      await cmdWait(connection, positional[0], positional.slice(1), flags, options.signal);
      return;
    case "config":
      cmdConfig(createCliConfigStorage(dataDir), positional[0], positional.slice(1), flags);
      return;
    default:
      writeJsonEnvelope({ ok: false, error: { message: `Unknown command: ${command}` } });
      setCapturedCliExitCode(1);
      captureHumanCliOutput(() => writeHumanLine(c.red(`Unknown command: ${command}`)));
  }
}

function ensureJsonFlag(args: readonly string[]): string[] {
  const separator = args.indexOf("--");
  const flagArgs = separator === -1 ? args : args.slice(0, separator);
  const positionalArgs = separator === -1 ? [] : args.slice(separator);
  const normalized: string[] = [];

  for (let index = 0; index < flagArgs.length; index += 1) {
    const arg = flagArgs[index];
    if (arg !== "--json") {
      if (arg !== undefined) normalized.push(arg);
      continue;
    }

    const value = flagArgs[index + 1];
    if (value && !value.startsWith("--")) index += 1;
  }

  return [...normalized, "--json", ...positionalArgs];
}

function renderCapturedError(message: string): string {
  return c.withAnsiCapture(() => `${c.red(`  Error: ${message}`)}\n`);
}

function parseCliJsonEnvelope(stdout: string): CliJsonEnvelope | undefined {
  if (!stdout.trim()) return undefined;
  try {
    const value: unknown = JSON.parse(stdout);
    if (!isRecord(value)) return undefined;
    if (value.ok === true && isRecord(value.data)) {
      return value as CliJsonEnvelope;
    }
    if (
      value.ok === false &&
      isRecord(value.error) &&
      typeof value.error.message === "string" &&
      (value.error.status === undefined || typeof value.error.status === "number")
    ) {
      return value as CliJsonEnvelope;
    }
  } catch {}
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
