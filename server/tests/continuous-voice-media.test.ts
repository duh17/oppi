import { describe, expect, it, vi } from "vitest";

import {
  LIVE_VOICE_PLAYBACK_SAMPLE_RATE,
  ReadAloudLiveVoiceTts,
  selectLiveVoiceMediaAdapter,
  type LiveVoiceTtsPort,
  VoiceCallMediaCoordinator,
  YuwpVoiceMediaAdapter,
  type VoiceMediaAdapter,
} from "../src/continuous-voice-media.js";
import {
  DeterministicVoiceCallFrontend,
  VoiceCallController,
} from "../src/continuous-voice-call.js";
import {
  StreamingSttProvider,
  type SttProvider,
  type SttTranscriptUpdate,
} from "../src/stt-provider.js";
import {
  VoiceApprovalBridge,
  type VoiceApprovalChallenge,
  type VoiceFrontendSemanticEvent,
} from "../src/continuous-voice.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";
import type { ServerMessage, Session } from "../src/types.js";

/** Test turns end after a short pause; the default is sized for real speech. */
const TEST_TURN_END_PAUSE_MS = 5;

function localAdapter(
  stt: SttProvider,
  options: ConstructorParameters<typeof YuwpVoiceMediaAdapter>[1] = {},
): YuwpVoiceMediaAdapter {
  return new YuwpVoiceMediaAdapter(stt, { turnEndPauseMs: TEST_TURN_END_PAUSE_MS, ...options });
}

/** Let the user's pause end the turn and spoken approval delivery settle. */
const turnEnd = () => new Promise<void>((resolve) => setTimeout(resolve, 60));

class ScriptedSttProvider implements SttProvider {
  readonly name = "scripted-yuwp";
  readonly model = "test-asr";
  started = false;
  stopped = false;
  fed: Buffer[] = [];
  startError?: Error;
  private tokenCb?: (update: SttTranscriptUpdate) => void;

