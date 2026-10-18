import type { Session, VoiceControlSessionPurpose } from "./types.js";

export const VOICE_CONTROL_SESSION_PURPOSE: VoiceControlSessionPurpose = "voice-control";

export function isDeclaredVoiceControlSession(
  session: Pick<Session, "workspaceId" | "control" | "voice">,
): boolean {
  return (
    session.workspaceId === undefined &&
    session.control === undefined &&
    session.voice?.purpose === VOICE_CONTROL_SESSION_PURPOSE
  );
}

/** Owner tokens stay valid for ordinary APIs but never become voice controllers. */
export function authenticatedVoiceDeviceId(
  principal: { kind: "owner" } | { kind: "device"; deviceId: string },
): string | undefined {
  return principal.kind === "device" ? principal.deviceId : undefined;
}
