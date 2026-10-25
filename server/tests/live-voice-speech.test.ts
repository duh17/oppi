import { describe, expect, it } from "vitest";

import { VoiceCallController, type VoiceDelegation } from "../src/continuous-voice-call.js";
import {
  VoiceCallMediaCoordinator,
  YuwpVoiceMediaAdapter,
  type LiveVoiceTtsPort,
} from "../src/continuous-voice-media.js";
import {
  LiveVoiceSessionLink,
  LiveVoiceSpeech,
  type RunOutcome,
} from "../src/live-voice-speech.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import type { SttProvider, SttTranscriptUpdate } from "../src/stt-provider.js";
import type { VoiceCallDelegationUpdateKind } from "../src/types.js";
import { DeterministicVoiceCallFrontend } from "./helpers/deterministic-voice-call-frontend.js";

const start = { type: "agent_start" } as SessionBackendEvent;

function assistant(text: string, extra: Record<string, unknown> = {}) {
  return {
    role: "assistant",
    content: text ? [{ type: "text", text }] : [],
    stopReason: "stop",
    ...extra,
  };
}

function runEnd(message: Record<string, unknown>): SessionBackendEvent {
  return {
    type: "agent_end",
    willRetry: false,
    messages: [{ role: "assistant", content: [], stopReason: "stop", ...message }],
  } as unknown as SessionBackendEvent;
}

/** One reply as the runtime streams it: started empty, growing by chunks, then ended. */
function writeReply(speech: LiveVoiceSpeech, sessionId: string) {
  let text = "";
  const send = (type: string, extra: Record<string, unknown> = {}) =>
    speech.observe(sessionId, { type, message: assistant(text, extra) } as SessionBackendEvent);
  send("message_start");
  return {
    write(chunk: string) {
      text += chunk;
      send("message_update");
    },
    end(extra: Record<string, unknown> = {}) {
      send("message_end", extra);
    },
  };
}

/** A whole run with one written reply. */
function replyRun(speech: LiveVoiceSpeech, sessionId: string, text: string): void {
  speech.observe(sessionId, start);
  const reply = writeReply(speech, sessionId);
  reply.write(text);
  reply.end();
  speech.observe(sessionId, runEnd(assistant(text)));
}

interface SavedMessage {
  customType: string;
  content: string;
  display: boolean;
  details?: { active?: boolean };
}

/**
 * A Pi runtime as the extension sees it: the active tool list, the registered tool, and a
 * session that follows Pi's `sendMessage` rules for a message without `triggerTurn`: saved at
 * once when idle, held until the current turn ends while a run is in progress. `saved` is what
 * the next model call would carry for the call; `entries` is the saved session a restart reloads.
 */
class FakeRuntime {
  active = ["read"];
  stale = false;
  busy = false;
  /** Saved history, oldest first; the model's context is the part from `contextFrom`. */
  entries: Array<{ type: "custom_message" } & SavedMessage>;
  private contextFrom = 0;
  private pending: SavedMessage[] = [];
  private readonly handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
  private tool: { execute: (id: string, params: { text: string }) => Promise<unknown> } | undefined;

  constructor(
    speech: LiveVoiceSpeech,
    sessionId: string,
    saved: Array<{ type: "custom_message" } & SavedMessage> = [],
  ) {
    this.entries = [...saved];
    speech.extension(sessionId).factory({
      on: (event: string, handler: (event: unknown, ctx: unknown) => unknown) =>
        this.handlers.set(event, handler),
      registerTool: (tool: FakeRuntime["tool"]) => (this.tool = tool),
      getActiveTools: () => {
        if (this.stale) throw new Error("ctx is stale");
        return [...this.active];
      },
      setActiveTools: (names: string[]) => (this.active = names),
      sendMessage: (
        message: SavedMessage,
        options?: { triggerTurn?: boolean; deliverAs?: string },
      ) => {
        // Anything but a plain context message would start or steer a turn, or wait for a prompt.
        if (options?.triggerTurn !== false || options.deliverAs) {
          throw new Error("call mode must be context only");
        }
        if (this.busy) this.pending.push(message);
        else this.entries.push({ type: "custom_message", ...message });
      },
    } as never);
  }

  startSession(): void {
    this.fire("session_start");
  }

  private fire(event: string): void {
    const ctx = {
      sessionManager: { buildContextEntries: () => this.entries.slice(this.contextFrom) },
    };
    this.handlers.get(event)?.({}, ctx);
  }

