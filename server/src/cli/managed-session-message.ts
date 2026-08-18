const ATTRIBUTED_PREFIX_RE = /^This is a message from session \S+:\s*/;
const BARE_PREFIX_RE = /^This is a message:\s*/;

export function attributeManagedSessionMessage(
  text: string,
  callerSessionId?: string,
): string {
  if (!callerSessionId) return text;
  return `This is a message from session ${callerSessionId}: ${stripManagedSessionMessagePrefix(text)}`;
}

function stripManagedSessionMessagePrefix(text: string): string {
  const withoutAttributed = text.replace(ATTRIBUTED_PREFIX_RE, "");
  if (withoutAttributed !== text) return withoutAttributed;
  return text.replace(BARE_PREFIX_RE, "");
}
