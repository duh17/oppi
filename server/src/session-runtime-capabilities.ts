import type { Session } from "./types.js";

export type SessionRuntimeKind = "oppi" | "pi-tui";
export type StreamingInputKind = "steer" | "follow_up";

function isPiTuiSession(session: Pick<Session, "runtime">): boolean {
  return session.runtime === "pi-tui";
}

export function runtimeLogTag(session: Pick<Session, "runtime">): SessionRuntimeKind {
  return isPiTuiSession(session) ? "pi-tui" : "oppi";
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
