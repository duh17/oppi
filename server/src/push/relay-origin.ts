/** Relay origins for `push.relays` (protocol/push/spec.md §5). */

export type RelayOriginsResult = { ok: true; value: string[] } | { ok: false; error: string };

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "[::1]", "localhost"]);

/**
 * One relay origin: `https://host[:port]`, or `http://` on a loopback host for local testing.
 * No path, query, fragment, or credentials: send tokens travel only in headers.
 */
export function parseRelayOrigin(
  raw: unknown,
): { ok: true; value: string } | { ok: false; error: string } {
  if (typeof raw !== "string" || raw.trim().length === 0) {
    return { ok: false, error: "expected an https origin" };
  }
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return { ok: false, error: `not a URL: ${raw}` };
  }
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    (url.pathname !== "/" && url.pathname !== "")
  ) {
    return { ok: false, error: `expected an origin without path, query, or credentials: ${raw}` };
  }
  if (url.protocol === "https:") return { ok: true, value: url.origin };
  if (url.protocol === "http:" && LOOPBACK_HOSTS.has(url.hostname)) {
    return { ok: true, value: url.origin };
  }
  return { ok: false, error: `relay must use https (http only on loopback): ${raw}` };
}

/** `[primary]` or `[primary, standby]`. */
export function parseRelayOrigins(raw: unknown): RelayOriginsResult {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 2) {
    return { ok: false, error: "expected [primary] or [primary, standby]" };
  }
  const origins: string[] = [];
  for (const entry of raw) {
    const parsed = parseRelayOrigin(entry);
    if (!parsed.ok) return parsed;
    if (origins.includes(parsed.value)) return { ok: false, error: "standby repeats the primary" };
    origins.push(parsed.value);
  }
  return { ok: true, value: origins };
}
