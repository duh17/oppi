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
 * Completeness depends on GET /sessions returning every Session.id with no
 * default limit or recency window. A later default cap would make unique-prefix
 * resolution silently wrong.
 */
export function resolveUniqueSessionId(target: string, sessionIds: readonly string[]): string {
  const trimmed = target.trim();
  if (!trimmed) {
    throw sessionIdTargetError(
      "session id is required",
      400,
      "session_id_required",
      "Pass a Session.id or a unique prefix, for example 11111111.",
    );
  }

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
  if (targets.length === 0) return [];
  const result = await call<{ sessions?: Array<{ id?: unknown }> }>("/sessions");
  const sessionIds = (result.sessions ?? [])
    .map((session) => session.id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);
  return targets.map((target) => resolveUniqueSessionId(target, sessionIds));
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
