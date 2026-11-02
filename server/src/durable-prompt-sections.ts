import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Conversation } from "@earendil-works/pi-durable";
import { ProjectContextDoc } from "../plugins/project-context/contract.js";
import {
  renderProjectContext,
  renderSkills,
  type DurableProjectResources,
} from "./durable-project-resources.js";
import type { MobileOutputGuideSettingsSnapshot } from "./mobile-output-guide-settings.js";
import { OPPI_CLI_SYSTEM_PROMPT_HINT } from "./oppi-cli-prompt.js";
import { buildMobileOutputGuide, buildOppiSystemPromptAppend } from "./oppi-docs.js";
import { isOppiCliPromptEnabled, isOppiDocsPromptEnabled } from "./sdk-backend.js";
import type { ServerConfig } from "./types.js";

/** Oppi's appends to the system prompt, rendered by the `project-context` sections. */
type PromptAppends = {
  readonly oppiDocs?: string;
  readonly mobileOutputGuide?: string;
  readonly oppiCli?: string;
};

/** The project resources a durable session presents, with Oppi's prompt appends. */
export type PresentedResources = DurableProjectResources & { readonly appends: PromptAppends };

/**
 * Oppi's appends to a workspace session's prompt, gated as an SDK session's
 * `buildSdkAppendSystemPrompt` gates them. The docs and `oppi` CLI hints are for host sessions
 * only: a sandbox prompt never names host paths. The Mobile Output Guide follows its setting,
 * but never after a saved Agent's replacement prompt.
 */
export function promptAppends(options: {
  sandbox: boolean;
  replace: boolean;
  serverConfig: Pick<ServerConfig, "oppiDocsPrompt" | "oppiCliPrompt"> | undefined;
  guide: MobileOutputGuideSettingsSnapshot;
}): PromptAppends {
  const { sandbox, replace, serverConfig, guide } = options;
  const oppiDocs =
    !sandbox && isOppiDocsPromptEnabled(serverConfig) ? buildOppiSystemPromptAppend() : undefined;
  return {
    ...(oppiDocs ? { oppiDocs } : {}),
    ...(guide.enabled && !replace ? { mobileOutputGuide: buildMobileOutputGuide() } : {}),
    ...(!sandbox && isOppiCliPromptEnabled(serverConfig)
      ? { oppiCli: OPPI_CLI_SYSTEM_PROMPT_HINT }
      : {}),
  };
}

/** Store the rendered sections; a changed section reaches the model on its next request. */
export async function syncProjectContext(
  conversation: Conversation,
  resources: PresentedResources,
): Promise<void> {
  const tools = (await conversation.agent(BACKGROUND_CONTEXT)).tools.map((tool) => tool.name);
  const next = {
    ...resources.appends,
    projectContext: renderProjectContext(resources.contextFiles),
    skills: renderSkills(resources.skills, tools),
  };
  await conversation.commit(async (tx) => {
    const doc = await tx.doc(ProjectContextDoc, conversation.id);
    for (const key of [
      "oppiDocs",
      "mobileOutputGuide",
      "oppiCli",
      "projectContext",
      "skills",
    ] as const) {
      const value = next[key];
      if (doc[key] === value) continue;
      if (value === undefined) delete doc[key];
      else doc[key] = value;
    }
  }, BACKGROUND_CONTEXT);
}
