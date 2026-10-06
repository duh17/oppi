import type { Extension, ToolRegistration } from "@earendil-works/pi-durable";
import { DurableAsk } from "../extensions/durable/ask/durable.js";
import { DurableWorkingWords } from "../extensions/durable/working-words/durable.js";

/**
 * The control conversation's EXACT extension selection, in order. It is stored as an array,
 * never an `{ add }` edit, and is never part of `DurableHarness.baseExtensions`: the control
 * conversation gets no coding tools, sandbox tools, sessions tools, project context, MCP, or
 * bash. New capabilities of the control conversation are added here and only here.
 */
export const CONTROL_CONVERSATION_EXTENSIONS: readonly Extension[] = [
  DurableAsk,
  DurableWorkingWords,
];

/** The tools the selection offers, by registration. */
export function controlConversationTools(): ToolRegistration[] {
  return CONTROL_CONVERSATION_EXTENSIONS.flatMap((extension) => extension.tools ?? []);
}

/** Base instruction until the control extension contributes its own prompt section. */
export const CONTROL_CONVERSATION_INSTRUCTIONS =
  "You are Oppi's control agent. You manage this Oppi server for its owner. Be concise.";
