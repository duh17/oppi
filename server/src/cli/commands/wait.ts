/* eslint-disable no-console, local/structured-log-format */
import * as c from "../../ansi.js";
import type { Storage } from "../../storage.js";
import { localApiRequest, type LocalApiHostResolvers } from "../local-api-client.js";
import { writeJsonEnvelope } from "../output.js";
import { apiStatus } from "../resources.js";

type WaitSession = {
  id: string;
  status?: string;
  [key: string]: unknown;
};

export async function cmdWait(
  storage: Storage,
  target: string | undefined,
  positional: string[],
  flags: Record<string, string>,
  hostResolvers: LocalApiHostResolvers = {},
): Promise<void> {
  const jsonOutput = flags.json === "true";

  try {
    if ((target || "session") !== "session") {
      throw new Error("Usage: oppi wait session <id> --status <status>");
    }

    const sessionId = positional[0];
    if (!sessionId) throw new Error("session id is required");

    const expectedStatus = flags.status?.trim() || "stopped";
    const timeoutMs = parseDurationMs(flags.timeout ?? "10m");
    const pollMs = parseDurationMs(flags.poll ?? "1s");
    if (pollMs < 1) throw new Error("--poll must be a positive duration");
    const deadline = Date.now() + timeoutMs;

    for (;;) {
      const result = await localApiRequest<{ session?: WaitSession }>(
        storage,
        `/sessions/${encodeURIComponent(sessionId)}`,
        undefined,
        hostResolvers,
      );
      const session = result.session;
      if (session && sessionMatchesStatus(session, expectedStatus)) {
        if (jsonOutput) {
          writeJsonEnvelope({ ok: true, data: { session, matchedStatus: expectedStatus } });
        } else {
          console.log(c.green("  ✓ Wait condition met"));
          console.log(`  Session: ${c.cyan(session.id)}`);
          console.log(`  Status:  ${session.status ?? "unknown"}`);
          console.log("");
        }
        return;
      }

      if (Date.now() >= deadline) {
        throw new Error(`Timed out waiting for session ${sessionId} to become ${expectedStatus}`);
      }
      await sleep(Math.min(pollMs, Math.max(0, deadline - Date.now())));
    }
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    const status = apiStatus(error);
    if (jsonOutput) {
      writeJsonEnvelope({ ok: false, error: { message, ...(status ? { status } : {}) } });
      process.exitCode = 1;
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(1);
  }
}

function sessionMatchesStatus(session: WaitSession, expectedStatus: string): boolean {
  if (expectedStatus === "active") return session.status !== "stopped";
  return session.status === expectedStatus;
}

function parseDurationMs(value: string): number {
  const match = value.trim().match(/^(\d+)(ms|s|m|h|d)?$/);
  if (!match) throw new Error("Duration must look like 500ms, 15s, 5m, 1h, or 1d");
  const amountText = match[1];
  const unit = match[2] ?? "ms";
  const amount = Number.parseInt(amountText, 10);
  const multiplier =
    unit === "ms"
      ? 1
      : unit === "s"
        ? 1_000
        : unit === "m"
          ? 60_000
          : unit === "h"
            ? 3_600_000
            : 86_400_000;
  return amount * multiplier;
}

async function sleep(ms: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, ms));
}
