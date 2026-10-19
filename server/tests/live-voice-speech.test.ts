import { describe, expect, it } from "vitest";

import {
  DeterministicVoiceCallFrontend,
  VoiceCallController,
} from "../src/continuous-voice-call.js";
import {
  VoiceCallMediaCoordinator,
  YuwpVoiceMediaAdapter,
  type LiveVoiceTtsPort,
} from "../src/continuous-voice-media.js";
import type { VoiceDelegation } from "../src/continuous-voice.js";
import {
  LiveVoiceSessionLink,
  LiveVoiceSpeech,
  type RunOutcome,
} from "../src/live-voice-speech.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import type { SttProvider, SttTranscriptUpdate } from "../src/stt-provider.js";
import type { VoiceCallDelegationUpdateKind } from "../src/types.js";

const start = { type: "agent_start" } as SessionBackendEvent;

function runEnd(message: Record<string, unknown>): SessionBackendEvent {
  return {
    type: "agent_end",
    willRetry: false,
    messages: [{ role: "assistant", content: [], stopReason: "stop", ...message }],
  } as unknown as SessionBackendEvent;
}

const reply = (text: string) => runEnd({ content: [{ type: "text", text }] });

/** A Pi runtime as the extension sees it: the active tool list and the registered tool. */
class FakeRuntime {
  active = ["read"];
  stale = false;
  private readonly handlers = new Map<string, () => void>();
  private tool: { execute: (id: string, params: { text: string }) => Promise<unknown> } | undefined;

  constructor(speech: LiveVoiceSpeech, sessionId: string) {
    speech.extension(sessionId).factory({
      on: (event: string, handler: () => void) => this.handlers.set(event, handler),
      registerTool: (tool: FakeRuntime["tool"]) => (this.tool = tool),
      getActiveTools: () => {
        if (this.stale) throw new Error("ctx is stale");
        return [...this.active];
      },
      setActiveTools: (names: string[]) => (this.active = names),
    } as never);
  }

  startSession(): void {
    this.handlers.get("session_start")?.();
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
