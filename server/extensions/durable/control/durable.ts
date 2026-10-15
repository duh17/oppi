import type { Context, JsonValue } from "@earendil-works/chord";
import type { TSchema } from "typebox";
import {
  defineDoc,
  defineExtension,
  defineTool,
  section,
  type Extension,
  type TaskId,
  type ToolRegistration,
  type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import {
  DurableUI,
  oppiHost,
  requestUI,
  type ControlJson,
  type ControlWrite,
  type DurableControlHost,
} from "oppi/durable";

// ---------------------------------------------------------------------------------------------
// The tools: ONE table. Every control tool, its argv, and its schemas live here. The schemas
// mirror server types (`AgentDefinition` in agent-launch-service.ts, `AgentSchedule` in
// agent-schedules.ts, the `oppi session|workspace ...` JSON data) and the CLI's own flags, and are
// kept small on purpose: they are sent with every request and shown in the `codemode` section.
// ---------------------------------------------------------------------------------------------

type Schema = { [key: string]: unknown };
const str: Schema = { type: "string" };
const num: Schema = { type: "number" };
const bool: Schema = { type: "boolean" };
const any: Schema = {};
const list = (items: Schema): Schema => ({ type: "array", items });
const obj = (properties: { [key: string]: Schema }, required: string[] = []): Schema => ({
  type: "object",
  properties,
  ...(required.length > 0 ? { required } : {}),
});
const noArgs: Schema = { type: "object", properties: {}, additionalProperties: false };
const nullable = (schema: Schema): Schema => ({ anyOf: [schema, { type: "null" }] });

const agent = obj({ id: str, version: num }, ["id", "version"]);

/** First-class `oppi agent create|update` flags (kebab-case there); JSON is for bulk edits via oppi(). */
const agentFields = { name: str, instructions: str, model: str };
const scheduleRow = obj({ id: str, status: str }, ["id", "status"]);

const id = { id: str };
const idOnly = obj(id, ["id"]);

interface Entry {
  /** The tool name. */
  name: string;
  description: string;
  /** The CLI command words. */
  cmd: string[];
  input: Schema;
  output: Schema;
  /** Sends requests that change Oppi; each asks the owner. Every other tool only reads. */
  write?: true;
  /** Arguments passed as positionals, in order; an array argument spreads. Every other argument is a flag. */
  positional?: string[];
  /** Words appended after the arguments. */
  fixed?: string[];
  /** Flag name for an argument whose flag is not its kebab-case name. */
  flagOf?: { [argument: string]: string };
  /** Resolve the whole envelope instead of its `data`. */
  envelope?: true;
  /** Resolve `data[pick]`, the one record the command returns. */
  pick?: string;
  /** Bring the command's `data` to the one shape `output` declares. */
  shape?: (data: ControlJson) => JsonValue;
}

const TABLE: readonly Entry[] = [
  {
    name: "oppi",
    description:
      "Run any oppi CLI command, for example argv ['session','list','--since','1d']. Returns the JSON envelope. Writes ask the owner.",
    cmd: [],
    input: obj({ argv: list(str) }, ["argv"]),
    output: obj({ ok: bool, data: any, error: obj({ message: str, code: str }, ["message"]) }, [
      "ok",
    ]),
    write: true,
    envelope: true,
  },
  {
    name: "agents_list",
    description: "List saved Agents.",
    cmd: ["agent", "list"],
    input: noArgs,
    output: obj({ agents: list(obj({ id: str, name: str }, ["id", "name"])) }, ["agents"]),
  },
  {
    name: "agents_get",
    description: "Read one saved Agent.",
    cmd: ["agent", "get"],
    input: idOnly,
    positional: ["id"],
    output: agent,
    pick: "agent",
  },
  {
    name: "agents_create",
    description: "Create a saved Agent.",
    cmd: ["agent", "create"],
    input: obj(agentFields, ["name"]),
    output: agent,
    write: true,
    pick: "agent",
  },
  {
    name: "agents_update",
    description: "Update a saved Agent. Pass expectedVersion.",
    cmd: ["agent", "update"],
    input: obj({ ...id, expectedVersion: num, instructions: str, model: str }, ["id"]),
    positional: ["id"],
    output: agent,
    write: true,
    pick: "agent",
  },
  {
    name: "agents_archive",
    description: "Archive a saved Agent.",
    cmd: ["agent", "archive"],
    input: idOnly,
    positional: ["id"],
    output: any,
    write: true,
  },
  {
    name: "schedules_list",
    description: "List schedules.",
    cmd: ["schedule", "list"],
    input: noArgs,
    output: obj({ schedules: list(scheduleRow) }, ["schedules"]),
  },
  {
    name: "schedules_get",
    description: "Read one schedule.",
    cmd: ["schedule", "get"],
    input: idOnly,
    positional: ["id"],
    output: any,
    pick: "schedule",
  },
  {
    name: "schedules_create",
    description: "Create a schedule: one of at, every, or cron.",
    cmd: ["schedule", "create"],
    input: obj(
      {
        name: str,
        prompt: str,
        workspace: str,
        agent: str,
        at: str,
        every: str,
        cron: str,
        tz: str,
      },
      ["name", "prompt"],
    ),
    output: scheduleRow,
    write: true,
    pick: "schedule",
  },
  {
    name: "schedules_update",
    description: "Patch a schedule's definition.",
    cmd: ["schedule", "update"],
    input: obj({ ...id, patch: any }, ["id", "patch"]),
    positional: ["id"],
    flagOf: { patch: "definition-json" },
    output: any,
    write: true,
  },
  {
    name: "schedules_run",
    description: "Run a schedule now.",
    cmd: ["schedule", "run"],
    input: idOnly,
    positional: ["id"],
    output: obj({ id: str, sessionId: str }, ["id"]),
    write: true,
    pick: "run",
  },
  {
    name: "sessions_create",
    description: "Start a session in a workspace with a prompt.",
    cmd: ["session", "create"],
    input: obj({ workspace: str, prompt: str }, ["workspace", "prompt"]),
    output: obj({ session_id: str }, ["session_id"]),
    write: true,
  },
  {
    name: "sessions_send",
    description: "Send a message to a session.",
    cmd: ["session", "send"],
    input: obj({ ...id, text: str }, ["id", "text"]),
    positional: ["id"],
    output: any,
    write: true,
  },
  {
    name: "sessions_wait",
    description: "Wait until sessions are idle; never poll. Check timed_out.",
    cmd: ["session", "wait"],
    input: obj({ ids: list(str), timeout: str, all: bool }, ["ids"]),
    positional: ["ids"],
    output: obj(
      {
        timed_out: bool,
        sessions: list(
          obj({ session_id: str, status: nullable(str), reason: str }, ["session_id"]),
        ),
      },
      ["timed_out", "sessions"],
    ),
    // One shape for every case: the CLI answers one id with that session's object, and many
    // ids, `all`, or a timeout with a `sessions` list; a status can be unknown (null).
    shape: (data) => {
      if (typeof data.session_id === "string")
        return {
          timed_out: false,
          sessions: [
            {
              session_id: data.session_id,
              status: data.status ?? null,
              ...(typeof data.reason === "string" ? { reason: data.reason } : {}),
            },
          ],
        };
      return { timed_out: data.timed_out === true, sessions: data.sessions ?? [] };
    },
  },
  {
    name: "sessions_response",
    description: "Read a session's last response.",
    cmd: ["session", "inspect"],
    input: idOnly,
    positional: ["id"],
    fixed: ["--view", "response", "--turns", "last"],
    output: obj({ text: str }, ["text"]),
  },
  {
    name: "workspaces_list",
    description: "List workspaces.",
    cmd: ["workspace", "list"],
    input: noArgs,
    output: obj({ workspaces: list(obj({ id: str, name: str }, ["id"])) }, ["workspaces"]),
  },
  {
    name: "workspaces_get",
    description: "Read one workspace.",
    cmd: ["workspace", "get"],
    input: idOnly,
    positional: ["id"],
    output: any,
    pick: "workspace",
  },
];

const kebab = (name: string): string =>
  name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);

