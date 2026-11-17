import { isPinnableURL } from "./storage/pins-store.js";
import type { PinRoute } from "./types.js";

/**
 * `oppi://` pane links, decoded by the rules of `protocol/links.json` (version 1), the same rules
 * the app's `PaneLinkCodec` follows. The server decodes a link it is handed to check it, never to
 * open it: an extension surface's tile names its target this way.
 *
 * Every pane link only opens and takes an optional `server=`. Session and thread links ignore
 * every other parameter; the rest refuse an unknown or repeated parameter, user-info, and a port,
 * and only a file link takes a fragment, `#L<line>`. Route and parameter names are
 * case-insensitive. Pairing (`connect`), `workspace`, and `terminal` links are not pane links.
 */

/** A route as a link decodes to it: a pin's route, or a workspace's Git or a commit. */
export type PaneRoute =
  | PinRoute
  | { kind: "git"; workspace: string; worktree: string | null }
  | { kind: "commit"; workspace: string; sha: string };

export interface PaneLink {
  /** An identity fingerprint, or null for the server the link came from. */
  server: string | null;
  route: PaneRoute;
}

export type PaneLinkErrorCode =
  | "missing"
  | "unknownParameter"
  | "duplicateParameter"
  | "invalidValue"
  | "unexpectedPath"
  | "unexpectedComponent"
  | "conflictingOrigin";

export interface PaneLinkError {
  code: PaneLinkErrorCode;
  detail?: string;
}

export type PaneLinkResult = { ok: true; link: PaneLink } | { ok: false; error: PaneLinkError };

const STRICT_ROUTES = new Set([
  "sessions",
  "file",
  "files",
  "git",
  "panel",
  "read",
  "browser",
  "godot",
]);

function fail(code: PaneLinkErrorCode, detail?: string): PaneLinkResult {
  return { ok: false, error: detail === undefined ? { code } : { code, detail } };
}

