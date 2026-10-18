import { describe, expect, it, vi } from "vitest";

import {
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
  VoiceControlBridgeRegistry,
  VoicePiControlBridge,
  type VoiceApprovalChallenge,
  type VoiceFrontendSemanticEvent,
} from "../src/continuous-voice.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";
import type { ServerMessage, Session } from "../src/types.js";

/** Spoken approval delivery awaits the runtime's UI response; let it settle. */
const flushMicrotasks = () => new Promise<void>((resolve) => setImmediate(resolve));

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
    voice: { purpose: "voice-control" },
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
  it("commits a Yuwp/ASR segment through commitFrontendUtterance on the attached lease", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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

    coordinator.feedAudio("connection-1", Buffer.from("pcm-bytes"));
    stt.emit({
      text: "list open sessions",
      committedText: "list open sessions",
      activeText: "",
    });

    const snapshot = calls.snapshot(started.state.callId);
    expect(stt.started).toBe(true);
    expect(stt.fed).toHaveLength(1);
    expect(snapshot.delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-1",
        utteranceId: "utterance-1",
        request: "list open sessions",
        state: "delegated",
      }),
    ]);
    expect(frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_delegation_update",
        kind: "delegated",
        text: "list open sessions",
      }),
    );
  });

  it("updates a partial transcript without creating a delegation", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt, { idleCommitMs: 15 }),
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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
      const adapter = new YuwpVoiceMediaAdapter(stt, { idleCommitMs: 15 });
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

  it("sends leftover Yuwp text into the hidden Pi voice-control bridge", async () => {
    const bridge = new VoicePiControlBridge();
    const sendMessage = vi.fn();
    const handlers = new Map<string, (event: unknown, ctx: { isIdle(): boolean }) => void>();
    bridge.extension.factory({
      registerTool() {},
      on(name: string, handler: (event: unknown, ctx: { isIdle(): boolean }) => void) {
        handlers.set(name, handler);
      },
      sendMessage,
    } as never);
    handlers.get("session_start")?.({}, { isIdle: () => true });

    const registry = new VoiceControlBridgeRegistry();
    registry.register("voice-1", bridge);
    const calls = new VoiceCallController({
      now: () => 1_000,
      nextCallId: () => "call-1",
      dispatchDelegation: (sessionId, delegation) => registry.dispatch(sessionId, delegation),
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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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

    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        customType: "oppi.voice.delegation",
        content: "list open sessions",
        details: expect.objectContaining({
          callId: "call-1",
          delegationId: "delegation-pi-1",
          utteranceId: "utterance-pi-1",
        }),
      }),
      expect.objectContaining({ triggerTurn: true }),
    );
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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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

    expect(createDictationManager).not.toHaveBeenCalled();
    expect(stt.name).toBe("scripted-yuwp");
    expect(calls.snapshot(started.state.callId).delegations).toHaveLength(1);
  });

  it("fails closed when ASR cannot start and does not leave a live call", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    stt.startError = new Error("STT backend unreachable");
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
      calls,
    });
    const sent: ServerMessage[] = [];
    const handler = new WsMessageHandler({
      sessions: {
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
    const adapter = new YuwpVoiceMediaAdapter(stt);
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
    const grok = { start: vi.fn(), publish: vi.fn(), stop: vi.fn() } as VoiceMediaAdapter;
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

  it("commits a mid-call Yuwp segment into the Pi bridge without ending the call", async () => {
    const bridge = new VoicePiControlBridge();
    const sendMessage = vi.fn();
    const handlers = new Map<string, (event: unknown, ctx: { isIdle(): boolean }) => void>();
    bridge.extension.factory({
      registerTool() {},
      on(name: string, handler: (event: unknown, ctx: { isIdle(): boolean }) => void) {
        handlers.set(name, handler);
      },
      sendMessage,
    } as never);
    handlers.get("session_start")?.({}, { isIdle: () => true });

    const registry = new VoiceControlBridgeRegistry();
    registry.register("voice-1", bridge);
    const calls = new VoiceCallController({
      now: () => 1_000,
      nextCallId: () => "call-1",
      dispatchDelegation: (sessionId, delegation) => registry.dispatch(sessionId, delegation),
    });
    const stt = new ScriptedSttProvider();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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

    expect(calls.snapshot(started.state.callId).lifecycle).toBe("active");
    expect(calls.snapshot(started.state.callId).frontend).toBe("attached");
    expect(sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        customType: "oppi.voice.delegation",
        content: "summarize the inbox",
      }),
      expect.objectContaining({ triggerTurn: true }),
    );
    await coordinator.detach("connection-1");
  });

  it("Yuwp adapter emits only semantic frontend events", async () => {
    const stt = new ScriptedSttProvider();
    const adapter = new YuwpVoiceMediaAdapter(stt);
    const events: VoiceFrontendSemanticEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });
    stt.emit({ text: "hi", activeText: "hi" });
    stt.emit({ text: "hi there", committedText: "hi there", activeText: "" });

    expect(events.map((event) => event.type)).toEqual([
      "connected",
      "user_speech_started",
      "user_transcript_partial",
      "user_speech_ended",
      "user_utterance_committed",
    ]);
    expect(JSON.stringify(events)).not.toMatch(/gpt.?live|grok|openai.?realtime|webrtc/i);
  });

  it("speaks voice_update text through publish and cancels the previous generation", async () => {
    const stt = new ScriptedSttProvider();
    const spoken: string[] = [];
    const cancelled: string[] = [];
    const tts = new GateableTtsPort({
      onSpeak(text) {
        spoken.push(text);
      },
      onCancel(text) {
        cancelled.push(text);
      },
    });
    const adapter = new YuwpVoiceMediaAdapter(stt, { tts });
    const events: VoiceFrontendSemanticEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });

    const first = adapter.publish({
      delegationId: "delegation-1",
      kind: "progress",
      text: "working on it",
    });
    await tts.waitForSpeak("working on it");
    const second = adapter.publish({
      delegationId: "delegation-1",
      kind: "final",
      text: "three open sessions",
    });
    await tts.waitForSpeak("three open sessions");
    tts.release("three open sessions");
    await Promise.allSettled([first, second]);

    expect(spoken).toEqual(["working on it", "three open sessions"]);
    expect(cancelled).toEqual(["working on it"]);
    expect(events.map((event) => event.type)).toEqual([
      "connected",
      "assistant_speech_started",
      "assistant_speech_stopped",
      "assistant_speech_started",
      "assistant_speech_stopped",
    ]);
  });

  it("forwards voice_update text from the call controller to Yuwp publish PCM", async () => {
    const calls = makeCalls();
    const stt = new ScriptedSttProvider();
    const tts = new GateableTtsPort();
    const frontend = new DeterministicVoiceCallFrontend({
      connectionId: "connection-1",
      authenticatedDeviceId: "paired-device-a",
    });
    const coordinator = new VoiceCallMediaCoordinator({
      createAdapter: () => new YuwpVoiceMediaAdapter(stt, { tts }),
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

    const update = {
      delegationId: "delegation-1",
      kind: "final" as const,
      text: "You have three open sessions",
    };
    calls.applyDelegationUpdate(started.state.callId, update);
    const published = coordinator.publish(started.state.callId, update);
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
        createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
      await flushMicrotasks();

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
        createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
      await flushMicrotasks();

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
        createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
      await flushMicrotasks();

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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
    await flushMicrotasks();

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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt),
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
    await flushMicrotasks();

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
    const adapter = new YuwpVoiceMediaAdapter(stt, { tts, idleCommitMs: 0 });
    adapter.setPlaybackSink((chunk) => pcm.push(Buffer.from(chunk)));
    const events: VoiceFrontendSemanticEvent[] = [];
    await adapter.start((event) => {
      events.push(event);
    });

    const speaking = adapter.publish({
      delegationId: "delegation-1",
      kind: "progress",
      text: "working on it",
    });
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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt, { tts, idleCommitMs: 0 }),
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

    const published = coordinator.publish(started.state.callId, {
      delegationId: "delegation-speak",
      kind: "progress",
      text: "working on it",
    });
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

    expect(commit).toHaveBeenCalled();
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
      createAdapter: () => new YuwpVoiceMediaAdapter(stt, { tts, idleCommitMs: 0 }),
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
    const published = coordinator.publish(started.state.callId, {
      delegationId: "delegation-speak",
      kind: "progress",
      text: "Stop worker-1?",
    });
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
    await flushMicrotasks();

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

function abortError(): Error {
  const error = new Error("aborted");
  error.name = "AbortError";
  return error;
}
