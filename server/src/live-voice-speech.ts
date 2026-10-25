import type { AssistantMessage } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  InlineExtension,
  ExtensionContext,
  SessionEntry,
} from "@earendil-works/pi-coding-agent";

import {
  CALL_STARTED,
  NO_CALL_ATTACHED,
  SAID_ALOUD,
  SPEAK_DESCRIPTION,
  SPEAK_GUIDELINES,
  SPEAK_TOOL_NAME,
  SpeakParams,
} from "../extensions/durable/live-voice/contract.js";
import type { VoiceCallController, VoiceDelegation } from "./continuous-voice-call.js";
import { createLogger } from "./logger.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { speakableText, speechPassages } from "./speech-synthesis.js";

const log = createLogger({ base: { component: "live_voice_speech" } });

type RunMessages = Extract<SessionBackendEvent, { type: "agent_end" }>["messages"];

export const SPEAK_TOOL = SPEAK_TOOL_NAME;
/** Hidden custom message in the session that tells the agent a call started or ended. */
const CALL_MODE_TYPE = "oppi-live-voice-call";
const CALL_ENDED =
  "The Live Voice call ended. Later messages are typed, not speech transcripts. Nobody is listening: replies are no longer read aloud and the speak tool is gone. Stop writing a spoken opening and resume normal written chat.";
/** Live Voice status lines on the phone are a glance, not the transcript. */
const STATUS_MAX_CHARS = 500;

export interface RunOutcome {
  /** `blocked` when the run failed or was stopped. */
  kind: "final" | "blocked";
  /** What the caller last heard from the run, if anything. */
  spoken: string | undefined;
}

export interface LiveVoiceSpeechSink {
  /** Words for the caller said whole: a `speak` heads-up, or how a run failed. */
  speak(sessionId: string, text: string): void;
  /** The next sentence of reply `replyId`'s spoken opening, while the reply is still being written. */
  speakSentence(sessionId: string, replyId: string, text: string): void;
  /**
   * Reply `replyId`'s spoken opening is written; `opening` is all of it the caller should hear.
   * `streamed` when its sentences already went out through `speakSentence`; otherwise the reply
   * opened with written markdown and `opening` is its speakable start, known once it ended.
   */
  openingWritten(sessionId: string, replyId: string, opening: string, streamed: boolean): void;
  runEnded(sessionId: string, outcome: RunOutcome): void;
}

/**
 * What a session runtime of either engine needs from Live Voice: to hear when a call attaches or
 * detaches, and to say the `speak` tool's words. A durable runtime reaches it through
 * `DurableHarness.bindLiveVoice`.
 */
export interface LiveVoiceRuntimePort {
  /**
   * Register a runtime of `sessionId` that turns `speak` on or off. It is called at once with the
   * session's current call state, then on every attach and detach. Returns the unregister.
   */
  attachRuntime(sessionId: string, activate: (attached: boolean) => void): () => void;
  /** `speak`'s words: plays them on the session's call. Throws when no call is attached. */
  spoke(sessionId: string, text: string): void;
}

interface SessionSpeechState {
  callAttached: boolean;
  /** What the caller last heard from this run, if anything. */
  spokenThisRun: string | undefined;
  /** The reply being written now, said while it is written. */
  reply: SpokenOpening | undefined;
  /** A reply that failed after saying something; its automatic retry does not say it again. */
  failedReply: SpokenOpening | undefined;
  /** Each live runtime of the session turns `speak` on or off here. */
  runtimes: Set<(attached: boolean) => void>;
}

/**
 * The agent side of a Live Voice call. While a call is attached to a session, the opening of
 * each reply the agent writes is said to the caller, sentence by sentence while it is still
 * being written, and the agent has a `speak` tool for a heads-up before long work. One hidden
 * message in the session says the call started, another says it ended. A failed run says it
 * failed, so the caller is never left in silence.
 */
export class LiveVoiceSpeech implements LiveVoiceRuntimePort {
  private readonly sessions = new Map<string, SessionSpeechState>();
  private replies = 0;

  constructor(private readonly sink: LiveVoiceSpeechSink) {}

