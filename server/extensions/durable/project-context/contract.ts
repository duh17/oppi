import { defineDoc } from "@earendil-works/pi-durable";

/**
 * The rendered `project_context` and `skills` sections of a conversation. The server writes it
 * when a session attaches or reloads; the durable entry reads it. Shared by both, so it imports
 * nothing from `oppi/durable`, which only the extension loader resolves.
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
