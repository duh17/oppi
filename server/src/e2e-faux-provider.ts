import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import type {
  AssistantMessage,
  Message,
  SimpleStreamOptions,
  TranscriptContext,
} from "@earendil-works/pi-ai";

import { createLogger } from "./logger.js";

const log = createLogger({ base: { component: "e2e_faux_provider" } });

export const E2E_FAUX_PROVIDER_ID = "oppi-e2e-faux";
export const E2E_FAUX_MODEL_ID = "oppi-e2e-faux-1";

/** Slow enough that a UI test sees the live row for several seconds before the reply lands. */
const E2E_FAUX_TOKENS_PER_SECOND = 10;

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
  const [{ createFauxCore, fauxAssistantMessage }, { createProvider }] = await Promise.all([
    import("@earendil-works/pi-ai/providers/faux"),
    import("@earendil-works/pi-ai/models"),
  ]);
  const core = createFauxCore({
    api: E2E_FAUX_PROVIDER_ID,
    provider: E2E_FAUX_PROVIDER_ID,
    models: [{ id: E2E_FAUX_MODEL_ID, name: "Oppi E2E Faux", reasoning: false, input: ["text"] }],
    tokensPerSecond: E2E_FAUX_TOKENS_PER_SECOND,
  });
  const reply = (context: TranscriptContext): AssistantMessage =>
    fauxAssistantMessage(e2eFauxReplyText(lastUserText(context.messages)));
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
