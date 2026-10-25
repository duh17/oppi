import { describe, expect, it, vi } from "vitest";

import {
  LIVE_VOICE_PLAYBACK_SAMPLE_RATE,
  ReadAloudLiveVoiceTts,
  selectLiveVoiceMediaAdapter,
  type LiveVoiceTtsPort,
  VoiceCallMediaCoordinator,
  type VoiceMediaAdapter,
  type VoiceMediaEvent,
  YuwpVoiceMediaAdapter,
} from "../src/continuous-voice-media.js";
import { VoiceCallController } from "../src/continuous-voice-call.js";
import {
  StreamingSttProvider,
  type SttProvider,
  type SttSpeechState,
  type SttStartResult,
  type SttTranscriptUpdate,
} from "../src/stt-provider.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";
import type { ServerMessage, Session } from "../src/types.js";
import { DeterministicVoiceCallFrontend } from "./helpers/deterministic-voice-call-frontend.js";

/** Test turns end after a short pause; the default is sized for real speech. */
const TEST_TURN_END_PAUSE_MS = 5;

function localAdapter(
  stt: SttProvider,
  options: ConstructorParameters<typeof YuwpVoiceMediaAdapter>[1] = {},
): YuwpVoiceMediaAdapter {
  return new YuwpVoiceMediaAdapter(stt, { turnEndPauseMs: TEST_TURN_END_PAUSE_MS, ...options });
}

/** Let a committed turn finish handing over, so the next one is judged on its own. */
const settled = () => new Promise<void>((resolve) => setImmediate(resolve));

/** Let the user's pause end the turn. */
const turnEnd = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

class ScriptedSttProvider implements SttProvider {
  readonly name = "scripted-yuwp";
  readonly model = "test-asr";
  started = false;
  stopped = false;
  fed: Buffer[] = [];
  startError?: Error;
  private tokenCb?: (update: SttTranscriptUpdate) => void;
  private speechCb?: (state: SttSpeechState) => void;

  async start(): Promise<SttStartResult> {
    if (this.startError) throw this.startError;
    this.started = true;
    return { contextApplied: false };
  }

  onSpeechState(cb: (state: SttSpeechState) => void): void {
    this.speechCb = cb;
  }

  speech(state: SttSpeechState): void {
    this.speechCb?.(state);
  }

  feedAudio(pcm: Buffer): void {
    this.fed.push(pcm);
  }

  onToken(cb: (update: SttTranscriptUpdate) => void): void {
    this.tokenCb = cb;
  }

  stopResult: { text: string; committedText?: string; activeText?: string } = { text: "" };

  async stop(): Promise<{ text: string; committedText?: string; activeText?: string }> {
    this.stopped = true;
    return this.stopResult;
  }

  emit(update: SttTranscriptUpdate): void {
    this.tokenCb?.(update);
  }
}