/** The CLI argv for the tool's arguments: positionals, then flags. The Harness validated them. */
function argvOf(entry: Entry, given: { [key: string]: unknown }): string[] {
  if (entry.name === "oppi") return [...(given.argv as string[])];
  const properties = Object.keys(entry.input.properties as object);
  const positional = (entry.positional ?? []).flatMap((name) => {
    const found = given[name];
    const parts = Array.isArray(found) ? found : [found];
    if (parts.length === 0 || !parts.every((part) => typeof part === "string" && part !== ""))
      throw new TypeError(`Missing argument: ${name}`);
    return parts as string[];
  });
  const flags = properties
    .filter((name) => !(entry.positional ?? []).includes(name) && given[name] !== undefined)
    .flatMap((name) => {
      const flag = `--${entry.flagOf?.[name] ?? kebab(name)}`;
      const found = given[name];
      if (found === true) return [flag];
      if (found === false) return [];
      return [flag, typeof found === "object" ? JSON.stringify(found) : String(found)];
    });
  // Positionals go after `--`: an id may start with `-`, which the CLI would read as a flag.
  return [
    ...entry.cmd,
    ...flags,
    ...(entry.fixed ?? []),
    ...(positional.length > 0 ? ["--", ...positional] : []),
  ];
}

/** The prompt section: what the control conversation is for, and how to use its tools. */
export const CONTROL_SECTION = [
  "Oppi control: manage Agents, schedules, sessions, and workspaces through the tools here. " +
    "Call them directly, or batch them in a codemode script (tools.<name>). " +
    "Every write asks the owner first. Read before you write.",
  "- Use sessions_wait, never poll; check timed_out.",
  "- Always pass --since: oppi({ argv: ['session','list','--since','1d'] }).",
  "- agents_update: pass expectedVersion.",
  "- Unfamiliar verb: oppi({ argv: [cmd,'--help'] }) first.",
].join("\n");

