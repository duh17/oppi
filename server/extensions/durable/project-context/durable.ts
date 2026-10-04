import { defineDoc, defineExtension, section } from "@earendil-works/pi-durable";

/**
 * Durable port of Pi's `project_context` and `skills` system prompt sections.
 * The server loads AGENTS files and Skills when a session attaches or reloads and
 * stores the rendered sections on the conversation, so a run that resumes while
 * no session is attached still sends the same prompt.
 */
export const ProjectContextDoc = defineDoc<{
  /** Body of the `project_context` section; unset without context files. */
  projectContext?: string;
  /** Body of the `skills` section; unset without model-visible Skills. */
  skills?: string;
}>({
  kind: "oppi.project-context",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({}),
});

export const DurableProjectContext = defineExtension({
  name: "project-context",
  sections: [
    section(
      "project_context",
      async (input, context) =>
        (await input.read.snapshot(ProjectContextDoc, input.conversationId, context))
          ?.projectContext,
    ),
    section(
      "skills",
      async (input, context) =>
        (await input.read.snapshot(ProjectContextDoc, input.conversationId, context))?.skills,
    ),
  ],
});
