import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ModelRegistry } from "@earendil-works/pi-coding-agent";
import {
  AgentDoc,
  type AgentState,
  type Conversation,
  type Harness,
} from "@earendil-works/pi-durable";
import { resolveSessionSeedModel } from "./sdk-backend.js";
import { isThinkingLevel, THINKING_LEVELS, type ThinkingLevel } from "./thinking-levels.js";

/**
 * Model and thinking choice of one conversation, persisted through `configure()`.
 * `SessionHost.models` keeps one per open conversation.
 */
export class DurableModels {
  constructor(
    private readonly harness: Harness,
    private readonly conversation: Conversation,
    private readonly registry: ModelRegistry,
  ) {}

  /** The committed choice, not an attachment's view of it. */
  async current(): Promise<Pick<AgentState, "model" | "thinkingLevel">> {
    const agent = await this.harness.snapshot(AgentDoc, this.conversation.id, BACKGROUND_CONTEXT);
    return { model: agent?.model, thinkingLevel: agent?.thinkingLevel };
  }

  available(): ReturnType<ModelRegistry["getAvailable"]> {
    return this.registry.getAvailable();
  }

  /** Select `provider/modelId` (or a unique id); undefined when it is unavailable. */
  async select(
    modelId: string,
  ): Promise<{ provider: string; id: string; name: string; thinkingLevel?: string } | undefined> {
    const model = resolveSessionSeedModel(this.registry, modelId);
    if (!model) return undefined;
    await this.conversation.configure(
      { model: { provider: model.provider, modelId: model.id } },
      BACKGROUND_CONTEXT,
    );
    const { thinkingLevel } = await this.current();
    return { provider: model.provider, id: model.id, name: model.name, thinkingLevel };
  }

  async selectThinking(level: ThinkingLevel): Promise<void> {
    await this.conversation.configure({ thinkingLevel: level }, BACKGROUND_CONTEXT);
  }

  /** The next (or previous) available model, wrapping; undefined when none is available. */
  async cycleModel(
    direction: "forward" | "backward" = "forward",
  ): Promise<
    { model: { provider: string; id: string }; thinkingLevel: ThinkingLevel } | undefined
  > {
    const models = this.registry.getAvailable();
    if (!models.length) return undefined;
    const current = await this.current();
    const index = models.findIndex(
      (model) => model.provider === current.model?.provider && model.id === current.model?.modelId,
    );
    const next =
      models[(index + (direction === "forward" ? 1 : -1) + models.length) % models.length];
    if (!next) return undefined;
    const selected = await this.select(`${next.provider}/${next.id}`);
    return {
      model: { provider: next.provider, id: next.id },
      thinkingLevel:
        selected?.thinkingLevel !== undefined && isThinkingLevel(selected.thinkingLevel)
          ? selected.thinkingLevel
          : "off",
    };
  }

  async cycleThinking(): Promise<ThinkingLevel> {
    const { thinkingLevel } = await this.current();
    const next =
      THINKING_LEVELS[
        (THINKING_LEVELS.indexOf(thinkingLevel as ThinkingLevel) + 1) % THINKING_LEVELS.length
      ] ?? "off";
    await this.selectThinking(next);
    return next;
  }
}
