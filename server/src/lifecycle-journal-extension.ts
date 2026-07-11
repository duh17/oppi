import type { InlineExtension } from "@earendil-works/pi-coding-agent";

/**
 * Versioned Pi custom-entry type used to persist structural lifecycle events.
 *
 * Pi's normal JSONL entries persist messages and tool results, but structural
 * events such as agent_end are otherwise live-only. Persisting those events in
 * the same branch-aware session log lets every client rebuild lifecycle state
 * from Pi evidence after process replacement, reconnect, or server restart.
 */
export const OPPI_LIFECYCLE_CUSTOM_TYPE = "oppi-lifecycle";

export type OppiLifecycleEventType =
  | "agent_start"
  | "agent_end"
  | "agent_settled"
  | "turn_start"
  | "turn_end"
  | "tool_execution_start"
  | "tool_execution_end";

export interface OppiLifecycleEntryData {
  version: 1;
  event: OppiLifecycleEventType;
  turnIndex?: number;
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
}

export function createLifecycleJournalExtension(): InlineExtension {
  return {
    name: "oppi-lifecycle-journal",
    factory: (pi) => {
      const append = (data: OppiLifecycleEntryData): void => {
        pi.appendEntry(OPPI_LIFECYCLE_CUSTOM_TYPE, data);
      };

      pi.on("agent_start", () => {
        append({ version: 1, event: "agent_start" });
      });
      pi.on("agent_end", () => {
        append({ version: 1, event: "agent_end" });
      });
      pi.on("agent_settled", () => {
        append({ version: 1, event: "agent_settled" });
      });
      pi.on("turn_start", (event) => {
        append({ version: 1, event: "turn_start", turnIndex: event.turnIndex });
      });
      pi.on("turn_end", (event) => {
        append({ version: 1, event: "turn_end", turnIndex: event.turnIndex });
      });
      pi.on("tool_execution_start", (event) => {
        append({
          version: 1,
          event: "tool_execution_start",
          toolCallId: event.toolCallId,
          toolName: event.toolName,
        });
      });
      pi.on("tool_execution_end", (event) => {
        append({
          version: 1,
          event: "tool_execution_end",
          toolCallId: event.toolCallId,
          toolName: event.toolName,
          isError: event.isError,
        });
      });
    },
  };
}
