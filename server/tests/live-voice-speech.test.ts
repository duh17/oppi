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

function runEnd(message: Record<string, unknown>): SessionBackendEvent {
  return {
    type: "agent_end",
    willRetry: false,
    messages: [{ role: "assistant", content: [], stopReason: "stop", ...message }],
  } as unknown as SessionBackendEvent;
}

const reply = (text: string) => runEnd({ content: [{ type: "text", text }] });

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
  const said: string[] = [];
  const ended: RunOutcome[] = [];
  const speech = new LiveVoiceSpeech({
    speak: (_sessionId, text) => said.push(text),
    runEnded: (_sessionId, outcome) => ended.push(outcome),
  });
  return { speech, said, ended };
}

describe("LiveVoiceSpeech", () => {
  it("reads the opening of the final reply when the agent never spoke", () => {
    const { speech, said, ended } = speechHarness();
    speech.setCallAttached("s1", true);

    speech.observe("s1", start);
    speech.observe(
      "s1",
      reply("## Result\n\nThree sessions are running. Two are busy.\n\n```ts\ncode()\n```"),
    );

    expect(said).toEqual(["Result. Three sessions are running. Two are busy."]);
    expect(ended).toEqual([
      { kind: "final", spoken: "Result. Three sessions are running. Two are busy." },
    ]);
  });

  it("stays quiet at the end of a run the agent already spoke in", async () => {
    const { speech, said, ended } = speechHarness();
    const runtime = new FakeRuntime(speech, "s1");
    runtime.startSession();
    speech.setCallAttached("s1", true);

    speech.observe("s1", start);
    await runtime.speak("Three are running.");
    speech.observe("s1", reply("Three sessions are running, two busy."));

    expect(said).toEqual(["Three are running."]);
    expect(ended).toEqual([{ kind: "final", spoken: "Three are running." }]);
  });

  it("says a failed run failed instead of going silent", () => {
    const { speech, said, ended } = speechHarness();
    speech.setCallAttached("s1", true);

    speech.observe(
      "s1",
      runEnd({ stopReason: "error", errorMessage: "You're out of extra usage." }),
    );
    speech.observe("s1", runEnd({ stopReason: "aborted" }));

    expect(said).toEqual(["That failed: You're out of extra usage.", "Stopped."]);
    expect(ended.map((outcome) => outcome.kind)).toEqual(["blocked", "blocked"]);
  });

  it("does nothing for a session without a call, or after the call ends", () => {
    const { speech, said, ended } = speechHarness();
    speech.observe("s1", reply("Nobody is listening."));
    speech.setCallAttached("s1", true);
    speech.setCallAttached("s1", false);
    speech.observe("s1", reply("Still nobody."));

    expect(said).toEqual([]);
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
  it("joins a call to its session: words in as prompts, speak out as call audio, status on the phone", async () => {
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

    link.speech.observe("sess-1", start);
    await runtime.speak("Three are running.");
    await turnEnd();
    link.speech.observe("sess-1", reply("Three sessions are running."));
    expect(Buffer.concat(phone.audio).toString()).toBe("Three are running.");
    expect(statuses().slice(-2)).toEqual([
      ["progress", "Three are running."],
      ["final", "Three are running."],
    ]);

    failNext = true;
    stt.emit("how many sessions are running and stop the build");
    await turnEnd();
    expect(statuses().at(-1)).toEqual(["blocked", "Session is stopped"]);
    expect(Buffer.concat(phone.audio).toString()).toBe(
      "Three are running.That did not reach the session.",
    );

    await media.detach("connection-1");
    expect(runtime.active).not.toContain("speak");
  });
});
