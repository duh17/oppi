import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { AgentDoc, type Conversation } from "@earendil-works/pi-durable";
import {
  PROJECT_CONTEXT_SECTIONS,
  ProjectContextDoc,
  type ProjectContextField,
} from "../plugins/project-context/contract.js";
import {
  renderProjectContext,
  renderSkills,
  type DurableProjectResources,
} from "./durable-project-resources.js";

/**
 * The project resources a durable session presents, with Oppi's appends to its prompt: what
 * `oppiAppendSystemPrompt` returns, in its order.
 */
export type PresentedResources = DurableProjectResources & { readonly appends: readonly string[] };

/**
 * Store the rendered sections; a changed section reaches the model on its next request. The
 * appends render as one section, joined as Pi joins a classic session's appends.
 */
export async function syncProjectContext(
  conversation: Conversation,
  resources: PresentedResources,
): Promise<void> {
  const tools = (await conversation.agent(BACKGROUND_CONTEXT)).tools.map((tool) => tool.name);
  const next: Record<ProjectContextField, string | undefined> = {
    oppiAppend: resources.appends.length > 0 ? resources.appends.join("\n\n") : undefined,
    projectContext: renderProjectContext(resources.contextFiles),
    skills: renderSkills(resources.skills, tools),
  };
  await conversation.commit(async (tx) => {
    const doc = await tx.doc(ProjectContextDoc, conversation.id);
    for (const { field } of PROJECT_CONTEXT_SECTIONS) {
      const value = next[field];
      if (doc[field] === value) continue;
      if (value === undefined) delete doc[field];
      else doc[field] = value;
    }
  }, BACKGROUND_CONTEXT);
}

/**
 * A conversation created while the workspace prompt was part of its instructions still carries
 * it there; the `oppi_append` section renders it now, so drop it from the instructions to send it
 * once. Only where the old layout put it: a whole paragraph right after the `Working directory`
 * line, so a saved Agent's appended text that merely starts with the same words stays. Matches
 * the current workspace prompt exactly: a prompt edited since the conversation was created stays
 * in its instructions.
 */
export async function dropInstructionsWorkspacePrompt(
  conversation: Conversation,
  workspacePrompt: string | undefined,
): Promise<void> {
  if (!workspacePrompt) return;
  const escaped = workspacePrompt.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const embedded = new RegExp(`(Working directory: [^\\n]*)\\n\\n${escaped}(?=\\n\\n|$)`);
  const stored = (await conversation.agent(BACKGROUND_CONTEXT)).instructions;
  if (stored === undefined || !embedded.test(stored)) return;
  await conversation.commit(async (tx) => {
    const agent = await tx.doc(AgentDoc, conversation.id);
    if (typeof agent.instructions === "string")
      agent.instructions = agent.instructions.replace(embedded, "$1");
  }, BACKGROUND_CONTEXT);
}