  /** A compaction summarizes everything saved so far out of the model's context. */
  compact(): void {
    this.contextFrom = this.entries.length;
    this.fire("session_compact");
  }

  /** Tree navigation moves the leaf back to `length` saved entries; later ones leave the path. */
  navigateTo(length: number): void {
    this.entries = this.entries.slice(0, length);
    this.contextFrom = Math.min(this.contextFrom, length);
    this.fire("session_tree");
  }

  /** What before_agent_start returns for a new run. */
  startRun(): unknown {
    this.busy = true;
    return this.handlers.get("before_agent_start")?.({}, {});
  }

  /** The turn's tool results are in: Pi saves what was held during the turn. */
  endTurn(): void {
    for (const message of this.pending) this.entries.push({ type: "custom_message", ...message });
    this.pending = [];
  }

  endRun(): void {
    this.endTurn();
    this.busy = false;
  }

  /** Call-mode messages in order, as the model would read them. */
  get callMessages(): SavedMessage[] {
    return this.entries.filter((entry) => entry.customType === "oppi-live-voice-call");
  }

  /** The call state the model's context ends on. */
  get contextSaysCall(): boolean | undefined {
    return this.callMessages.at(-1)?.details?.active;
  }

  speak(text: string): Promise<unknown> {
    if (!this.tool) throw new Error("speak was never registered");
    return this.tool.execute("call-1", { text });
  }
}

function speechHarness() {
  /** What a caller hears on a voice that says replies as they are written (the local route). */
  const heard: string[] = [];
  /** Each reply's whole opening once written, as a voice that cannot stream (Grok) hears it. */
  const openings: string[] = [];
  const ended: RunOutcome[] = [];
  const speech = new LiveVoiceSpeech({
    speak: (_sessionId, text) => heard.push(text),
    speakSentence: (_sessionId, _replyId, text) => heard.push(text),
    openingWritten: (_sessionId, _replyId, opening, streamed) => {
      openings.push(opening);
      if (!streamed) heard.push(opening);
    },
    runEnded: (_sessionId, outcome) => ended.push(outcome),
  });
  return { speech, heard, openings, ended };
}

