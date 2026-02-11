import type { TraceEvent } from "./trace.js";

export type FileMutation =
  | { id: string; kind: "edit"; oldText: string; newText: string }
  | { id: string; kind: "write"; content: string };

/** Normalize tool names (`functions.edit` → `edit`) for trace matching. */
export function normalizeToolName(tool: string | undefined): string {
  if (!tool) return "";
  const normalized = tool.trim().toLowerCase();
  const parts = normalized.split(".");
  return parts[parts.length - 1] ?? normalized;
}

export function collectFileMutations(trace: TraceEvent[], reqPath: string): FileMutation[] {
  const mutations: FileMutation[] = [];

  for (const event of trace) {
    if (event.type !== "toolCall") continue;

    const toolName = normalizeToolName(event.tool);
    if (toolName !== "edit" && toolName !== "write") continue;

    const args = event.args ?? {};
    const pathArg = typeof args.path === "string" ? args.path.trim() : "";
    if (pathArg !== reqPath) continue;

    if (toolName === "edit") {
      const oldText = typeof args.oldText === "string" ? args.oldText : "";
      const newText = typeof args.newText === "string" ? args.newText : "";
      mutations.push({ id: event.id, kind: "edit", oldText, newText });
    } else {
      const content = typeof args.content === "string" ? args.content : "";
      mutations.push({ id: event.id, kind: "write", content });
    }
  }

  return mutations;
}
