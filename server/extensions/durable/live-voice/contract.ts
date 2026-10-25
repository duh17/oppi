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
  "Say a brief heads-up out loud on the Live Voice call attached to this session, before work that takes a while. Your reply's opening is already said aloud; do not repeat it here.";

/** What the agent is told when a call attaches: how the user's messages arrive and how to answer. */
// Wording follows what Codex's realtime voice made of written replies:
// `.internal/reports/live-voice-spoken-style-from-codex-20261024.md`.
export const CALL_STARTED =
  "A Live Voice call started on this session: the user is talking to you by voice. Their messages are speech transcripts, also the ones that arrive while you are working: they may be unpunctuated, split across messages, or contain recognition errors. Read for intent, and ask one short question only when a misheard word would change what you do. The first paragraph of any text you write is read aloud while you write it; the rest stays on screen. When you need any other tool before you can answer, call speak first, before that tool, with a few words on what you are about to do (for example: Checking the logs), so the user is not left in silence while you work, and write no text alongside tool calls: speak is your voice while you work.";

export const SPEAK_GUIDELINES = [
  "A Live Voice call is attached: the user is listening, maybe away from the screen. The first paragraph of any text you write, up to its first line break, is read aloud; the rest stays on screen.",
  "Open your reply, the text you write once any work is done, with one spoken paragraph, then a blank line, then any written detail. Answer first: the result, the state, yes or no, or the one question you need answered. One to three short plain sentences, under about 400 characters. A reply that needed no tools can be the spoken paragraph alone.",
  "The spoken paragraph has no markdown, lists, links, code, paths, URLs, IDs, hashes, branch names, versions, or commands: name things in words and leave exact values to the written part. Round numbers and say at most two. Keep any caveat that changes what the user should do: not done, unverified, failed, blocked, or needs approval. No filler, acknowledgement, or restating the request.",
  "Use speak only for a short heads-up: first, before any other tool, whenever you need tools before you can answer, and when you need the user mid-task. Write no text alongside tool calls; speak is your voice while you work. Never speak your answer: your reply's opening already says it.",
];

export const NO_CALL_ATTACHED = "No Live Voice call is attached; answer in text.";
export const SAID_ALOUD = "Said aloud.";

export const SpeakParams = Type.Object({
  text: Type.String({ minLength: 1, maxLength: SPEAK_MAX_CHARS }),
});
