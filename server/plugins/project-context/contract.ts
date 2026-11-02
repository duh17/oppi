import { defineDoc } from "@earendil-works/pi-durable";

/**
 * The `project-context` sections, in prompt order: each section's key, the `ProjectContextDoc`
 * field holding its body (unset omits the section), and whether it renders tagged.
 *
 * - `oppi_append`: Oppi's appends to the system prompt, in the order `oppiAppendSystemPrompt`
 *   gives them (the docs hint, the `oppi` CLI hint, the workspace prompt, the Mobile Output
 *   Guide), untagged as a classic session appends them.
 * - `project_context`: the AGENTS files.
 * - `skills`: the model-visible Skills.
 */
export const PROJECT_CONTEXT_SECTIONS = [
  { key: "oppi_append", field: "oppiAppend", tag: false },
  { key: "project_context", field: "projectContext", tag: true },
  { key: "skills", field: "skills", tag: true },
] as const;

export type ProjectContextField = (typeof PROJECT_CONTEXT_SECTIONS)[number]["field"];

/**
 * The rendered `project-context` sections of a conversation. The server writes it when a session
 * attaches or reloads; the plugin reads it. Shared by both, so it imports nothing from `oppi/v1`,
 * which only the plugin host resolves.
 */
export const ProjectContextDoc = defineDoc<Partial<Record<ProjectContextField, string>>>({
  kind: "oppi.project-context",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({}),
  // Written only when a section changes.
  checkpointWhen: () => false,
});
