import { Type } from "typebox";
import type { Context, JsonValue } from "@earendil-works/chord";
import {
  CodemodeSandbox,
  renderDeclarations,
  type CodemodeJsonSchema,
  type CodemodeTool,
} from "@earendil-works/pi-codemode";
import {
  defineExtension,
  defineTool,
  section,
  type ConversationId,
  type Extension,
  type ToolRegistration,
  type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { DurableUI, requestUI } from "../durable-ui.js";

/** A JSON object; the CLI envelope is one, and a memo must be JSON. */
export type ControlJson = { [key: string]: JsonValue };

/** One write the CLI is about to send, as the owner must see it before it goes out. */
export interface ControlWrite {
  method: string;
  /** Path and query, as sent. */
  path: string;
  body?: JsonValue;
  /** For a PATCH: the record as it is now, fetched by the host; absent when it could not be read. */
  current?: JsonValue;
  currentError?: string;
}

/**
 * What the control tools need from Oppi. The extension is static harness code and cannot import
 * server modules, so the server hands this in when it binds the Harness (see `DurableControlCli`).
 */
export interface DurableControlHost {
  /**
   * Run one `oppi` CLI invocation in this process and resolve its JSON envelope; never rejects
   * for a failing command. `onWrite` is awaited before each non-GET request is sent and decides
   * it by resolving or throwing; without `onWrite` every non-GET is refused. `key` is
   * deterministic per call, so a retry of the same call is the same write: the host derives
   * idempotency keys from it. `wrote` is true once a write was approved.
   */
  run(
    argv: readonly string[],
    options: {
      conversationId: ConversationId;
      key: string;
      signal: AbortSignal;
      onWrite?: (write: ControlWrite) => Promise<void>;
    },
  ): Promise<{ envelope: ControlJson; wrote: boolean }>;
}

// ---------------------------------------------------------------------------------------------
// The script API: ONE table. Everything the sandbox can call, its argv, and its schemas live here.
// The schemas mirror server types (`AgentDefinition` in agent-launch-service.ts, `AgentSchedule` in
// agent-schedules.ts, the `oppi session|workspace ...` JSON data) and the CLI's own flags, and are
// kept small on purpose: the rendered declarations are part of the system prompt, which has a
// fixed budget (see the control tests).
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

const agent = obj({ id: str, version: num }, ["id", "version"]);

/** First-class `oppi agent create|update` flags (kebab-case there); JSON is for bulk edits via oppi(). */
const agentFields = { name: str, instructions: str, model: str };
const scheduleRow = obj({ id: str, status: str }, ["id", "status"]);

const id = { id: str };
const idOnly = obj(id, ["id"]);

interface Entry {
  /** The script name; `a.b` is member `b` of the frozen object `a`. */
  name: string;
  /** The CLI command words. */
  cmd: string[];
  input: Schema;
  output: Schema;
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
}

const TABLE: readonly Entry[] = [
  {
    name: "oppi",
    cmd: [],
    input: list(str),
    output: obj({ ok: bool, data: any, error: obj({ message: str, code: str }, ["message"]) }, [
      "ok",
    ]),
    envelope: true,
  },
  {
    name: "agents.list",
    cmd: ["agent", "list"],
    input: noArgs,
    output: obj(
      { agents: list(obj({ id: str, name: str, version: num }, ["id", "name", "version"])) },
      ["agents"],
    ),
  },
  {
    name: "agents.get",
    cmd: ["agent", "get"],
    input: idOnly,
    positional: ["id"],
    output: agent,
    pick: "agent",
  },
  {
    name: "agents.create",
    cmd: ["agent", "create"],
    input: obj(agentFields, ["name"]),
    output: agent,
    pick: "agent",
  },
  {
    name: "agents.update",
    cmd: ["agent", "update"],
    input: obj({ ...id, expectedVersion: num, instructions: str, model: str }, ["id"]),
    positional: ["id"],
    output: agent,
    pick: "agent",
  },
  {
    name: "agents.archive",
    cmd: ["agent", "archive"],
    input: idOnly,
    positional: ["id"],
    output: any,
  },
  {
    name: "schedules.list",
    cmd: ["schedule", "list"],
    input: noArgs,
    output: obj({ schedules: list(scheduleRow) }, ["schedules"]),
  },
  {
    name: "schedules.get",
    cmd: ["schedule", "get"],
    input: idOnly,
    positional: ["id"],
    output: any,
    pick: "schedule",
  },
  {
    name: "schedules.create",
    cmd: ["schedule", "create"],
    input: obj({ prompt: str, workspace: str, at: str, every: str, cron: str }, ["prompt"]),
    output: scheduleRow,
    pick: "schedule",
  },
  {
    name: "schedules.update",
    cmd: ["schedule", "update"],
    input: obj({ ...id, patch: any }, ["id", "patch"]),
    positional: ["id"],
    flagOf: { patch: "definition-json" },
    output: any,
  },
  {
    name: "schedules.run",
    cmd: ["schedule", "run"],
    input: idOnly,
    positional: ["id"],
    output: obj({ id: str, sessionId: str }, ["id"]),
    pick: "run",
  },
  {
    name: "sessions.create",
    cmd: ["session", "create"],
    input: obj({ workspace: str, prompt: str }, ["workspace", "prompt"]),
    output: obj({ session_id: str }, ["session_id"]),
  },
  {
    name: "sessions.send",
    cmd: ["session", "send"],
    input: obj({ ...id, text: str }, ["id", "text"]),
    positional: ["id"],
    output: any,
  },
  {
    name: "sessions.wait",
    cmd: ["session", "wait"],
    input: obj({ ids: list(str), timeout: str, all: bool }, ["ids"]),
    positional: ["ids"],
    output: obj(
      { timed_out: bool, sessions: list(obj({ session_id: str, status: str }, ["session_id"])) },
      ["sessions"],
    ),
  },
  {
    name: "sessions.response",
    cmd: ["session", "inspect"],
    input: idOnly,
    positional: ["id"],
    fixed: ["--view", "response", "--turns", "last"],
    output: obj({ text: str }, ["text"]),
  },
  {
    name: "workspaces.list",
    cmd: ["workspace", "list"],
    input: noArgs,
    output: obj({ workspaces: list(obj({ id: str, name: str }, ["id"])) }, ["workspaces"]),
  },
  {
    name: "workspaces.get",
    cmd: ["workspace", "get"],
    input: idOnly,
    positional: ["id"],
    output: any,
    pick: "workspace",
  },
];

const kebab = (name: string): string =>
  name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);