// ---------------------------------------------------------------------------------------------
// The owner's confirm card
// ---------------------------------------------------------------------------------------------

const YES = "Yes";
const YES_ALL = "Yes to all remaining in this script";
const NO = "No";
/** Longest request body a confirm card shows. A longer one is refused: the owner approves only what they can read. */
const CARD_BODY_LIMIT = 6000;

/**
 * "Yes to all" of one codemode script, on the script's own task: its later writes go out without
 * a card, and the next script asks again. Retired with the script.
 */
const ScriptApproval = defineDoc<{ all: boolean }>({
  kind: "oppi.control-approval",
  version: 1,
  scope: "task",
  initial: () => ({ all: false }),
});

/**
 * Cards of one script, or of one conversation's direct calls, are asked one at a time, so a
 * "Yes to all" answer covers the writes waiting behind it. Process memory: a restart re-asks in
 * whatever order the calls resume.
 */
const asking = new Map<string, Promise<unknown>>();

class Declined extends Error {
  readonly code = "declined";

  constructor() {
    super("The owner declined this write.");
  }
}

/**
 * A rerun of the call built another write than the one the owner was asked about at this card:
 * the CLI resolves names (a workspace, an agent, a session prefix) into the request, and they
 * can resolve elsewhere after a restart. A saved answer belongs to its request only.
 */
class CardChanged extends Error {
  readonly code = "card_changed";

  constructor() {
    super(
      "This write is not the one the owner was asked about before the restart, so it was not " +
        "sent. Call the tool again.",
    );
  }
}

/** The body does not fit on a confirm card, so nothing is asked and nothing is sent. */
class BodyTooLarge extends Error {
  readonly code = "body_too_large";

  constructor(length: number) {
    super(
      `The request body is ${length} characters; a confirm card shows at most ${CARD_BODY_LIMIT}, ` +
        "and nothing was sent. Send less in one write.",
    );
  }
}

