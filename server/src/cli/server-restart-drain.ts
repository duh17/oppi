import type { ServerDrainStatus, DrainSession } from "../server-drain.js";
import { safeErrorMessage } from "../log-utils.js";
import * as c from "../ansi.js";
import { createCliConnectionConfig, type CliConnectionConfig } from "./connection-config.js";
import { localApiRequest, type LocalApiError } from "./local-api-client.js";
import { writeHumanLine, writeJsonEnvelope } from "./output.js";
import { parseDurationMs } from "./commands/wait.js";

/** Exit code when the running server predates drain restarts (no `/server/restart`). */
export const DRAIN_UNSUPPORTED_EXIT_CODE = 4;
/** How long `--wait` keeps waiting past the deadline for the restarted server to answer. */
const WAIT_GRACE_MS = 5 * 60_000;
const WAIT_POLL_MS = 2_000;

const MODE_FLAGS = ["drain", "status", "cancel"] as const;

/**
 * Whether `oppi server restart` names a drain flag. A drain-only option without `--drain`
 * (`--max-wait 30m`) lands here too, so it is refused instead of restarting at once.
 */
export function usesDrainRestartFlags(flags: Record<string, string>): boolean {
  return (
    MODE_FLAGS.some((flag) => flags[flag] === "true") ||
    flags.wait !== undefined ||
    flags["max-wait"] !== undefined
  );
}

/**
 * `oppi server restart --drain [--max-wait <duration>] [--wait]`, `--cancel`, and `--status`:
 * ask the server that owns this data directory to restart itself once running turns finish,
 * cancel that, or show it.
 */
export async function cmdServerRestartDrain(flags: Record<string, string>): Promise<void> {
  const json = flags.json === "true";
  const modes = MODE_FLAGS.filter((flag) => flags[flag] === "true");
  if (modes.length !== 1) {
    return fail(json, "Pass exactly one of --drain, --status, or --cancel", 1);
  }
  const mode = modes[0];
  if (mode !== "drain" && (flags.wait !== undefined || flags["max-wait"] !== undefined)) {
    return fail(json, "--wait and --max-wait go with --drain", 1);
  }
  let maxWaitMs: number | undefined;
  if (mode === "drain" && flags["max-wait"] !== undefined) {
    try {
      maxWaitMs = parseDurationMs(flags["max-wait"]);
    } catch (error) {
      return fail(json, safeErrorMessage(error), 1);
    }
  }
  const connection = createCliConnectionConfig(process.env.OPPI_DATA_DIR || undefined);
  const requestedAt = Date.now();
  let status: ServerDrainStatus;
  try {
    const result = await localApiRequest<{ restart: ServerDrainStatus }>(
      connection,
      "/server/restart",
      mode === "cancel"
        ? { method: "DELETE" }
        : mode === "status"
          ? {}
          : { method: "POST", body: maxWaitMs !== undefined ? { maxWaitMs } : {} },
    );
    status = result.restart;
  } catch (error) {
    if ((error as LocalApiError).status === 404) {
      return fail(
        json,
        "The running server predates drain restarts; restart it with `oppi server restart`",
        DRAIN_UNSUPPORTED_EXIT_CODE,
      );
    }
    return fail(json, safeErrorMessage(error), 1);
  }

  if (mode === "drain" && flags.wait === "true") {
    if (!json) printPending(status);
    const outcome = await waitForRestart(connection, requestedAt, status);
    if (outcome !== "restarted") {
      return fail(
        json,
        outcome === "cancelled"
          ? "The restart was cancelled"
          : "The server did not come back after the restart",
        1,
      );
    }
    if (json) writeJsonEnvelope({ ok: true, data: { restart: status, restarted: true } });
    else writeHumanLine(c.green("  ✓ The server restarted\n"));
    return;
  }

  if (json) {
    writeJsonEnvelope({ ok: true, data: { restart: status } });
    return;
  }
  if (mode === "cancel") {
    writeHumanLine(c.green("  ✓ Restart cancelled"));
    if (status.heldInputs > 0) {
      writeHumanLine(c.dim(`    Sending ${status.heldInputs} held message(s) now.`));
    }
    writeHumanLine("");
    return;
  }
  if (mode === "status" && status.state === "idle") {
    writeHumanLine(c.dim("  No restart is pending.\n"));
    return;
  }
  printPending(status);
}

/**
 * Wait until a server that started after `requestedAt` answers this data directory's socket.
 * The restart re-execs the same process, so its uptime, not its pid, shows the new start.
 */
async function waitForRestart(
  connection: CliConnectionConfig,
  requestedAt: number,
  pending: ServerDrainStatus,
): Promise<"restarted" | "cancelled" | "timeout"> {
  const deadline = (pending.deadlineAt ?? requestedAt) + WAIT_GRACE_MS;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, WAIT_POLL_MS));
    try {
      const info = await localApiRequest<{ uptime?: number }>(connection, "/server/info", {
        signal: AbortSignal.timeout(5_000),
      });
      const startedAt = Date.now() - (info.uptime ?? Infinity) * 1_000;
      // Uptime is whole seconds: allow one second of rounding.
      if (startedAt > requestedAt - 1_000) return "restarted";
      const { restart } = await localApiRequest<{ restart: ServerDrainStatus }>(
        connection,
        "/server/restart",
        { signal: AbortSignal.timeout(5_000) },
      );
      if (restart.state === "idle") return "cancelled";
    } catch {
      // Down while it restarts.
    }
  }
  return "timeout";
}

function printPending(status: ServerDrainStatus): void {
  if (status.state === "restarting") {
    writeHumanLine(c.green("  ✓ Running turns finished; the server is restarting"));
    writeHumanLine("");
    return;
  }
  const deadline = status.deadlineAt ? new Date(status.deadlineAt).toLocaleTimeString() : "?";
  writeHumanLine(c.green("  ✓ Restart pending: the server restarts once running turns finish"));
  writeHumanLine(c.dim(`    At the latest at ${deadline}; then busy turns are cut short.`));
  printSessions("Waiting for", status.busy);
  printSessions("Waiting on you (restarted through)", status.waitingOnUser);
  if (status.heldInputs > 0) writeHumanLine(c.dim(`    Held messages: ${status.heldInputs}`));
  writeHumanLine(c.dim("    New prompts are held until after the restart."));
  writeHumanLine(c.dim("    Cancel: oppi server restart --cancel"));
  writeHumanLine("");
}

function printSessions(label: string, sessions: DrainSession[]): void {
  if (sessions.length === 0) return;
  writeHumanLine(`    ${label}:`);
  for (const session of sessions) {
    writeHumanLine(
      `      ${session.sessionId.slice(0, 8)}  ${session.engine.padEnd(7)}  ${session.name ?? ""}`,
    );
  }
}

function fail(json: boolean, message: string, code: number): void {
  if (json) writeJsonEnvelope({ ok: false, error: { message } });
  else {
    writeHumanLine(c.red(`  ✗ ${message}`));
    writeHumanLine("");
  }
  process.exitCode = code;
}
