import type { Context, JsonValue } from "@earendil-works/chord";
import type { ToolExecutionApi } from "@earendil-works/pi-durable";
import { GondolinExecutionEnv } from "./durable-gondolin-env.js";
import {
  oppiHost,
  type OppiInternalUrlsHost,
  type SessionReading,
} from "./durable-extension-api.js";
import { createSshReader } from "./internal-url-ssh.js";
import {
  pageText,
  pickRow,
  readInternalUrl,
  type InternalTarget,
  type SchemeReader,
} from "./internal-urls.js";
import { isRecord } from "./json-shape.js";
import type { TraceEvent } from "./trace.js";
import type { Session } from "./types.js";

// What the durable `read` tool resolves for `agent://`, `history://`, and `mcp://`, and the
// registry other built-ins add a scheme to (`register`; `proc://` is background-jobs'). Read only.
//
// Who may read whom: a session reads the transcripts of the sessions in its own workspace
// (`history://`) and the answers of the sessions it launched, directly or through its children
// (`agent://`). It never sees another workspace's sessions, so an id from one is "not found".

// The caller's view of sessions is `oppiHost().sessions(env).reading`, scoped by the runtime's
// bound threads to the conversation that runs the call.

/** Schemes plugins registered, by name. */
const registered = new Map<string, SchemeReader>();
const BUILT_IN_SCHEMES = new Set(["agent", "history", "mcp", "ssh"]);
const readSsh = createSshReader();

export const internalUrls: OppiInternalUrlsHost = {
  register(scheme, reader) {
    if (BUILT_IN_SCHEMES.has(scheme)) throw new Error(`${scheme}:// is the server's own scheme`);
    registered.set(scheme, reader);
  },
  async read(args, api, context) {
    const readers = new Map<string, SchemeReader>(registered);
    const bound =
      (read: typeof readHistory): SchemeReader =>
      (target) => {
        const reading = oppiHost().sessions(api.env)?.reading;
        if (!reading)
          throw new Error(`${target.scheme}:// needs an Oppi session, and this call has none.`);
        return read(reading, target);
      };
    readers.set("history", bound(readHistory));
    readers.set("agent", bound(readAgent));
    readers.set("mcp", readMcp);
    readers.set("ssh", (target, toolApi, toolContext) => {
      // The server's ssh would reach hosts the sandbox is meant to keep a session away from.
      if (toolApi.env instanceof GondolinExecutionEnv)
        throw new Error("ssh:// is not available in sandbox sessions.");
      return readSsh(target, toolApi, toolContext);
    });
    const text = await readInternalUrl(args.path, readers, api, context);
    if (text === undefined) return undefined;
    // `read` declares a structured output: its text, as for a file.
    const paged = pageText(text, args.offset, args.limit);
    return { output: [{ type: "text", text: paged }], structuredOutput: paged };
  },
};

// --- sessions --------------------------------------------------------------------------------

/** The sessions the caller launched, directly or through its children, newest first. */
function descendants(sessions: readonly Session[], callerId: string): Session[] {
  const found = new Set<string>([callerId]);
  const result: Session[] = [];
  // Parents may be listed after their children: repeat until no session joins.
  for (let joined = true; joined;) {
    joined = false;
    for (const session of sessions) {
      const parent = session.launch?.parentSessionId;
      if (found.has(session.id) || parent === undefined || !found.has(parent)) continue;
      found.add(session.id);
      result.push(session);
      joined = true;
    }
  }
  return result.sort((a, b) => b.lastActivity - a.lastActivity);
}

const sessionLabel = (session: Session): string =>
  [
    session.id,
    session.status,
    session.name ?? session.firstMessage?.slice(0, 60),
    `active ${new Date(session.lastActivity).toISOString()}`,
  ]
    .filter(Boolean)
    .join("  ");

function listSessions(title: string, sessions: readonly Session[], hint: string): string {
  return sessions.length === 0
    ? `${title}: none.`
    : `${title} (${hint}):\n${sessions.map(sessionLabel).join("\n")}`;
}

function noPath(target: InternalTarget): void {
  if (target.path !== "" && target.path !== "/")
    throw new Error(
      `${target.scheme}://${target.id} has no sub-paths (got "${target.path}"). Read ${target.scheme}://${target.id}.`,
    );
}

async function readHistory(reading: SessionReading, target: InternalTarget): Promise<string> {
  noPath(target);
  const visible = reading.workspaceSessions();
  if (target.id === "")
    return listSessions(
      "Sessions in this workspace",
      visible.sort((a, b) => b.lastActivity - a.lastActivity),
      "read history://<id> for a transcript",
    );
  const session = pickRow(target, "session", visible);
  const trace = await reading.transcript(session.id);
  if (trace === null)
    throw new Error(
      `history://${session.id} cannot be read: it is not a server-durable session. Use \`oppi session trace ${session.id}\`.`,
    );
  return `${sessionLabel(session)}\n\n${renderTranscript(trace)}`;
}