/** The CLI argv for what the script passed: positionals, then flags, checked against the entry's schema. */
function argvOf(entry: Entry, value: unknown): string[] {
  if (entry.name === "oppi") {
    if (!Array.isArray(value) || !value.every((part) => typeof part === "string"))
      throw new TypeError("oppi expects an array of strings, for example oppi(['agent', 'list'])");
    return value as string[];
  }
  if (value !== undefined && (typeof value !== "object" || value === null || Array.isArray(value)))
    throw new TypeError("Expected an object argument");
  const given = (value ?? {}) as { [key: string]: unknown };
  const properties = Object.keys(entry.input.properties as object);
  const unknown = Object.keys(given).filter((name) => !properties.includes(name));
  if (unknown.length > 0) throw new TypeError(`Unknown argument: ${unknown.join(", ")}`);
  for (const name of (entry.input.required as string[] | undefined) ?? [])
    if (given[name] === undefined) throw new TypeError(`Missing argument: ${name}`);
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

/** The declarations of the table; rendered once, shown to the model in the prompt section. */
export const CONTROL_DECLARATIONS = renderDeclarations({
  globals: TABLE.map((entry) => ({
    name: entry.name,
    inputSchema: entry.input as CodemodeJsonSchema,
    outputSchema: entry.output as CodemodeJsonSchema,
    execute: () => undefined,
  })),
});

const ROLE =
  "Oppi control. oppi_query: read-only JS. oppi_script: may write; the owner approves each " +
  "write. Query first. Globals:";
const GUIDANCE = [
  "Filter in JS before text().",
  "Use sessions.wait, never poll (no timers); check timed_out.",
  "Always pass --since: oppi(['session','list','--since','1d']).",
  "agents.update: pass expectedVersion.",
  "Unfamiliar verb: oppi([cmd,'--help']) first.",
];
/** The prompt section: role, the rendered declarations, the guidance. */
export const CONTROL_SECTION = `${ROLE}\n${CONTROL_DECLARATIONS}\n${GUIDANCE.map((line) => `- ${line}`).join("\n")}`;

// ---------------------------------------------------------------------------------------------
// One script execution
// ---------------------------------------------------------------------------------------------

const YES = "Yes";
const YES_ALL = "Yes to all remaining in this script";
const NO = "No";
/** Longest request body shown whole on a confirm card. */
const CARD_BODY_LIMIT = 6000;

/** What a confirmed call keeps, so a rerun after a crash returns it instead of writing again. */
type Saved = { argv: string[]; envelope: ControlJson; all: boolean };

class Declined extends Error {
  constructor() {
    super("The owner declined this write.");
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
    lines.push(
      "Request body:",
      text.length > CARD_BODY_LIMIT
        ? `${text.slice(0, CARD_BODY_LIMIT)}\n… ${text.length - CARD_BODY_LIMIT} more characters`
        : text,
    );
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

/**
 * One tool call's script. Indices are taken synchronously when the script calls, so they are the
 * script's own call order however the calls overlap; a rerun after a crash numbers them the same.
 */
class ControlScript {
  private calls = 0;
  private writes = 0;
  private approveAll = false;
  /** Confirm cards are asked one at a time, so "Yes to all" covers the writes behind it. */
  private approvals: Promise<void> = Promise.resolve();

  constructor(
    private readonly api: ToolExecutionApi,
    private readonly context: Context,
    private readonly host: DurableControlHost,
    private readonly writable: boolean,
  ) {}

  stats(): { calls: number; writes: number } {
    return { calls: this.calls, writes: this.writes };
  }

  globals(): CodemodeTool[] {
    return TABLE.map((entry) => ({
      name: entry.name,
      inputSchema: entry.input as CodemodeJsonSchema,
      outputSchema: entry.output as CodemodeJsonSchema,
      execute: async (value, { signal }) => {
        const envelope = await this.call(argvOf(entry, value), signal);
        if (entry.envelope) return envelope;
        if (envelope.ok === true) {
          const data = envelope.data as ControlJson | undefined;
          return (entry.pick && data ? data[entry.pick] : data) ?? null;
        }
        const error = envelope.error as { message?: string; code?: string } | undefined;
        throw new Error(
          `${error?.message ?? "oppi command failed"}${error?.code ? ` [${error.code}]` : ""}`,
        );
      },
    }));
  }

  private async call(argv: string[], signal: AbortSignal): Promise<ControlJson> {
    const index = this.calls++;
    const name = `oppi-call:${index}`;
    const saved = await this.api.memo<Saved>(name, this.context);
    if (saved) {
      if (JSON.stringify(saved.argv) !== JSON.stringify(argv))
        throw new Error(
          `oppi call ${index} is not the call that already ran before the restart; run the script again`,
        );
      if (saved.all) this.approveAll = true;
      return saved.envelope;
    }
    // Aborting the script abandons a pending card; aborting the call stops everything.
    const context = Object.create(this.context, {
      abortSignal: {
        value: AbortSignal.any([
          signal,
          ...(this.context.abortSignal ? [this.context.abortSignal] : []),
        ]),
      },
    }) as Context;
    let asked = 0;
    const result = await this.host.run(argv, {
      conversationId: this.api.conversationId,
      key: `${this.api.taskId}:${index}`,
      signal: context.abortSignal ?? signal,
      ...(this.writable
        ? { onWrite: (write: ControlWrite) => this.confirm(`${index}.${asked++}`, write, context) }
        : {}),
    });
    if (!result.wrote) return result.envelope;
    this.writes++;
    // First write wins: a crash between the store write and here reruns the call with the same
    // key, and the host's idempotency keys make that the same write.
    const kept: Saved = { argv, envelope: result.envelope, all: this.approveAll };
    return (await this.api.memo<Saved>(name, kept, context)).envelope;
  }

  private confirm(slot: string, write: ControlWrite, context: Context): Promise<void> {
    const ask = async (): Promise<void> => {
      if (this.approveAll) return;
      const id = `oppi-confirm:${this.api.taskId}:${slot}`;
      let answer;
      try {
        answer = await requestUI(
          this.api,
          {
            id,
            method: "select",
            title: `Allow ${write.method} ${write.path.split("?")[0]}?`,
            message: cardMessage(write),
            options: [YES, YES_ALL, NO],
            extensionScopeId: "oppi:control",
            extensionDisplayName: "Oppi control",
          },
          context,
        );
      } catch (error) {
        // The script ended with the card still open; the call itself is still live.
        if (context.abortSignal?.aborted && !this.context.abortSignal?.aborted)
          await this.dropCard(id).catch(() => undefined);
        throw error;
      }
      if (answer.cancelled || (answer.value !== YES && answer.value !== YES_ALL))
        throw new Declined();
      if (answer.value === YES_ALL) this.approveAll = true;
    };
    const next = this.approvals.then(ask, ask);
    this.approvals = next.catch(() => undefined);
    return next;
  }

  private dropCard(id: string): Promise<void> {
    return this.api.commit(async (tx) => {
      delete (await tx.doc(DurableUI, this.api.conversationId)).requests[id];
    }, this.context);
  }
}

function scriptTool(
  name: "oppi_query" | "oppi_script",
  host: () => DurableControlHost | undefined,
): ToolRegistration {
  const writable = name === "oppi_script";
  return defineTool({
    name,
    description: writable
      ? "Run JavaScript that reads and changes Oppi through the globals in the oppi-control section. " +
        "Every write asks the owner first. Output with text() or return a value."
      : "Run JavaScript that reads Oppi through the globals in the oppi-control section. Read-only: " +
        "any write is refused. Output with text() or return a value.",
    parameters: Type.Object({
      code: Type.String({ description: "Body of an async function; return and await work." }),
    }),
    // A rerun after a crash replays the script from the top: confirmed writes are memoized per
    // call, so they are returned, not repeated (see ControlScript.call).
    replay: "safe",
    async execute(input, api, context) {
      const bound = host();
      if (!bound) throw new Error("Oppi control is not available: the Oppi host is not bound");
      const script = new ControlScript(api, context, bound, writable);
      const sandbox = new CodemodeSandbox({ globals: script.globals() });
      try {
        const result = await sandbox.execute(input.code, {
          ...(context.abortSignal ? { signal: context.abortSignal } : {}),
        });
        const content: Array<{ type: "text"; text: string }> = result.output.flatMap((item) =>
          item.type === "text" ? [{ type: "text" as const, text: item.text }] : [],
        );
        if (result.ok && result.value !== undefined)
          content.push({ type: "text", text: JSON.stringify(result.value) });
        if (!result.ok)
          content.push({ type: "text", text: result.error.stack ?? result.error.message });
        return { content, details: script.stats(), ...(result.ok ? {} : { isError: true }) };
      } finally {
        await sandbox.close();
      }
    },
  });
}

export function createDurableControl(host: () => DurableControlHost | undefined): Extension {
  return defineExtension({
    name: "oppi.control",
    tools: [scriptTool("oppi_query", host), scriptTool("oppi_script", host)],
    sections: [section("oppi-control", () => CONTROL_SECTION, { tag: false })],
  });
}