function makeVoiceSession(id = "voice-1"): Session {
  return {
    id,
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeCalls(): VoiceCallController {
  let callSequence = 0;
  return new VoiceCallController({
    nextCallId: () => `call-${++callSequence}`,
    now: () => 1_000,
  });
}

describe("continuous voice media", () => {
  it("hands Pi one request per spoken turn while streaming ASR locks in words", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    let sequence = 0;
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
      nextUtteranceId: () => `utterance-${++sequence}`,
      nextDelegationId: () => `delegation-${sequence}`,
    });

    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    coordinator.feedAudio("connection-1", Buffer.from("pcm-bytes"));
    // R2T2 shape: the call's transcript is cumulative and every update is committed.
    const lockIn = (text: string) => stt.emit({ text, committedText: text, activeText: "" });

    lockIn("Can");
    lockIn("Can you ask pi how");
    lockIn("Can you ask pi how many sessions are running?");
    expect(calls.snapshot(started.state.callId).delegations).toEqual([]);
    await turnEnd();

    // The next turn revises the earlier punctuation; only the new words are handed off.
    lockIn("Can you ask pi how many sessions are running, and");
    lockIn("Can you ask pi how many sessions are running, and then check the tests?");
    await turnEnd();

    expect(stt.fed).toHaveLength(1);
    expect(calls.snapshot(started.state.callId).delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-1",
        request: "Can you ask pi how many sessions are running?",
        state: "delegated",
      }),
      expect.objectContaining({
        delegationId: "delegation-2",
        request: "and then check the tests?",
        state: "delegated",
      }),
    ]);
    expect(frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        partialTranscript: "and then check the tests?",
      }),
    );
    await coordinator.detach("connection-1");
    expect(calls.snapshot(started.state.callId).delegations).toHaveLength(2);
  });

  it("ends a turn on the audio when the backend reports speech, not on a stalled transcript", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt, { turnEndPauseMs: 100 });
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    // Recognition stalls mid-sentence while the user keeps talking (a speaking report with
    // every feed, ~200 ms apart in production): no cut-off, however long the text stalls.
    stt.emit({ text: "帮我看一下现在有几个会话" });
    for (let i = 0; i < 8; i++) {
      stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    expect(committed).toEqual([]);

    // A mid-sentence pause long enough for the backend's end of speech: the turn does not
    // read as finished, so it waits for the user to go on.
    stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });
    await Promise.resolve();
    expect(committed).toEqual([]);

    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    await turnEnd();
    expect(committed).toEqual([]);
    stt.emit({ text: "帮我看一下现在有几个会话在跑了吗？" });
    stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });
    await Promise.resolve();
    expect(committed).toEqual(["帮我看一下现在有几个会话在跑了吗？"]);

    // An end of speech with nothing new to hand over is a no-op.
    stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });
    await Promise.resolve();
    expect(committed).toHaveLength(1);
  });

  it("ends the turn when speech reports stop arriving, as on mute or a stalled upload", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt);
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    // The last report said speaking, then the feeds stopped (the user muted mid-word).
    stt.emit({ text: "run the server" });
    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    await turnEnd();

    expect(committed).toEqual(["run the server"]);
  });

  it("hands over an unpunctuated turn once the silence is long enough", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt, { turnEndPauseMs: 60_000 });
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    stt.emit({ text: "then run the server tests" });
    stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });
    stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 1_000 });
    await Promise.resolve();
    expect(committed).toEqual([]);

    stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 1_200 });
    await Promise.resolve();
    expect(committed).toEqual(["then run the server tests"]);
  });

  it("hands over a finished sentence after a short silence, before the backend calls it", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt, { turnEndPauseMs: 60_000 });
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    stt.emit({ text: "Run the server tests." });
    stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 200 });
    await Promise.resolve();
    expect(committed).toEqual([]);

    stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 450 });
    await Promise.resolve();
    expect(committed).toEqual(["Run the server tests."]);
  });

  it("ends a turn whose silent reports never measure silence, as when the detector heard no speech", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt, { turnEndPauseMs: 100 });
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    // Recognized text the detector never counted as speech: silent reports keep arriving
    // with no trailing silence, and must not hold the turn open.
    stt.emit({ text: "run the tests" });
    for (let i = 0; i < 6; i++) {
      stt.speech({ speechActive: false, speechFinal: false });
      await new Promise((resolve) => setTimeout(resolve, 40));
    }

    expect(committed).toEqual(["run the tests"]);
  });

  it("still ends a silent turn when the backend never marks the end of speech", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt);
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    stt.emit({ text: "list open sessions" });
    stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 200 });
    await turnEnd();

    expect(committed).toEqual(["list open sessions"]);
  });

  it("hands Pi each Chinese turn, which has no spaces between words", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt);
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    stt.emit({ text: "帮我看一下有几个会话在跑" });
    await turnEnd();
    // The next turn revises the punctuation of the first and adds no spaces.
    stt.emit({ text: "帮我看一下有几个会话在跑。然后跑一下测试" });
    await turnEnd();

    expect(committed).toEqual(["帮我看一下有几个会话在跑", "然后跑一下测试"]);
  });

  it("hands Pi the next turn after the ASR session restarts its transcript", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt);
    const committed: string[] = [];
    await adapter.start((event) => {
      if (event.type === "user_utterance_committed") committed.push(event.text);
    });

    stt.emit({ text: "list every open session in the oppi workspace" });
    await turnEnd();
    // A long mute outlasted Yuwp's idle timeout; the recreated session hears from scratch.
    stt.emit({ text: "stop the build", transcriptRestarted: true });
    await turnEnd();

    expect(committed).toEqual(["list every open session in the oppi workspace", "stop the build"]);
  });

  it("updates a partial transcript without creating a delegation", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });

    stt.emit({ text: "lis", activeText: "lis" });

    const snapshot = calls.snapshot(started.state.callId);
    expect(snapshot.partialTranscript).toBe("lis");
    expect(snapshot.delegations).toEqual([]);
    expect(frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        partialTranscript: "lis",
      }),
    );
  });

  it("commits a stable Yuwp partial after idle without ending the call", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt, { turnEndPauseMs: 15 }),
      calls,
      nextUtteranceId: () => "utterance-idle-1",
      nextDelegationId: () => "delegation-idle-1",
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });

    stt.emit({
      text: "list open sessions",
      committedText: "",
      activeText: "list open sessions",
    });
    expect(calls.snapshot(started.state.callId).delegations).toEqual([]);

    await new Promise((resolve) => setTimeout(resolve, 40));

    expect(calls.snapshot(started.state.callId).lifecycle).toBe("active");
    expect(calls.snapshot(started.state.callId).frontend).toBe("attached");
    expect(calls.snapshot(started.state.callId).delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-idle-1",
        request: "list open sessions",
        state: "delegated",
      }),
    ]);
    await coordinator.detach("connection-1");
  });

  it("commits leftover Yuwp active text when the STT session stops", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    stt.stopResult = {
      text: "list open sessions",
      committedText: "list open sessions",
      activeText: "",
    };
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
      nextUtteranceId: () => "utterance-stop-1",
      nextDelegationId: () => "delegation-stop-1",
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });

    stt.emit({
      text: "list open sessions",
      committedText: "",
      activeText: "list open sessions",
    });
    expect(calls.snapshot(started.state.callId).delegations).toEqual([]);

    await coordinator.detach("connection-1");

    expect(calls.snapshot(started.state.callId).delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-stop-1",
        utteranceId: "utterance-stop-1",
        request: "list open sessions",
        state: "delegated",
      }),
    ]);
  });

  it("emits at most one user_utterance_committed per distinct segment when idle pause and stop overlap", async () => {
    vi.useFakeTimers();
    try {
      const stt = new ScriptedSttProvider();
      stt.stopResult = {
        text: "list open sessions",
        committedText: "list open sessions",
        activeText: "",
      };
      const adapter = localAdapter(stt, { turnEndPauseMs: 15 });
      const committed: string[] = [];
      let releaseFirst = () => {};
      const holdFirst = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      let sawFirst = () => {};
      const firstStarted = new Promise<void>((resolve) => {
        sawFirst = resolve;
      });
      await adapter.start(async (event) => {
        if (event.type !== "user_utterance_committed") return;
        committed.push(event.text);
        if (committed.length === 1) {
          sawFirst();
          await holdFirst;
        }
      });

      stt.emit({
        text: "list open sessions",
        committedText: "",
        activeText: "list open sessions",
      });

      const idle = vi.advanceTimersByTimeAsync(15);
      await firstStarted;
      stt.emit({
        text: "list open sessions",
        committedText: "list open sessions",
        activeText: "",
      });
      const stopping = adapter.stop();
      releaseFirst();
      await Promise.all([idle, stopping]);

      expect(committed).toEqual(["list open sessions"]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("sends what was said before End to the call's session", async () => {
    const dispatched: Array<{ sessionId: string; request: string }> = [];
    const calls = new VoiceCallController({
      now: () => 1_000,
      nextCallId: () => "call-1",
      dispatchDelegation: (sessionId, delegation) =>
        dispatched.push({ sessionId, request: delegation.request }),
    });
    const stt = new ScriptedSttProvider();
    stt.stopResult = {
      text: "list open sessions",
      committedText: "list open sessions",
      activeText: "",
    };
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
      nextUtteranceId: () => "utterance-pi-1",
      nextDelegationId: () => "delegation-pi-1",
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    stt.emit({
      text: "list open sessions",
      committedText: "",
      activeText: "list open sessions",
    });
    await coordinator.detach("connection-1");

    expect(dispatched).toEqual([{ sessionId: "voice-1", request: "list open sessions" }]);
  });

  it("does not use the dictation stream or DictationManager as the call engine", async () => {
    const createDictationManager = vi.fn();
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
      nextUtteranceId: () => "utterance-1",
      nextDelegationId: () => "delegation-1",
    });

    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    coordinator.feedAudio("connection-1", Buffer.from("pcm"));
    stt.emit({ text: "hello", committedText: "hello" });
    await turnEnd();

    expect(createDictationManager).not.toHaveBeenCalled();
    expect(stt.name).toBe("scripted-yuwp");
    expect(calls.snapshot(started.state.callId).delegations).toHaveLength(1);
  });

  it("fails closed when ASR cannot start and does not leave a live call", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    stt.startError = new Error("STT backend unreachable");
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
    });
    const sent: ServerMessage[] = [];
    const handler = new WsMessageHandler({
      sessions: {
        supportsLiveVoice: () => true,
        sendPrompt: vi.fn(),
        sendSteer: vi.fn(),
        sendFollowUp: vi.fn(),
        abort: vi.fn(),
        stopSession: vi.fn(),
        setModel: vi.fn(),
        cycleModel: vi.fn(),
        setThinkingLevel: vi.fn(),
        cycleThinkingLevel: vi.fn(),
        reload: vi.fn(),
        newSession: vi.fn(),
        setSessionName: vi.fn(),
        compact: vi.fn(),
        setAutoCompaction: vi.fn(),
        fork: vi.fn(),
        setSteeringMode: vi.fn(),
        setFollowUpMode: vi.fn(),
        setAutoRetry: vi.fn(),
        abortRetry: vi.fn(),
        abortBash: vi.fn(),
        getMessages: vi.fn(),
        getForkMessages: vi.fn(),
        getSessionTree: vi.fn(),
        navigateTree: vi.fn(),
        getSessionStats: vi.fn(),
        getCommands: vi.fn(),
        shareSession: vi.fn(),
        respondToExtensionUI: vi.fn(),
      } as unknown as WsMessageHandlerDeps["sessions"],
      ensureSessionContextWindow: (session) => session,
      voiceCalls: calls,
      voiceMedia: coordinator,
    });

    const attachLogs: string[] = [];
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
      attachLogs.push(String(chunk));
      return true;
    }) as typeof process.stderr.write);

    try {
      await handler.handleClientMessage(
        makeVoiceSession(),
        { type: "voice_call_start", clientCallId: "client-1", requestId: "start-1" },
        (message) => sent.push(message),
        { connId: "connection-1", authenticatedDeviceId: "paired-device-a" },
      );
    } finally {
      stderr.mockRestore();
    }

    expect(sent).toEqual([
      expect.objectContaining({
        type: "command_result",
        command: "voice_call_start",
        requestId: "start-1",
        success: false,
        error: expect.stringMatching(/STT backend unreachable|ASR|unavailable/i),
      }),
    ]);
    expect(sent.some((message) => message.type === "voice_call_state")).toBe(false);
    expect(calls.snapshot("call-1").lifecycle).toBe("ended");
    expect(calls.snapshot("call-1").frontend).toBe("detached");
    const payload = attachLogs.join("\n");
    expect(payload).toContain('"event":"ws.voice_media.attach_failed"');
    expect(payload).toContain('"callId":"call-1"');
    expect(payload).toContain('"sessionId":"voice-1"');
    expect(payload).toMatch(/STT backend unreachable/);
  });

  it("starts no media when the caller's socket closes while the old media is still stopping", async () => {
    const calls = makeCalls();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    let releaseStop: () => void = () => {};
    const adapters: VoiceMediaAdapter[] = [];
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => {
        const first = adapters.length === 0;
        const adapter: VoiceMediaAdapter = {
          start: vi.fn(),
          speak: vi.fn(),
          feedAudio: vi.fn(),
          // Yuwp's stop can take seconds; only the first adapter's is slow here.
          stop: first
            ? () => new Promise<void>((resolve) => (releaseStop = resolve))
            : vi.fn(),
        };
        adapters.push(adapter);
        return adapter;
      },
      calls,
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    const input = {
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    };
    await coordinator.attach(input);

    const reattach = coordinator.attach(input);
    // Mirrors server.ts handleConnectionClosed while the old adapter is stopping.
    calls.disconnectConnection("connection-1");
    await coordinator.detach("connection-1");
    releaseStop();
    await reattach;

    expect(adapters).toHaveLength(1);
    expect(coordinator.feedAudio("connection-1", Buffer.from("pcm"))).toBe(false);
    expect(coordinator.callIdsForSession("voice-1")).toEqual([]);
  });

  it("one-shot Live Voice STT skips constructor warmup so start does not race createSession", async () => {
    const endpoint = "http://127.0.0.1:7936";
    const streamUrl = `${endpoint}/v1/audio/transcriptions/stream`;
    let creates = 0;
    let inFlight = 0;
    let maxInFlight = 0;
    const fetchFn = (async (input: string | URL | Request, init?: RequestInit) => {
      const url =
        typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const method = init?.method ?? "GET";
      if (method === "POST" && url === streamUrl) {
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        creates += 1;
        await new Promise((resolve) => setTimeout(resolve, 20));
        inFlight -= 1;
        return new Response(JSON.stringify({ session_id: `s${creates}` }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ text: "" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }) as typeof fetch;

    const stt = new StreamingSttProvider({ endpoint, model: "test-asr", warmUp: false }, fetchFn);
    const adapter = localAdapter(stt);
    await adapter.start(async () => {});
    expect(creates).toBe(1);
    expect(maxInFlight).toBe(1);
    await adapter.stop();
    expect(creates).toBe(1);
  });

  it("selects the configured media backend and fails closed when it cannot run", () => {
    const stt = new ScriptedSttProvider();
    const yuwp = { sttEndpoint: "http://127.0.0.1:7936", createStt: () => stt };
    expect(selectLiveVoiceMediaAdapter({ liveVoiceBackend: undefined, ...yuwp })).toBeInstanceOf(
      YuwpVoiceMediaAdapter,
    );
    expect(() => selectLiveVoiceMediaAdapter({ liveVoiceBackend: "yuwp" })).toThrow(
      "Live Voice ASR is unavailable",
    );
    const grok = { start: vi.fn(), speak: vi.fn(), stop: vi.fn() } as VoiceMediaAdapter;
    expect(
      selectLiveVoiceMediaAdapter({
        liveVoiceBackend: "grok-voice",
        ...yuwp,
        createGrokVoice: () => grok,
      }),
    ).toBe(grok);
    expect(() => selectLiveVoiceMediaAdapter({ liveVoiceBackend: "grok-voice", ...yuwp })).toThrow(
      "Grok Voice is unavailable",
    );
    expect(() => selectLiveVoiceMediaAdapter({ liveVoiceBackend: "gpt-live", ...yuwp })).toThrow(
      "Unknown Live Voice media backend",
    );
  });

  it("sends a mid-call turn to the call's session without ending the call", async () => {
    const dispatched: Array<{ sessionId: string; request: string }> = [];
    const calls = new VoiceCallController({
      now: () => 1_000,
      nextCallId: () => "call-1",
      dispatchDelegation: (sessionId, delegation) =>
        dispatched.push({ sessionId, request: delegation.request }),
    });
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls,
      nextUtteranceId: () => "utterance-live-1",
      nextDelegationId: () => "delegation-live-1",
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });

    stt.emit({
      text: "summarize the inbox",
      committedText: "summarize the inbox",
      activeText: "",
    });
    await turnEnd();

    expect(calls.snapshot(started.state.callId).lifecycle).toBe("active");
    expect(calls.snapshot(started.state.callId).frontend).toBe("attached");
    expect(dispatched).toEqual([{ sessionId: "voice-1", request: "summarize the inbox" }]);
    await coordinator.detach("connection-1");
  });

  it("Yuwp adapter reports what the caller says and nothing provider-specific", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt);
    const events: VoiceMediaEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });
    stt.emit({ text: "hi", activeText: "hi" });
    stt.emit({ text: "hi there", committedText: "hi there", activeText: "" });
    await turnEnd();

    expect(events.some((event) => event.type === "user_transcript_partial")).toBe(true);
    expect(events.at(-1)).toMatchObject({ type: "user_utterance_committed", text: "hi there" });
    expect(JSON.stringify(events)).not.toMatch(/gpt.?live|grok|openai.?realtime|webrtc/i);
  });

  it("speaks with the read-aloud voice at the phone's 24 kHz whatever rate the engine uses", async () => {
    // Drama 3 returns 44.1 kHz float WAV; played as 24 kHz it would sound slow and low.
    const engineRate = 44_100;
    const requests: Record<string, unknown>[] = [];
    const fetchFn = (async (_url: string, init: RequestInit) => {
      requests.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return new Response(floatMonoWav(new Array(engineRate / 10).fill(0.25), engineRate));
    }) as unknown as typeof fetch;
    const tts = new ReadAloudLiveVoiceTts(
      { provider: "http", endpoint: "http://127.0.0.1:7938", voice: "elena" },
      { fetchFn },
    );

    const chunks: Buffer[] = [];
    for await (const chunk of tts.speak(
      "Three sessions are running.",
      new AbortController().signal,
    )) {
      chunks.push(chunk);
    }

    const pcm = Buffer.concat(chunks);
    expect(requests).toEqual([expect.objectContaining({ voice: "elena" })]);
    expect(pcm.length / 2).toBe(LIVE_VOICE_PLAYBACK_SAMPLE_RATE / 10);
    expect(pcm.readInt16LE(0)).toBe(Math.round(0.25 * 32767));
    expect(pcm.readInt16LE(pcm.length - 2)).toBe(Math.round(0.25 * 32767));
  });

  it("drops queued speech when the user starts talking and says later words", async () => {
    const stt = new ScriptedSttProvider();
    const spoken: string[] = [];
    const pcm: string[] = [];
    const tts = new GateableTtsPort({ onSpeak: (text) => spoken.push(text) });
    const adapter = localAdapter(stt, { tts, turnEndPauseMs: 60_000 });
    adapter.setPlaybackSink((chunk) => pcm.push(chunk.toString()));
    await adapter.start(() => {});
    const update = (text: string) => adapter.speak(text);

    const playing = update("working on it");
    const queued = update("still working");
    await tts.waitForSpeak("working on it");
    stt.emit({ text: "wait" });
    await Promise.all([playing, queued]);
    const later = update("done");
    await tts.waitForSpeak("done");
    tts.release("done");
    await later;

    expect(spoken).toEqual(["working on it", "done"]);
    expect(pcm).toEqual(["done"]);
  });

  it("says newer words after the ones playing instead of cutting them off", async () => {
    const stt = new ScriptedSttProvider();
    const spoken: string[] = [];
    const cancelled: string[] = [];
    const pcm: string[] = [];
    const tts = new GateableTtsPort({
      onSpeak(text) {
        spoken.push(text);
      },
      onCancel(text) {
        cancelled.push(text);
      },
    });
    const adapter = localAdapter(stt, { tts });
    adapter.setPlaybackSink((chunk) => pcm.push(chunk.toString()));

    const first = adapter.speak("working on it");
    await tts.waitForSpeak("working on it");
    const second = adapter.speak("three open sessions");
    await turnEnd();
    expect(spoken).toEqual(["working on it"]);

    tts.release("working on it");
    await tts.waitForSpeak("three open sessions");
    tts.release("three open sessions");
    await Promise.all([first, second]);

    expect(spoken).toEqual(["working on it", "three open sessions"]);
    expect(cancelled).toEqual([]);
    expect(pcm).toEqual(["working on it", "three open sessions"]);
  });

  it("logs why each turn ended and a call summary, never the words said", async () => {
    const lines: Record<string, unknown>[] = [];
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
      const line = JSON.parse(String(chunk)) as Record<string, unknown>;
      if (String(line.event).startsWith("voice_media.")) lines.push(line);
      return true;
    }) as typeof process.stderr.write);
    try {
      const stt = new ScriptedSttProvider();
      stt.stopResult = { text: "Plum is the passphrase. Plum again. Plum and then. Plum, plum" };
      const adapter = localAdapter(stt, { callId: "call-1" });
      await adapter.start(async () => {});

      stt.emit({ text: "Plum is the passphrase." });
      stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });
      await settled();
      stt.emit({ text: "Plum is the passphrase. Plum again." });
      stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 450 });
      await settled();
      stt.emit({ text: "Plum is the passphrase. Plum again. Plum and then" });
      stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 1_200 });
      await settled();
      stt.emit({ text: "Plum is the passphrase. Plum again. Plum and then. Plum" });
      await turnEnd();
      stt.emit({ text: "Plum is the passphrase. Plum again. Plum and then. Plum, plum" });
      await adapter.stop();

      const turns = lines.filter((line) => line.event === "voice_media.turn_committed");
      expect(turns.map((line) => [line.reason, line.endsSentence, line.units])).toEqual([
        ["speech_final", true, 4],
        ["sentence_end_silence", true, 2],
        ["unfinished_silence", false, 3],
        ["watchdog", false, 1],
        ["call_stop", false, 1],
      ]);
      expect(turns[0]).toMatchObject({ callId: "call-1", trailingSilenceMs: 700 });
      const summary = lines.find((line) => line.event === "voice_media.call_summary");
      expect(summary).toMatchObject({
        callId: "call-1",
        turns: 5,
        endReasons: {
          speech_final: 1,
          sentence_end_silence: 1,
          unfinished_silence: 1,
          watchdog: 1,
          call_stop: 1,
        },
      });
      expect(JSON.stringify(lines)).not.toMatch(/plum/i);
    } finally {
      stderr.mockRestore();
    }
  });

  it("plays what the session's agent says as call audio", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const tts = new GateableTtsPort();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt, { tts }),
      calls,
      nextUtteranceId: () => "utterance-1",
      nextDelegationId: () => "delegation-1",
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    coordinator.feedAudio("connection-1", Buffer.from("pcm"));
    stt.emit({ text: "list open sessions", committedText: "list open sessions" });
    await turnEnd();

    const published = coordinator.speak(started.state.callId, "You have three open sessions");
    await tts.waitForSpeak("You have three open sessions");
    tts.release("You have three open sessions");
    await published;

    expect(frontend.audio).toEqual([Buffer.from("You have three open sessions")]);
    expect(calls.snapshot(started.state.callId).lifecycle).toBe("active");
    await coordinator.detach("connection-1");
  });


  it("aborts in-flight Yuwp TTS on the first user partial", async () => {
    const stt = new ScriptedSttProvider();
    const cancelled: string[] = [];
    const pcm: Buffer[] = [];
    const tts = new GateableTtsPort({
      onCancel(text) {
        cancelled.push(text);
      },
    });
    const adapter = localAdapter(stt, { tts, turnEndPauseMs: 60_000 });
    adapter.setPlaybackSink((chunk) => pcm.push(Buffer.from(chunk)));
    await adapter.start(async () => {});

    const speaking = adapter.speak("working on it");
    await tts.waitForSpeak("working on it");

    stt.emit({ text: "stop", activeText: "stop" });
    tts.release("working on it");
    await speaking;

    expect(cancelled).toEqual(["working on it"]);
    expect(pcm).toEqual([]);
  });

  it("cancels in-flight and queued speech after two consecutive speaking reports", async () => {
    const stt = new ScriptedSttProvider();
    const cancelled: string[] = [];
    const spoken: string[] = [];
    const pcm: Buffer[] = [];
    const tts = new GateableTtsPort({
      onSpeak: (text) => spoken.push(text),
      onCancel: (text) => cancelled.push(text),
    });
    const adapter = localAdapter(stt, { tts, turnEndPauseMs: 60_000 });
    adapter.setPlaybackSink((chunk) => pcm.push(Buffer.from(chunk)));
    await adapter.start(async () => {});

    const playing = adapter.speak("working on it");
    const queued = adapter.speak("still working");
    await tts.waitForSpeak("working on it");

    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    expect(cancelled).toEqual([]);
    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    tts.release("working on it");
    await Promise.all([playing, queued]);

    expect(cancelled).toEqual(["working on it"]);
    expect(spoken).toEqual(["working on it"]);
    expect(pcm).toEqual([]);
  });

  it("tells the phone to drop buffered audio on each speech barge-in", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const tts = new GateableTtsPort();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt, { tts, turnEndPauseMs: 60_000 }),
      calls,
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    const partials = () =>
      frontend.messages.flatMap((message) =>
        message.type === "voice_call_state" ? [message.partialTranscript] : [],
      );
    const speaking = { speechActive: true, speechFinal: false, trailingSilenceMs: 0 };

    const first = coordinator.speak(started.state.callId, "working on it");
    await tts.waitForSpeak("working on it");
    stt.speech(speaking);
    expect(partials()).toEqual([]);
    stt.speech(speaking);
    expect(partials()).toEqual(["…"]);
    tts.release("working on it");
    await first;

    // The user only coughed: the placeholder clears so the next "…" is a change again.
    stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });
    expect(partials()).toEqual(["…", undefined]);

    const second = coordinator.speak(started.state.callId, "still here");
    await tts.waitForSpeak("still here");
    stt.speech(speaking);
    stt.speech(speaking);
    expect(partials()).toEqual(["…", undefined, "…"]);
    tts.release("still here");
    await second;
    await coordinator.detach("connection-1");
  });

  it("barges in on audio the phone is still playing, not after it ends", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    // TTS runs faster than real time: 3 s of audio is sent at once and nothing stays pending.
    const threeSeconds = Buffer.alloc(3 * LIVE_VOICE_PLAYBACK_SAMPLE_RATE * 2);
    const tts: LiveVoiceTtsPort = {
      async *speak() {
        yield threeSeconds;
      },
    };
    let clock = 1_000;
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt, { tts, turnEndPauseMs: 60_000, now: () => clock }),
      calls,
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    const partials = () =>
      frontend.messages.flatMap((message) =>
        message.type === "voice_call_state" ? [message.partialTranscript] : [],
      );
    const speaking = { speechActive: true, speechFinal: false, trailingSilenceMs: 0 };

    await coordinator.speak(started.state.callId, "working on it");
    clock += 500;
    stt.speech(speaking);
    stt.speech(speaking);
    expect(partials()).toEqual(["…"]);
    stt.speech({ speechActive: false, speechFinal: true, trailingSilenceMs: 700 });

    await coordinator.speak(started.state.callId, "still here");
    clock += 3_001;
    stt.speech(speaking);
    stt.speech(speaking);
    expect(partials()).toEqual(["…", undefined]);
    await coordinator.detach("connection-1");
  });

  it("keeps speaking through isolated speaking reports", async () => {
    const stt = new ScriptedSttProvider();
    const cancelled: string[] = [];
    const pcm: string[] = [];
    const tts = new GateableTtsPort({ onCancel: (text) => cancelled.push(text) });
    const adapter = localAdapter(stt, { tts, turnEndPauseMs: 60_000 });
    adapter.setPlaybackSink((chunk) => pcm.push(chunk.toString()));
    await adapter.start(async () => {});

    const playing = adapter.speak("working on it");
    await tts.waitForSpeak("working on it");

    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    stt.speech({ speechActive: false, speechFinal: false, trailingSilenceMs: 200 });
    stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
    tts.release("working on it");
    await playing;

    expect(cancelled).toEqual([]);
    expect(pcm).toEqual(["working on it"]);
  });

  describe("the phone's voice_call_barge_in", () => {
    /** A call started through the socket handler on `connection-1`, with local ASR and TTS. */
    async function bargeInCall() {
      const calls = makeCalls();
      const stt = new ScriptedSttProvider();
      let clock = 1_000;
      const spoken: string[] = [];
      const cancelled: string[] = [];
      const tts = new GateableTtsPort({
        onSpeak: (text) => spoken.push(text),
        onCancel: (text) => cancelled.push(text),
      });
      const coordinator = new VoiceCallMediaCoordinator({
        createAdapter: ({ callId }) =>
          localAdapter(stt, { tts, callId, turnEndPauseMs: 60_000, now: () => clock }),
        calls,
      });
      const handler = new WsMessageHandler({
        sessions: { supportsLiveVoice: () => true } as unknown as WsMessageHandlerDeps["sessions"],
        ensureSessionContextWindow: (session) => session,
        voiceCalls: calls,
        voiceMedia: coordinator,
      });
      const sent: ServerMessage[] = [];
      const audio: string[] = [];
      const send = (connId: string, message: Record<string, unknown>) =>
        handler.handleClientMessage(
          makeVoiceSession(),
          message as Parameters<WsMessageHandler["handleClientMessage"]>[1],
          (reply) => sent.push(reply),
          {
            connId,
            authenticatedDeviceId: "paired-device-a",
            sendAudio: (pcm) => audio.push(pcm.toString()),
          },
        );
      await send("connection-1", {
        type: "voice_call_start",
        clientCallId: "client-1",
        requestId: "start-1",
      });
      const { callId, controllerLeaseEpoch } = calls.snapshot("call-1");
      const bargeIn = async (
        requestId: string,
        overrides: { callId?: string; controllerLeaseEpoch?: number; connId?: string } = {},
      ) => {
        sent.length = 0;
        await send(overrides.connId ?? "connection-1", {
          type: "voice_call_barge_in",
          callId: overrides.callId ?? callId,
          controllerLeaseEpoch: overrides.controllerLeaseEpoch ?? controllerLeaseEpoch,
          requestId,
        });
        return sent.find((message) => message.type === "command_result");
      };
      return {
        calls,
        coordinator,
        stt,
        tts,
        spoken,
        cancelled,
        audio,
        sent,
        callId,
        bargeIn,
        /** Moves the adapter's clock: how long the phone may still be playing what was sent. */
        advance: (ms: number) => (clock += ms),
      };
    }

    it("drops the reply being said and queued before answering, once per request", async () => {
      const lines: Record<string, unknown>[] = [];
      const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
        const line = JSON.parse(String(chunk)) as Record<string, unknown>;
        if (String(line.event).startsWith("voice_media.")) lines.push(line);
        return true;
      }) as typeof process.stderr.write);
      try {
        const call = await bargeInCall();
        const playing = call.coordinator.speak(call.callId, "working on it");
        const queued = call.coordinator.speak(call.callId, "still working");
        await call.tts.waitForSpeak("working on it");

        expect(await call.bargeIn("barge-1")).toEqual({
          type: "command_result",
          command: "voice_call_barge_in",
          requestId: "barge-1",
          success: true,
          data: { callId: call.callId, cancelled: true },
        });
        // Cancelled before the result went out: no audio of that reply can follow it.
        expect(call.cancelled).toEqual(["working on it"]);
        await Promise.all([playing, queued]);

        const next = call.coordinator.speak(call.callId, "done");
        await call.tts.waitForSpeak("done");
        // A repeat of the handled request cannot cut off the reply that started after it.
        expect(await call.bargeIn("barge-1")).toMatchObject({
          success: true,
          data: { cancelled: false },
        });
        call.tts.release("done");
        await next;
        call.advance(1_000);
        // Nothing is queued and the phone has played it all: a late barge-in changes nothing.
        expect(await call.bargeIn("barge-2")).toMatchObject({
          success: true,
          data: { cancelled: false },
        });

        expect(call.spoken).toEqual(["working on it", "done"]);
        expect(call.audio).toEqual(["done"]);
        expect(call.calls.snapshot(call.callId).lifecycle).toBe("active");
        await call.coordinator.detach("connection-1");

        const bargeIns = lines.filter((line) => line.event === "voice_media.barge_in");
        expect(bargeIns).toEqual([
          expect.objectContaining({ source: "local", queuedItems: 2, callId: call.callId }),
        ]);
        expect(lines.find((line) => line.event === "voice_media.call_summary")).toMatchObject({
          bargeIns: 1,
          localBargeIns: 1,
        });
      } finally {
        stderr.mockRestore();
      }
    });

    /** `voice_media.*` log lines while `run` runs. */
    async function voiceLogs(run: () => Promise<void>): Promise<Record<string, unknown>[]> {
      const lines: Record<string, unknown>[] = [];
      const stderr = vi.spyOn(process.stderr, "write").mockImplementation(((chunk: unknown) => {
        const line = JSON.parse(String(chunk)) as Record<string, unknown>;
        if (String(line.event).startsWith("voice_media.")) lines.push(line);
        return true;
      }) as typeof process.stderr.write);
      try {
        await run();
      } finally {
        stderr.mockRestore();
      }
      return lines;
    }

    const placeholderSent = (sent: ServerMessage[]) =>
      sent.some(
        (message) => message.type === "voice_call_state" && message.partialTranscript === "\u2026",
      );

    it("phone first: the speech detector's barge-in on the same speech finds nothing left", async () => {
      const call = await bargeInCall();
      const lines = await voiceLogs(async () => {
        const playing = call.coordinator.speak(call.callId, "working on it");
        await call.tts.waitForSpeak("working on it");
        expect(await call.bargeIn("barge-1")).toMatchObject({ data: { cancelled: true } });

        call.stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
        call.stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
        await playing;
        expect(placeholderSent(call.sent)).toBe(false);
        expect(call.cancelled).toEqual(["working on it"]);
        await call.coordinator.detach("connection-1");
      });
      expect(lines.filter((line) => line.event === "voice_media.barge_in")).toEqual([
        expect.objectContaining({ source: "local" }),
      ]);
      expect(lines.find((line) => line.event === "voice_media.call_summary")).toMatchObject({
        bargeIns: 1,
        localBargeIns: 1,
      });
    });

    it("detector first: the phone's barge-in on the same speech is a no-op", async () => {
      const call = await bargeInCall();
      const lines = await voiceLogs(async () => {
        const playing = call.coordinator.speak(call.callId, "working on it");
        await call.tts.waitForSpeak("working on it");
        call.stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
        call.stt.speech({ speechActive: true, speechFinal: false, trailingSilenceMs: 0 });
        await playing;
        expect(placeholderSent(call.sent)).toBe(true);

        expect(await call.bargeIn("barge-1")).toMatchObject({
          success: true,
          data: { cancelled: false },
        });
        expect(call.cancelled).toEqual(["working on it"]);
        await call.coordinator.detach("connection-1");
      });
      expect(lines.filter((line) => line.event === "voice_media.barge_in")).toEqual([
        expect.objectContaining({ source: "vad" }),
      ]);
    });

    it("counts a phone barge-in on audio the phone is still playing after the queue drained", async () => {
      const call = await bargeInCall();
      // 100 ms of playback: the test TTS sends each character as one byte.
      const reply = "x".repeat(4_800);
      const lines = await voiceLogs(async () => {
        const spoken = call.coordinator.speak(call.callId, reply);
        await call.tts.waitForSpeak(reply);
        call.tts.release(reply);
        await spoken;
        call.advance(40);
        expect(await call.bargeIn("barge-1")).toMatchObject({ data: { cancelled: true } });
        await call.coordinator.detach("connection-1");
      });
      expect(lines.filter((line) => line.event === "voice_media.barge_in")).toEqual([
        expect.objectContaining({ source: "local", queuedItems: 0, playbackRemainingMs: 60 }),
      ]);
    });

    it("refuses a stale lease, another call, or another connection, and keeps speaking", async () => {
      const call = await bargeInCall();
      const playing = call.coordinator.speak(call.callId, "working on it");
      await call.tts.waitForSpeak("working on it");

      for (const overrides of [
        { controllerLeaseEpoch: 99 },
        { connId: "connection-2" },
        { callId: "call-other" },
      ]) {
        expect(await call.bargeIn("barge-x", overrides)).toMatchObject({
          command: "voice_call_barge_in",
          requestId: "barge-x",
          success: false,
        });
      }

      call.tts.release("working on it");
      await playing;
      expect(call.cancelled).toEqual([]);
      expect(call.audio).toEqual(["working on it"]);
      await call.coordinator.detach("connection-1");
    });
  });

  it("delegates a later committed utterance after barge-in and keeps the call up", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const cancelled: string[] = [];
    const tts = new GateableTtsPort({
      onCancel(text) {
        cancelled.push(text);
      },
    });
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt, { tts, turnEndPauseMs: 25 }),
      calls,
      nextUtteranceId: () => "utterance-1",
      nextDelegationId: () => "delegation-1",
    });
    const started = calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });

    const published = coordinator.speak(started.state.callId, "working on it");
    await tts.waitForSpeak("working on it");
    const commit = vi.spyOn(calls, "commitFrontendUtterance");

    stt.emit({ text: "wait", activeText: "wait" });
    tts.release("working on it");
    await published;

    expect(cancelled).toEqual(["working on it"]);
    expect(commit).not.toHaveBeenCalled();
    expect(calls.snapshot(started.state.callId).delegations).toEqual([]);
    expect(calls.snapshot(started.state.callId).lifecycle).toBe("active");
    expect(calls.snapshot(started.state.callId).frontend).toBe("attached");
    expect(frontend.audio).toEqual([]);

    stt.emit({
      text: "list open sessions",
      committedText: "list open sessions",
      activeText: "",
    });
    stt.stopResult = {
      text: "list open sessions",
      committedText: "list open sessions",
    };
    await turnEnd();

    expect(commit).toHaveBeenCalledTimes(1);
    expect(calls.snapshot(started.state.callId).delegations).toEqual([
      expect.objectContaining({
        request: "list open sessions",
        state: "delegated",
      }),
    ]);
    expect(calls.snapshot(started.state.callId).lifecycle).toBe("active");
    await coordinator.detach("connection-1");
  });

});