/** `name: before → after` for each leaf of a merge patch against the record it patches. */
function patchDiff(body: JsonValue, current: JsonValue): string[] {
  const record = (value: JsonValue | undefined): ControlJson | undefined =>
    value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
  let base = record(current);
  // `GET /agents/:id` wraps the record, and an Agent's patch is of its `definition`.
  const wrapped =
    base && Object.keys(base).length === 1 ? record(Object.values(base)[0]) : undefined;
  base = wrapped ?? base;
  const inner = record(base?.definition);
  const lines: string[] = [];
  const walk = (patch: JsonValue, before: JsonValue | undefined, name: string): void => {
    const patchRecord = record(patch);
    if (patchRecord) {
      for (const [key, value] of Object.entries(patchRecord))
        walk(value, record(before)?.[key], name ? `${name}.${key}` : key);
      return;
    }
    if (JSON.stringify(patch) === JSON.stringify(before)) return;
    const shown = (value: JsonValue | undefined): string =>
      value === undefined ? "(unset)" : JSON.stringify(value);
    lines.push(`  ${name}: ${shown(before)} → ${patch === null ? "(removed)" : shown(patch)}`);
  };
  const patch = record(body);
  if (!patch) return lines;
  for (const [key, value] of Object.entries(patch)) {
    const before = base && key in base ? base[key] : inner?.[key];
    walk(value, before, key);
  }
  return lines;
}

function cardMessage(write: ControlWrite): string {
  const lines = [`${write.method} ${write.path}`];
  if (write.body !== undefined) {
    const text = JSON.stringify(write.body, null, 2);
    if (text.length > CARD_BODY_LIMIT) throw new BodyTooLarge(text.length);
    lines.push("Request body:", text);
  }
  if (write.method === "PATCH") {
    if (write.current === undefined)
      lines.push(
        `Current record unavailable${write.currentError ? `: ${write.currentError}` : ""}.`,
      );
    else {
      const diff = write.body === undefined ? [] : patchDiff(write.body, write.current);
      lines.push("Changes against the current record:", ...(diff.length > 0 ? diff : ["  (none)"]));
    }
    if (!/[?&]expectedVersion=/.test(write.path))
      lines.push("No expected version: this applies over any newer change.");
  }
  return lines.join("\n");
}

/** The codemode script that made this call, or undefined for a call the model made directly. */
async function scriptOf(api: ToolExecutionApi, context: Context): Promise<TaskId | undefined> {
  const input = (await api.getTask(api.taskId, context))?.input as
    { kind?: string; parent?: TaskId } | undefined;
  return input?.kind === "nested" ? input.parent : undefined;
}

/**
 * Ask the owner about one write of this call. The card is this call's (its task and the write's
 * place in the command), and `requestUI` keeps the answer with the call, so a rerun after a
 * crash, which runs the same arguments, gets the same answer instead of a second card.
 */