describe("LiveVoiceSpeech", () => {
  it("says a reply's spoken opening sentence by sentence while it is still being written", () => {
    const { speech, heard, openings, ended } = speechHarness();
    speech.setCallAttached("s1", true);
    speech.observe("s1", start);
    const reply = writeReply(speech, "s1");

    reply.write("Three sessions are running at 2.5");
    expect(heard).toEqual([]);
    reply.write(" GB. Two are");
    expect(heard).toEqual(["Three sessions are running at 2.5 GB."]);
    reply.write(" busy with `npm test`.\n\n| Session | State |\n|---|---|\n| a | busy |");
    expect(heard).toEqual(["Three sessions are running at 2.5 GB.", "Two are busy with npm test."]);
    // A voice that takes the opening whole has it before the written detail is done.
    const opening = "Three sessions are running at 2.5 GB. Two are busy with npm test.";
    expect(openings).toEqual([opening]);

    reply.write("\n| b | idle |");
    reply.end();
    speech.observe("s1", runEnd(assistant("")));
    expect(heard).toHaveLength(2);
    expect(openings).toEqual([opening]);
    expect(ended).toEqual([{ kind: "final", spoken: opening }]);
  });

  it("says the speakable start of a reply that opens with written markdown once it is written", () => {
    const { speech, heard, ended } = speechHarness();
    speech.setCallAttached("s1", true);

    replyRun(
      speech,
      "s1",
      "## Result\n\nThree sessions are running. Two are busy.\n\n```ts\ncode()\n```",
    );
    replyRun(speech, "s1", "**Summary**\nAll green.");
    replyRun(speech, "s1", "**Yes, it is fixed.**\n\nThe cause was a stale cache.");
    replyRun(speech, "s1", "Tests pass. **Here is the breakdown:**\n- unit\n- e2e");
    replyRun(speech, "s1", "Here is what changed:\n- the speech settings\n- the call screen");

    expect(heard).toEqual([
      "Result. Three sessions are running. Two are busy.",
      "Summary. All green.",
      "Yes, it is fixed.",
      "Tests pass.",
      "Here is what changed: the speech settings. the call screen.",
    ]);
    expect(ended.at(-1)).toEqual({ kind: "final", spoken: heard.at(-1) });
  });

  it("stops the spoken opening at its first line break or once it is long enough", () => {
    const { speech, heard } = speechHarness();
    speech.setCallAttached("s1", true);
    const sentence = "This sentence is about sixty characters long, give or take.";

    replyRun(speech, "s1", `${Array(10).fill(sentence).join(" ")}\nMore.`);
    expect(heard).toEqual(Array(6).fill(sentence));

    // A run of words with no sentence end is said up to its last whole word, mid-stream.
    heard.length = 0;
    speech.observe("s1", start);
    const rambling = writeReply(speech, "s1");
    const words = "and then the pipeline ".repeat(20);
    rambling.write(`${words}configurati`);
    expect(heard).toHaveLength(1);
    expect(words.startsWith(`${heard[0]} `)).toBe(true);
    expect(heard[0]!.length).toBeLessThanOrEqual(400);
  });

  it("does not repeat what the caller heard when the call attaches again or a failed reply is retried", () => {
    const { speech, heard, openings, ended } = speechHarness();
    speech.setCallAttached("s1", true);
    const failedThenRetried = (first: string, second: string) => {
      // Two failed attempts; classic Pi starts each retry with agent_start.
      for (let attempt = 0; attempt < 2; attempt++) {
        speech.observe("s1", start);
        const failed = writeReply(speech, "s1");
        failed.write(first);
        failed.end({ stopReason: "error", errorMessage: "overloaded" });
        speech.observe("s1", {
          ...runEnd({ stopReason: "error" }),
          willRetry: true,
        } as SessionBackendEvent);
      }
      speech.observe("s1", start);
      const retry = writeReply(speech, "s1");
      retry.write(second);
      retry.end();
      speech.observe("s1", runEnd(assistant(second)));
    };

    // The opening was complete and handed over before the failure: neither voice hears it twice.
    failedThenRetried("All good. Tests pass.\n\nDet", "All good. Tests pass.\n\nDetails.");
    expect(heard).toEqual(["All good.", "Tests pass."]);
    expect(openings).toEqual(["All good. Tests pass."]);
    expect(ended.at(-1)).toEqual({ kind: "final", spoken: "All good. Tests pass." });

    heard.length = 0;
    openings.length = 0;
    speech.observe("s1", start);
    const failed = writeReply(speech, "s1");
    failed.write("The deploy is done. ");
    speech.setCallAttached("s1", true);
    failed.write("Every check passed. It");
    failed.end({ stopReason: "error", errorMessage: "overloaded" });
    speech.observe("s1", {
      ...runEnd({ stopReason: "error" }),
      willRetry: true,
    } as SessionBackendEvent);
    const retry = writeReply(speech, "s1");
    retry.write("The deploy is done. Every check passed. It took four minutes.");
    retry.end();

    expect(heard).toEqual(["The deploy is done.", "Every check passed.", "It took four minutes."]);
    expect(openings).toEqual(["The deploy is done. Every check passed. It took four minutes."]);
  });

  it("still says the reply after a speak heads-up, and nothing for a reply that hands over to tools", async () => {
    const { speech, heard, ended } = speechHarness();
    const runtime = new FakeRuntime(speech, "s1");
    runtime.startSession();
    speech.setCallAttached("s1", true);

    speech.observe("s1", start);
    await runtime.speak("On it, checking the logs.");
    const handover = writeReply(speech, "s1");
    handover.end({
      stopReason: "toolUse",
      content: [{ type: "toolCall", id: "t1", name: "bash", arguments: {} }],
    });
    const reply = writeReply(speech, "s1");
    reply.write("The logs are clean.\n\nDetails follow.");
    reply.end();
    speech.observe("s1", runEnd(assistant("The logs are clean.\n\nDetails follow.")));

    expect(heard).toEqual(["On it, checking the logs.", "The logs are clean."]);
    expect(ended).toEqual([{ kind: "final", spoken: "The logs are clean." }]);
  });

  it("says a failed run failed instead of going silent", () => {
    const { speech, heard, ended } = speechHarness();
    speech.setCallAttached("s1", true);

    speech.observe(
      "s1",
      runEnd({ stopReason: "error", errorMessage: "You're out of extra usage." }),
    );
    speech.observe("s1", runEnd({ stopReason: "aborted" }));

    expect(heard).toEqual(["That failed: You're out of extra usage.", "Stopped."]);
    expect(ended.map((outcome) => outcome.kind)).toEqual(["blocked", "blocked"]);
  });

  it("does nothing for a session without a call, or after the call ends", () => {
    const { speech, heard, ended } = speechHarness();
    replyRun(speech, "s1", "Nobody is listening.");
    speech.setCallAttached("s1", true);
    speech.setCallAttached("s1", false);
    replyRun(speech, "s1", "Still nobody.");

    expect(heard).toEqual([]);
    expect(ended).toEqual([]);
  });

  it("turns speak on for the live runtime even when a disposed runtime's API is stale", () => {
    const { speech } = speechHarness();
    const disposed = new FakeRuntime(speech, "s1");
    disposed.startSession();
    // Force-disposed without session_shutdown: its Pi API now throws.
    disposed.stale = true;
    const live = new FakeRuntime(speech, "s1");
    live.startSession();

    expect(() => speech.setCallAttached("s1", true)).not.toThrow();
    expect(live.active).toContain("speak");

    speech.setCallAttached("s1", false);
    expect(live.active).not.toContain("speak");
  });

  it("keeps speak on for every run of a call even after the runtime dropped it", () => {
    const { speech } = speechHarness();
    const runtime = new FakeRuntime(speech, "s1");
    runtime.startSession();
    speech.setCallAttached("s1", true);
    // The runtime settled its own loadout after the call attached and dropped speak.
    runtime.active = ["read"];

    runtime.startRun();
    expect(runtime.active).toContain("speak");

    speech.setCallAttached("s1", false);
    runtime.active = ["read", "speak"];
    runtime.endRun();
    runtime.startRun();
    expect(runtime.active).not.toContain("speak");
  });

  describe("call mode in the session context", () => {
    it("says once that the call started, with the guidance the agent needs, and adds nothing per run", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      expect(runtime.callMessages).toEqual([]);

      speech.setCallAttached("s1", true);
      speech.setCallAttached("s1", true);
      expect(runtime.callMessages).toHaveLength(1);
      const [started] = runtime.callMessages;
      expect(started?.display).toBe(false);
      expect(started?.details).toEqual({ active: true });

      for (let run = 0; run < 3; run++) {
        expect(runtime.startRun()).toBeUndefined();
        runtime.endRun();
      }
      expect(runtime.callMessages).toHaveLength(1);
    });

    it("says once that the call ended, and a typed session after it hears nothing more", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      speech.setCallAttached("s1", true);
      speech.setCallAttached("s1", false);
      speech.setCallAttached("s1", false);

      expect(runtime.callMessages.map((message) => message.details?.active)).toEqual([true, false]);
      expect(runtime.callMessages[1]?.display).toBe(false);

      expect(runtime.startRun()).toBeUndefined();
      expect(runtime.callMessages).toHaveLength(2);
    });

    it("reaches the model call of a run already in progress when the call attaches mid-run", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      runtime.startRun();

      speech.setCallAttached("s1", true);
      // Held while the turn's tool calls are still settling, so the context stays well formed.
      expect(runtime.contextSaysCall).toBeUndefined();
      runtime.endTurn();
      // The steered message that follows, and the model call after it, see the call.
      expect(runtime.contextSaysCall).toBe(true);
      expect(runtime.active).toContain("speak");
    });

    it("reaches a run in progress when the call detaches mid-run", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      speech.setCallAttached("s1", true);
      runtime.startRun();

      speech.setCallAttached("s1", false);
      runtime.endTurn();

      expect(runtime.contextSaysCall).toBe(false);
      expect(runtime.active).not.toContain("speak");
    });

    it("leaves the newest state last after a call attaches, detaches, and attaches again", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      runtime.startRun();

      speech.setCallAttached("s1", true);
      speech.setCallAttached("s1", false);
      speech.setCallAttached("s1", true);
      runtime.endRun();
      expect(runtime.contextSaysCall).toBe(true);

      speech.setCallAttached("s1", false);
      speech.setCallAttached("s1", true);
      speech.setCallAttached("s1", false);
      expect(runtime.contextSaysCall).toBe(false);
    });

    it("ends a call the saved session still claims after a restart", () => {
      const first = speechHarness();
      const before = new FakeRuntime(first.speech, "s1");
      before.startSession();
      first.speech.setCallAttached("s1", true);
      expect(before.contextSaysCall).toBe(true);

      // The server restarts: calls are gone, the saved session is all that is left.
      const second = speechHarness();
      const after = new FakeRuntime(second.speech, "s1", before.entries);
      after.startSession();

      expect(after.contextSaysCall).toBe(false);
      expect(after.callMessages).toHaveLength(2);
      expect(after.active).not.toContain("speak");
    });

    it("does not repeat the end of a call when a reopened session already ends on it", () => {
      const { speech } = speechHarness();
      const first = new FakeRuntime(speech, "s1");
      first.startSession();
      speech.setCallAttached("s1", true);
      speech.setCallAttached("s1", false);

      const reopened = new FakeRuntime(speech, "s1", first.entries);
      reopened.startSession();
      expect(reopened.callMessages.map((message) => message.details?.active)).toEqual([
        true,
        false,
      ]);
    });

    it("says the call again after a compaction summarized its start away, once per compaction", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      speech.setCallAttached("s1", true);

      runtime.compact();
      expect(runtime.callMessages.map((message) => message.details?.active)).toEqual([true, true]);
      // The new message is in the context now: another event changes nothing.
      runtime.navigateTo(runtime.entries.length);
      expect(runtime.callMessages).toHaveLength(2);
      runtime.compact();
      expect(runtime.callMessages).toHaveLength(3);
    });

    it("adds nothing after a compaction when no call is attached", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      speech.setCallAttached("s1", true);
      speech.setCallAttached("s1", false);

      runtime.compact();
      expect(runtime.callMessages).toHaveLength(2);
    });

    it("ends a call the context claims when the session navigates back into it", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      speech.setCallAttached("s1", true);
      const insideCall = runtime.entries.length;
      runtime.entries.push({
        type: "custom_message",
        customType: "other",
        content: "work",
        display: true,
      });
      speech.setCallAttached("s1", false);

      // The leaf moves back to a point where the call was live, with no call attached now.
      runtime.navigateTo(insideCall);
      expect(runtime.contextSaysCall).toBe(false);
    });

    it("says the call again when the session navigates to before its start during a call", () => {
      const { speech } = speechHarness();
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();
      runtime.entries.push({
        type: "custom_message",
        customType: "other",
        content: "earlier",
        display: true,
      });
      const beforeCall = runtime.entries.length;
      speech.setCallAttached("s1", true);

      runtime.navigateTo(beforeCall);
      expect(runtime.contextSaysCall).toBe(true);
      expect(runtime.callMessages).toHaveLength(1);
    });

    it("tells a session that was resumed while a call is attached", () => {
      const { speech } = speechHarness();
      speech.setCallAttached("s1", true);
      const runtime = new FakeRuntime(speech, "s1");
      runtime.startSession();

      expect(runtime.contextSaysCall).toBe(true);
      expect(runtime.active).toContain("speak");
    });
  });
});

