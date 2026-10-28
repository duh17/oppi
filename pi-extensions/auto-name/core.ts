// What the classic (`index.ts`) and durable (`durable.ts`) entries share: the title contract (model
// instructions, first-message prompt, normalization), the config file, and the model choice. Only
// type imports from Pi, so both engines load it, and a package outside the server loads it too.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  Api,
  AssistantMessage,
  Context,
  Model,
} from "@earendil-works/pi-ai";

/** The model calls the entries make, over Pi's `ModelRegistry` (classic) or pi-ai's `Models` (durable). */
export interface TitleModels {
  find(provider: string, id: string): Model<Api> | undefined;
  available(): Promise<readonly Model<Api>[]> | readonly Model<Api>[];
  complete(
    model: Model<Api>,
    context: Context,
    options: { maxTokens: number; temperature: number; signal: AbortSignal },
  ): Promise<AssistantMessage>;
}

export type TitleResult = { title: string } | { problem: string };

/** The instructions, first-message prompt, and normalization are one contract: `session-title.json`. */
export const TITLE_INSTRUCTIONS = `You generate concise coding session titles.
Return exactly one line containing only the title text.

Rules:
- 2 to 6 words.
- Start with a category verb or noun when the intent is clear:
  "Fix", "Debug", "Add", "Refactor", "Review", "Investigate", "Polish", "Test", "Research".
- Capture one concrete objective using specific nouns from the request (feature name, bug symptom, file, subsystem, tool).
- Skip conversational filler like "please", "can you", "help me", or "I need to".
- No quotes, markdown, emojis, or trailing punctuation.

Examples:
- "fix the websocket reconnect state drift" -> Fix WebSocket Reconnect Drift
- "let's polish the review view icons" -> Polish Review View Icons
- "can you investigate why voice input language changes" -> Investigate Voice Input Language Bug
- "research code review agents" -> Research Code Review Agents
- "install our app" -> Install App`;

/** A first message shorter than this is not enough to title a session. */
export const MIN_MESSAGE_LENGTH = 15;
const MAX_SOURCE_CHARACTERS = 600;
const MAX_TITLE_LENGTH = 48;
const GENERATION_TIMEOUT_MS = 15_000;

/**
 * Hand the first message over as data to title. Sent bare, models such as Haiku answer it
 * ("I can't see the attachment...") instead of titling it.
 */
export function titlePrompt(firstMessage: string): string {
  const source = Array.from(firstMessage.trim())
    .slice(0, MAX_SOURCE_CHARACTERS)
    .join("");
  return `Create a concise session title from the first user message.

<first_user_message>
${source}
</first_user_message>`;
}

