import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import { oppiHost } from "oppi/durable";
import {
  CALL_STARTED,
  LIVE_VOICE_EXTENSION,
  NO_CALL_ATTACHED,
  SAID_ALOUD,
  SPEAK_DESCRIPTION,
  SPEAK_GUIDELINES,
  SPEAK_TOOL_NAME,
  SpeakParams,
} from "./contract.js";

const speak = defineTool({
  name: SPEAK_TOOL_NAME,
  description: SPEAK_DESCRIPTION,
  parameters: SpeakParams,
  executionMode: "sequential",
  // Default `unsafe`: words a crash interrupted are not said again.
  async execute(args, api) {
    const text = args.text.trim();
    if (!text) throw new Error("speak text must not be empty");
    const say = oppiHost().liveVoice(api.env);
    if (!say) throw new Error(NO_CALL_ATTACHED);
    say(text);
    return { output: [{ type: "text", text: SAID_ALOUD }], details: { text } };
  },
});

/**
 * Selected only while a Live Voice call is attached (`DurableBackend`): the section tells the
 * agent about the call, and both leave the prompt when the call ends.
 */
export default defineExtension({
  name: LIVE_VOICE_EXTENSION,
  tools: [speak],
  sections: [section("live-voice", () => [CALL_STARTED, ...SPEAK_GUIDELINES].join("\n"))],
});
