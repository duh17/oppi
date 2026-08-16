import type { LocalApiRequestOptions } from "../local-api-client.js";
import { writeHumanLine } from "../output.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

// ─── Steering (send / abort) ───

type SessionSendKind = "prompt" | "steer" | "follow_up";

export function resolveSendStreamingKind(
  flags: Record<string, string>,
): "steer" | "follow_up" | undefined {
  const steer = flags.steer === "true";
  const followUp = flags["follow-up"] === "true";
  if (steer && followUp) {
    throw new Error("--steer and --follow-up cannot be used together");
  }
  if (steer) return "steer";
  if (followUp) return "follow_up";
  return undefined;
}

// Compact, single-line session output. Agents parse --json; humans get the fact without framing.
export function printSessionNotice(message: string): void {
  writeHumanLine(message);
}

export async function sendSessionInput(
  id: string,
  commandType: SessionSendKind,
  text: string,
  call: SessionListApiCall,
): Promise<Record<string, unknown>> {
  try {
    return await call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}/command`, {
      method: "POST",
      body: {
        type: commandType,
        message: text,
        ...(commandType === "prompt" ? { streamingBehavior: "steer" } : {}),
      },
    });
  } catch (err) {
    // Keep older or incompatible runtimes actionable if they reject the prompt-or-steer form.
    if (commandType === "prompt" && err instanceof Error && /idle session/i.test(err.message)) {
      err.message = `${err.message}. Retry with --steer to interrupt the current turn or --follow-up to queue after it.`;
    }
    throw err;
  }
}

export function assertNoCommandError(result: Record<string, unknown>, hintSteering = false): void {
  const messages = Array.isArray(result.messages) ? result.messages : [];
  for (const message of messages) {
    if (
      message &&
      typeof message === "object" &&
      (message as { type?: unknown }).type === "error"
    ) {
      const errorText = (message as { error?: unknown }).error;
      let detail = typeof errorText === "string" ? errorText : "Session command was rejected";
      if (hintSteering && /idle session/i.test(detail)) {
        detail = `${detail}. Retry with --steer to interrupt the current turn or --follow-up to queue after it.`;
      }
      throw new Error(detail);
    }
  }
}
