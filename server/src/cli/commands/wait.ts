/* eslint-disable no-console */
import * as c from "../../ansi.js";
import {
  createAbortError,
  localApiRequest,
  throwIfAborted,
  type LocalApiConnection,
} from "../local-api-client.js";
import {
  cliExitCodeFromUnknown,
  cliJsonErrorFromUnknown,
  codeValue,
  printDetails,
  setCapturedCliExitCode,
  writeJsonEnvelope,
} from "../output.js";
import { apiStatus } from "../resources.js";
import { assertNotSelfTargetingSession } from "../../session-caller-identity.js";
import { resolveSessionIdTargets } from "../session-id-target.js";

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
  signal?: AbortSignal,
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
    throwIfAborted(signal);

    const [resolvedSessionId] = await resolveSessionIdTargets([sessionId], (path, options) =>
      localApiRequest(storage, path, signal ? { ...options, signal } : options),
    );
    if (!resolvedSessionId) throw new Error("session id is required");
    assertNotSelfTargetingSession([resolvedSessionId]);

    for (;;) {
      throwIfAborted(signal);
      const result = await localApiRequest<{ session?: WaitSession }>(
        storage,
        `/sessions/${encodeURIComponent(resolvedSessionId)}`,
        signal ? { signal } : undefined,
      );
      const session = result.session;
      if (session && sessionMatchesStatus(session, expectedStatus)) {
        throwIfAborted(signal);
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
        throw new Error(
          `Timed out waiting for session ${resolvedSessionId} to become ${expectedStatus}`,
        );
      }
      await sleepWithSignal(Math.min(pollMs, Math.max(0, deadline - Date.now())), signal);
    }
  } catch (error: unknown) {
    if (signal?.aborted) throw createAbortError(signal);
    const message = error instanceof Error ? error.message : String(error);
    const status = apiStatus(error);
    if (jsonOutput) {
      writeJsonEnvelope({
        ok: false,
        error: cliJsonErrorFromUnknown(error, message, status),
      });
      setCapturedCliExitCode(cliExitCodeFromUnknown(error));
      return;
    }
    console.log(c.red(`  Error: ${message}`));
    process.exit(cliExitCodeFromUnknown(error));
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

export async function sleepWithSignal(ms: number, signal?: AbortSignal): Promise<void> {
  throwIfAborted(signal);
  if (ms <= 0) return;

  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const cleanup = (): void => {
      if (timer !== undefined) clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    };
    const onAbort = (): void => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(createAbortError(signal));
    };
    const onTimer = (): void => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve();
    };

    signal?.addEventListener("abort", onAbort, { once: true });
    const timer = setTimeout(onTimer, ms);
    if (signal?.aborted) onAbort();
  });
}
