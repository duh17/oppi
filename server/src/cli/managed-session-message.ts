const ATTRIBUTED_PREFIX_RE = /^This is a message from session \S+:\s*/;
const ATTRIBUTED_CALLER_RE = /^This is a message from session (\S+):/;
const BARE_PREFIX_RE = /^This is a message:\s*/;

export function attributeManagedSessionMessage(text: string, callerSessionId?: string): string {
  if (!callerSessionId) return text;
  return `This is a message from session ${callerSessionId}: ${stripManagedSessionMessagePrefix(text)}`;
}

/** The session a managed message says it comes from (`attributeManagedSessionMessage`). */
export function managedSessionMessageCaller(text: string): string | undefined {
  return ATTRIBUTED_CALLER_RE.exec(text)?.[1];
}

function stripManagedSessionMessagePrefix(text: string): string {
  const withoutAttributed = text.replace(ATTRIBUTED_PREFIX_RE, "");
  if (withoutAttributed !== text) return withoutAttributed;
  return text.replace(BARE_PREFIX_RE, "");
}