async function confirm(
  api: ToolExecutionApi,
  context: Context,
  script: TaskId | undefined,
  slot: number,
  write: ControlWrite,
): Promise<void> {
  // Before "Yes to all" too: no write goes out with a body its owner could not see.
  const message = cardMessage(write);
  const ask = async (): Promise<void> => {
    // What the owner is asked, kept with the call before anything is asked, first write wins.
    // Under "Yes to all" too: a rerun's write must be the one this card stood for.
    const shown = JSON.stringify([write.method, write.path, write.body ?? null]);
    if ((await api.memo<string>(`oppi-card:${slot}`, shown, context)) !== shown)
      throw new CardChanged();
    if (script !== undefined && (await api.snapshot(ScriptApproval, script, context))?.all === true)
      return;
    const id = `oppi-confirm:${api.taskId}:${slot}`;
    let answer;
    try {
      answer = await requestUI(
        api,
        {
          id,
          method: "select",
          title: `Allow ${write.method} ${write.path.split("?")[0]}?`,
          message,
          options: script === undefined ? [YES, NO] : [YES, YES_ALL, NO],
          extensionScopeId: "oppi:control",
          extensionDisplayName: "Oppi control",
        },
        context,
      );
    } catch (error) {
      // The call was stopped with its card still open: take the card down.
      if (context.abortSignal?.aborted)
        await api
          .commit(async (tx) => {
            delete (await tx.doc(DurableUI, api.conversationId)).requests[id];
          }, context)
          .catch(() => undefined);
      throw error;
    }
    if (answer.cancelled || (answer.value !== YES && answer.value !== YES_ALL))
      throw new Declined();
    if (answer.value === YES_ALL && script !== undefined)
      await api.commit(async (tx) => {
        (await tx.doc(ScriptApproval, script)).all = true;
      }, context);
  };
  const queue = script !== undefined ? `script:${script}` : `conversation:${api.conversationId}`;
  const next = (asking.get(queue) ?? Promise.resolve()).then(ask, ask);
  const settled = next.catch(() => undefined);
  asking.set(queue, settled);
  try {
    await next;
  } finally {
    if (asking.get(queue) === settled) asking.delete(queue);
  }
}

// ---------------------------------------------------------------------------------------------
// One tool per table entry
// ---------------------------------------------------------------------------------------------

/**
 * A control tool: ordinary, so the model calls it directly and codemode scripts call it as
 * `tools.<name>`. A finished call keeps its result, and a write carries a replay key derived from
 * its task, so a rerun after a crash neither runs twice nor writes twice for keyed commands.
 */
function controlTool(
  entry: Entry,
  host: (env: ExecutionEnv | undefined) => DurableControlHost | undefined,
): ToolRegistration {
  return defineTool({
    name: entry.name,
    description: entry.description,
    // JSON Schema; pi-durable validates arguments and structured output with TypeBox, which accepts it.
    parameters: entry.input as unknown as TSchema,
    structuredOutputSchema: entry.output as unknown as TSchema,
    replay: "safe",
    async execute(args, api, context) {
      const bound = host(api.env);
      if (!bound) throw new Error("Oppi control is not available: the Oppi host is not bound");
      const argv = argvOf(entry, args as { [key: string]: unknown });
      const script = entry.write ? await scriptOf(api, context) : undefined;
      let slot = 0;
      const { envelope } = await bound.run(argv, {
        conversationId: api.conversationId,
        key: String(api.taskId),
        signal: context.abortSignal ?? new AbortController().signal,
        ...(entry.write
          ? { onWrite: (write: ControlWrite) => confirm(api, context, script, slot++, write) }
          : {}),
      });
      let value: JsonValue;
      if (entry.envelope) value = envelope;
      else if (envelope.ok === true) {
        const data = envelope.data as ControlJson | undefined;
        value = (entry.pick && data ? data[entry.pick] : data) ?? null;
        if (entry.shape && data) value = entry.shape(data);
      } else {
        const error = envelope.error as { message?: string; code?: string } | undefined;
        throw new Error(
          `${error?.message ?? "oppi command failed"}${error?.code ? ` [${error.code}]` : ""}`,
        );
      }
      return {
        output: [{ type: "text" as const, text: JSON.stringify(value) }],
        structuredOutput: value,
      };
    },
  });
}

/**
 * The `oppi.control` extension over `host`, which finds the `oppi` CLI for a tool call's
 * execution env. The package's entry binds it to `oppiHost()`; tests bind their own.
 */
export function createDurableControl(
  host: (env: ExecutionEnv | undefined) => DurableControlHost | undefined,
): Extension {
  return defineExtension({
    name: "oppi.control",
    tools: TABLE.map((entry) => controlTool(entry, host)),
    sections: [section("oppi-control", () => CONTROL_SECTION, { tag: false })],
  });
}

/** The durable entry (`package.json` `oppi.durable`): the control tools over the server's CLI. */
export default createDurableControl((env) => oppiHost().control(env));
