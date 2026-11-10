import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type {
  AssistantMessage,
  Message,
  ToolCall,
  SimpleStreamOptions,
  TranscriptContext,
} from "@earendil-works/pi-ai";

import { createLogger } from "./logger.js";

const log = createLogger({ base: { component: "e2e_faux_provider" } });

export const E2E_FAUX_PROVIDER_ID = "oppi-e2e-faux";
export const E2E_FAUX_MODEL_ID = "oppi-e2e-faux-1";

/**
 * Slow enough that a UI test can queue inputs, stop, or drop the connection while a reply
 * streams: a reply takes over ten seconds to land.
 */
const E2E_FAUX_TOKENS_PER_SECOND = 4;

/**
 * Test-only scripted model for the iOS E2E harness (`e2e.sh --faux-model`). It needs both
 * `OPPI_E2E_UI_HARNESS=1` and `OPPI_E2E_FAUX_PROVIDER=1` in the server's environment: no
 * config key, route, or app request can turn it on.
 */
export function e2eFauxProviderEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.OPPI_E2E_UI_HARNESS === "1" && env.OPPI_E2E_FAUX_PROVIDER === "1";
}

/** The scripted answer to one request: the same reply for the same prompt, every time. */
export function e2eFauxReplyText(prompt: string): string {
  return [
    `Durable faux reply to: ${prompt}`,
    "",
    "This answer comes from the Oppi E2E faux provider. It streams in small chunks so the app shows a live row first. When the turn ends, the committed reply replaces the live row. End of faux reply.",
  ].join("\n");
}

/**
 * Scripted tool calls, so a UI test can drive tool rows and subagents. The last line of the
 * prompt decides them, and only when the prompt is the newest message (a tool result is answered
 * with text):
 *
 * - `faux:bash <command>` calls `bash` with the command.
 * - `faux:subagent <name> <task>` spawns a background subagent with the task; a task that is
 *   itself a directive makes the child call that tool.
 * - `faux:subagent-wait <name> <task>` spawns it in the foreground: the call waits for its answer.
 * - `faux:subagents <name> <task> || <name> <task> ...` spawns several background subagents in
 *   one answer, as a model does when it delegates in parallel.
 * - `faux:ask <question>` asks the user the question, with two options, and waits for the answer.
 *
 * Only the last line counts, so a reply that echoes a directive (every reply ends with
 * `End of faux reply.`) never triggers another call. No directive: no calls.
 */
export function e2eFauxToolCalls(messages: readonly Message[]): FauxCall[] {
  if (messages.at(-1)?.role !== "user") return [];
  const line = lastDirective(messages);
  const [, many] = /^faux:subagents\s+(.+)$/.exec(line) ?? [];
  if (many)
    return many.split("||").flatMap((spec) => directiveCall(`faux:subagent ${spec.trim()}`));
  return directiveCall(line);
}

type FauxCall = { name: string; arguments: Record<string, unknown> };

function directiveCall(line: string): FauxCall[] {
  const [, command] = /^faux:bash\s+(.+)$/.exec(line) ?? [];
  if (command) return [{ name: "bash", arguments: { command } }];
  const [, question] = /^faux:ask\s+(.+)$/.exec(line) ?? [];
  if (question) {
    const options = [
      { value: "first", label: "The first" },
      { value: "second", label: "The second" },
    ];
    return [{ name: "ask", arguments: { questions: [{ id: "choice", question, options }] } }];
  }
  const [, mode, name, task] = /^faux:subagent(-wait)?\s+(\S+)\s+(.+)$/.exec(line) ?? [];
  if (!name || !task) return [];
  const args = { action: "spawn", name, task, ...(mode ? { wait: true } : {}) };
  return [{ name: "subagent", arguments: args }];
}

/**
 * `faux:fail <error>`: the request fails with that error, as a provider's refused request does.
 * Only for the newest message, as a tool call's directive.
 */
export function e2eFauxFailure(messages: readonly Message[]): string | undefined {
  if (messages.at(-1)?.role !== "user") return undefined;
  return /^faux:fail\s+(.+)$/.exec(lastDirective(messages))?.[1];
}

/** The last line of the newest user text: where a directive goes. */
function lastDirective(messages: readonly Message[]): string {
  return lastUserText(messages).split("\n").at(-1)?.trim() ?? "";
}

function lastUserText(messages: readonly Message[]): string {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (message.role !== "user") continue;
    const content = message.content;
    const text =
      typeof content === "string"
        ? content
        : content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n");
    return text.trim();
  }
  return "";
}

/**
 * Register the scripted model on the server-wide model runtime when the E2E gate is set.
 * Only durable sessions use that runtime; classic sessions build their own from models.json.
 * The faux module is imported here so a normal server never loads it.
 */
export async function registerE2EFauxProvider(models: ModelRuntime): Promise<boolean> {
  if (!e2eFauxProviderEnabled()) return false;
  const [{ createFauxCore, fauxAssistantMessage, fauxToolCall }, { createProvider }] =
    await Promise.all([
      import("@earendil-works/pi-ai/providers/faux"),
      import("@earendil-works/pi-ai/models"),
    ]);
  const core = createFauxCore({
    api: E2E_FAUX_PROVIDER_ID,
    provider: E2E_FAUX_PROVIDER_ID,
    models: [{ id: E2E_FAUX_MODEL_ID, name: "Oppi E2E Faux", reasoning: false, input: ["text"] }],
    tokensPerSecond: E2E_FAUX_TOKENS_PER_SECOND,
  });
  const reply = (context: TranscriptContext): AssistantMessage => {
    const failure = e2eFauxFailure(context.messages);
    if (failure) return fauxAssistantMessage("", { stopReason: "error", errorMessage: failure });
    const calls = e2eFauxToolCalls(context.messages);
    return calls.length > 0
      ? fauxAssistantMessage(
          calls.map((call) => fauxToolCall(call.name, call.arguments as ToolCall["arguments"])),
          { stopReason: "toolUse" },
        )
      : fauxAssistantMessage(e2eFauxReplyText(lastUserText(context.messages)));
  };
  // The faux core answers from a queue. Queue the scripted step right before each request
  // takes it, so the script never runs dry and concurrent requests cannot steal a step.
  const stream: typeof core.stream = (model, context, options?: SimpleStreamOptions) => {
    core.setResponses([reply]);
    return core.stream(model, context, options);
  };
  models.registerNativeProvider(
    createProvider({
      id: E2E_FAUX_PROVIDER_ID,
      name: "Oppi E2E Faux",
      auth: { apiKey: { name: "Faux", resolve: async () => ({ auth: {} }) } },
      models: core.models,
      api: {
        stream,
        streamSimple: stream,
        fetchDeferred: core.fetchDeferred,
        cancelDeferred: core.cancelDeferred,
      },
    }),
  );
  log.warn("e2e.faux_provider_registered", {
    model: `${E2E_FAUX_PROVIDER_ID}/${E2E_FAUX_MODEL_ID}`,
  });
  return true;
}
