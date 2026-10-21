import type {
  ExtensionAPI,
  InlineExtension,
  ExtensionContext,
  SessionEntry,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import type { VoiceCallController, VoiceDelegation } from "./continuous-voice-call.js";
import { createLogger } from "./logger.js";
import type { SessionBackendEvent } from "./pi-events.js";
import { speakableText, speechPassages } from "./speech-synthesis.js";

const log = createLogger({ base: { component: "live_voice_speech" } });

type RunMessages = Extract<SessionBackendEvent, { type: "agent_end" }>["messages"];

export const SPEAK_TOOL = "speak";
/** Hidden custom message in the session that tells the agent a call started or ended. */
const CALL_MODE_TYPE = "oppi-live-voice-call";
const CALL_STARTED =
  "A Live Voice call started on this session. The user's messages now arrive as speech turned into text: they may be unpunctuated or contain recognition errors, so read for intent. This holds for messages that arrive while you are working too. Answer each one by calling speak first, before any other tool. If you can answer right away, speak the answer. Otherwise speak a few words acknowledging it (for example: On it, checking the logs), then work, and speak the outcome when done.";
const CALL_ENDED =
  "The Live Voice call ended. The speak tool is gone and nobody is listening. The user's messages are typed again: resume normal written chat.";
const MAX_SPOKEN_CHARS = 2_000;
/** Live Voice status lines on the phone are a glance, not the transcript. */
const STATUS_MAX_CHARS = 500;

export interface RunOutcome {
  /** `blocked` when the run failed or was stopped. */
  kind: "final" | "blocked";
  /** What the caller last heard from the run, if anything. */
  spoken: string | undefined;
}

export interface LiveVoiceSpeechSink {
  /** The agent's words for the caller. */
  speak(sessionId: string, text: string): void;
  runEnded(sessionId: string, outcome: RunOutcome): void;
}

interface SessionSpeechState {
  callAttached: boolean;
  /** What this run said aloud, if anything. */
  spokenThisRun: string | undefined;
  /** Each live Pi runtime of the session turns `speak` on or off here. */
  runtimes: Set<(attached: boolean) => void>;
}

/**
 * The agent side of a Live Voice call. While a call is attached to a session, its agent has a
 * `speak` tool and answers out loud with it; one hidden message in the session says the call
 * started, another says it ended. A run that ends without speaking still gets its
 * final reply's opening read aloud, and a failed run says it failed, so the caller is never
 * left in silence.
 */
export class LiveVoiceSpeech {
  private readonly sessions = new Map<string, SessionSpeechState>();

  constructor(private readonly sink: LiveVoiceSpeechSink) {}

  setCallAttached(sessionId: string, attached: boolean): void {
    const state = this.state(sessionId);
    state.callAttached = attached;
    state.spokenThisRun = undefined;
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

  /** Pi extension for one session's runtime: registers `speak`, active only during a call. */
  extension(sessionId: string): InlineExtension {
    return {
      name: "oppi-live-voice-speak",
      factory: (pi) => this.bind(sessionId, pi),
    };
  }

  /** Session events: a run that never spoke reads its final reply's opening, or its failure. */
  observe(sessionId: string, event: SessionBackendEvent): void {
    const state = this.sessions.get(sessionId);
    if (!state?.callAttached) return;
    if (event.type === "agent_start") {
      state.spokenThisRun = undefined;
      return;
    }
    if (event.type !== "agent_end" || event.willRetry) return;
    const spokenThisRun = state.spokenThisRun;
    state.spokenThisRun = undefined;
    const ending = finalReply(event.messages);
    if (ending.failed) {
      this.sink.speak(sessionId, ending.text);
      this.sink.runEnded(sessionId, { kind: "blocked", spoken: ending.text });
      return;
    }
    let spoken = spokenThisRun;
    if (spoken === undefined && ending.text) {
      spoken = ending.text;
      this.sink.speak(sessionId, spoken);
    }
    this.sink.runEnded(sessionId, { kind: "final", spoken });
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
    pi.on("session_start", (_event, ctx) => {
      readContext(ctx.sessionManager);
      const state = this.state(sessionId);
      state.runtimes.add(activate);
      // After a server restart the saved session may still say a call is live while the call
      // is gone; this ends it in the context.
      activate(state.callAttached);
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
      const state = this.sessions.get(sessionId);
      if (!state) return;
      state.runtimes.delete(activate);
      this.forgetIfIdle(sessionId, state);
    });
    pi.registerTool({
      name: SPEAK_TOOL,
      label: "Speak",
      description:
        "Say something out loud to the user on the Live Voice call attached to this session.",
      promptSnippet: "Talk to the user out loud on the attached Live Voice call",
      promptGuidelines: [
        "A Live Voice call is attached: the user is listening, maybe away from the screen. Answer every user message with speak, in one to three short spoken sentences.",
        "Write speak text the way you would say it: no markdown, lists, code, URLs, or file paths read out. Say what changed or what you found, not how.",
        "On long work, use speak for a brief heads-up when you start and when you finish or need the user. Keep your normal written reply in the chat too.",
      ],
      parameters: Type.Object({
        text: Type.String({ minLength: 1, maxLength: MAX_SPOKEN_CHARS }),
      }),
      defaultActive: false,
      executionMode: "sequential",
      execute: async (_toolCallId, params) => {
        const text = params.text.trim();
        if (!text) throw new Error("speak text must not be empty");
        const state = this.sessions.get(sessionId);
        if (!state?.callAttached) {
          throw new Error("No Live Voice call is attached; answer in text.");
        }
        state.spokenThisRun = text;
        this.sink.speak(sessionId, text);
        return { content: [{ type: "text" as const, text: "Said aloud." }], details: { text } };
      },
    });
  }

  private state(sessionId: string): SessionSpeechState {
    let state = this.sessions.get(sessionId);
    if (!state) {
      state = { callAttached: false, spokenThisRun: undefined, runtimes: new Set() };
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

/** How the run ended, as the caller should hear it. */
function finalReply(messages: RunMessages): { text: string; failed: boolean } {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (!message || message.role !== "assistant") continue;
    if (message.stopReason === "error") {
      const reason = speechPassages(speakableText(message.errorMessage ?? ""))[0];
      return { text: reason ? `That failed: ${reason}` : "That failed.", failed: true };
    }
    if (message.stopReason === "aborted") return { text: "Stopped.", failed: true };
    const text = message.content
      .flatMap((part) => (part.type === "text" ? [part.text] : []))
      .join("\n");
    const opening = speechPassages(speakableText(text))[0];
    if (opening) return { text: opening, failed: false };
  }
  return { text: "", failed: false };
}

/** The call side the session link drives. */
export interface LiveVoiceCallMedia {
  callIdsForSession(sessionId: string): string[];
  speak(callId: string, text: string): Promise<void>;
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
      speak: (sessionId, text) => this.speakOnSession(sessionId, text),
      runEnded: (sessionId, outcome) => {
        for (const callId of this.media?.callIdsForSession(sessionId) ?? []) {
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

  private speakOnSession(sessionId: string, text: string): void {
    for (const callId of this.media?.callIdsForSession(sessionId) ?? []) {
      this.report(callId, undefined, "progress", text);
      void this.media?.speak(callId, text);
    }
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