function percentDecoded(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

/** The parts of a URL as the app's `URLComponents` reads them; undefined for another scheme. */
function components(input: string):
  | {
      user?: string;
      port?: string;
      host: string;
      path: string;
      query?: string;
      fragment?: string;
    }
  | undefined {
  const scheme = /^oppi:/i.exec(input);
  if (!scheme) return undefined;
  let rest = input.slice(scheme[0].length);
  let fragment: string | undefined;
  const hash = rest.indexOf("#");
  if (hash >= 0) {
    fragment = percentDecoded(rest.slice(hash + 1));
    rest = rest.slice(0, hash);
  }
  let query: string | undefined;
  const mark = rest.indexOf("?");
  if (mark >= 0) {
    query = rest.slice(mark + 1);
    rest = rest.slice(0, mark);
  }
  let host = "";
  let user: string | undefined;
  let port: string | undefined;
  if (rest.startsWith("//")) {
    const end = rest.indexOf("/", 2);
    let authority = end >= 0 ? rest.slice(2, end) : rest.slice(2);
    rest = end >= 0 ? rest.slice(end) : "";
    const at = authority.lastIndexOf("@");
    if (at >= 0) {
      user = authority.slice(0, at);
      authority = authority.slice(at + 1);
    }
    const colon = authority.lastIndexOf(":");
    if (colon >= 0) {
      port = authority.slice(colon + 1);
      authority = authority.slice(0, colon);
    }
    host = percentDecoded(authority);
  }
  return {
    host,
    path: rest,
    ...(user === undefined ? {} : { user }),
    ...(port === undefined ? {} : { port }),
    ...(query === undefined ? {} : { query }),
    ...(fragment === undefined ? {} : { fragment }),
  };
}

/** Query items in order, each value percent-decoded (`+` stays a plus, as in the app). */
function queryItems(query: string | undefined): { name: string; value: string }[] {
  if (!query) return [];
  return query.split("&").map((item) => {
    const equals = item.indexOf("=");
    return equals >= 0
      ? {
          name: percentDecoded(item.slice(0, equals)),
          value: percentDecoded(item.slice(equals + 1)),
        }
      : { name: percentDecoded(item), value: "" };
  });
}

/**
 * `input` as a pane link, or the first rule it breaks; undefined when it is not a pane link at
 * all (another scheme, or an `oppi://` link another owner parses).
 */
export function decodePaneLink(input: string): PaneLinkResult | undefined {
  const parts = components(input);
  if (!parts) return undefined;
  const segments = parts.path
    .split("/")
    .filter((segment) => segment.length > 0)
    .map(percentDecoded);
  if (parts.host) segments.unshift(parts.host);
  const name = segments[0]?.toLowerCase();
  if (name === undefined) return undefined;
  const path = segments.slice(1);
  const query = queryItems(parts.query);
  if (name === "session" || name === "thread") return decodeSession(name, path, query);
  if (!STRICT_ROUTES.has(name)) return undefined;
  if (parts.user !== undefined) return fail("unexpectedComponent", "user");
  if (parts.port !== undefined) return fail("unexpectedComponent", "port");
  return decodeStrict(name, path, query, parts.fragment);
}

function decodeSession(
  name: "session" | "thread",
  path: string[],
  query: { name: string; value: string }[],
): PaneLinkResult {
  const id = path.length === 1 ? path[0]?.trim() : undefined;
  if (!id) return fail("unexpectedPath");
  let server: string | undefined;
  for (const item of query) {
    if (item.name.toLowerCase() !== "server") continue;
    if (server !== undefined) return fail("duplicateParameter", "server");
    server = item.value.trim();
  }
  return { ok: true, link: { server: server || null, route: { kind: name, id } } };
}

const ALLOWED: Record<string, readonly string[]> = {
  sessions: ["workspace"],
  file: ["workspace", "worktree", "host", "session", "path"],
  files: ["workspace", "host", "path"],
  browser: ["url"],
  godot: ["project"],
  panel: ["session", "id"],
  read: ["session", "url"],
};

function decodeStrict(
  name: string,
  path: string[],
  query: { name: string; value: string }[],
  fragment: string | undefined,
): PaneLinkResult {
  const allowed =
    name === "git"
      ? path.length === 0
        ? ["workspace", "worktree"]
        : ["workspace"]
      : (ALLOWED[name] ?? []);
  const values = new Map<string, string>();
  const seen = new Set<string>();
  for (const item of query) {
    const key = item.name.toLowerCase();
    if (key !== "server" && !allowed.includes(key)) return fail("unknownParameter", item.name);
    // A repeated name could mean two things; refuse rather than pick one.
    if (seen.has(key)) return fail("duplicateParameter", key);
    seen.add(key);
    const value = item.value.trim();
    if (value) values.set(key, value);
  }
  if (fragment !== undefined && name !== "file") return fail("unexpectedComponent", "fragment");
  const server = values.get("server") ?? null;
  const ok = (route: PaneRoute): PaneLinkResult => ({ ok: true, link: { server, route } });
  const required = (key: string): string | undefined => values.get(key);

  if (name === "git") {
    const workspace = required("workspace");
    if (path.length === 0) {
      return workspace
        ? ok({ kind: "git", workspace, worktree: values.get("worktree") ?? null })
        : fail("missing", "workspace");
    }
    const [segment, rawSha] = path;
    if (path.length !== 2 || segment?.toLowerCase() !== "commit") return fail("unexpectedPath");
    const sha = rawSha?.toLowerCase() ?? "";
    if (!/^[0-9a-f]{4,64}$/.test(sha)) return fail("invalidValue", "sha");
    return workspace ? ok({ kind: "commit", workspace, sha }) : fail("missing", "workspace");
  }
  if (path.length > 0) return fail("unexpectedPath");
  switch (name) {
    case "sessions":
      return ok({ kind: "sessions", workspace: values.get("workspace") ?? null });
    case "file":
      return decodeFile(values, fragment, ok);
    case "files":
      return decodeFiles(values, ok);
    case "browser": {
      const url = required("url");
      if (!url) return fail("missing", "url");
      return isPinnableURL(url) ? ok({ kind: "browser", url }) : fail("invalidValue", "url");
    }
    case "godot": {
      const project = required("project");
      return project ? ok({ kind: "godot", project }) : fail("missing", "project");
    }
    case "read": {
      const session = required("session");
      if (!session) return fail("missing", "session");
      const url = required("url");
      if (!url) return fail("missing", "url");
      // An internal URL: a scheme and what follows it (`proc://bash-3`).
      return /^[a-z][a-z0-9+.-]*:\/\//i.test(url)
        ? ok({ kind: "read", session, url })
        : fail("invalidValue", "url");
    }
    default: {
      const session = required("session");
      if (!session) return fail("missing", "session");
      const id = required("id");
      return id ? ok({ kind: "panel", session, id }) : fail("missing", "id");
    }
  }
}

/** A folder in a workspace, or with `host=1` in the server's home folder (`~` or `~/…`). */
function decodeFiles(
  values: Map<string, string>,
  ok: (route: PaneRoute) => PaneLinkResult,
): PaneLinkResult {
  const path = values.get("path") ?? null;
  if (!values.has("host")) {
    const workspace = values.get("workspace");
    return workspace ? ok({ kind: "files", workspace, path }) : fail("missing", "workspace");
  }
  if (values.has("workspace")) return fail("conflictingOrigin");
  if (values.get("host") !== "1") return fail("invalidValue", "host");
  if (path === null || path === "~") return ok({ kind: "files", origin: "host", path: null });
  return path.startsWith("~/")
    ? ok({ kind: "files", origin: "host", path })
    : fail("invalidValue", "path");
}

function decodeFile(
  values: Map<string, string>,
  fragment: string | undefined,
  ok: (route: PaneRoute) => PaneLinkResult,
): PaneLinkResult {
  let line: number | null = null;
  if (fragment !== undefined) {
    const digits = fragment.slice(1);
    if (
      !fragment.startsWith("L") ||
      !/^[0-9]+$/.test(digits) ||
      !(Number(digits) >= 1) ||
      !Number.isSafeInteger(Number(digits))
    )
      return fail("invalidValue", "line");
    line = Number(digits);
  }
  const named = ["workspace", "host", "session"].filter((key) => values.has(key));
  if (named.length > 1) return fail("conflictingOrigin");
  const origin = named[0];
  if (origin === undefined) return fail("missing", "workspace");
  if (origin !== "workspace" && values.has("worktree")) return fail("unknownParameter", "worktree");
  const path = values.get("path");
  if (path === undefined) return fail("missing", "path");
  // The origin's own value is present: `named` holds only keys `values` has.
  const originValue = values.get(origin) ?? "";
  if (origin === "workspace") {
    return ok({
      kind: "file",
      origin: "workspace",
      workspace: originValue,
      worktree: values.get("worktree") ?? null,
      path,
      line,
    });
  }
  if (origin === "host") {
    return values.get("host") === "1"
      ? ok({ kind: "file", origin: "host", path, line })
      : fail("invalidValue", "host");
  }
  return ok({ kind: "file", origin: "session", session: originValue, path, line });
}
