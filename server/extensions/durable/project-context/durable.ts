import { defineExtension, section } from "@earendil-works/pi-durable";
import { ProjectContextDoc } from "./contract.js";

/**
 * Durable port of Pi's `project_context` and `skills` system prompt sections.
 * The server loads AGENTS files and Skills when a session attaches or reloads and
 * stores the rendered sections on the conversation, so a run that resumes while
 * no session is attached still sends the same prompt.
 */
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

/** The durable entry (`package.json` `oppi.durable`). */
export default DurableProjectContext;