  setCallAttached(sessionId: string, attached: boolean): void {
    const state = this.state(sessionId);
    // The coordinator repeats an attach for every connection; a reply in progress goes on.
    if (state.callAttached !== attached) {
      state.spokenThisRun = undefined;
      state.reply = undefined;
      state.failedReply = undefined;
    }
    state.callAttached = attached;
    for (const activate of [...state.runtimes]) {
      try {
        activate(attached);
      } catch (error) {
        // A runtime disposed without session_shutdown (a forced stop) has a stale Pi API.
        // Drop it so it cannot block the live runtime or a later call.
        state.runtimes.delete(activate);
        log.warn("live_voice.speak_toggle_failed", {
          sessionId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
    this.forgetIfIdle(sessionId, state);
  }

  attachRuntime(sessionId: string, activate: (attached: boolean) => void): () => void {
    const state = this.state(sessionId);
    state.runtimes.add(activate);
    activate(state.callAttached);
    return () => {
      const current = this.sessions.get(sessionId);
      if (!current) return;
      current.runtimes.delete(activate);
      this.forgetIfIdle(sessionId, current);
    };
  }

  spoke(sessionId: string, text: string): void {
    const state = this.sessions.get(sessionId);
    if (!state?.callAttached) throw new Error(NO_CALL_ATTACHED);
    state.spokenThisRun = text;
    this.sink.speak(sessionId, text);
  }

  /** Pi extension for one session's runtime: registers `speak`, active only during a call. */
  extension(sessionId: string): InlineExtension {
    return {
      name: "oppi-live-voice-speak",
      factory: (pi) => this.bind(sessionId, pi),
    };
  }

  /** Session events: each reply's opening is said as it is written; a failed run says so. */
  observe(sessionId: string, event: SessionBackendEvent): void {
    const state = this.sessions.get(sessionId);
    if (!state?.callAttached) return;
    switch (event.type) {
      case "agent_start":
        state.spokenThisRun = undefined;
        state.reply = undefined;
        return;
      case "message_start":
        if (event.message.role !== "assistant") return;
        state.reply = new SpokenOpening(`reply-${++this.replies}`, state.failedReply);
        state.failedReply = undefined;
        this.hearReply(sessionId, state, event.message, false);
        return;
      case "message_update":
      case "message_end":
        if (event.message.role !== "assistant") return;
        this.hearReply(sessionId, state, event.message, event.type === "message_end");
        return;
      case "agent_end": {
        if (event.willRetry) return;
        const spoken = state.spokenThisRun;
        state.spokenThisRun = undefined;
        state.reply = undefined;
        state.failedReply = undefined;
        const failure = runFailure(event.messages);
        if (failure) {
          this.sink.speak(sessionId, failure);
          this.sink.runEnded(sessionId, { kind: "blocked", spoken: failure });
          return;
        }
        this.sink.runEnded(sessionId, { kind: "final", spoken });
        return;
      }
      default:
        return;
    }
  }

  /**
   * The reply grew or finished: say the new sentences of its opening. A reply that opens with
   * written markdown instead (a heading, a list, a table) has the speakable start of its text
   * said once it is done, unless it handed over to tools.
   */
  private hearReply(
    sessionId: string,
    state: SessionSpeechState,
    message: AssistantMessage,
    ended: boolean,
  ): void {
    // A call that attached mid-reply hears that reply from here.
    const reply = (state.reply ??= new SpokenOpening(`reply-${++this.replies}`));
    if (reply.done && !ended) return;
    const wasDone = reply.done;
    const text = replyText(message);
    // A reply cut off by an error or a stop leaves its unfinished sentence unsaid.
    const complete = ended && message.stopReason !== "error" && message.stopReason !== "aborted";
    for (const sentence of reply.next(text, complete)) {
      this.sink.speakSentence(sessionId, reply.id, sentence);
    }
    // The spoken opening is complete even though the reply goes on in writing.
    if (!wasDone && reply.done && reply.sentences.length > 0) {
      const opening = reply.sentences.join(" ");
      // A retry that only repeats a handed-over opening is heard already; it is still what the run said.
      if (reply.repeatsHandedOver) state.spokenThisRun = opening;
      else this.openingWritten(sessionId, state, reply.id, opening, true);
      reply.handedOver = true;
    }
    if (!ended) return;
    state.reply = undefined;
    if (message.stopReason === "error") state.failedReply = reply;
    if (reply.sentences.length > 0) return;
    if (message.stopReason !== "stop" && message.stopReason !== "length") return;
    const opening = speechPassages(speakableText(text))[0];
    if (opening) this.openingWritten(sessionId, state, reply.id, opening, false);
  }

  private openingWritten(
    sessionId: string,
    state: SessionSpeechState,
    replyId: string,
    opening: string,
    streamed: boolean,
  ): void {
    state.spokenThisRun = opening;
    this.sink.openingWritten(sessionId, replyId, opening, streamed);
  }

  private bind(sessionId: string, pi: ExtensionAPI): void {
    const setSpeakActive = (attached: boolean): void => {
      const active = pi.getActiveTools();
      const has = active.includes(SPEAK_TOOL);
      if (attached && !has) pi.setActiveTools([...active, SPEAK_TOOL]);
      else if (!attached && has) pi.setActiveTools(active.filter((name) => name !== SPEAK_TOOL));
    };
    // What the model's context last says about the call. Read from the context Pi builds for the
    // current leaf (after compaction, at the current tree position), not from the whole saved
    // history: a compaction can summarize the message away and tree navigation can move the leaf
    // across it, so the history alone can claim a state the model never sees.
    let announced = false;
    const readContext = (sessionManager: ExtensionContext["sessionManager"]): void => {
      announced = lastAnnouncedCall(sessionManager.buildContextEntries());
    };
    // The call mode is context, not a turn: `triggerTurn: false` appends the message at once when
    // the session is idle, and while a run is in progress holds it until the current turn's tool
    // results are in, so the run's next model call sees it. `steer` and `nextTurn` delivery
    // would start a turn or wait for the next prompt, and a steered message would miss it.
    const announce = (attached: boolean): void => {
      if (attached === announced) return;
      announced = attached;
      pi.sendMessage(
        {
          customType: CALL_MODE_TYPE,
          content: attached ? CALL_STARTED : CALL_ENDED,
          display: false,
          details: { active: attached },
        },
        { triggerTurn: false },
      );
    };
    const activate = (attached: boolean): void => {
      setSpeakActive(attached);
      announce(attached);
    };
    let detach: (() => void) | undefined;
    pi.on("session_start", (_event, ctx) => {
      readContext(ctx.sessionManager);
      // After a server restart the saved session may still say a call is live while the call
      // is gone; the first activation ends it in the context.
      detach = this.attachRuntime(sessionId, activate);
    });
    // The context changed under the call: say again what the call is now.
    const resync = (_event: unknown, ctx: ExtensionContext): void => {
      readContext(ctx.sessionManager);
      announce(this.sessions.get(sessionId)?.callAttached ?? false);
    };
    pi.on("session_compact", resync);
    pi.on("session_tree", resync);
    // Each run settles its own loadout: an activation from attach can be lost while a new
    // runtime is still settling its tools.
    pi.on("before_agent_start", () => {
      setSpeakActive(this.sessions.get(sessionId)?.callAttached ?? false);
      return undefined;
    });
    pi.on("session_shutdown", () => {
      detach?.();
      detach = undefined;
    });
    pi.registerTool({
      name: SPEAK_TOOL,
      label: "Speak",
      description: SPEAK_DESCRIPTION,
      promptSnippet: "Talk to the user out loud on the attached Live Voice call",
      promptGuidelines: SPEAK_GUIDELINES,
      parameters: SpeakParams,
      defaultActive: false,
      executionMode: "sequential",
      execute: async (_toolCallId, params) => {
        // A heads-up; the reply's own opening is said when it is written.
        const text = params.text.trim();
        if (!text) throw new Error("speak text must not be empty");
        this.spoke(sessionId, text);
        return { content: [{ type: "text" as const, text: SAID_ALOUD }], details: { text } };
      },
    });
  }

  private state(sessionId: string): SessionSpeechState {
    let state = this.sessions.get(sessionId);
    if (!state) {
      state = {
        callAttached: false,
        spokenThisRun: undefined,
        reply: undefined,
        failedReply: undefined,
        runtimes: new Set(),
      };
      this.sessions.set(sessionId, state);
    }
    return state;
  }

  private forgetIfIdle(sessionId: string, state: SessionSpeechState): void {
    if (!state.callAttached && state.runtimes.size === 0) this.sessions.delete(sessionId);
  }
}

/** Whether the newest call-mode message in a model context says a call is live. */
function lastAnnouncedCall(branch: readonly SessionEntry[]): boolean {
  for (let index = branch.length - 1; index >= 0; index--) {
    const entry = branch[index];
    if (entry?.type !== "custom_message" || entry.customType !== CALL_MODE_TYPE) continue;
    return (entry.details as { active?: boolean } | undefined)?.active === true;
  }
  return false;
}

/** What the caller should hear when the run's last reply failed or was stopped. */
function runFailure(messages: RunMessages): string | undefined {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (!message || message.role !== "assistant") continue;
    if (message.stopReason === "error") {
      const reason = speechPassages(speakableText(message.errorMessage ?? ""))[0];
      return reason ? `That failed: ${reason}` : "That failed.";
    }
    if (message.stopReason === "aborted") return "Stopped.";
    return undefined;
  }
  return undefined;
}

function replyText(message: AssistantMessage): string {
  return message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n");
}

/**
 * The spoken opening of a reply ends at its first line break, or after the sentence that
 * reaches this many characters. Codex's realtime voice said a short version of the agent's
 * written reply (`.internal/reports/live-voice-spoken-style-from-codex-20261024.md`).
 */
const OPENING_MAX_CHARS = 400;
/** Markdown that starts a written block rather than a spoken sentence. */
const WRITTEN_START = /^(#|[-*+]\s|\d+[.)]\s|[-*_]{3}|\||>|`{3}|~{3}|\$\$|<|!\[)/;
/** Where a sentence ends: closing punctuation before a space, or CJK closing punctuation. */
const SENTENCE_END = /[.!?]["'\u201d\u2019)\]*_]*(?=\s)|[\u3002\uff01\uff1f]/g;
/** Text that ends a sentence, at its end. */
const ENDS_SENTENCE = /([.!?]["'\u201d\u2019)\]]*|[\u3002\uff01\uff1f])$/;
/** A sentence that only introduces what follows ("Here is what I found:"). */
const INTRODUCES = /[:\uff1a]$/;

/**
 * A reply's spoken opening, cut into sentences while the reply is written: the prose before
 * its first line break, capped at OPENING_MAX_CHARS. Text only grows while a reply streams, so
 * each update scans only what was not said yet.
 */
export class SpokenOpening {
  /** What was said so far, as heard. */
  readonly sentences: string[] = [];
  /** Nothing more of this reply is said. */
  done = false;
  /** Index in the reply's text of the first character not said yet; unset until it starts. */
  private cursor: number | undefined;
  private chars = 0;
  /** The whole opening went out as one piece (`openingWritten`) for voices that cannot stream. */
  handedOver = false;
  /** Sentences the caller already heard from a failed attempt at this reply, in order. */
  private heard: string[];
  private saidNew = false;

  constructor(
    readonly id: string,
    private readonly failed?: SpokenOpening,
  ) {
    this.heard = [...(failed?.sentences ?? [])];
  }

  /** A retry that added nothing to an opening its failed attempt already handed over. */
  get repeatsHandedOver(): boolean {
    return this.failed?.handedOver === true && !this.saidNew;
  }

  /** The new sentences in `text`, the reply so far; `complete` once it is fully written. */
  next(text: string, complete: boolean): string[] {
    if (this.done) return [];
    const said: string[] = [];
    if (this.cursor === undefined) {
      const start = text.search(/\S/);
      // Wait for enough text to tell a sentence from a markdown block (`10. `, a fence).
      if (start < 0 || (!complete && text.length - start < 4 && !text.includes("\n", start))) {
        if (complete) this.done = true;
        return said;
      }
      if (WRITTEN_START.test(text.slice(start, start + 4))) {
        this.done = true;
        return said;
      }
      this.cursor = start;
    }
    const lineBreak = text.indexOf("\n", this.cursor);
    const end = lineBreak < 0 ? text.length : lineBreak;
    const pending = text.slice(this.cursor, end);
    let from = 0;
    for (const match of pending.matchAll(SENTENCE_END)) {
      const to = match.index + match[0].length;
      if (!this.say(pending.slice(from, to), said)) return said;
      from = to;
    }
    this.cursor += from;
    const ended = lineBreak >= 0 || complete;
    if (ended || pending.length - from > OPENING_MAX_CHARS) {
      let rest = pending.slice(from).trim();
      // A long run without a sentence end is said up to its last whole word, not held to the end.
      if (!ended) rest = rest.slice(0, Math.max(0, rest.lastIndexOf(" ", OPENING_MAX_CHARS)));
      // A first line without a sentence in it is a label or heading over written detail.
      const spoken = speakableText(rest);
      const label = lineBreak >= 0 && this.sentences.length === 0 && !ENDS_SENTENCE.test(spoken);
      if (!label && !INTRODUCES.test(spoken)) this.say(rest, said);
      this.done = true;
    }
    return said;
  }

  /** Say one sentence unless the opening is already long enough; false once it is. */
  private say(raw: string, said: string[]): boolean {
    const sentence = speakableText(raw);
    if (!sentence) return true;
    if (this.sentences.length > 0 && this.chars + sentence.length > OPENING_MAX_CHARS) {
      this.done = true;
      return false;
    }
    this.sentences.push(sentence);
    this.chars += sentence.length + 1;
    if (this.heard[0] === sentence) this.heard.shift();
    else {
      this.heard = [];
      this.saidNew = true;
      said.push(sentence);
    }
    return true;
  }
}

/** The call side the session link drives. */
export interface LiveVoiceCallMedia {
  callIdsForSession(sessionId: string): string[];
  /** `replyId` names the reply a sentence belongs to (see `VoiceMediaAdapter.speak`). */
  speak(callId: string, text: string, replyId?: string): Promise<void>;
  /** The call's voice says replies sentence by sentence as they are written. */
  streamsReplies(callId: string): boolean;
}

/**
 * Joins Live Voice calls to their sessions: what the caller says becomes their message in the
 * session, what the agent speaks plays on every call attached to it, and the phone's status
 * line follows the run. The server owns one.
 */
export class LiveVoiceSessionLink {
  readonly speech: LiveVoiceSpeech;
  private calls: Pick<
    VoiceCallController,
    "latestOpenDelegationId" | "applyDelegationUpdate"
  > | null = null;
  private media: LiveVoiceCallMedia | null = null;

  constructor(
    private readonly sendPrompt: (sessionId: string, delegation: VoiceDelegation) => Promise<void>,
  ) {
    this.speech = new LiveVoiceSpeech({
      speak: (sessionId, text) => {
        for (const callId of this.callIdsForSession(sessionId)) {
          this.report(callId, undefined, "progress", text);
          void this.media?.speak(callId, text);
        }
      },
      speakSentence: (sessionId, replyId, text) => {
        for (const callId of this.callIdsForSession(sessionId)) {
          if (this.media?.streamsReplies(callId)) void this.media.speak(callId, text, replyId);
        }
      },
      // A voice that cannot stream (Grok) hears each reply's opening whole, once it is written.
      openingWritten: (sessionId, replyId, opening, streamed) => {
        for (const callId of this.callIdsForSession(sessionId)) {
          this.report(callId, undefined, "progress", opening);
          if (!streamed || !this.media?.streamsReplies(callId)) {
            void this.media?.speak(callId, opening, replyId);
          }
        }
      },
      runEnded: (sessionId, outcome) => {
        for (const callId of this.callIdsForSession(sessionId)) {
          this.report(callId, undefined, outcome.kind, outcome.spoken ?? "Done.");
        }
      },
    });
  }

  /** Late binding: the call controller and media coordinator are built around this link. */
  connect(
    calls: Pick<VoiceCallController, "latestOpenDelegationId" | "applyDelegationUpdate">,
    media: LiveVoiceCallMedia,
  ): void {
    this.calls = calls;
    this.media = media;
  }

  /** The caller's words arrive in the session as their message; they steer a busy run. */
  dispatch(sessionId: string, delegation: VoiceDelegation): void {
    this.sendPrompt(sessionId, delegation).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      log.warn("live_voice.prompt_failed", {
        sessionId,
        callId: delegation.callId,
        error: message,
      });
      this.report(delegation.callId, delegation.delegationId, "blocked", message);
      void this.media?.speak(delegation.callId, "That did not reach the session.");
    });
  }

  sessionMediaChanged(sessionId: string, attached: boolean): void {
    this.speech.setCallAttached(sessionId, attached);
  }

  private callIdsForSession(sessionId: string): string[] {
    return this.media?.callIdsForSession(sessionId) ?? [];
  }

  /** The phone's status line, against one utterance or the newest one not yet answered. */
  private report(
    callId: string,
    delegationId: string | undefined,
    kind: "progress" | "final" | "blocked",
    text: string,
  ): void {
    const calls = this.calls;
    if (!calls) return;
    const target = delegationId ?? calls.latestOpenDelegationId(callId);
    if (!target) return;
    try {
      calls.applyDelegationUpdate(callId, {
        delegationId: target,
        kind,
        text: text.slice(0, STATUS_MAX_CHARS),
      });
    } catch (error) {
      // The call ended or moved while the agent spoke; status follows the call, not the agent.
      log.warn("live_voice.status_failed", {
        callId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
}
