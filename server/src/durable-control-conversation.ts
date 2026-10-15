import type { Extension, ToolRegistration } from "@earendil-works/pi-durable";

/**
 * The control conversation's EXACT extension selection, in order: the built-ins `ask`,
 * `working-words`, and `oppi.control` (found by name in the loaded built-ins), then pi-durable's
 * `codemode` extension, whose scripts call the control tools. It is stored as an array, never an
 * `{ add }` edit, and is never part of `DurableHarness.defaultExtensions`: the control
 * conversation gets no coding tools, sandbox tools, sessions tools, project context, MCP, or
 * bash. New capabilities of the control conversation are added here and only here. Its
 * instructions are the `oppi-control` prompt section of `oppi.control`.
 */
export function controlConversationExtensions(
  builtIn: (name: string) => Extension,
  codemode: Extension,
): readonly Extension[] {
  return [builtIn("ask"), builtIn("working-words"), builtIn("oppi.control"), codemode];
}

/** The tools a selection offers, by registration. */
export function controlConversationTools(extensions: readonly Extension[]): ToolRegistration[] {
  return extensions.flatMap((extension) => extension.tools ?? []);
}
