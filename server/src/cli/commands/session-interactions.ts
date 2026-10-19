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

// Every delivery kind is a prompt with a streaming behavior: an idle session starts a turn now,
// a busy one steers or queues. The bare `steer`/`follow_up` commands reject an idle session,
// which a caller cannot rule out between checking status and sending.
const STREAMING_BEHAVIOR: Record<SessionSendKind, "steer" | "followUp"> = {
  prompt: "steer",
  steer: "steer",
  follow_up: "followUp",
};

export async function sendSessionInput(
  id: string,
  commandType: SessionSendKind,
  text: string,
  call: SessionListApiCall,
  /** Caller-chosen id of the turn; the server keeps it on the turn so a retry is the same turn. */
  turnId?: string,
): Promise<Record<string, unknown>> {
  return call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}/command`, {
    method: "POST",
    body: {
      type: "prompt",
      message: text,
      ...(turnId ? { clientTurnId: turnId, requestId: turnId } : {}),
      streamingBehavior: STREAMING_BEHAVIOR[commandType],
    },
  });
}

export function assertNoCommandError(result: Record<string, unknown>): void {
  const messages = Array.isArray(result.messages) ? result.messages : [];
  for (const message of messages) {
    if (
      message &&
      typeof message === "object" &&
      (message as { type?: unknown }).type === "error"
    ) {
      const errorText = (message as { error?: unknown }).error;
      throw new Error(typeof errorText === "string" ? errorText : "Session command was rejected");
    }
  }
}
