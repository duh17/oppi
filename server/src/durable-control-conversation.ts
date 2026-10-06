import type { Extension, ToolRegistration } from "@earendil-works/pi-durable";
import { DurableAsk } from "../extensions/durable/ask/durable.js";
import { DurableWorkingWords } from "../extensions/durable/working-words/durable.js";

/**
 * The control conversation's EXACT extension selection, in order, given its `oppi.control`
 * extension (which needs the Oppi host the Harness owner binds). It is stored as an array,
 * never an `{ add }` edit, and is never part of `DurableHarness.baseExtensions`: the control
 * conversation gets no coding tools, sandbox tools, sessions tools, project context, MCP, or
 * bash. New capabilities of the control conversation are added here and only here. Its
 * instructions are the `oppi-control` prompt section of `oppi.control`.
 */
export function controlConversationExtensions(control: Extension): readonly Extension[] {
  return [DurableAsk, DurableWorkingWords, control];
}

/** The tools a selection offers, by registration. */
export function controlConversationTools(extensions: readonly Extension[]): ToolRegistration[] {
  return extensions.flatMap((extension) => extension.tools ?? []);
}
