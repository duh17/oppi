import type { Session } from "./types.js";

export type SessionRuntimeKind = "oppi" | "pi-tui";
export type StreamingInputKind = "steer" | "follow_up";

function isPiTuiSession(session: Pick<Session, "runtime">): boolean {
  return session.runtime === "pi-tui";
}

export function isServerDurableSession(
  session: Pick<Session, "runtime" | "serverDurable">,
): boolean {
  return !isPiTuiSession(session) && session.serverDurable !== undefined;
}

/** Bound to a durable conversation: needs the Harness whether or not new sessions still enroll. */
export function hasServerDurableBinding<T extends Pick<Session, "runtime" | "serverDurable">>(
  session: T,
): session is T & { serverDurable: { conversationId: number } } {
  return isServerDurableSession(session) && session.serverDurable?.conversationId !== undefined;
}

export function runtimeLogTag(session: Pick<Session, "runtime">): SessionRuntimeKind {
  return isPiTuiSession(session) ? "pi-tui" : "oppi";
}

/**
 * Live engine for session start and the turn/tool `runtime` tag.
 * A durable row with a Pi session file still starts on SdkBackend.
 */
export function usesDurableEngine(
  session: Pick<Session, "runtime" | "serverDurable" | "piSessionFile">,
): boolean {
  return isServerDurableSession(session) && !session.piSessionFile;
}

/**
 * Bounded backend for turn and tool ops metrics.
 * Reuses `SessionRuntimeKind` (`oppi`, `pi-tui`) and the durable engine name.
 * `durable` is `usesDurableEngine`, not merely a `serverDurable` row.
 * A terminal mirror stays `pi-tui`.
 */
export type SessionMetricRuntime = "oppi" | "durable" | "pi-tui";

export function sessionMetricRuntime(
  session: Pick<Session, "runtime" | "serverDurable" | "piSessionFile">,
): SessionMetricRuntime {
  if (isPiTuiSession(session)) return "pi-tui";
  if (usesDurableEngine(session)) return "durable";
  return "oppi";
}

export function shouldRecordPromptLocally(session: Pick<Session, "runtime">): boolean {
  // Terminal-owned turns are authoritative in pi-tui; Oppi only projects them.
  return !isPiTuiSession(session);
}

export function promptBusyErrorMessage(session: Pick<Session, "runtime">): string {
  return isPiTuiSession(session)
    ? "Prompt requires an idle terminal session; use steer or follow_up while a turn is streaming"
    : "Prompt requires an idle session; use steer or follow_up while a turn is streaming";
}

export function streamingInputBusyErrorMessage(
  session: Pick<Session, "runtime">,
  kind: StreamingInputKind,
): string {
  const label = kind === "steer" ? "Steer" : "Follow-up";
  return isPiTuiSession(session)
    ? `${label} requires an active streaming terminal turn`
    : `${label} requires an active streaming turn`;
}

export function attachmentWorkspaceErrorMessage(session: Pick<Session, "runtime">): string {
  return isPiTuiSession(session)
    ? "Attachments require a workspace-backed pi-tui session"
    : "Attachments require a workspace-backed session";
}