class GateableTtsPort implements LiveVoiceTtsPort {
  private readonly gates = new Map<string, { release: () => void; cancel: () => void }>();
  private readonly spoken = new Set<string>();
  private readonly waiters: Array<(text: string) => void> = [];

  constructor(
    private readonly hooks: {
      onSpeak?: (text: string) => void;
      onCancel?: (text: string) => void;
    } = {},
  ) {}

  async *speak(text: string, signal?: AbortSignal): AsyncIterable<Buffer> {
    this.hooks.onSpeak?.(text);
    this.spoken.add(text);
    for (const waiter of this.waiters.splice(0)) waiter(text);
    await new Promise<void>((resolve, reject) => {
      if (signal?.aborted) {
        this.hooks.onCancel?.(text);
        reject(abortError());
        return;
      }
      const onAbort = () => {
        this.gates.delete(text);
        this.hooks.onCancel?.(text);
        reject(abortError());
      };
      this.gates.set(text, {
        release: () => {
          signal?.removeEventListener("abort", onAbort);
          this.gates.delete(text);
          resolve();
        },
        cancel: onAbort,
      });
      signal?.addEventListener("abort", onAbort, { once: true });
    });
    if (signal?.aborted) return;
    yield Buffer.from(text);
  }

  waitForSpeak(text: string): Promise<void> {
    if (this.spoken.has(text) || this.gates.has(text)) return Promise.resolve();
    return new Promise((resolve) => {
      this.waiters.push((spoken) => {
        if (spoken === text) resolve();
      });
    });
  }

  release(text: string): void {
    this.gates.get(text)?.release();
  }
}

function floatMonoWav(samples: number[], sampleRate: number): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + samples.length * 4, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(3, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 4, 28);
  header.writeUInt16LE(4, 32);
  header.writeUInt16LE(32, 34);
  header.write("data", 36);
  header.writeUInt32LE(samples.length * 4, 40);
  const data = Buffer.alloc(samples.length * 4);
  samples.forEach((sample, index) => data.writeFloatLE(sample, index * 4));
  return Buffer.concat([header, data]);
}

function abortError(): Error {
  const error = new Error("aborted");
  error.name = "AbortError";
  return error;
}