class ScriptedStt implements SttProvider {
  readonly name = "scripted";
  readonly model = "test";
  private tokenCb?: (update: SttTranscriptUpdate) => void;
  async start() {
    return { contextApplied: false };
  }
  feedAudio(): void {}
  onToken(cb: (update: SttTranscriptUpdate) => void): void {
    this.tokenCb = cb;
  }
  async stop() {
    return { text: "" };
  }
  emit(text: string): void {
    this.tokenCb?.({ text });
  }
}

const echoTts: LiveVoiceTtsPort = {
  async *speak(text: string) {
    yield Buffer.from(text);
  },
};

const turnEnd = () => new Promise<void>((resolve) => setTimeout(resolve, 40));

describe("LiveVoiceSessionLink", () => {
  it("joins a call to its session: words in as prompts, replies out as call audio, status on the phone", async () => {
    const prompts: Array<{ sessionId: string; request: string }> = [];
    let failNext = false;
    const link = new LiveVoiceSessionLink(async (sessionId, delegation: VoiceDelegation) => {
      if (failNext) throw new Error("Session is stopped");
      prompts.push({ sessionId, request: delegation.request });
    });
    let callSequence = 0;
    const calls = new VoiceCallController({
      nextCallId: () => `call-${++callSequence}`,
      dispatchDelegation: (sessionId, delegation) => link.dispatch(sessionId, delegation),
    });
    const stt = new ScriptedStt();
    let delegationSequence = 0;
    const media = new VoiceCallMediaCoordinator({
      createAdapter: () => new YuwpVoiceMediaAdapter(stt, { tts: echoTts, turnEndPauseMs: 5 }),
      calls,
      nextDelegationId: () => `delegation-${++delegationSequence}`,
      onSessionMediaChanged: (sessionId, attached) => link.sessionMediaChanged(sessionId, attached),
    });
    link.connect(calls, media);
    const runtime = new FakeRuntime(link.speech, "sess-1");
    runtime.startSession();
    const phone = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "phone",
    });
    const statuses = (): Array<[VoiceCallDelegationUpdateKind, string]> =>
      phone.messages.flatMap((message) =>
        message.type === "voice_delegation_update" ? [[message.kind, message.text] as const] : [],
      ) as Array<[VoiceCallDelegationUpdateKind, string]>;

    expect(runtime.active).not.toContain("speak");
    const started = calls.startCall(
      { controlSessionId: "sess-1", clientCallId: "client-1" },
      phone.connection,
    );
    await media.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: phone.connection,
    });
    expect(runtime.active).toContain("speak");

    stt.emit("how many sessions are running");
    await turnEnd();
    expect(prompts).toEqual([{ sessionId: "sess-1", request: "how many sessions are running" }]);

    const heard = () => phone.audio.map((chunk) => chunk.toString());
    link.speech.observe("sess-1", start);
    await runtime.speak("On it.");
    const answer = writeReply(link.speech, "sess-1");
    answer.write("Three sessions are running. Two");
    await turnEnd();
    // The first sentence plays while the rest is still being written.
    expect(heard()).toEqual(["On it.", "Three sessions are running."]);
    answer.write(" are busy.\n\n- a\n- b");
    answer.end();
    link.speech.observe("sess-1", runEnd(assistant("")));
    await turnEnd();
    expect(heard()).toEqual(["On it.", "Three sessions are running.", "Two are busy."]);
    const opening = "Three sessions are running. Two are busy.";
    expect(statuses().slice(-3)).toEqual([
      ["progress", "On it."],
      ["progress", opening],
      ["final", opening],
    ]);

    // The caller talks over a reply: the rest of it is dropped, the reply to them is said.
    link.speech.observe("sess-1", start);
    const interrupted = writeReply(link.speech, "sess-1");
    interrupted.write("The build is green. ");
    await turnEnd();
    stt.emit("how many sessions are running wait");
    interrupted.write("It took four minutes.");
    interrupted.end();
    await turnEnd();
    expect(prompts.at(-1)).toEqual({ sessionId: "sess-1", request: "wait" });
    const steered = writeReply(link.speech, "sess-1");
    steered.write("Okay, waiting.");
    steered.end();
    link.speech.observe("sess-1", runEnd(assistant("Okay, waiting.")));
    await turnEnd();
    expect(heard().slice(3)).toEqual(["The build is green.", "Okay, waiting."]);

    failNext = true;
    stt.emit("how many sessions are running wait and stop the build");
    await turnEnd();
    expect(statuses().at(-1)).toEqual(["blocked", "Session is stopped"]);
    expect(heard().at(-1)).toBe("That did not reach the session.");

    await media.detach("connection-1");
    expect(runtime.active).not.toContain("speak");
  });
});

