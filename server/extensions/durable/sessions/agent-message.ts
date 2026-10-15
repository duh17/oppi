// Pure transcript metadata: safe to import without loading the Durable runtime.
import type { JsonValue } from "@earendil-works/chord";

/**
 * Entry kind an input from another agent session is placed as, instead of `pi.user`
 * (pi-durable `InputEntry`). Its model message is still the plain user message; the
 * entry data says who sent it, so the transcript shows it as that session's message.
 */
export const AGENT_MESSAGE_ENTRY_KIND = "oppi.agent-message";

/** Who sent a user-role input that the user did not type. Protocol shape. */
export type MessageOrigin = {
  kind: "session";
  /** Sending session. */
  sessionId: string;
  name?: string;
  /** task: handed over at spawn; report: a background child's answer; message: session_send. */
  intent: "task" | "report" | "message";
};

/** What an agent message entry stores. */
export type AgentMessageData = {
  origin: MessageOrigin;
  /** UTF-16 offset where the displayed text starts: the model-only header before it is hidden. */
  textOffset?: number;
};

/** The pi-durable `InputEntry` an input from `origin` is placed as. */
export function agentMessageEntry(
  origin: MessageOrigin,
  textOffset?: number,
): { kind: string; data: { [key: string]: JsonValue } } {
  const { kind, sessionId, name, intent } = origin;
  return {
    kind: AGENT_MESSAGE_ENTRY_KIND,
    data: {
      origin: { kind, sessionId, intent, ...(name ? { name } : {}) },
      ...(textOffset ? { textOffset } : {}),
    },
  };
}

const INTENTS = new Set<MessageOrigin["intent"]>(["task", "report", "message"]);

/** The origin of an entry, if it is a well-formed agent message. */
export function agentMessageOrigin(
  kind: string | undefined,
  data: unknown,
): AgentMessageData | undefined {
  if (kind !== AGENT_MESSAGE_ENTRY_KIND || !data || typeof data !== "object") return undefined;
  const { origin, textOffset } = data as Record<string, unknown>;
  if (!origin || typeof origin !== "object") return undefined;
  const { kind: originKind, sessionId, name, intent } = origin as Record<string, unknown>;
  if (originKind !== "session") return undefined;
  if (typeof sessionId !== "string" || !sessionId) return undefined;
  if (typeof intent !== "string" || !INTENTS.has(intent as MessageOrigin["intent"]))
    return undefined;
  return {
    origin: {
      kind: "session",
      sessionId,
      ...(typeof name === "string" && name ? { name: name.slice(0, 200) } : {}),
      intent: intent as MessageOrigin["intent"],
    },
    ...(Number.isSafeInteger(textOffset) && (textOffset as number) > 0
      ? { textOffset: textOffset as number }
      : {}),
  };
}

/** Displayed text of an agent message: the model text after its header. */
export function agentMessageText(text: string, data: AgentMessageData): string {
  const offset = data.textOffset ?? 0;
  if (offset <= 0 || offset > text.length) return text;
  const body = text.slice(offset).trimStart();
  return body || text;
}
