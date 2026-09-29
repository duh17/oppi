import type { LocalApiRequestOptions } from "./local-api-client.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

const AMBIGUOUS_ID_LIST_LIMIT = 10;

export type SessionIdTargetError = Error & {
  status: number;
  code: "session_id_required" | "session_not_found" | "session_prefix_ambiguous";
  hint: string;
  exitCode: number;
};

/**
 * Resolve a CLI session target the way official Pi does --session / --fork:
 * exact Session.id first, otherwise id.startsWith(target). Unlike Pi's first-match,
 * this is unique-or-error so an ambiguous prefix lists every full id.
 *
 * `sessionIds` must hold every Session.id that starts with the target. The
 * server's idPrefix filter guarantees that without a limit or recency window.
 */
export function resolveUniqueSessionId(target: string, sessionIds: readonly string[]): string {
  const trimmed = requiredTarget(target);
  const ids = [...new Set(sessionIds.filter((id) => id.length > 0))];
  const exact = ids.find((id) => id === trimmed);
  if (exact !== undefined) return exact;

  const matches = ids.filter((id) => id.startsWith(trimmed)).sort();
  if (matches.length === 1) {
    const match = matches[0];
    if (match !== undefined) return match;
  }
  if (matches.length === 0) {
    throw sessionIdTargetError(
      `Session not found: ${trimmed}`,
      404,
      "session_not_found",
      "Use the full Session.id or a longer unique prefix. List ids with `oppi session list --json`.",
    );
  }
  throw sessionIdTargetError(
    `Ambiguous session prefix '${trimmed}': ${formatAmbiguousMatches(matches)}`,
    409,
    "session_prefix_ambiguous",
    "Pass more of the UUID until exactly one session matches.",
  );
}

export async function resolveSessionIdTargets(
  targets: readonly string[],
  call: SessionListApiCall,
): Promise<string[]> {
  const resolved: string[] = [];
  for (const target of targets) {
    // Empty targets fail locally; an empty idPrefix would list every session.
    const trimmed = requiredTarget(target);
    // Ask the server for prefix matches only. The full list serializes every
    // stored session and was the server's most expensive request.
    const result = await call<{ sessions?: Array<{ id?: unknown }> }>(
      `/sessions?idPrefix=${encodeURIComponent(trimmed)}`,
    );
    const sessionIds = (result.sessions ?? [])
      .map((session) => session.id)
      .filter((id): id is string => typeof id === "string" && id.length > 0);
    resolved.push(resolveUniqueSessionId(trimmed, sessionIds));
  }
  return resolved;
}

function requiredTarget(target: string): string {
  const trimmed = target.trim();
  if (trimmed) return trimmed;
  throw sessionIdTargetError(
    "session id is required",
    400,
    "session_id_required",
    "Pass a Session.id or a unique prefix, for example 11111111.",
  );
}

function formatAmbiguousMatches(matches: readonly string[]): string {
  if (matches.length <= AMBIGUOUS_ID_LIST_LIMIT) return matches.join(", ");
  const shown = matches.slice(0, AMBIGUOUS_ID_LIST_LIMIT).join(", ");
  return `${shown}, and ${matches.length - AMBIGUOUS_ID_LIST_LIMIT} more`;
}

function sessionIdTargetError(
  message: string,
  status: number,
  code: SessionIdTargetError["code"],
  hint: string,
): SessionIdTargetError {
  const error = new Error(message) as SessionIdTargetError;
  error.status = status;
  error.code = code;
  error.hint = hint;
  error.exitCode = 1;
  return error;
}
