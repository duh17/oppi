import { defineDoc } from "@earendil-works/pi-durable";

/**
 * The rendered prompt sections of a conversation: Oppi's appends to the system prompt, then
 * `project_context` and `skills`. The server writes it when a session attaches or reloads; the
 * plugin reads it. Shared by both, so it imports nothing from `oppi/v1`, which only the plugin
 * host resolves.
 */
export const ProjectContextDoc = defineDoc<{
  /** Where Oppi's docs are; unset for a sandbox, Oppi Control, or `oppiDocsPrompt` off. */
  oppiDocs?: string;
  /** The Mobile Output Guide; unset while its setting is off. */
  mobileOutputGuide?: string;
  /** The `oppi` CLI hint; unset unless `oppiCliPrompt` is on (never a sandbox or Oppi Control). */
  oppiCli?: string;
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
  // Written only when a section changes.
  checkpointWhen: () => false,
});
