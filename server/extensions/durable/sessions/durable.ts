import { Type } from "typebox";
import type { Context } from "@earendil-works/chord";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  AssistantEntry,
  configure,
  defineDoc,
  defineExtension,
  defineTask,
  defineTool,
  section,
  type ConversationId,
  type EntryId,
  type Extension,
  type TaskId,
  type ToolExecutionApi,
  type ToolExecutionResult,
} from "@earendil-works/pi-durable";

/**
 * What the sessions tools need from Oppi. The extension is static harness code and
 * cannot import server modules, so the server hands these in when it binds the
 * Harness (see `DurableThreads`).
 */
export interface DurableSessionsHost {
  /**
   * The Oppi Session bound to an owned child conversation, created and attached on
   * first use. Idempotent: one Session per conversation id, however often this runs.
   */
  materialize(child: { conversationId: ConversationId; name: string }): Promise<string>;
  /** The durable conversation an Oppi session id is bound to. */
  conversationOf(sessionId: string): ConversationId | undefined;
  /**
   * Why the calling conversation may not reach this session's conversation, or undefined
   * when it may. A sandbox caller reaches only sandbox sessions of its own workspace.
   */
  refuseReach(caller: ConversationId, target: ConversationId): Promise<string | undefined>;
  /** Attach a stopped Session so a message to it makes progress. */
  activate(sessionId: string): Promise<void>;
  /** Validate the model and thinking level a spawn asks for; rejects with a message for the model. */
  resolveAgent(options: { model?: string; thinking?: string }): Promise<{
    model?: { provider: string; modelId: string };
    thinkingLevel?: Parameters<typeof configure>[2]["thinkingLevel"];
  }>;
}

