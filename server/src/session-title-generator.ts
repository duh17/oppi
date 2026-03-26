/**
 * Session title generator — auto-generates concise task titles for sessions.
 *
 * Uses a configurable model provider to generate 3-5 word titles from the
 * first user message. Standalone and stateless — no pi system prompt, no
 * conversation history.
 */

import { completeSimple } from "@mariozechner/pi-ai";
import type { ModelRegistry } from "@mariozechner/pi-coding-agent";
import type { Api, Model } from "@mariozechner/pi-ai";

import { ts } from "./log-utils.js";

// ─── Types ───

export interface AutoTitleConfig {
  enabled: boolean;
  model?: string;
}

export interface TitleGenerationMetrics {
  durationMs: number;
  model: string;
  status: "success" | "error" | "timeout";
  tokens: number;
}

export interface SessionTitleProvider {
  name: string;
  generateTitle(firstMessage: string): Promise<string | null>;
}

// ─── Constants ───

const TITLE_SYSTEM_PROMPT = `You generate concise coding session titles.
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

const MIN_MESSAGE_LENGTH = 15;
const MAX_TITLE_LENGTH = 48;
const GENERATION_TIMEOUT_MS = 15_000;

// ─── Normalization ───

/**
 * Normalize a generated title: strip LLM artifacts, quotes, punctuation, cap length.
 * Port of iOS ChatActionHandler.normalizeTitle().
 */
export function normalizeTitle(raw: string | null | undefined): string | null {
  if (!raw) return null;

  let title = raw.trim();
  if (title.length === 0) return null;

  // Take first line only
  const newlineIdx = title.indexOf("\n");
  if (newlineIdx !== -1) {
    title = title.substring(0, newlineIdx);
  }

  // Strip "Title:" prefix LLMs sometimes add
  title = title.replace(/^title\s*:\s*/i, "");

  // Strip wrapping quotes (straight, curly, backticks) and brackets
  title = title.replace(/^[\s"'`\u201c\u201d\u2018\u2019[\]()]+/, "");
  title = title.replace(/[\s"'`\u201c\u201d\u2018\u2019[\]()]+$/, "");

  // Strip trailing punctuation
  title = title.replace(/[.,:;!?]+$/, "");

  // Collapse whitespace
  title = title
    .split(/\s+/)
    .filter((s) => s.length > 0)
    .join(" ");

  // Cap length at word boundary
  if (title.length > MAX_TITLE_LENGTH) {
    title = title.substring(0, MAX_TITLE_LENGTH);
    const lastSpace = title.lastIndexOf(" ");
    if (lastSpace > 0) {
      title = title.substring(0, lastSpace);
    }
    // Trim any trailing punctuation or hyphens left at the boundary
    title = title.replace(/[.,:;!?\- ]+$/, "");
  }

  return title.length > 0 ? title : null;
}

// ─── Providers ───

/**
 * Disabled provider — returns null. Used when auto-title is off.
 */
export class DisabledProvider implements SessionTitleProvider {
  readonly name = "disabled";

  async generateTitle(_firstMessage: string): Promise<string | null> {
    return null;
  }
}

/** Parse "provider/model-id" into { provider, model }. */
function parseModelId(modelId: string): { provider: string; model: string } | null {
  const slash = modelId.indexOf("/");
  if (slash <= 0) return null;
  return { provider: modelId.substring(0, slash), model: modelId.substring(slash + 1) };
}

/**
 * API model provider — calls any model available through the pi SDK ModelRegistry.
 * Works with Anthropic, OpenAI, local MLX, etc.
 */
export class ApiModelTitleProvider implements SessionTitleProvider {
  readonly name = "api-model";
  private readonly modelId: string;
  private readonly modelRegistry: ModelRegistry;
  private readonly onMetrics?: (metrics: TitleGenerationMetrics) => void;

  constructor(
    modelId: string,
    modelRegistry: ModelRegistry,
    onMetrics?: (metrics: TitleGenerationMetrics) => void,
  ) {
    this.modelId = modelId;
    this.modelRegistry = modelRegistry;
    this.onMetrics = onMetrics;
  }

  async generateTitle(firstMessage: string): Promise<string | null> {
    const startMs = Date.now();
    let status: TitleGenerationMetrics["status"] = "error";
    let tokens = 0;

    try {
      const model = this.resolveModel();
      if (!model) {
        console.warn(`${ts()} [auto-title] model not found: ${this.modelId}`);
        return null;
      }
      const apiKey = await this.modelRegistry.getApiKey(model);
      const abortController = new AbortController();
      const timeout = setTimeout(() => abortController.abort(), GENERATION_TIMEOUT_MS);

      try {
        const response = await completeSimple(
          model,
          {
            systemPrompt: TITLE_SYSTEM_PROMPT,
            messages: [{ role: "user", content: firstMessage, timestamp: Date.now() }],
          },
          {
            maxTokens: 30,
            temperature: 0.3,
            apiKey,
            signal: abortController.signal,
          },
        );

        clearTimeout(timeout);

        tokens =
          (response.usage?.input ?? 0) +
          (response.usage?.output ?? 0) +
          (response.usage?.cacheRead ?? 0);

        const text = response.content
          .filter((c): c is { type: "text"; text: string } => c.type === "text")
          .map((c) => c.text)
          .join("");

        const normalized = normalizeTitle(text);
        status = normalized ? "success" : "error";
        return normalized;
      } catch (err: unknown) {
        clearTimeout(timeout);
        if (abortController.signal.aborted) {
          status = "timeout";
          console.warn(`${ts()} [auto-title] generation timed out for model ${this.modelId}`);
        } else {
          const message = err instanceof Error ? err.message : String(err);
          console.warn(`${ts()} [auto-title] generation failed: ${message}`);
        }
        return null;
      }
    } finally {
      const durationMs = Date.now() - startMs;
      this.onMetrics?.({
        durationMs,
        model: this.modelId,
        status,
        tokens,
      });
    }
  }

  private resolveModel(): Model<Api> | undefined {
    const parsed = parseModelId(this.modelId);
    if (!parsed) return undefined;
    return this.modelRegistry.find(parsed.provider, parsed.model);
  }
}

// ─── Concurrency Limiter ───

/**
 * Simple concurrency limiter to avoid rate limiting when multiple sessions
 * are created simultaneously.
 */
class ConcurrencyLimiter {
  private running = 0;
  private queue: Array<() => void> = [];

  constructor(private readonly maxConcurrent: number) {}

  async run<T>(fn: () => Promise<T>): Promise<T> {
    if (this.running >= this.maxConcurrent) {
      await new Promise<void>((resolve) => this.queue.push(resolve));
    }
    this.running += 1;
    try {
      return await fn();
    } finally {
      this.running -= 1;
      const next = this.queue.shift();
      if (next) next();
    }
  }
}

// ─── Title Generator (Orchestrator) ───

export interface SessionTitleGeneratorDeps {
  getConfig: () => AutoTitleConfig;
  modelRegistry: ModelRegistry;
  /** Get current session state — returns undefined if session no longer exists. */
  getSession: (sessionId: string) => { id: string; name?: string } | undefined;
  /** Persist session name update. */
  updateSessionName: (sessionId: string, name: string) => void;
  /** Broadcast session state to connected clients. */
  broadcastSessionUpdate: (sessionId: string) => void;
  onMetrics?: (metrics: TitleGenerationMetrics) => void;
}

export class SessionTitleGenerator {
  private readonly deps: SessionTitleGeneratorDeps;
  private readonly limiter = new ConcurrencyLimiter(2);

  constructor(deps: SessionTitleGeneratorDeps) {
    this.deps = deps;
  }

  /**
   * Attempt to generate a title for a session. Fire-and-forget.
   * Only generates when:
   * - Auto-title is enabled
   * - Session has no existing name
   * - First message is long enough to be meaningful
   */
  tryGenerateTitle(session: { id: string; name?: string; firstMessage?: string }): void {
    const config = this.deps.getConfig();
    if (!config.enabled) return;
    if (session.name && session.name.length > 0) return;
    if (!session.firstMessage || session.firstMessage.length < MIN_MESSAGE_LENGTH) return;
    if (!config.model) return;

    const firstMessage = session.firstMessage;
    const sessionId = session.id;

    // Fire and forget — don't block the turn
    void this.limiter.run(async () => {
      try {
        const provider = this.createProvider(config);
        const title = await provider.generateTitle(firstMessage);
        if (!title) return;

        // Re-check: name may have been set by pi sync or manual rename
        const current = this.deps.getSession(sessionId);
        if (!current || (current.name && current.name.length > 0)) return;

        this.deps.updateSessionName(sessionId, title);
        this.deps.broadcastSessionUpdate(sessionId);
        console.log("[auto-title] generated", { sessionId, title });
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.warn(`${ts()} [auto-title] failed for session=${sessionId}: ${message}`);
      }
    });
  }

  private createProvider(config: AutoTitleConfig): SessionTitleProvider {
    if (!config.enabled || !config.model) {
      return new DisabledProvider();
    }
    return new ApiModelTitleProvider(config.model, this.deps.modelRegistry, this.deps.onMetrics);
  }
}
