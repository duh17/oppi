import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { oppiHost } from "oppi/durable";
import {
  NOTIFY_DESCRIPTION,
  NOTIFY_GUIDELINES,
  NOTIFY_TOOL_NAME,
  NotifyParams,
  notifyOutcomeText,
  type NotifyOutcome,
} from "./contract.js";

const notify = defineTool({
  name: NOTIFY_TOOL_NAME,
  description: NOTIFY_DESCRIPTION,
  parameters: NotifyParams,
  // Default `unsafe`: a call a crash interrupted is not sent again.
  async execute(args, api) {
    const send = oppiHost().notify(api.env);
    const outcome: NotifyOutcome = send ? await send(args) : { status: "off" };
    return { output: [{ type: "text", text: notifyOutcomeText(outcome) }], details: outcome };
  },
});

/**
 * Selected only for a top-level session while push is on (`DurableBackend`), so the model never
 * sees a tool that cannot reach anyone.
 */
export default defineExtension({
  name: "oppi.notify",
  tools: [notify],
  sections: [section("notify-guidelines", () => NOTIFY_GUIDELINES.join("\n"))],
});
