import type { Session } from "./types.js";

export function mirrorSessionResumeFile(session: Session): string | undefined {
  return session.piSessionFile ?? session.piSessionFiles?.[session.piSessionFiles.length - 1];
}

export function canResumeStoppedMirrorAsManaged(
  session: Session,
  mirrorConnected: boolean,
): boolean {
  return (
    session.runtime === "pi-tui-mirror" &&
    session.status === "stopped" &&
    !mirrorConnected &&
    mirrorSessionResumeFile(session) !== undefined
  );
}

export function promoteStoppedMirrorToManaged(session: Session): Session {
  const resumeFile = mirrorSessionResumeFile(session);
  session.runtime = "managed";
  session.mirror = undefined;
  if (resumeFile) {
    session.piSessionFile = resumeFile;
    session.piSessionFiles = Array.from(new Set([...(session.piSessionFiles ?? []), resumeFile]));
  }
  return session;
}
