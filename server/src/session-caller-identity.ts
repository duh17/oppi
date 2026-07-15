export const OPPI_CALLER_SESSION_ID_ENV = "OPPI_CALLER_SESSION_ID";

export function callerSessionIdFromEnvironment(
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  const sessionId = env[OPPI_CALLER_SESSION_ID_ENV]?.trim();
  return sessionId || undefined;
}

export function callerSessionIdentityShellPrefix(sessionId: string): string {
  // Single-quote for POSIX-compatible shells without allowing session data to alter the command.
  const quotedSessionId = `'${sessionId.replaceAll("'", "'\\''")}'`;
  return `export ${OPPI_CALLER_SESSION_ID_ENV}=${quotedSessionId}`;
}

export function assertNotSelfTargetingSession(
  targetSessionIds: readonly string[],
  callerSessionId = callerSessionIdFromEnvironment(),
): void {
  if (callerSessionId && targetSessionIds.some((sessionId) => sessionId === callerSessionId)) {
    throw new Error(`Cannot target the calling Oppi session (${callerSessionId})`);
  }
}