async function readAgent(reading: SessionReading, target: InternalTarget): Promise<string> {
  noPath(target);
  const children = descendants(reading.workspaceSessions(), reading.sessionId);
  if (target.id === "")
    return listSessions(
      "Sessions this session launched",
      children,
      "read agent://<id> for the answer",
    );
  const child = pickRow(target, "child session", children);
  const { id } = child;
  const trace = await reading.transcript(id);
  if (trace === null)
    throw new Error(
      `agent://${id} cannot be read: it is not a server-durable session. Use \`oppi session trace ${id}\`.`,
    );
  const running = child.status === "busy" || child.status === "starting";
  const answer = [...trace].reverse().find((event) => event.type === "assistant" && event.text);
  if (!running)
    return `${sessionLabel(child)}\n\n${answer?.text ?? "(the session has not produced an answer)"}`;
  const progress = trace.slice(-5).map(renderEvent).filter(Boolean).join("\n");
  return `${sessionLabel(child)}\nStill working; the answer is not final.\n\nProgress:\n${progress}`;
}

const EVENT_TEXT_CAP = 4000;

function clip(text: string, cap = EVENT_TEXT_CAP): string {
  return text.length > cap ? `${text.slice(0, cap)}… [${text.length - cap} more characters]` : text;
}

function renderEvent(event: TraceEvent): string {
  switch (event.type) {
    case "user":
    case "assistant":
    case "system":
      return event.text ? `## ${event.type}\n${clip(event.text)}` : "";
    case "toolCall":
      return `→ ${event.tool ?? "tool"} ${clip(JSON.stringify(event.args ?? {}), 300)}`;
    case "toolResult":
      return `← ${clip(event.output ?? "", 600)}`;
    case "compaction":
      return "[context compacted]";
    default:
      return "";
  }
}

function renderTranscript(trace: readonly TraceEvent[]): string {
  return trace.map(renderEvent).filter(Boolean).join("\n\n");
}

// --- mcp -------------------------------------------------------------------------------------

/**
 * `mcp://<resource-uri>` through the session's own MCP resource tools, so the servers it reaches
 * and the answer it gets are exactly what `list_mcp_resources` and `read_mcp_resource` give it.
 */
const readMcp: SchemeReader = async (target, api, context) => {
  // The listing is JSON text; a read's text is the resource itself, never parsed.
  const listing = await mcpCall(api, "list_mcp_resources", {}, context);
  const listed = recordsOf(typeof listing === "string" ? parseJson(listing) : listing, "resources");
  if (target.rest === "")
    return listed.length === 0
      ? "No MCP resources are available."
      : `MCP resources (read mcp://<uri>):\n${listed
          .map((item) => `${String(item.server)}  ${String(item.uri)}  ${String(item.name ?? "")}`)
          .join("\n")}`;
  const match = listed.find((item) => item.uri === target.rest);
  if (!match)
    throw new Error(
      `No MCP resource "${target.rest}". Available: ${listed.map((item) => String(item.uri)).join(", ") || "none"}.`,
    );
  const read = await mcpCall(
    api,
    "read_mcp_resource",
    { server: String(match.server), uri: target.rest },
    context,
  );
  if (typeof read === "string") return read;
  const contents = recordsOf(read, "contents");
  return contents
    .map(
      (part) =>
        (contents.length > 1 ? `${String(part.uri)}:\n` : "") +
        (typeof part.text === "string"
          ? part.text
          : `[binary ${String(part.mimeType ?? "data")}, ${String(part.blob ?? "").length} base64 characters omitted]`),
    )
    .join("\n\n");
};

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function recordsOf(value: unknown, key: string): Record<string, unknown>[] {
  const list = isRecord(value) ? value[key] : undefined;
  return Array.isArray(list) ? list.filter(isRecord) : [];
}

async function mcpCall(
  api: ToolExecutionApi,
  tool: string,
  args: { [key: string]: JsonValue },
  context: Context,
): Promise<unknown> {
  const result = await api.executeTool(tool, args, context).catch((error: unknown) => {
    throw new Error(
      `mcp:// needs the session's MCP resource tools, which are not available here (${error instanceof Error ? error.message : String(error)}).`,
    );
  });
  if (result.isError)
    throw new Error(
      result.diagnostics.map((diagnostic) => diagnostic.message).join("; ") || `${tool} failed`,
    );
  return result.structuredOutput;
}
