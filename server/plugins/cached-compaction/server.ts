import type { Context } from "@earendil-works/chord/context";
import {
  calculateCost,
  type AssistantMessage,
  type Message,
  type Model,
  type Usage,
} from "@earendil-works/pi-ai";
import {
  CompactionTask,
  hook,
  ProviderDoc,
  UsageDoc,
  type ContextView,
  type EntryId,
  type HookApi,
  type TaskRuntime,
} from "@earendil-works/pi-durable";
import { defineExtension, defineFacet, Extensions } from "oppi/v1";

// Compaction that reads the prompt cache. pi-durable's summarizer sends the summarized history
// as one new serialized user message with `cacheRetention: "none"`, so every compaction pays the
// whole span as uncached input. While the conversation's cache is warm, this plugin's
// `beforeCompact` hook sends the conversation's own request instead, the same system prompt,
// tools, messages, model, thinking level, stream options, and provider session, plus one
// instruction to summarize. The provider reads that prefix from its cache, and pi-durable places
// the returned summary exactly as it places its own.
//
// Reading the whole conversation is not always cheaper: pi-durable's request cuts each tool
// result to 2000 characters and drops thinking, so for a history made mostly of tool output it
// can be a small fraction of the context, while this request also writes the newest answer and
// the instruction to the cache. The hook estimates both at the model's prices and steps aside
// when pi-durable's is cheaper. It also steps aside for a cold cache, and when the reply is not a
// clean text summary.

const CACHED_COMPACTION_EXTENSION = "cached-compaction";

/**
 * The share of the cache lifetime the prefix must still have left to count as warm: the
 * provider refreshes it when it reads the last request, about that answer's timestamp, and this
 * request must reach the provider before it expires.
 */
const WARM_MARGIN = 0.1;
const ONE_HOUR_MS = 60 * 60_000;
const FIVE_MINUTES_MS = 5 * 60_000;
/** How much of the kept part's first message the instruction quotes to mark where it starts. */
const KEPT_EXCERPT_CHARS = 300;
/** pi-durable's summarizer keeps this much of each tool result (`TOOL_RESULT_MAX_CHARS`). */
const STOCK_TOOL_RESULT_CHARS = 2000;
/** pi-ai's token estimate (`estimateTextTokens`). */
const CHARS_PER_TOKEN = 4;

const SUMMARY_FORMAT = `Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.`;

/**
 * What pi-durable's compaction task hands its hooks besides `HookApi`: the task's own runtime
 * (`CompactionTask`'s `select` phase calls `hook(compaction, runtime, context)`). The hook needs
 * the whole current context and the request settings, which `HookApi` does not carry. Without
 * them the hook steps aside.
 */
type CompactionRuntime = HookApi &
  Pick<
    TaskRuntime<unknown, never, unknown, object>,
    "context" | "agent" | "settings" | "signal" | "commit"
  >;

function compactionRuntime(api: HookApi): CompactionRuntime | undefined {
  const runtime = api as Partial<CompactionRuntime>;
  return typeof runtime.context === "function" &&
    typeof runtime.agent === "function" &&
    typeof runtime.commit === "function" &&
    runtime.settings !== undefined &&
    runtime.signal !== undefined
    ? (runtime as CompactionRuntime)
    : undefined;
}

/**
 * The messages the conversation's last request sent, or would send next: the current context,
 * without a trailing tool-calling answer whose results are not all in yet (a compaction may run
 * while tools do). Such an answer cannot be followed by another message, and the request that
 * produced it ended just before it.
 */
function requestPrefix(messages: readonly Message[]): readonly Message[] {
  let index = messages.length - 1;
  while (index >= 0 && messages[index]?.role !== "assistant") index--;
  const answer = messages[index];
  if (answer?.role !== "assistant") return messages;
  const calls = answer.content.flatMap((part) => (part.type === "toolCall" ? [part.id] : []));
  const answered = new Set(
    messages
      .slice(index + 1)
      .flatMap((message) => (message.role === "toolResult" ? [message.toolCallId] : [])),
  );
  return calls.every((id) => answered.has(id)) ? messages : messages.slice(0, index);
}

/** The provider's cache of a request: its newest answer, and whether it lives an hour. */
type CachedPrefix = { readonly last: AssistantMessage; readonly oneHour: boolean };

