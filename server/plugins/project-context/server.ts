import { section } from "@earendil-works/pi-durable";
import { defineExtension, defineFacet, Extensions } from "oppi/v1";
import { PROJECT_CONTEXT_SECTIONS, ProjectContextDoc } from "./contract.js";

/**
 * Durable port of what Pi's resource loader puts in the system prompt: Oppi's appends, then the
 * `project_context` and `skills` sections (`PROJECT_CONTEXT_SECTIONS`). The server renders them
 * when a session attaches or reloads and stores them on the conversation, so a run that resumes
 * while no session is attached still sends the same prompt.
 */
export const DurableProjectContext = defineExtension({
  name: "project-context",
  runtimes: ["host", "sandbox"],
  sections: PROJECT_CONTEXT_SECTIONS.map(({ key, field, tag }) =>
    section(
      key,
      async (input, context) =>
        (await input.read.snapshot(ProjectContextDoc, input.conversationId, context))?.[field],
      { tag },
    ),
  ),
});

/** The plugin facet. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableProjectContext));
