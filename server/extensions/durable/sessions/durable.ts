import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import type { Context, JsonValue } from "@earendil-works/chord";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import {
  AgentDoc,
  AssistantEntry,
  LiveDoc,
  defineDoc,
  defineExtension,
  defineTask,
  defineTool,
  section,
  type Agent,
  type ConversationId,
  type EntryId,
  type Extension,
  type TaskId,
  type ToolExecutionApi,
  type ToolExecutionResult,
  type Tx,
} from "@earendil-works/pi-durable";
import { agentMessageEntry, type MessageOrigin } from "./agent-message.js";

/** A session as the sender of an agent message. */
type Sender = { sessionId: string; name?: string };

function sentBy(
  sender: Sender | undefined,
  intent: MessageOrigin["intent"],
  textOffset?: number,
): { entry?: ReturnType<typeof agentMessageEntry> } {
  return sender
    ? { entry: agentMessageEntry({ kind: "session", ...sender, intent }, textOffset) }
    : {};
}

/** What `subagent spawn` asks for. */
export type SubagentRequest = {
  /** A saved Agent, by id or name. */
  agent?: string;
  /** provider/model; overrides the saved Agent's. */
  model?: string;
  /** Overrides the saved Agent's. */
  thinking?: string;
  allowNestedDelegation?: boolean;
};

/** A spawn the host resolved: how the child conversation is configured. */
export interface ResolvedSubagent {
  /** The saved Agent's name, for `list`. */
  agent?: string;
  /**
   * Configure the new child inside its creating commit: its agent (`configure`), runtime, and
   * `oppi.agent` documents, so it never exists unconfigured.
   */
  apply(tx: Tx, child: ConversationId): Promise<void>;
}

/**
 * What the subagent tool needs from Oppi. The extension is static harness code and cannot
 * import server modules, so the server hands these in when it binds the Harness (see
 * `DurableThreads`).
 */
export interface DurableSessionsHost {
  /**
   * The Oppi Session bound to an owned child conversation, created and attached on
   * first use. Idempotent: one Session per conversation id, however often this runs.
   */
  materialize(
    child: { conversationId: ConversationId; name: string },
    env?: ExecutionEnv,
  ): Promise<string>;
  /** The store of the calling conversation. */
  storeIdOfEnv(env?: ExecutionEnv): string;
  /** The Oppi session bound to a conversation of the calling store: who sent an agent message. */
  sessionOf(conversationId: ConversationId, env?: ExecutionEnv): Sender | undefined;
  /** Submit to a bound session's own store. Undefined on success, otherwise an error message. */
  submit(
    sessionId: string,
    input: {
      content: string;
      whenBusy: "steer" | "followUp";
      requestId: string;
      entry?: ReturnType<typeof agentMessageEntry>;
    },
  ): Promise<string | undefined>;
  /** Wait until a bound session's conversation is idle. */
  waitForIdle(sessionId: string): Promise<string | undefined>;
  /** Attach a stopped Session so a message to it makes progress. */
  activate(sessionId: string): Promise<void>;
  /**
   * Resolve a spawn: the saved Agent, model, and thinking level, checked against the caller's
   * delegation grant and workspace. Rejects with a message for the model.
   */
  resolveAgent(
    request: SubagentRequest,
    caller: { conversationId: ConversationId; env?: ExecutionEnv; agent: Agent },
  ): Promise<ResolvedSubagent>;
}

type Child = {
  conversationId: ConversationId;
  sessionId?: string;
  /** The saved Agent it was spawned as. */
  agent?: string;
  /** Owned by an anchor: its answer comes back as a follow-up. Else owned by the spawning call. */
  background: boolean;
  /** Hands a background child its task and reports the answer. */
  reporter?: TaskId;
};

/** The children of a conversation by name, and which spawn call made which, so a rerun finds it. */
const Subagents = defineDoc<{
  children: Record<string, Child>;
  calls: Record<string, string>;
}>({
  kind: "oppi.subagents",
  version: 1,
  scope: "conversation",
  history: "latest",
  // A fork of the parent starts without its children.
  fork: "initial",
  initial: () => ({ children: {}, calls: {} }),
});

/**
 * Owner of a background child. It finishes at once; being a background task it is the
 * boundary that keeps the parent's Stop and idle waits away from the child
 * (pi-durable example 23).
 */