/**
 * The prefix the provider still holds, if any: the newest answer in it is younger than the cache
 * lifetime. An answer that wrote one-hour cache marks the one-hour lifetime; otherwise the
 * provider's default five minutes applies. A stream that turns caching off holds none.
 */
function warmPrefix(
  messages: readonly Message[],
  cacheRetention: string | undefined,
  now: number,
): CachedPrefix | undefined {
  if (cacheRetention === "none") return undefined;
  const answers = messages.filter((message) => message.role === "assistant");
  const last = answers.at(-1);
  if (last === undefined) return undefined;
  const oneHour =
    cacheRetention === "long" || answers.some((answer) => (answer.usage.cacheWrite1h ?? 0) > 0);
  const lifetime = oneHour ? ONE_HOUR_MS : FIVE_MINUTES_MS;
  return now - last.timestamp < lifetime * (1 - WARM_MARGIN) ? { last, oneHour } : undefined;
}

/** Characters a message adds to a request; `toolResultCap` cuts tool results as pi-durable does. */
function messageChars(message: Message, toolResultCap = Number.POSITIVE_INFINITY): number {
  if (message.role === "system") return 0;
  if (typeof message.content === "string") return message.content.length;
  let chars = 0;
  for (const part of message.content) {
    if (part.type === "text") chars += part.text.length;
    else if (part.type === "thinking") chars += part.thinking.length;
    else if (part.type === "toolCall")
      chars += part.name.length + JSON.stringify(part.arguments).length;
  }
  return message.role === "toolResult" ? Math.min(chars, toolResultCap) : chars;
}

function estimatedCost(model: Model<string>, usage: Partial<Usage>): number {
  const full: Usage = {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    ...usage,
  };
  return calculateCost(model, full).total;
}

/**
 * Whether reading the conversation from the cache costs no more than pi-durable's request, at the
 * model's prices; both answers cost the same, so only the input counts. This request reads what
 * the last one sent and writes the rest (the newest answer onward, and the instruction).
 * pi-durable's sends the summarized messages as text with tool results cut and no thinking, and a
 * prompt about as long as the instruction.
 */
function cheaperThanStock(
  model: Model<string>,
  prefix: CachedPrefix,
  request: readonly Message[],
  summarized: readonly Message[],
  instruction: string,
): boolean {
  const read = prefix.last.usage.input + prefix.last.usage.cacheRead + prefix.last.usage.cacheWrite;
  const fresh = request.slice(request.indexOf(prefix.last));
  const write = Math.ceil(
    (fresh.reduce((sum, message) => sum + messageChars(message), 0) + instruction.length) /
      CHARS_PER_TOKEN,
  );
  const stock = Math.ceil(
    (summarized.reduce((sum, message) => sum + messageChars(message, STOCK_TOOL_RESULT_CHARS), 0) +
      instruction.length) /
      CHARS_PER_TOKEN,
  );
  const cached = estimatedCost(model, {
    cacheRead: read,
    cacheWrite: write,
    ...(prefix.oneHour ? { cacheWrite1h: write } : {}),
  });
  return cached <= estimatedCost(model, { input: stock });
}

/** The instruction appended to the conversation: what to summarize, where the kept part starts. */
function summaryInstruction(kept: Message | undefined, instructions: string | undefined): string {
  const scope =
    kept === undefined
      ? "Summarize the whole conversation above."
      : `Summarize the conversation above up to the ${kept.role === "assistant" ? "assistant" : "user"} message that begins:\n\n<kept-start>\n${excerpt(kept)}\n</kept-start>\n\nThat message and everything after it stay verbatim after your summary, so leave them out. If you cannot find it, summarize the whole conversation.`;
  const focus = instructions === undefined ? "" : `\n\nAdditional focus: ${instructions}`;
  return `Stop the current task. Do not call any tools and do not continue the conversation. Your only job now is to write a context checkpoint summary that replaces the earlier part of this conversation; another LLM will continue the work from it. If the conversation starts with an earlier summary, preserve its information and fold the newer messages into it.

${scope}

${SUMMARY_FORMAT}${focus}`;
}

function excerpt(message: Message): string {
  const parts =
    typeof message.content === "string"
      ? [message.content]
      : message.content.flatMap((part) => {
          if (part.type === "text") return [part.text];
          if (part.type === "toolCall") return [`${part.name}(${JSON.stringify(part.arguments)})`];
          return [];
        });
  const text = parts.join("\n").trim();
  return text.length <= KEPT_EXCERPT_CHARS ? text : `${text.slice(0, KEPT_EXCERPT_CHARS)}…`;
}

