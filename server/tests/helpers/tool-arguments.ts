import { validateToolArguments } from "@earendil-works/pi-ai";
import type { ToolRegistration } from "@earendil-works/pi-durable";

/**
 * What the durable Harness makes of a model's `args` for `tool` before it runs it: the coerced
 * arguments, or the validation error the model is shown, thrown. The Harness validates every call
 * with this pi-ai function.
 */
export function toolArguments(tool: ToolRegistration, args: Record<string, unknown>): unknown {
  return validateToolArguments(tool, {
    type: "toolCall",
    id: "call",
    name: tool.name,
    arguments: args,
  });
}

/** The tool named `name` among an extension's tools. */
export function toolNamed(
  tools: readonly ToolRegistration[] | undefined,
  name: string,
): ToolRegistration {
  const tool = tools?.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`No tool ${name}`);
  return tool;
}