/** Which background child was spawned by which tool call, so a rerun finds it. */
const Spawns = defineDoc<{
  spawns: Record<string, { conversationId: ConversationId; reporter?: TaskId }>;
}>({
  kind: "oppi.sessions",
  version: 1,
  scope: "conversation",
  history: "latest",
  // A fork of the parent starts without its children.
  fork: "initial",
  initial: () => ({ spawns: {} }),
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
};
type ReporterState = { phase: "deliver" } | { phase: "report"; report?: string };

function textOf(message: AssistantMessage | undefined): string {
  return (message?.content ?? [])
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join("");
}

/**
 * Hands a background child its task and posts its answer back to the parent. Background
 * too, so the parent's Stop and idle waits leave it alone. Request ids make a restart
 * deliver the task once and the report once.
 */
/** Registered name of the reporter task; Stop aborts tasks of this kind (see `DurableHarness`). */
export const SESSION_REPORTER_TASK = "oppi.session-reporter";

const Reporter = defineTask<ReporterInput, ReporterState, null>({
  name: SESSION_REPORTER_TASK,
  version: 1,
  initial: () => ({ phase: "deliver" }),
  phases: {
    deliver: async (reporter, runtime, context) => {
      const { conversationId, sessionId, name, task } = reporter.input;
      const child = await runtime.conversation(conversationId, context);
      if (!child) throw new Error(`Session ${sessionId} conversation disappeared`);
      const submission = await child.submit(
        { type: "input", content: task, requestId: `oppi-spawn:${reporter.id}` },
        context,
      );
      const settled = await submission.wait(context);
      await runtime.commit(async (tx) => {
        const next = (report?: string) =>
          ({ status: "running", checkpoint: { phase: "report", report } }) as const;
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
        return next(`[session ${name} (${sessionId}) finished, no reply needed] ${textOf(answer)}`);
      }, context);
    },
    report: async (reporter, runtime, context) => {
      const report = reporter.state.checkpoint.report;
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
  "session_spawn starts a child session for a self-contained task. By default it waits for the " +
  "child's answer; with background true it returns at once and the answer arrives later as a " +
  "follow-up message, so do not poll. session_send messages any session (steer interrupts at the " +
  "next step, followUp waits for its current answer), session_wait waits for sessions to go idle, " +
  "and session_abort stops a child you spawned. Child sessions cannot spawn sessions.";

type ReplyDetails = Record<string, string | number | boolean>;

function reply(
  text: string,
  details: ReplyDetails,
  isError = false,
): ToolExecutionResult<ReplyDetails> {
  return { content: [{ type: "text" as const, text }], details, ...(isError ? { isError } : {}) };
}

/** `api.commit` read of a conversation's owner; undefined for an ownerless conversation. */
async function ownerOf(
  api: ToolExecutionApi,
  id: ConversationId,
  context: Context,
): Promise<ConversationId | undefined> {
  return api.commit(async (tx) => (await tx.conversation(id))?.owner?.conversationId, context);
}

export function createDurableSessions(host: () => DurableSessionsHost | undefined): Extension {
  const bound = (): DurableSessionsHost => {
    const current = host();
    if (!current) throw new Error("Session tools are not available: the Oppi host is not bound");
    return current;
  };
  /** The conversation of an Oppi session, or the reason the tools cannot use it. */
  const target = async (
    sessionId: string,
    api: ToolExecutionApi,
  ): Promise<{ conversationId: ConversationId } | { error: string }> => {
    const host = bound();
    const conversationId = host.conversationOf(sessionId);
    if (conversationId === undefined)
      return { error: `Session ${sessionId} is not a durable session.` };
    if (conversationId === api.conversationId) return { error: "A session cannot target itself." };
    // Before anything attaches, prompts or waits on the target.
    const refusal = await host.refuseReach(api.conversationId, conversationId);
    if (refusal !== undefined) return { error: refusal };
    return { conversationId };
  };

  const spawn = defineTool({
    name: "session_spawn",
    description:
      "Start a child session for a self-contained task. Waits for the child's answer unless " +
      "background is true, which returns at once and delivers the answer later as a follow-up message. " +
      "Child sessions cannot spawn sessions.",
    parameters: Type.Object({
      task: Type.String({ description: "What the child session should do." }),
      name: Type.Optional(Type.String({ description: "Name shown for the child session." })),
      background: Type.Optional(
        Type.Boolean({ description: "Return at once; the answer arrives later as a follow-up." }),
      ),
      model: Type.Optional(
        Type.String({ description: "provider/model; default: this session's." }),
      ),
      thinking: Type.Optional(
        Type.String({ description: "Thinking level; default: this session's." }),
      ),
    }),
    // A rerun after a crash finds the same child, Session and submission.
    replay: "safe",
    async execute(args, api, context) {
      const sessions = bound();
      const task = args.task.trim();
      if (!task) throw new Error("session_spawn requires a task.");
      if ((await ownerOf(api, api.conversationId, context)) !== undefined)
        throw new Error("Child sessions cannot spawn sessions.");
      const agent = await sessions.resolveAgent({
        ...(args.model ? { model: args.model } : {}),
        ...(args.thinking ? { thinking: args.thinking } : {}),
      });
      const name = args.name?.trim() || (task.split("\n", 1)[0] ?? task).slice(0, 80);
      const choices = {
        ...(agent.model ? { model: agent.model } : {}),
        ...(agent.thinkingLevel ? { thinkingLevel: agent.thinkingLevel } : {}),
      };

      if (args.background === true) {
        const spawned = await api.commit(async (tx) => {
          const state = await tx.doc(Spawns, api.conversationId);
          const existing = state.spawns[String(api.taskId)];
          if (existing) return { conversationId: existing.conversationId };
          const background = { ownership: { kind: "conversation" }, background: true } as const;
          const anchor = await tx.createTask(Anchor, null, background);
          const child = await tx.createConversation({
            ownership: { kind: "task", taskId: anchor },
          });
          await configure(tx, child.id, choices);
          state.spawns[String(api.taskId)] = { conversationId: child.id };
          return { conversationId: child.id };
        }, context);
        const sessionId = await sessions.materialize({
          conversationId: spawned.conversationId,
          name,
        });
        await api.details({ conversationId: spawned.conversationId, sessionId }, context);
        // The reporter is created after the Session is bound, so the child never runs unattached.
        await api.commit(async (tx) => {
          const entry = (await tx.doc(Spawns, api.conversationId)).spawns[String(api.taskId)];
          if (!entry) throw new Error("Background session spawn record disappeared");
          if (entry.reporter !== undefined) return;
          entry.reporter = await tx.createTask(
            Reporter,
            { conversationId: spawned.conversationId, sessionId, name, task },
            { ownership: { kind: "conversation" }, background: true },
          );
        }, context);
        return reply(
          `Started session ${sessionId} (${name}) in the background. Its answer arrives later as a ` +
            "follow-up message; do not poll. Use session_send, session_wait or session_abort to manage it.",
          { conversationId: spawned.conversationId, sessionId, background: true },
        );
      }

      // Foreground: the child belongs to this call. Aborting the call aborts the child, and the
      // parent stays busy until the child is idle.
      const conversationId = await api.commit(async (tx) => {
        const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
        if (existing !== undefined) return existing.id;
        const created = await tx.createConversation({
          ownership: { kind: "task", taskId: api.taskId },
        });
        await configure(tx, created.id, choices);
        return created.id;
      }, context);
      const sessionId = await sessions.materialize({ conversationId, name });
      await api.details({ conversationId, sessionId }, context);
      const child = await api.conversation(conversationId, context);
      if (!child) throw new Error(`Session ${sessionId} conversation disappeared`);
      const settled = await (
        await child.submit(
          { type: "input", content: task, requestId: `oppi-spawn:${api.taskId}` },
          context,
        )
      ).wait(context);
      if (settled.status !== "done" || settled.type !== "input")
        throw new Error(`Session ${sessionId} did not answer: ${settled.status}`);
      const answer = await answerText(api, settled.answer, context);
      return reply(answer, { conversationId, sessionId });
    },
  });

  const send = defineTool({
    name: "session_send",
    description:
      "Send a message to another session. steer interrupts it at its next step; followUp waits for " +
      "its current answer. Returns once the message is queued; use session_wait to wait for it.",
    parameters: Type.Object({
      sessionId: Type.String(),
      text: Type.String(),
      mode: Type.Union([Type.Literal("steer"), Type.Literal("followUp")]),
    }),
    // The request id is per call, so a rerun delivers the message once.
    replay: "safe",
    async execute(args, api, context) {
      const found = await target(args.sessionId, api);
      if ("error" in found) return reply(found.error, { sessionId: args.sessionId }, true);
      await bound().activate(args.sessionId);
      const conversation = await api.conversation(found.conversationId, context);
      if (!conversation)
        return reply(
          `Session ${args.sessionId} has no conversation.`,
          { sessionId: args.sessionId },
          true,
        );
      const requestId = `oppi-send:${api.taskId}`;
      await conversation.submit(
        { type: "input", content: args.text, whenBusy: args.mode, requestId },
        context,
      );
      return reply(`Sent to session ${args.sessionId} (${args.mode}).`, {
        sessionId: args.sessionId,
        conversationId: found.conversationId,
        requestId,
      });
    },
  });

  const wait = defineTool({
    name: "session_wait",
    description: "Wait until every listed session is idle.",
    parameters: Type.Object({ sessionIds: Type.Array(Type.String(), { minItems: 1 }) }),
    replay: "safe",
    async execute(args, api, context) {
      const handles = [];
      for (const sessionId of args.sessionIds) {
        const found = await target(sessionId, api);
        if ("error" in found) return reply(found.error, { sessionId }, true);
        const handle = await api.conversation(found.conversationId, context);
        if (!handle) return reply(`Session ${sessionId} has no conversation.`, { sessionId }, true);
        handles.push(handle);
      }
      await Promise.all(handles.map((handle) => handle.waitForIdle(context)));
      return reply(`Idle: ${args.sessionIds.join(", ")}.`, {
        sessionIds: args.sessionIds.join(","),
      });
    },
  });

  const abort = defineTool({
    name: "session_abort",
    description: "Stop the current work of a child session you spawned. It stays usable.",
    parameters: Type.Object({ sessionId: Type.String() }),
    // Repeating an abort could stop newer work.
    replay: "unsafe",
    async execute(args, api, context) {
      const found = await target(args.sessionId, api);
      if ("error" in found) return reply(found.error, { sessionId: args.sessionId }, true);
      if ((await ownerOf(api, found.conversationId, context)) !== api.conversationId)
        return reply(
          `Session ${args.sessionId} is not one of your children; session_abort only stops sessions you spawned.`,
          { sessionId: args.sessionId },
          true,
        );
      const child = await api.conversation(found.conversationId, context);
      if (!child)
        return reply(
          `Session ${args.sessionId} has no conversation.`,
          { sessionId: args.sessionId },
          true,
        );
      await child.abort(context);
      return reply(`Stopped session ${args.sessionId}.`, { sessionId: args.sessionId });
    },
  });

  return defineExtension({
    name: "oppi.sessions",
    tools: [spawn, send, wait, abort],
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
