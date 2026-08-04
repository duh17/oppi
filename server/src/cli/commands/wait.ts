/* eslint-disable no-console */
import * as c from "../../ansi.js";
import { localApiRequest, type LocalApiConnection } from "../local-api-client.js";
import { codeValue, printDetails, setCapturedCliExitCode, writeJsonEnvelope } from "../output.js";
import { apiStatus } from "../resources.js";
import { assertNotSelfTargetingSession } from "../../session-caller-identity.js";

type WaitSession = {
  id: string;
  status?: string;
  [key: string]: unknown;
};

export async function cmdWait(
  storage: LocalApiConnection,
  target: string | undefined,
  positional: string[],
  flags: Record<string, string>,
): Promise<void> {
  const jsonOutput = flags.json === "true";

  try {
    if ((target || "session") !== "session") {
      throw new Error("Usage: oppi wait session <id> --status <status>");
    }

    const sessionId = positional[0];
    if (!sessionId) throw new Error("session id is required");
    assertNotSelfTargetingSession([sessionId]);

    const expectedStatus = flags.status?.trim() || "stopped";
    const timeoutMs = parseDurationMs(flags.timeout ?? "10m");
    const pollMs = parseDurationMs(flags.poll ?? "1s");
    if (pollMs < 1) throw new Error("--poll must be a positive duration");
    const deadline = Date.now() + timeoutMs;

    for (;;) {
      const result = await localApiRequest<{ session?: WaitSession }>(
        storage,
        `/sessions/${encodeURIComponent(sessionId)}`,
      );
      const session = result.session;
      if (session && sessionMatchesStatus(session, expectedStatus)) {
        if (jsonOutput) {
          writeJsonEnvelope({ ok: true, data: { session, matchedStatus: expectedStatus } });
        } else {
          printDetails("✓ Wait condition met", [
            ["Session", codeValue(session.id)],
            ["Status", session.status ?? "unknown"],
          ]);
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
      setCapturedCliExitCode(1);
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

export function parseDurationMs(value: string): number {
  const match = value.trim().match(/^(\d+)(ms|s|m|h|d)?$/);
  if (!match) throw new Error("Duration must look like 500ms, 15s, 5m, 1h, or 1d");
  const amountText = match[1];
  // Bare numbers are seconds so --timeout 900 matches help (`<s>`) and supervisor scripts.
  // Use an explicit ms/s/m/h/d suffix when another unit is intended.
  const unit = match[2] ?? "s";
  const amount = Number.parseInt(amountText, 10);
  if (!Number.isSafeInteger(amount)) {
    throw new Error("Duration is too large");
  }
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
  const durationMs = amount * multiplier;
  if (!Number.isSafeInteger(durationMs)) {
    throw new Error("Duration is too large");
  }
  return durationMs;
}

async function sleep(ms: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, ms));
}
