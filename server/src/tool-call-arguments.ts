/**
 * A tool call's arguments as the server reads them off Pi's message blocks, the rule Pi's
 * providers and the classic trace use (`arguments || tryParseJson(partialJson)`):
 * `arguments` unless it is falsy (absent, null, false, 0, or an empty string), else the
 * provider's streamed `partialJson`, parsed to an object.
 *
 * The whole server resolves it here: the conversation stream projects the result into the
 * wire block and renders rows from it, and the classic trace and Session Outline read it for
 * theirs. A call whose partial text is not an object yet resolves to `undefined`, so a row
 * shows no arguments rather than stale text.
 */
export function resolveToolArguments(
  block: Record<string, unknown>,
): Record<string, unknown> | undefined {
  if (block.arguments) return asRecord(block.arguments);
  return parseJsonObject(block.partialJson);
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function parseJsonObject(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "string") return undefined;
  try {
    return asRecord(JSON.parse(value));
  } catch {
    return undefined;
  }
}
