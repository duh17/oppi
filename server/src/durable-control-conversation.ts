import type { Extension, ToolRegistration } from "@earendil-works/pi-durable";

/**
 * The EXACT extension selection of every durable Oppi Control session (the standing control
 * conversation and each `POST /control-sessions` session), in order: the built-ins `ask`,
 * `working-words`, `oppi.control`, and `project-context` (found by name in the loaded built-ins),
 * pi-durable's `codemode` extension, whose scripts call the control tools, and pi-durable's
 * CodingTools (`read`, `write`, `edit`, `bash`), as a classic Pi Control session had. It is stored
 * as an array, never an `{ add }` edit, and is never part of `DurableHarness.defaultExtensions`: a
 * control session gets no sandbox tools, sessions tools, AGENTS files, Skills, MCP, or Pi package
 * extensions. `project-context` renders only Oppi's appends there: the Mobile Output Guide, under
 * its setting. New capabilities of control sessions are added here and only here. Their
 * instructions are the `oppi-control` prompt section of `oppi.control`.
 *
 * The confirm cards guard only `oppi.control`'s tools. `bash` can run any command, `oppi`
 * included, without a card: like classic Pi Control, the prompt asks the model to show a
 * write and wait for the owner's yes, which is an instruction, not an enforced gate.
 */
export function controlConversationExtensions(
  builtIn: (name: string) => Extension,
  codemode: Extension,
  codingTools: Extension,
): readonly Extension[] {
  return [
    builtIn("ask"),
    builtIn("working-words"),
    builtIn("oppi.control"),
    builtIn("project-context"),
    codemode,
    codingTools,
  ];
}

/** The tools a selection offers, by registration. */
export function controlConversationTools(extensions: readonly Extension[]): ToolRegistration[] {
  return extensions.flatMap((extension) => extension.tools ?? []);
}
