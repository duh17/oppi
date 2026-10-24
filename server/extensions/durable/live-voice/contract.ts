import { Type } from "typebox";

// The agent-facing `speak` tool and call guidance, shared by the classic inline extension
// (`server/src/live-voice-speech.ts`) and the durable built-in (`./durable.ts`), so both runtimes
// offer the same words and limits. Imports nothing from `oppi/durable`, which only the extension
// loader resolves. The server decides when a session has the tool (`LiveVoiceSpeech`).

export const SPEAK_TOOL_NAME = "speak";
/** The durable built-in's name; a session selects it only while a call is attached. */
export const LIVE_VOICE_EXTENSION = "oppi.live-voice";

export const SPEAK_MAX_CHARS = 2_000;

export const SPEAK_DESCRIPTION =
  "Say something out loud to the user on the Live Voice call attached to this session.";

/** What the agent is told when a call attaches: how the user's messages arrive and how to answer. */
export const CALL_STARTED =
  "A Live Voice call started on this session. The user's messages now arrive as speech turned into text: they may be unpunctuated or contain recognition errors, so read for intent. This holds for messages that arrive while you are working too. Answer each one by calling speak first, before any other tool. If you can answer right away, speak the answer. Otherwise speak a few words acknowledging it (for example: On it, checking the logs), then work, and speak the outcome when done.";

export const SPEAK_GUIDELINES = [
  "A Live Voice call is attached: the user is listening, maybe away from the screen. Answer every user message with speak, in one to three short spoken sentences.",
  "Write speak text the way you would say it: no markdown, lists, code, URLs, or file paths read out. Say what changed or what you found, not how.",
  "On long work, use speak for a brief heads-up when you start and when you finish or need the user. Keep your normal written reply in the chat too.",
];

export const NO_CALL_ATTACHED = "No Live Voice call is attached; answer in text.";
export const SAID_ALOUD = "Said aloud.";

export const SpeakParams = Type.Object({
  text: Type.String({ minLength: 1, maxLength: SPEAK_MAX_CHARS }),
});
