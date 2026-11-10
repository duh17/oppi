import type { Context } from "@earendil-works/chord/context";
import { DEFAULT_MAX_BYTES, DEFAULT_MAX_LINES } from "@earendil-works/pi-coding-agent";
import type { ToolExecutionApi } from "@earendil-works/pi-durable";

// Internal URLs (`agent://`, `history://`, `mcp://`, `ssh://`, `proc://`) that the agent's `read` tool
// resolves, read only. This module is the pure part: parsing, id-prefix matching, the refusal
// text for schemes Oppi does not serve, and paging. The scheme readers live with their owners:
// sessions, MCP, and ssh in `durable-internal-urls.ts`, background jobs in `plugins/background-jobs`.

/** One parsed `scheme://id/path` URL. */
export interface InternalTarget {
  readonly scheme: string;
  /** The first segment after `scheme://`; empty for a bare `scheme://`. */
  readonly id: string;
  /** What follows the id, starting with `/`; empty when there is none. */
  readonly path: string;
  /** Everything after `scheme://`, as written; MCP resource URIs are opaque and use this. */
  readonly rest: string;
  /**
   * The one of `ids` this target's id names: an exact id, else the one id it is a prefix of. Throws
   * for no match, listing the valid ids, and for an ambiguous prefix, listing its matches.
   */
  pick(kind: string, ids: readonly string[]): string;
}

/** Reads one scheme; resolves the text the `read` tool returns. */
export type SchemeReader = (
  target: InternalTarget,
  api: ToolExecutionApi,
  context: Context,
) => Promise<string>;

/** Schemes Oppi does not serve, each with the tool that does the same job. */
const UNSUPPORTED: Readonly<Record<string, string>> = {
  omp: "omp:// documentation URLs are not available in Oppi. Search the web or read the repository instead.",
  pr: "pr:// is not available in Oppi. Use bash: `gh pr view <N>`, or `gh pr diff <N>` for the diff.",
  issue: "issue:// is not available in Oppi. Use bash: `gh issue view <N>`.",
  artifact:
    "artifact:// is not available: Oppi keeps no artifact store. When bash truncates its output it names the file holding the full log; read that path.",
  local:
    "local:// is not available: Oppi sessions have no shared scratch location. Write files under the working directory.",
};

const SCHEME = /^([a-z][a-z0-9+.-]*):\/\/(.*)$/is;
const MAX_LISTED_IDS = 20;

/** The URL a `read` path is, or undefined for a file path (and `file://`, which Pi resolves). */
export function parseInternalUrl(path: string): InternalTarget | undefined {
  const match = SCHEME.exec(path.trim());
  if (!match) return undefined;
  const [, name = "", rest = ""] = match;
  const scheme = name.toLowerCase();
  if (scheme === "file") return undefined;
  const slash = rest.indexOf("/");
  const id = slash < 0 ? rest : rest.slice(0, slash);
  return {
    scheme,
    id,
    path: slash < 0 ? "" : rest.slice(slash),
    rest,
    pick: (kind, ids) => pickId(kind, id, ids),
  };
}

/** The row of `rows` the target's id names, as `InternalTarget.pick` matches ids. */
export function pickRow<T extends { id: string }>(
  target: InternalTarget,
  kind: string,
  rows: readonly T[],
): T {
  const id = target.pick(
    kind,
    rows.map((row) => row.id),
  );
  return rows.find((row) => row.id === id) as T;
}

function pickId(kind: string, id: string, ids: readonly string[]): string {
  if (ids.includes(id)) return id;
  const matches = id === "" ? [] : ids.filter((candidate) => candidate.startsWith(id));
  const [only] = matches;
  if (only !== undefined && matches.length === 1) return only;
  if (matches.length > 1)
    throw new Error(
      `Ambiguous ${kind} id prefix "${id}": ${listIds(matches)}. Use more of the id.`,
    );
  throw new Error(
    ids.length === 0
      ? `No ${kind} "${id}": there are none to read.`
      : `No ${kind} "${id}". Valid ids: ${listIds(ids)}.`,
  );
}

function listIds(ids: readonly string[]): string {
  const shown = ids.slice(0, MAX_LISTED_IDS).join(", ");
  return ids.length > MAX_LISTED_IDS ? `${shown}, and ${ids.length - MAX_LISTED_IDS} more` : shown;
}

/**
 * The text of the internal URL `path`, or undefined when `path` is a file path. Throws for a
 * scheme no reader serves, naming the tool to use instead where there is one.
 */
export async function readInternalUrl(
  path: string,
  readers: ReadonlyMap<string, SchemeReader>,
  api: ToolExecutionApi,
  context: Context,
): Promise<string | undefined> {
  const target = parseInternalUrl(path);
  if (!target) return undefined;
  const reader = readers.get(target.scheme);
  if (reader) return reader(target, api, context);
  const refusal = UNSUPPORTED[target.scheme];
  if (refusal) throw new Error(refusal);
  throw new Error(
    `Unknown URL scheme "${target.scheme}://". Supported: ${[...readers.keys()].map((scheme) => `${scheme}://`).join(", ")}.`,
  );
}

/** `text` from line `offset` (1-based) for `limit` lines, within the `read` tool's own caps. */
export function pageText(text: string, offset?: number, limit?: number): string {
  const lines = text.split("\n");
  const start = Math.max(0, (offset ?? 1) - 1);
  if (start > 0 && start >= lines.length)
    throw new Error(`Offset ${offset} is beyond the end (${lines.length} lines).`);
  const wanted = Math.min(lines.length, limit === undefined ? lines.length : start + limit);
  let end = Math.min(wanted, start + DEFAULT_MAX_LINES);
  let bytes = 0;
  for (let i = start; i < end; i += 1) {
    bytes += Buffer.byteLength(lines[i] ?? "") + 1;
    if (bytes > DEFAULT_MAX_BYTES && i > start) {
      end = i;
      break;
    }
  }
  const body = lines.slice(start, end).join("\n");
  return end < lines.length
    ? `${body}\n\n[Showing lines ${start + 1}-${end} of ${lines.length}. Use offset=${end + 1} to continue.]`
    : body;
}