const Anchor = defineTask<null, { phase: "done" }, null>({
  name: "oppi.session-anchor",
  version: 1,
  initial: () => ({ phase: "done" }),
  phases: {
    done: (_anchor, runtime, context) =>
      runtime.commit(
        () => ({ status: "terminal", outcome: { status: "completed", result: null } }),
        context,
      ),
  },
  abort: (_anchor, runtime, context) =>
    runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
});

type ReporterInput = {
  conversationId: ConversationId;
  sessionId: string;
  name: string;
  task: string;
  /** The spawning session; absent on reporters created before agent messages. */
  parent?: Sender;
};
type ReporterState =
  | { phase: "deliver" }
  | {
      phase: "report";
      report?: string;
      /** Length of the report's model-only header. */
      textOffset?: number;
    };

/** Model-only header of a finished child's report; the transcript shows the text after it. */
function reportHeader(name: string, sessionId: string): string {
  return `[session ${name} (${sessionId}) finished, no reply needed] `;
}

function textOf(message: AssistantMessage | undefined): string {
  return (message?.content ?? [])
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join("");
}

/** Registered name of the reporter task; Stop aborts tasks of this kind (see `DurableHarness`). */
export const SESSION_REPORTER_TASK = "oppi.session-reporter";

/**
 * Hands a background child its task and posts its answer back to the parent. Background
 * too, so the parent's Stop and idle waits leave it alone. Request ids make a restart
 * deliver the task once and the report once.
 */
const Reporter = defineTask<ReporterInput, ReporterState, null>({
  name: SESSION_REPORTER_TASK,
  version: 1,
  initial: () => ({ phase: "deliver" }),
  phases: {
    deliver: async (reporter, runtime, context) => {
      const { conversationId, sessionId, name, task, parent } = reporter.input;
      const child = await runtime.conversation(conversationId, context);
      if (!child) throw new Error(`Subagent ${name} (${sessionId}) conversation disappeared`);
      const submission = await child.submit(
        {
          type: "input",
          content: task,
          requestId: `oppi-spawn:${reporter.id}`,
          ...sentBy(parent, "task"),
        },
        context,
      );
      const settled = await submission.wait(context);
      await runtime.commit(async (tx) => {
        const next = (report?: string, textOffset?: number) =>
          ({
            status: "running",
            checkpoint: { phase: "report", report, ...(textOffset ? { textOffset } : {}) },
          }) as const;
        // Aborted: stopped or withdrawn. Whoever stopped it knows; nothing to report.
        if (settled.status === "unanswered")
          return next(
            settled.reason === "aborted"
              ? undefined
              : `[session ${name} (${sessionId}) failed: ${settled.reason}]`,
          );
        if (settled.type !== "input") return next();
        const answer = (await tx.entry(AssistantEntry, settled.answer))?.model?.[0] as
          AssistantMessage | undefined;
        const header = reportHeader(name, sessionId);
        return next(`${header}${textOf(answer)}`, header.length);
      }, context);
    },
    report: async (reporter, runtime, context) => {
      const { report, textOffset: saved } = reporter.state.checkpoint;
      const { sessionId, name } = reporter.input;
      // A report checkpointed before agent messages has no offset; its header is the same text.
      const header = reportHeader(name, sessionId);
      const textOffset = saved ?? (report?.startsWith(header) ? header.length : undefined);
      if (report !== undefined) {
        const parent = await runtime.conversation(runtime.conversationId, context);
        if (!parent) throw new Error("Parent conversation disappeared");
        // A follow-up starts a turn when the parent is idle, or waits for its answer.
        await parent.submit(
          {
            type: "input",
            content: report,
            whenBusy: "followUp",
            requestId: `oppi-report:${reporter.id}`,
            ...sentBy({ sessionId, name }, "report", textOffset),
          },
          context,
        );
      }
      await runtime.commit(
        () => ({ status: "terminal", outcome: { status: "completed", result: null } }),
        context,
      );
    },
  },
  abort: (_reporter, runtime, context) =>
    runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), context),
});