describe("LiveVoiceSessionLink with a voice that cannot stream", () => {
  it("hands each reply's opening over whole, once written, beside the heads-up", async () => {
    const link = new LiveVoiceSessionLink(async () => {});
    const calls = new VoiceCallController({
      nextCallId: () => "call-1",
      dispatchDelegation: (sessionId, delegation) => link.dispatch(sessionId, delegation),
    });
    // Grok Voice's shape: says whatever it is handed, takes no reply pieces.
    const said: string[] = [];
    const media = new VoiceCallMediaCoordinator({
      createAdapter: () => ({
        start: () => {},
        speak: (text: string) => void said.push(text),
        stop: () => {},
      }),
      calls,
      onSessionMediaChanged: (sessionId, attached) => link.sessionMediaChanged(sessionId, attached),
    });
    link.connect(calls, media);
    const runtime = new FakeRuntime(link.speech, "sess-1");
    runtime.startSession();
    const phone = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "phone",
    });
    const started = calls.startCall(
      { controlSessionId: "sess-1", clientCallId: "client-1" },
      phone.connection,
    );
    await media.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: phone.connection,
    });

    link.speech.observe("sess-1", start);
    await runtime.speak("Checking the logs.");
    const reply = writeReply(link.speech, "sess-1");
    reply.write("The logs are clean. Nothing failed.");
    expect(said).toEqual(["Checking the logs."]);
    reply.write("\n\n- `server.log`: clean");
    expect(said).toEqual(["Checking the logs.", "The logs are clean. Nothing failed."]);
    reply.end();
    link.speech.observe("sess-1", runEnd(assistant("")));
    expect(said).toHaveLength(2);
  });
});