  async start(): Promise<void> {
    if (this.startError) throw this.startError;
    this.started = true;
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

function makeSpokenApprovalHarness() {
  let now = 1_000;
  let challengeSequence = 0;
  let nonceSequence = 0;
  let receiptSequence = 0;
  const responses: Array<{ sessionId: string; response: unknown }> = [];
  const receipts: unknown[] = [];
  let calls!: VoiceCallController;
  const bridge = new VoiceApprovalBridge({
    now: () => now,
    activeControllerLease: (callId) => calls.activeControllerLease(callId),
    respondToUIRequest: (sessionId, response) => {
      responses.push({ sessionId, response });
      return true;
    },
    appendReceipt: (receipt) => receipts.push(receipt),
    nextChallengeId: () => `challenge-${++challengeSequence}`,
    nextNonce: () => `nonce-${++nonceSequence}`,
    nextReceiptId: () => `receipt-${++receiptSequence}`,
  });
  calls = new VoiceCallController({
    now: () => now,
    nextCallId: () => "call-1",
    leaseDurationMs: 30_000,
    approvalAuthority: bridge,
  });
  return { calls, bridge, responses, receipts };
}

function structuredBinding(requestId: string) {
  return {
    source: "structured_permission_gate" as const,
    sessionId: "session-1",
    requestId,
    canonicalAction: {
      kind: "oppi_command",
      args: ["session", "stop", "worker-1"],
    },
    targetRefs: ["session:worker-1"],
    policyRevision: "policy-7",
    risk: "voice_eligible" as const,
    expiresAt: 8_000,
    responses: {
      approveOnce: { confirmed: true as const },
      deny: { confirmed: false as const },
    },
  };
}

function presentArmedChallenge(
  harness: ReturnType<typeof makeSpokenApprovalHarness>,
  callId: string,
  requestId: string,
  summary = "Stop worker-1?",
): VoiceApprovalChallenge {
  harness.bridge.registerBinding(structuredBinding(requestId));
  const challenge = harness.bridge.issueChallenge({
    callId,
    sessionId: "session-1",
    requestId,
  });
  harness.calls.presentApproval(callId, { challenge, summary });
  return challenge;
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

  it("Yuwp adapter emits only semantic frontend events", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = localAdapter(stt);
    const events: VoiceFrontendSemanticEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });
    stt.emit({ text: "hi", activeText: "hi" });
    stt.emit({ text: "hi there", committedText: "hi there", activeText: "" });
    await turnEnd();

    expect(events.map((event) => event.type)).toEqual([
      "connected",
      "user_speech_started",
      "user_transcript_partial",
      "user_transcript_partial",
      "user_speech_ended",
      "user_utterance_committed",
    ]);
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
    const events: VoiceFrontendSemanticEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });

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
    expect(events.map((event) => event.type)).toEqual([
      "connected",
      "assistant_speech_started",
      "assistant_speech_stopped",
      "assistant_speech_started",
      "assistant_speech_stopped",
    ]);
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

  it.each([
    ["approve once", { outcome: "delivered", decision: "approve_once" }, { confirmed: true }],
    ["Approve once.", { outcome: "delivered", decision: "approve_once" }, { confirmed: true }],
    ["deny", { outcome: "delivered", decision: "deny" }, { confirmed: false }],
  ] as const)(
    "routes a pending-challenge Yuwp %j through submitApprovalTranscript",
    async (transcript, result, response) => {
      const harness = makeSpokenApprovalHarness();
      const stt = new ScriptedSttProvider();
      const frontend = new DeterministicVoiceCallFrontend({
        connectionId: "connection-1",
        authenticatedDeviceId: "paired-device-a",
      });
      const coordinator = new VoiceCallMediaCoordinator({
        createAdapter: () => localAdapter(stt),
        calls: harness.calls,
        nextUtteranceId: () => "utterance-1",
        nextDelegationId: () => "delegation-1",
      });
      const started = harness.calls.startCall(
        { controlSessionId: "voice-1", clientCallId: "client-1" },
        frontend.connection,
      );
      const challenge = presentArmedChallenge(harness, started.state.callId, "request-1");
      await coordinator.attach({
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontend: frontend.connection,
      });
      const commit = vi.spyOn(harness.calls, "commitFrontendUtterance");
      const submit = vi.spyOn(harness.calls, "submitApprovalTranscript");

      stt.emit({ text: transcript, committedText: transcript, activeText: "" });
      await turnEnd();

      expect(submit).toHaveBeenCalledWith(
        {
          callId: started.state.callId,
          controllerLeaseEpoch: started.state.controllerLeaseEpoch,
          challengeId: challenge.challengeId,
          transcript,
        },
        frontend.connection,
      );
      expect(commit).not.toHaveBeenCalled();
      expect(harness.calls.snapshot(started.state.callId).delegations).toEqual([]);
      expect(harness.responses).toEqual([
        {
          sessionId: "session-1",
          response: {
            type: "extension_ui_response",
            id: "request-1",
            ...response,
          },
        },
      ]);
      expect(frontend.messages).toContainEqual(
        expect.objectContaining({
          type: "voice_approval_result",
          challengeId: challenge.challengeId,
          ...result,
        }),
      );
      expect(JSON.stringify(harness.receipts)).not.toMatch(/Approve once\./);
      await coordinator.detach("connection-1");
    },
  );

  it.each(["tell me more", "repeat"] as const)(
    "treats pending-challenge Yuwp %j as a non-authorizing retry",
    async (transcript) => {
      const harness = makeSpokenApprovalHarness();
      const stt = new ScriptedSttProvider();
      const frontend = new DeterministicVoiceCallFrontend({
        connectionId: "connection-1",
        authenticatedDeviceId: "paired-device-a",
      });
      const coordinator = new VoiceCallMediaCoordinator({
        createAdapter: () => localAdapter(stt),
        calls: harness.calls,
        nextUtteranceId: () => "utterance-1",
        nextDelegationId: () => "delegation-1",
      });
      const started = harness.calls.startCall(
        { controlSessionId: "voice-1", clientCallId: "client-1" },
        frontend.connection,
      );
      const challenge = presentArmedChallenge(harness, started.state.callId, "request-1");
      await coordinator.attach({
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontend: frontend.connection,
      });
      const commit = vi.spyOn(harness.calls, "commitFrontendUtterance");

      stt.emit({ text: transcript, committedText: transcript, activeText: "" });
      await turnEnd();

      expect(commit).not.toHaveBeenCalled();
      expect(harness.calls.snapshot(started.state.callId).delegations).toEqual([]);
      expect(harness.responses).toEqual([]);
      expect(frontend.messages).toContainEqual(
        expect.objectContaining({
          type: "voice_approval_result",
          challengeId: challenge.challengeId,
          outcome: "retry",
          reason: transcript === "tell me more" ? "tell_me_more" : "repeat",
        }),
      );
      await coordinator.detach("connection-1");
    },
  );

  it.each(["Sure, that seems fine", "approve everything", "deny and approve once"] as const)(
    "fails closed for ambiguous pending-challenge Yuwp %j",
    async (transcript) => {
      const harness = makeSpokenApprovalHarness();
      const stt = new ScriptedSttProvider();
      const frontend = new DeterministicVoiceCallFrontend({
        connectionId: "connection-1",
        authenticatedDeviceId: "paired-device-a",
      });
      const coordinator = new VoiceCallMediaCoordinator({
        createAdapter: () => localAdapter(stt),
        calls: harness.calls,
        nextUtteranceId: () => "utterance-1",
        nextDelegationId: () => "delegation-1",
      });
      const started = harness.calls.startCall(
        { controlSessionId: "voice-1", clientCallId: "client-1" },
        frontend.connection,
      );
      const challenge = presentArmedChallenge(harness, started.state.callId, "request-1");
      await coordinator.attach({
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        frontend: frontend.connection,
      });
      const commit = vi.spyOn(harness.calls, "commitFrontendUtterance");
      const submit = vi.spyOn(harness.calls, "submitApprovalTranscript");

      stt.emit({ text: transcript, committedText: transcript, activeText: "" });
      await turnEnd();

      expect(submit).not.toHaveBeenCalled();
      expect(commit).not.toHaveBeenCalled();
      expect(harness.calls.snapshot(started.state.callId).delegations).toEqual([]);
      expect(harness.responses).toEqual([]);
      expect(harness.calls.snapshot(started.state.callId).pendingApprovals).toEqual([
        expect.objectContaining({ challengeId: challenge.challengeId }),
      ]);
      expect(
        frontend.messages.some(
          (message) =>
            message.type === "voice_delegation_update" || message.type === "voice_approval_result",
        ),
      ).toBe(false);
      await coordinator.detach("connection-1");
    },
  );

  it("still delegates a Yuwp utterance when no approval challenge is pending", async () => {
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
    const commit = vi.spyOn(calls, "commitFrontendUtterance");
    const submit = vi.spyOn(calls, "submitApprovalTranscript");

    stt.emit({
      text: "approve once",
      committedText: "approve once",
      activeText: "",
    });
    await turnEnd();

    expect(submit).not.toHaveBeenCalled();
    expect(commit).toHaveBeenCalled();
    expect(calls.snapshot(started.state.callId).delegations).toEqual([
      expect.objectContaining({
        request: "approve once",
        state: "delegated",
      }),
    ]);
    await coordinator.detach("connection-1");
  });

  it("binds multiple pending challenges to the oldest presented challenge", async () => {
    const harness = makeSpokenApprovalHarness();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => localAdapter(stt),
      calls: harness.calls,
      nextUtteranceId: () => "utterance-1",
      nextDelegationId: () => "delegation-1",
    });
    const started = harness.calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    const oldest = presentArmedChallenge(
      harness,
      started.state.callId,
      "request-oldest",
      "Stop worker-1?",
    );
    presentArmedChallenge(harness, started.state.callId, "request-newest", "Stop worker-2?");
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    const submit = vi.spyOn(harness.calls, "submitApprovalTranscript");
    const commit = vi.spyOn(harness.calls, "commitFrontendUtterance");

    stt.emit({
      text: "approve once",
      committedText: "approve once",
      activeText: "",
    });
    await turnEnd();

    expect(submit).toHaveBeenCalledWith(
      expect.objectContaining({ challengeId: oldest.challengeId }),
      frontend.connection,
    );
    expect(commit).not.toHaveBeenCalled();
    expect(harness.responses).toEqual([
      {
        sessionId: "session-1",
        response: {
          type: "extension_ui_response",
          id: "request-oldest",
          confirmed: true,
        },
      },
    ]);
    expect(harness.calls.snapshot(started.state.callId).pendingApprovals).toEqual([
      expect.objectContaining({ requestId: "request-newest" }),
    ]);
    await coordinator.detach("connection-1");
  });

  it("aborts in-flight Yuwp TTS on the first user partial while outputSpeaking", async () => {
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
    const events: VoiceFrontendSemanticEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });

    const speaking = adapter.speak("working on it");
    await tts.waitForSpeak("working on it");

    stt.emit({ text: "stop", activeText: "stop" });
    tts.release("working on it");
    await speaking;

    expect(cancelled).toEqual(["working on it"]);
    expect(pcm).toEqual([]);
    expect(events.map((event) => event.type)).toEqual([
      "connected",
      "assistant_speech_started",
      "assistant_speech_stopped",
      "user_speech_started",
      "user_transcript_partial",
    ]);
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

  it("routes a later committed approval phrase after barge-in when a challenge is pending", async () => {
    const harness = makeSpokenApprovalHarness();
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
      calls: harness.calls,
      nextUtteranceId: () => "utterance-1",
      nextDelegationId: () => "delegation-1",
    });
    const started = harness.calls.startCall(
      { controlSessionId: "voice-1", clientCallId: "client-1" },
      frontend.connection,
    );
    const challenge = presentArmedChallenge(harness, started.state.callId, "request-1");
    await coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    const published = coordinator.speak(started.state.callId, "Stop worker-1?");
    await tts.waitForSpeak("Stop worker-1?");
    const commit = vi.spyOn(harness.calls, "commitFrontendUtterance");
    const submit = vi.spyOn(harness.calls, "submitApprovalTranscript");

    stt.emit({ text: "um", activeText: "um" });
    tts.release("Stop worker-1?");
    await published;

    expect(cancelled).toEqual(["Stop worker-1?"]);
    expect(commit).not.toHaveBeenCalled();
    expect(submit).not.toHaveBeenCalled();
    expect(harness.calls.snapshot(started.state.callId).delegations).toEqual([]);
    expect(harness.calls.snapshot(started.state.callId).pendingApprovals).toEqual([
      expect.objectContaining({ challengeId: challenge.challengeId }),
    ]);
    expect(harness.calls.snapshot(started.state.callId).lifecycle).toBe("active");

    stt.emit({
      text: "approve once",
      committedText: "approve once",
      activeText: "",
    });
    await turnEnd();

    expect(submit).toHaveBeenCalledWith(
      {
        callId: started.state.callId,
        controllerLeaseEpoch: started.state.controllerLeaseEpoch,
        challengeId: challenge.challengeId,
        transcript: "approve once",
      },
      frontend.connection,
    );
    expect(commit).not.toHaveBeenCalled();
    expect(harness.calls.snapshot(started.state.callId).delegations).toEqual([]);
    stt.stopResult = {
      text: "approve once",
      committedText: "approve once",
    };
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