/** The summary of a clean `stop` with text and no tool call, as pi-durable's summarizer accepts. */
function summaryText(message: AssistantMessage): string | undefined {
  if (message.stopReason !== "stop" || message.content.some((part) => part.type === "toolCall"))
    return undefined;
  const text = message.content
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join("\n")
    .trim();
  return text.length === 0 ? undefined : text;
}

/** The first message of the entry the summary keeps, if the request carries it. */
function keptMessage(
  view: ContextView,
  firstKept: EntryId,
  request: readonly Message[],
): Message | undefined {
  const index = view.entries.findIndex((entry) => entry.id === firstKept);
  const first = view.contributions[index]?.[0];
  return first !== undefined && request.includes(first) ? first : undefined;
}

/** Add the summarizer's usage to the conversation's `pi.usage`, as pi-durable records its own. */
async function recordUsage(
  runtime: CompactionRuntime,
  message: AssistantMessage,
  context: Context,
): Promise<void> {
  const key = `${message.provider}/${message.model}`;
  const usage: Usage = message.usage;
  await runtime.commit(async (tx) => {
    const models = (await tx.doc(UsageDoc, runtime.conversationId)).models;
    const total = Object.hasOwn(models, key) ? models[key] : undefined;
    if (total === undefined) {
      models[key] = JSON.parse(JSON.stringify(usage)) as Usage;
      return undefined;
    }
    total.input += usage.input;
    total.output += usage.output;
    total.cacheRead += usage.cacheRead;
    total.cacheWrite += usage.cacheWrite;
    total.totalTokens += usage.totalTokens;
    if (usage.cacheWrite1h !== undefined)
      total.cacheWrite1h = (total.cacheWrite1h ?? 0) + usage.cacheWrite1h;
    if (usage.reasoning !== undefined) total.reasoning = (total.reasoning ?? 0) + usage.reasoning;
    total.cost.input += usage.cost.input;
    total.cost.output += usage.cost.output;
    total.cost.cacheRead += usage.cost.cacheRead;
    total.cost.cacheWrite += usage.cost.cacheWrite;
    total.cost.total += usage.cost.total;
    return undefined;
  }, context);
}

const CachedCompaction = defineExtension({
  name: CACHED_COMPACTION_EXTENSION,
  runtimes: ["host", "sandbox"],
  hooks: [
    hook(CompactionTask, {
      async beforeCompact(compaction, api, context) {
        const runtime = compactionRuntime(api);
        if (runtime === undefined) return undefined;
        const agent = await runtime.agent(context);
        const ref = agent.model;
        const model =
          ref === undefined ? undefined : api.models.getModel(ref.provider, ref.modelId);
        if (model === undefined) return undefined;
        const { deferred: _deferred, ...stream } = runtime.settings.stream;
        const view = await runtime.context(api.conversationId, context);
        const request = requestPrefix(view.messages);
        const prefix = warmPrefix(request, stream.cacheRetention, api.now());
        if (prefix === undefined) return undefined;
        const instruction = summaryInstruction(
          keptMessage(view, compaction.firstKept, request),
          compaction.instructions,
        );
        if (!cheaperThanStock(model, prefix, request, compaction.messages, instruction))
          return undefined;
        const sessionId = (await api.snapshot(ProviderDoc, api.conversationId, context))?.sessionId;
        if (sessionId === undefined) return undefined;

        const message = await api.models.completeSimple(
          model,
          {
            messages: [
              ...request,
              {
                role: "user",
                content: [{ type: "text", text: instruction }],
                timestamp: api.now(),
              },
            ],
          },
          {
            ...stream,
            signal: runtime.signal,
            telemetry: context.telemetry,
            sessionId,
            ...(agent.thinkingLevel === "off" ? {} : { reasoning: agent.thinkingLevel }),
          },
        );
        // An abort mark or close: pi-durable's abort handling owns the committed state.
        runtime.signal.throwIfAborted();
        await recordUsage(runtime, message, context);
        const summary = summaryText(message);
        return summary === undefined ? undefined : { summary };
      },
    }),
  ],
});

/** Off until the owner turns it on (`OFF_BY_DEFAULT_PLUGINS`). */
export default defineFacet((_host, self) => self.contribute(Extensions, CachedCompaction));
