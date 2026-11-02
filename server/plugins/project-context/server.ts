import { section, type PromptSection } from "@earendil-works/pi-durable";
import { defineExtension, defineFacet, Extensions } from "oppi/v1";
import { ProjectContextDoc } from "./contract.js";

type ProjectContextField =
  "oppiDocs" | "mobileOutputGuide" | "oppiCli" | "projectContext" | "skills";

/** A section rendering one field of the conversation's `ProjectContextDoc`; unset omits it. */
function stored(key: string, field: ProjectContextField): PromptSection {
  return section(
    key,
    async (input, context) =>
      (await input.read.snapshot(ProjectContextDoc, input.conversationId, context))?.[field],
  );
}

/**
 * Durable port of what Pi's resource loader puts in the system prompt: Oppi's appends (the docs
 * hint, the Mobile Output Guide, the `oppi` CLI hint), then the `project_context` and `skills`
 * sections. The server renders them when a session attaches or reloads and stores them on the
 * conversation, so a run that resumes while no session is attached still sends the same prompt.
 * The workspace prompt is part of the conversation's `instructions`, which render last.
 */
export const DurableProjectContext = defineExtension({
  name: "project-context",
  runtimes: ["host", "sandbox"],
  sections: [
    stored("oppi_docs", "oppiDocs"),
    stored("mobile_output_guide", "mobileOutputGuide"),
    stored("oppi_cli", "oppiCli"),
    stored("project_context", "projectContext"),
    stored("skills", "skills"),
  ],
});

/** The plugin facet. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableProjectContext));