const GUIDANCE =
  "subagent manages child sessions you address by name. spawn starts one for a self-contained " +
  "task; by default it runs in the background and its answer arrives later as a follow-up " +
  "message, so do not poll. wait: true makes spawn return the answer instead. agent picks a " +
  "saved Agent; model and thinking override it. send messages a child (steer by default, " +
  "followUp: true after its current answer), wait blocks until children are idle and returns " +
  "their latest answers, stop aborts a child's current work (it stays usable), list shows them. " +
  "A child can spawn its own children only when you pass allowNestedDelegation.";

type ReplyDetails = Record<string, JsonValue>;

function reply(
  text: string,
  details: ReplyDetails,
  isError = false,
): ToolExecutionResult<ReplyDetails> {
  return { output: [{ type: "text" as const, text }], details, ...(isError ? { isError } : {}) };
}

export function createDurableSessions(host: () => DurableSessionsHost | undefined): Extension {
  const bound = (): DurableSessionsHost => {
    const current = host();
    if (!current) throw new Error("subagent is not available: the Oppi host is not bound");
    return current;
  };
  const children = async (
    api: ToolExecutionApi,
    context: Context,
  ): Promise<Readonly<Record<string, Child>>> =>
    (await api.snapshot(Subagents, api.conversationId, context))?.children ?? {};
  /** The child's Session; bound again when a crash came between the spawn commit and the bind. */
  const sessionIdOf = (api: ToolExecutionApi, name: string, child: Child): Promise<string> =>
    child.sessionId !== undefined
      ? Promise.resolve(child.sessionId)
      : bound().materialize({ conversationId: child.conversationId, name }, api.env);

  const subagent = defineTool({
    name: "subagent",
    description:
      "Manage child sessions by name. spawn (name, task; optional agent, model, thinking, wait, " +
      "allowNestedDelegation) starts one: in the background by default, its answer arrives later " +
      "as a follow-up message; wait: true returns its answer instead. send (name, message; " +
      "followUp: true queues after its current answer instead of steering) messages one. wait " +
      "(names) blocks until they are idle and returns their latest answers. stop (name) aborts " +
      "its current work; it stays usable. list shows every child.",
    parameters: Type.Object({
      action: Type.Union([
        Type.Literal("spawn"),
        Type.Literal("send"),
        Type.Literal("wait"),
        Type.Literal("stop"),
        Type.Literal("list"),
      ]),
      name: Type.Optional(Type.String({ description: "The child, for spawn, send, and stop." })),
      names: Type.Optional(Type.Array(Type.String(), { description: "The children to wait for." })),
      task: Type.Optional(Type.String({ description: "spawn: what the child should do." })),
      message: Type.Optional(Type.String({ description: "send: the message." })),
      followUp: Type.Optional(
        Type.Boolean({ description: "send: queue after the child's current answer." }),
      ),
      agent: Type.Optional(Type.String({ description: "spawn: a saved Agent, by name or id." })),
      model: Type.Optional(
        Type.String({ description: "spawn: provider/model; default: the Agent's or yours." }),
      ),
      thinking: Type.Optional(
        Type.String({ description: "spawn: thinking level; default: the Agent's or yours." }),
      ),
      wait: Type.Optional(
        Type.Boolean({ description: "spawn: wait for the child's answer and return it." }),
      ),
      allowNestedDelegation: Type.Optional(
        Type.Boolean({ description: "spawn: let the child spawn children of its own." }),
      ),
    }),
    // A rerun after a crash finds the same child, Session, and submissions; stop records its
    // decision before it aborts, so a rerun does not stop newer work.
    replay: "safe",
    async execute(args, api, context) {
      switch (args.action) {
        case "spawn":
          return spawn(args, api, context);
        case "send": {
          const name = args.name?.trim() ?? "";
          const child = (await children(api, context))[name];
          if (!child) return reply(`No subagent named ${name}.`, { name }, true);
          if (!args.message) return reply("send needs a message.", { name }, true);
          const sessions = bound();
          const sessionId = await sessionIdOf(api, name, child);
          await sessions.activate(sessionId);
          const whenBusy = args.followUp === true ? "followUp" : "steer";
          const requestId = `oppi-send:${sessions.storeIdOfEnv(api.env)}:${api.conversationId}:${api.taskId}`;
          const submitError = await sessions.submit(sessionId, {
            content: args.message,
            whenBusy,
            requestId,
            ...sentBy(sessions.sessionOf(api.conversationId, api.env), "message"),
          });
          const details = { name, conversationId: child.conversationId, sessionId, requestId };
          if (submitError !== undefined) return reply(submitError, details, true);
          return reply(`Sent to ${name} (${whenBusy}).`, details);
        }
        case "wait": {
          const names = args.names ?? (args.name ? [args.name] : []);
          if (names.length === 0) return reply("wait needs names.", {}, true);
          const known = await children(api, context);
          const found = names.flatMap((name) => {
            const child = known[name];
            return child ? [{ name, child }] : [];
          });
          const missing = names.filter((name) => !known[name]);
          if (missing.length)
            return reply(`No subagent named ${missing.join(", ")}.`, { missing }, true);
          const sessions = bound();
          const waited = await Promise.all(
            found.map(async ({ name, child }) => {
              const sessionId = await sessionIdOf(api, name, child);
              const ids = { name, conversationId: child.conversationId, sessionId };
              const error = await sessions.waitForIdle(sessionId);
              if (error !== undefined) return { ids, error };
              const answer = await latestAnswer(api, child.conversationId, context);
              return { ids, text: `${name}: ${answer}` };
            }),
          );
          const details = { children: waited.map((result) => result.ids) };
          const failed = waited.find((result) => result.error !== undefined);
          if (failed?.error !== undefined) return reply(failed.error, details, true);
          return reply(waited.map((result) => result.text).join("\n\n"), details);
        }
        case "stop": {
          const name = args.name?.trim() ?? "";
          const child = (await children(api, context))[name];
          if (!child) return reply(`No subagent named ${name}.`, { name }, true);
          const details = {
            name,
            conversationId: child.conversationId,
            ...(child.sessionId ? { sessionId: child.sessionId } : {}),
          };
          const conversation = await api.conversation(child.conversationId, context);
          if (!conversation) return reply(`Subagent ${name} has no conversation.`, details, true);
          // The commit that stores this call's token decides to abort; a rerun finds an earlier
          // decision and skips the abort, which may already have reached newer work.
          const decision = randomUUID();
          if ((await api.memo<JsonValue>("stopped", decision, context)) === decision)
            await conversation.abort(context);
          return reply(`Stopped ${name}.`, details);
        }
        case "list": {
          const known = Object.entries(await children(api, context));
          if (known.length === 0) return reply("No subagents.", { children: [] });
          const rows = await Promise.all(
            known.map(async ([name, child]) => {
              const busy =
                (await api.snapshot(LiveDoc, child.conversationId, context))?.run !== undefined;
              const model = (await api.snapshot(AgentDoc, child.conversationId, context))?.model;
              return {
                line: [
                  name,
                  busy ? "working" : "idle",
                  `agent: ${child.agent ?? "none"}`,
                  `model: ${model ? `${model.provider}/${model.modelId}` : "default"}`,
                  `session: ${child.sessionId ?? "pending"}`,
                ].join(" | "),
                ids: {
                  name,
                  conversationId: child.conversationId,
                  ...(child.sessionId !== undefined ? { sessionId: child.sessionId } : {}),
                },
              };
            }),
          );
          return reply(rows.map((row) => row.line).join("\n"), {
            children: rows.map((row) => row.ids),
          });
        }
      }
    },
  });

  async function spawn(
    args: {
      name?: string;
      task?: string;
      agent?: string;
      model?: string;
      thinking?: string;
      wait?: boolean;
      allowNestedDelegation?: boolean;
    },
    api: ToolExecutionApi,
    context: Context,
  ): Promise<ToolExecutionResult<ReplyDetails>> {
    const sessions = bound();
    const name = args.name?.trim();
    const task = args.task?.trim();
    if (!name) return reply("spawn needs a name.", {}, true);
    if (!task) return reply("spawn needs a task.", { name }, true);
    const call = String(api.taskId);
    const before = await api.snapshot(Subagents, api.conversationId, context);
    const rerun = before?.calls[call] === name;
    if (!rerun && before?.children[name])
      return reply(`${name} already exists; use send.`, { name }, true);
    const foreground = args.wait === true;
    // A rerun finds its child below; only a new spawn resolves the Agent.
    const resolved = rerun
      ? undefined
      : await sessions.resolveAgent(
          {
            ...(args.agent ? { agent: args.agent } : {}),
            ...(args.model ? { model: args.model } : {}),
            ...(args.thinking ? { thinking: args.thinking } : {}),
            ...(args.allowNestedDelegation ? { allowNestedDelegation: true } : {}),
          },
          { conversationId: api.conversationId, env: api.env, agent: await api.agent(context) },
        );
    const conversationId = await api.commit(async (tx) => {
      const state = await tx.doc(Subagents, api.conversationId);
      const existing = state.calls[call];
      const earlier = existing === undefined ? undefined : state.children[existing];
      if (earlier) return earlier.conversationId;
      if (!resolved) throw new Error(`Subagent ${name} spawn record disappeared`);
      if (Object.hasOwn(state.children, name)) throw new Error(`${name} already exists; use send.`);
      // Foreground: the child belongs to this call, so aborting the call aborts it and the
      // parent stays busy until it is idle. Background: an anchor owns it.
      const owner = foreground
        ? api.taskId
        : await tx.createTask(Anchor, null, {
            ownership: { kind: "conversation" },
            background: true,
          });
      const child = await tx.createConversation({ ownership: { kind: "task", taskId: owner } });
      await resolved.apply(tx, child.id);
      state.children[name] = {
        conversationId: child.id,
        background: !foreground,
        ...(resolved.agent ? { agent: resolved.agent } : {}),
      };
      state.calls[call] = name;
      return child.id;
    }, context);
    const sessionId = await sessions.materialize({ conversationId, name }, api.env);
    await api.commit(async (tx) => {
      const child = (await tx.doc(Subagents, api.conversationId)).children[name];
      if (child && child.sessionId === undefined) child.sessionId = sessionId;
    }, context);
    await api.details({ name, conversationId, sessionId }, context);
    const parent = sessions.sessionOf(api.conversationId, api.env);

    if (!foreground) {
      // The reporter is created after the Session is bound, so the child never runs unattached.
      await api.commit(async (tx) => {
        const child = (await tx.doc(Subagents, api.conversationId)).children[name];
        if (!child) throw new Error(`Subagent ${name} spawn record disappeared`);
        if (child.reporter !== undefined) return;
        child.reporter = await tx.createTask(
          Reporter,
          { conversationId, sessionId, name, task, ...(parent ? { parent } : {}) },
          { ownership: { kind: "conversation" }, background: true },
        );
      }, context);
      return reply(
        `Started ${name} (session ${sessionId}) in the background. Its answer arrives later as ` +
          "a follow-up message; do not poll.",
        { name, conversationId, sessionId, background: true },
      );
    }

    const child = await api.conversation(conversationId, context);
    if (!child) throw new Error(`Subagent ${name} (${sessionId}) conversation disappeared`);
    const settled = await (
      await child.submit(
        {
          type: "input",
          content: task,
          requestId: `oppi-spawn:${api.taskId}`,
          ...sentBy(parent, "task"),
        },
        context,
      )
    ).wait(context);
    if (settled.status !== "done" || settled.type !== "input")
      throw new Error(`Subagent ${name} (${sessionId}) did not answer: ${settled.status}`);
    return reply(await answerText(api, settled.answer, context), {
      name,
      conversationId,
      sessionId,
    });
  }

  return defineExtension({
    name: "oppi.sessions",
    tools: [subagent],
    tasks: [Anchor, Reporter],
    sections: [section("sessions", () => GUIDANCE)],
  });
}

async function answerText(
  api: ToolExecutionApi,
  answer: EntryId,
  context: Context,
): Promise<string> {
  const entry = await api.commit((tx) => tx.entry(AssistantEntry, answer), context);
  return textOf(entry?.model?.[0] as AssistantMessage | undefined);
}

/** The text of a conversation's newest assistant message that has any. */
async function latestAnswer(
  api: ToolExecutionApi,
  conversationId: ConversationId,
  context: Context,
): Promise<string> {
  return api.commit(async (tx) => {
    let cursor;
    do {
      const page = await tx.scanEntries({ conversationId }, 50, cursor);
      for (const entry of page.items) {
        const message = entry.model?.[0];
        if (message?.role !== "assistant") continue;
        const text = textOf(message as AssistantMessage);
        if (text) return text;
      }
      cursor = page.next;
    } while (cursor);
    return "(no answer yet)";
  }, context);
}
