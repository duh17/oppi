import type { InlineExtension } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import {
  NOTIFY_BODY,
  NOTIFY_DESCRIPTION,
  NOTIFY_GUIDELINES,
  NOTIFY_TITLE,
  NOTIFY_TOOL_NAME,
  notifyOutcomeText,
  type NotifyOutcome,
} from "../plugins/notify/contract.js";
import type { SessionNotifyPort } from "./session-push-notifier.js";

/**
 * The agent `notify` tool for a classic session. Registered on each resource load only while
 * the server offers it to this session (top-level, push on), so a reload after push turns on
 * or off adds or drops it. The durable built-in (`plugins/notify`) is the same tool.
 */
export function createNotifyExtension(sessionId: string, port: SessionNotifyPort): InlineExtension {
  return {
    name: "oppi-notify",
    factory: (pi) => {
      if (!port.offersNotify(sessionId)) return;
      pi.registerTool({
        name: NOTIFY_TOOL_NAME,
        label: "Notify",
        description: NOTIFY_DESCRIPTION,
        promptSnippet: "Send the user a push notification when a result is ready to read",
        promptGuidelines: NOTIFY_GUIDELINES,
        parameters: Type.Object({
          title: Type.String(NOTIFY_TITLE),
          body: Type.String(NOTIFY_BODY),
        }),
        async execute(_toolCallId, params) {
          const outcome: NotifyOutcome = await port.notify(sessionId, params);
          return {
            content: [{ type: "text", text: notifyOutcomeText(outcome) }],
            details: outcome,
          };
        },
      });
    },
  };
}