/** Strip LLM artifacts, quotes, and punctuation from a generated title, and cap its length. */
export function normalizeTitle(raw: string | null | undefined): string | null {
  if (!raw) return null;

  let title = raw.trim();
  if (title.length === 0) return null;

  // First line only.
  const newlineIdx = title.indexOf("\n");
  if (newlineIdx !== -1) title = title.substring(0, newlineIdx);

  // "Title:" prefix some models add.
  title = title.replace(/^title\s*:\s*/i, "");

  // Wrapping quotes (straight, curly, backticks) and brackets.
  title = title.replace(/^[\s"'`\u201c\u201d\u2018\u2019[\]()]+/, "");
  title = title.replace(/[\s"'`\u201c\u201d\u2018\u2019[\]()]+$/, "");

  // Leading and trailing punctuation.
  title = title.replace(/^[.,:;!?]+/, "").replace(/[.,:;!?]+$/, "");

  title = title
    .split(/\s+/)
    .filter((s) => s.length > 0)
    .join(" ");

  // Cap at a word boundary.
  if (title.length > MAX_TITLE_LENGTH) {
    title = title.substring(0, MAX_TITLE_LENGTH);
    const lastSpace = title.lastIndexOf(" ");
    if (lastSpace > 0) title = title.substring(0, lastSpace);
    title = title.replace(/[.,:;!?\- ]+$/, "");
  }

  return title.length > 0 ? title : null;
}

// ─── Config ───

/** Pi's agent directory: `PI_CODING_AGENT_DIR`, else `~/.pi/agent`. */
export function agentDir(env: NodeJS.ProcessEnv = process.env): string {
  const dir = env.PI_CODING_AGENT_DIR;
  if (!dir) return join(homedir(), ".pi", "agent");
  return dir === "~" || dir.startsWith("~/")
    ? join(homedir(), dir.slice(2))
    : dir;
}

export interface AutoNameConfig {
  /** `provider/model-id`. Unset: a small model of the session's provider. */
  model?: string;
}

/**
 * `~/.pi/agent/auto-name.json`, `{ "model": "provider/model-id" }`, read at each use so an edit
 * applies to the next session. A missing or unreadable file is the default configuration.
 */
export function readConfig(dir: string = agentDir()): AutoNameConfig {
  try {
    const parsed: unknown = JSON.parse(
      readFileSync(join(dir, "auto-name.json"), "utf8"),
    );
    const model = (parsed as { model?: unknown } | null)?.model;
    return typeof model === "string" && model.trim()
      ? { model: model.trim() }
      : {};
  } catch {
    return {};
  }
}

// ─── Model choice ───

function parseModelId(
  id: string,
): { provider: string; model: string } | undefined {
  const slash = id.indexOf("/");
  return slash > 0 && slash < id.length - 1
    ? { provider: id.slice(0, slash), model: id.slice(slash + 1) }
    : undefined;
}

const SMALL_MODEL = /haiku|flash|mini|nano|lite|small/i;

/**
 * A small model of `provider` (the session's own): non-reasoning first, then cheapest. A title
 * needs 30 tokens, and a reasoning model may spend them thinking. Undefined without one.
 */
export function pickSmallModel(
  available: readonly Model<Api>[],
  provider: string,
): Model<Api> | undefined {
  return available
    .filter(
      (model) =>
        model.provider === provider &&
        (model.type ?? "chat") === "chat" &&
        SMALL_MODEL.test(model.id),
    )
    .sort(
      (a, b) =>
        Number(a.reasoning) - Number(b.reasoning) ||
        a.cost.input + a.cost.output - (b.cost.input + b.cost.output),
    )[0];
}

/**
 * The configured model, else a small model of the session's provider, else the session's own
 * model. A configured model that does not resolve is a problem, never a silent fallback to a
 * model the user did not name.
 */
export async function chooseModel(
  models: TitleModels,
  configured: string | undefined,
  session: { provider: string; id: string } | undefined,
): Promise<Model<Api> | { problem: string }> {
  if (configured) {
    const parsed = parseModelId(configured);
    const model = parsed && models.find(parsed.provider, parsed.model);
    return model ?? { problem: `model ${configured} is not available` };
  }
  if (!session)
    return { problem: "no model configured and the session has none" };
  const small = pickSmallModel(await models.available(), session.provider);
  const model = small ?? models.find(session.provider, session.id);
  return (
    model ?? { problem: `no model available for provider ${session.provider}` }
  );
}

// ─── Generation ───

function textOf(message: AssistantMessage): string {
  return message.content
    .filter(
      (part): part is { type: "text"; text: string } => part.type === "text",
    )
    .map((part) => part.text)
    .join("");
}

/** One title for `firstMessage`. Never throws: a failure is the `problem` to log. */
export async function generateTitle(
  models: TitleModels,
  model: Model<Api>,
  firstMessage: string,
): Promise<TitleResult> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), GENERATION_TIMEOUT_MS);
  try {
    const response = await models.complete(
      model,
      {
        systemPrompt: TITLE_INSTRUCTIONS,
        messages: [
          {
            role: "user",
            content: titlePrompt(firstMessage),
            timestamp: Date.now(),
          },
        ],
      },
      { maxTokens: 30, temperature: 0.3, signal: abort.signal },
    );
    // A 2-6 word title never fills maxTokens; a reply that does is the model answering the
    // message, and its cut-off text is no title.
    if (response.stopReason === "length")
      return { problem: "the model answered instead of titling" };
    if (response.stopReason === "error" || response.stopReason === "aborted")
      return {
        problem: abort.signal.aborted
          ? `timed out after ${GENERATION_TIMEOUT_MS} ms`
          : (response.errorMessage ?? "the model request failed"),
      };
    const title = normalizeTitle(textOf(response));
    return title ? { title } : { problem: "the model returned no title" };
  } catch (error) {
    return {
      problem: abort.signal.aborted
        ? `timed out after ${GENERATION_TIMEOUT_MS} ms`
        : error instanceof Error
          ? error.message
          : String(error),
    };
  } finally {
    clearTimeout(timer);
  }
}

/** The text of a user message's content (a string, or text parts). */
export function userText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter(
      (part): part is { type: "text"; text: string } => part?.type === "text",
    )
    .map((part) => part.text)
    .join("\n");
}

// ─── The whole job ───

export interface AutoNameJob {
  models: TitleModels;
  /** The first user message of the session. */
  firstMessage: string;
  /** The session's own model, for the default choice. */
  session: { provider: string; id: string } | undefined;
  /** The session's name now: another writer may have named it while the title was generating. */
  currentName(): string | undefined;
  setName(title: string): void | Promise<void>;
  /** Called once with why no title was set. */
  warn(problem: string): void;
  config?: AutoNameConfig;
}

/**
 * Title the session from its first message. Names only a session that is still unnamed when the
 * title is ready, so a name the user or another extension set meanwhile stays. Never throws.
 */
export async function autoName(job: AutoNameJob): Promise<void> {
  try {
    if (job.firstMessage.trim().length < MIN_MESSAGE_LENGTH) return;
    if (job.currentName()) return;
    const config = job.config ?? readConfig();
    const model = await chooseModel(job.models, config.model, job.session);
    if ("problem" in model) return job.warn(model.problem);
    const result = await generateTitle(job.models, model, job.firstMessage);
    if ("problem" in result) return job.warn(result.problem);
    if (job.currentName()) return;
    await job.setName(result.title);
  } catch (error) {
    job.warn(error instanceof Error ? error.message : String(error));
  }
}
