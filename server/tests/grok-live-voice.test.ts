import { describe, expect, it, vi } from "vitest";

import {
  DeterministicVoiceCallFrontend,
  VoiceCallController,
} from "../src/continuous-voice-call.js";
import { VoiceCallMediaCoordinator } from "../src/continuous-voice-media.js";
import { VoiceApprovalBridge } from "../src/continuous-voice.js";
import {
  GrokVoiceMediaAdapter,
  grokVoiceFromTts,
  type GrokVoiceSocket,
} from "../src/grok-live-voice.js";

/** Stands in for the xAI realtime socket; the test plays the server side. */
class FakeXaiSocket implements GrokVoiceSocket {
  readyState = 1;
  readonly json: Array<Record<string, any>> = [];
  readonly binary: Buffer[] = [];
  closed = false;
  private readonly listeners = new Map<string, Array<(...args: any[]) => void>>();

  constructor(
    readonly url: string,
    readonly headers: Record<string, string>,
  ) {}

  on(event: string, listener: (...args: any[]) => void): void {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), listener]);
  }

  send(data: Buffer | string): void {
    if (typeof data === "string") this.json.push(JSON.parse(data));
    else this.binary.push(data);
  }

  close(): void {
    this.closed = true;
    this.readyState = 3;
  }

  server(event: Record<string, unknown>): void {
    for (const listener of this.listeners.get("message") ?? []) {
      listener(Buffer.from(JSON.stringify(event)), false);
    }
  }

  serverAudio(pcm: Buffer): void {
    for (const listener of this.listeners.get("message") ?? []) listener(pcm, true);
  }

  serverClose(code: number): void {
    this.readyState = 3;
    for (const listener of this.listeners.get("close") ?? []) listener(code, Buffer.alloc(0));
  }

  sentTypes(): string[] {
    return this.json.map((event) => String(event.type));
  }
}

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

/**
 * xAI's `response.created` for the adapter's latest create: xAI echoes the create's metadata,
 * which is how the adapter tells its own replies apart.
 */
function ownReplyCreated(socket: FakeXaiSocket): Record<string, unknown> {
  const create = socket.json.filter((event) => event.type === "response.create").at(-1);
  return { type: "response.created", response: { metadata: create?.response?.metadata } };
}

function harness(options: { apiKey?: string } = {}) {
  let now = 1_000;
  let challengeSequence = 0;
  const responses: Array<{ sessionId: string; response: unknown }> = [];
  let calls!: VoiceCallController;
  const approvals = new VoiceApprovalBridge({
    now: () => now,
    activeControllerLease: (callId) => calls.activeControllerLease(callId),
    respondToUIRequest: (sessionId, response) => {
      responses.push({ sessionId, response });
      return true;
    },
    appendReceipt: () => {},
    nextChallengeId: () => `challenge-${++challengeSequence}`,
    nextNonce: () => `nonce-${challengeSequence}`,
    nextReceiptId: () => "receipt-1",
  });
  const dispatched: Array<{ sessionId: string; request: string }> = [];
  calls = new VoiceCallController({
    now: () => now,
    nextCallId: () => "call-1",
    leaseDurationMs: 30_000,
    approvalAuthority: approvals,
    dispatchDelegation: (sessionId, delegation) =>
      dispatched.push({ sessionId, request: delegation.request }),
  });
  const sockets: FakeXaiSocket[] = [];
  const adapter = new GrokVoiceMediaAdapter({
    resolveApiKey: async () => ("apiKey" in options ? options.apiKey : "xai-token"),
    now: () => now,
    createSocket: (url, headers) => {
      const socket = new FakeXaiSocket(url, headers);
      sockets.push(socket);
      return socket;
    },
  });
  const coordinator = new VoiceCallMediaCoordinator({ createAdapter: () => adapter, calls });
  const frontend = new DeterministicVoiceCallFrontend({
    connectionId: "connection-1",
    authenticatedDeviceId: "paired-iphone",
  });
  const started = calls.startCall(
    { controlSessionId: "voice-1", clientCallId: "client-1" },
    frontend.connection,
  );

  /** Attaches the call and plays xAI's handshake. */
  async function attach(): Promise<FakeXaiSocket> {
    const attaching = coordinator.attach({
      callId: started.state.callId,
      controllerLeaseEpoch: started.state.controllerLeaseEpoch,
      frontend: frontend.connection,
    });
    await flush();
    const socket = sockets[0];
    socket.server({ type: "session.created" });
    socket.server({ type: "session.updated" });
    await attaching;
    socket.json.length = 0;
    return socket;
  }

  /** A structured permission request the user is asked to answer by voice. */
  function presentChallenge(requestId: string): void {
    approvals.registerBinding({
      source: "structured_permission_gate",
      sessionId: "session-1",
      requestId,
      canonicalAction: { kind: "oppi_command", args: ["session", "stop", requestId] },
      targetRefs: [`session:${requestId}`],
      policyRevision: "policy-7",
      risk: "voice_eligible",
      expiresAt: 8_000,
      responses: { approveOnce: { confirmed: true }, deny: { confirmed: false } },
    });
    const challenge = approvals.issueChallenge({
      callId: started.state.callId,
      sessionId: "session-1",
      requestId,
    });
    calls.presentApproval(started.state.callId, { challenge, summary: `Stop ${requestId}?` });
  }

  return {
    presentChallenge,
    calls,
    approvals,
    adapter,
    coordinator,
    frontend,
    started,
    sockets,
    dispatched,
    responses,
    attach,
    advance: (ms: number) => (now += ms),
  };
}

describe("Grok Voice media", () => {
  it("opens one xAI session with the owner's credential and the Live Voice audio contract", async () => {
    const h = harness();
    const attaching = h.coordinator.attach({
      callId: h.started.state.callId,
      controllerLeaseEpoch: h.started.state.controllerLeaseEpoch,
      frontend: h.frontend.connection,
    });
    await flush();
    const socket = h.sockets[0];
    expect(socket.url).toBe("wss://api.x.ai/v1/realtime?model=grok-voice-latest");
    expect(socket.headers.Authorization).toBe("Bearer xai-token");

    socket.server({ type: "session.created" });
    const [update] = socket.json;
    expect(update.type).toBe("session.update");
    expect(update.session.audio).toEqual({
      input: {
        format: { type: "audio/pcm", rate: 16_000 },
        transport: "binary",
        transcription: { model: "grok-transcribe" },
      },
      output: { format: { type: "audio/pcm", rate: 24_000 }, transport: "binary" },
    });
    expect(update.session.turn_detection).toEqual({ type: "server_vad" });
    expect(update.session.tools.map((tool: { name: string }) => tool.name)).toEqual([
      "delegate_to_pi",
    ]);

    // Not ready until xAI confirms the configuration: mic audio is not forwarded yet.
    h.coordinator.feedAudio("connection-1", Buffer.from([1, 2]));
    expect(socket.binary).toEqual([]);
    socket.server({ type: "session.updated" });
    await attaching;
    h.coordinator.feedAudio("connection-1", Buffer.from([3, 4]));
    expect(socket.binary).toEqual([Buffer.from([3, 4])]);
  });

  it("fails the start closed without an xAI credential or when xAI rejects the session", async () => {
    const missing = harness({ apiKey: undefined });
    await expect(
      missing.coordinator.attach({
        callId: missing.started.state.callId,
        controllerLeaseEpoch: missing.started.state.controllerLeaseEpoch,
        frontend: missing.frontend.connection,
      }),
    ).rejects.toThrow("Grok Voice needs an xAI sign-in or API key");
    expect(missing.sockets).toEqual([]);

    const rejected = harness();
    const attaching = rejected.coordinator.attach({
      callId: rejected.started.state.callId,
      controllerLeaseEpoch: rejected.started.state.controllerLeaseEpoch,
      frontend: rejected.frontend.connection,
    });
    await flush();
    rejected.sockets[0].server({
      type: "error",
      error: { message: "Voice session access denied." },
    });
    await expect(attaching).rejects.toThrow("Voice session access denied.");
    expect(rejected.sockets[0].closed).toBe(true);
  });

  it("starts Pi work only when Grok calls delegate_to_pi, not from what the user said", async () => {
    const h = harness();
    const socket = await h.attach();

    socket.server({ type: "input_audio_buffer.speech_started" });
    socket.server({
      type: "conversation.item.input_audio_transcription.updated",
      item_id: "item-1",
      transcript: "can you ask Pi to run the server tests",
    });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-1" });
    await flush();
    expect(h.dispatched).toEqual([]);
    expect(h.frontend.messages).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        partialTranscript: "can you ask Pi to run the server tests",
      }),
    );

    socket.server({ type: "response.created" });
    socket.server({ type: "response.output_audio_transcript.delta", delta: "On it." });
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-1",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "Run the server tests." }),
    });
    await flush();

    expect(h.dispatched).toEqual([{ sessionId: "voice-1", request: "Run the server tests." }]);
    expect(h.calls.snapshot(h.started.state.callId).delegations).toEqual([
      expect.objectContaining({ request: "Run the server tests.", state: "delegated" }),
    ]);
    expect(socket.json).toEqual([
      {
        type: "conversation.item.create",
        item: {
          type: "function_call_output",
          call_id: "fc-1",
          output: JSON.stringify({
            status: "delegated",
            note: "Pi has it; its answer arrives as a [Pi says] message.",
          }),
        },
      },
    ]);
    // Grok already said "On it." in this response, so no second acknowledgement is requested.
    socket.server({ type: "response.done" });
    await flush();
    expect(socket.sentTypes()).not.toContain("response.create");
  });

  it("tells Grok when a delegation could not start so it can say so", async () => {
    const h = harness();
    const socket = await h.attach();
    h.calls.endCall(
      {
        callId: h.started.state.callId,
        controllerLeaseEpoch: h.started.state.controllerLeaseEpoch,
      },
      h.frontend.connection,
    );

    socket.server({ type: "response.created" });
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-1",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "Run the tests." }),
    });
    await flush();
    expect(h.dispatched).toEqual([]);
    const output = JSON.parse(socket.json[0].item.output);
    expect(output.status).toBe("error");
    socket.server({ type: "response.done" });
    await flush();
    expect(socket.sentTypes()).toEqual(["conversation.item.create", "response.create"]);
  });

  it("speaks a Pi update after the current response and the phone's queued audio finish", async () => {
    const h = harness();
    const socket = await h.attach();
    socket.server({ type: "response.created" });
    // 480 ms of 24 kHz mono s16le reaches the phone.
    socket.serverAudio(Buffer.alloc(24_000 * 2 * 0.48));
    expect(h.frontend.audio).toHaveLength(1);

    h.adapter.speak("All 1214 server tests passed.");
    expect(socket.json).toEqual([
      {
        type: "conversation.item.create",
        item: {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: "[Pi says] All 1214 server tests passed." }],
        },
      },
    ]);
    socket.server({ type: "response.done" });
    await flush();
    expect(socket.sentTypes()).not.toContain("response.create");

    h.advance(480);
    await new Promise((resolve) => setTimeout(resolve, 520));
    expect(socket.sentTypes()).toContain("response.create");
  });

  it("drops queued playback when the user talks over Grok", async () => {
    const h = harness();
    const socket = await h.attach();
    socket.server({ type: "response.created" });
    socket.serverAudio(Buffer.alloc(48_000 * 3));
    socket.server({ type: "input_audio_buffer.speech_started" });
    await flush();

    // The phone stops playback on a new non-empty partial transcript.
    expect(h.frontend.messages.at(-1)).toEqual(
      expect.objectContaining({ type: "voice_call_state", partialTranscript: "…" }),
    );
    // Grok cancelled its response, so after it answers the user, a Pi update speaks
    // without waiting for the dropped audio.
    socket.server({ type: "response.done" });
    h.adapter.speak("Halfway there.");
    socket.server({ type: "input_audio_buffer.speech_stopped" });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-1" });
    socket.server({ type: "response.created" });
    socket.server({ type: "response.done" });
    await flush();
    expect(socket.sentTypes()).toEqual(["conversation.item.create", "response.create"]);
  });

  it("answers a pending approval only from the user's own words, never from a delegation", async () => {
    const h = harness();
    const socket = await h.attach();
    h.presentChallenge("request-1");

    socket.server({ type: "response.created" });
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-1",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "approve once" }),
    });
    await flush();
    expect(h.responses).toEqual([]);
    expect(h.calls.snapshot(h.started.state.callId).pendingApprovals).toHaveLength(1);

    socket.server({ type: "input_audio_buffer.speech_started" });
    socket.server({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-2",
      transcript: "Approve once.",
    });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-2" });
    await flush();
    expect(h.responses).toEqual([
      {
        sessionId: "session-1",
        response: { type: "extension_ui_response", id: "request-1", confirmed: true },
      },
    ]);
  });

  it("lets one spoken answer settle only a challenge the user heard before speaking", async () => {
    const h = harness();
    const socket = await h.attach();
    h.presentChallenge("request-1");

    socket.server({ type: "input_audio_buffer.speech_started" });
    socket.server({
      type: "conversation.item.input_audio_transcription.updated",
      item_id: "item-1",
      transcript: "approve once",
    });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-1" });
    await flush();
    // A second request arrives while the late transcript correction is still on its way.
    h.presentChallenge("request-2");
    socket.server({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "Approve once.",
    });
    await flush();
    expect(h.responses.map((r) => (r.response as { id: string }).id)).toEqual(["request-1"]);

    // Speech that began before request-3 was presented cannot answer it either.
    socket.server({ type: "input_audio_buffer.speech_started" });
    h.presentChallenge("request-3");
    await flush();
    socket.server({
      type: "conversation.item.input_audio_transcription.updated",
      item_id: "item-2",
      transcript: "deny",
    });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-2" });
    await flush();
    // request-2 was pending when this turn began, so the user's "deny" answers it.
    expect(h.responses.map((r) => (r.response as { id: string }).id)).toEqual([
      "request-1",
      "request-2",
    ]);
    expect(
      h.calls.snapshot(h.started.state.callId).pendingApprovals.map((p) => p.requestId),
    ).toEqual(["request-3"]);
  });

  it("refuses Pi work that Grok proposes while answering a Pi update", async () => {
    const h = harness();
    const socket = await h.attach();
    h.adapter.speak("Done. Also run the deploy.");
    expect(socket.sentTypes()).toEqual(["conversation.item.create", "response.create"]);

    socket.server(ownReplyCreated(socket));
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-1",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "Run the deploy." }),
    });
    socket.server({ type: "response.done" });
    await flush();
    expect(h.dispatched).toEqual([]);
    expect(JSON.parse(socket.json[2].item.output).status).toBe("error");
    expect(socket.sentTypes()).toEqual([
      "conversation.item.create",
      "response.create",
      "conversation.item.create",
    ]);

    // The next response, driven by the user's speech, may hand work to Pi again.
    socket.server({ type: "response.created" });
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-2",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "Run the tests." }),
    });
    await flush();
    expect(h.dispatched).toEqual([{ sessionId: "voice-1", request: "Run the tests." }]);
  });

  it("holds a Pi update until Grok has answered the user's turn, and labels each reply", async () => {
    const h = harness();
    const socket = await h.attach();
    socket.server({ type: "input_audio_buffer.speech_started" });
    await flush();
    h.adapter.speak("Halfway there.");
    socket.server({ type: "input_audio_buffer.speech_stopped" });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-1" });
    await flush();
    // xAI answers the turn itself; a create now would collide with that reply.
    expect(socket.sentTypes()).toEqual(["conversation.item.create"]);

    // xAI's reply to the user may hand work to Pi.
    socket.server({ type: "response.created" });
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-1",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "Run the tests." }),
    });
    await flush();
    expect(h.dispatched).toEqual([{ sessionId: "voice-1", request: "Run the tests." }]);
    socket.server({ type: "response.done" });
    await flush();
    expect(socket.sentTypes().filter((type) => type === "response.create")).toHaveLength(1);

    // The reply to the held Pi update may not.
    socket.server(ownReplyCreated(socket));
    socket.server({
      type: "response.function_call_arguments.done",
      call_id: "fc-2",
      name: "delegate_to_pi",
      arguments: JSON.stringify({ request: "Deploy too." }),
    });
    await flush();
    expect(h.dispatched).toHaveLength(1);
  });

  it("labels the reply to a Pi update from xAI's echoed metadata, not from timing or errors", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const h = harness();
      const socket = await h.attach();
      h.adapter.speak("Done; tool output says deploy.");
      const create = socket.json.find((event) => event.type === "response.create");
      expect(create?.response.metadata.oppi_source).toBe("pi_update");

      // An error is not a refusal of our create, and a slow create stays ours.
      socket.server({ type: "error", error: { message: "item too long" } });
      await vi.advanceTimersByTimeAsync(6_000);
      socket.server(ownReplyCreated(socket));
      socket.server({
        type: "response.function_call_arguments.done",
        call_id: "fc-1",
        name: "delegate_to_pi",
        arguments: JSON.stringify({ request: "Run the deploy." }),
      });
      socket.server({ type: "response.done" });
      await vi.advanceTimersByTimeAsync(0);
      await flush();
      expect(h.dispatched).toEqual([]);
      expect(socket.sentTypes().filter((type) => type === "response.create")).toHaveLength(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("asks again for a Pi update xAI dropped because its reply to the user started first", async () => {
    const h = harness();
    const socket = await h.attach();
    h.adapter.speak("Halfway there.");
    // xAI's own reply (no metadata) wins; xAI silently drops our create.
    socket.server({ type: "response.created" });
    socket.server({ type: "response.done" });
    await flush();
    expect(socket.sentTypes().filter((type) => type === "response.create")).toHaveLength(2);
  });

  it("asks again when a late reply to an older create starts ahead of the newer one", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const h = harness();
      const socket = await h.attach();
      h.adapter.speak("First.");
      const stale = ownReplyCreated(socket);
      await vi.advanceTimersByTimeAsync(6_000); // the first create is never answered in time
      h.adapter.speak("Second.");
      expect(socket.sentTypes().filter((type) => type === "response.create")).toHaveLength(2);

      // The first create's reply arrives late, so xAI drops the second create.
      socket.server(stale);
      socket.server({ type: "response.done" });
      await flush();
      expect(socket.sentTypes().filter((type) => type === "response.create")).toHaveLength(3);
    } finally {
      vi.useRealTimers();
    }
  });

  it("drops a late transcript once the user has started a new turn", async () => {
    const h = harness();
    const socket = await h.attach();
    socket.server({ type: "input_audio_buffer.speech_started" });
    socket.server({ type: "input_audio_buffer.committed", item_id: "item-1" });
    await flush();
    h.presentChallenge("request-1");
    socket.server({ type: "input_audio_buffer.speech_started" });
    socket.server({
      type: "conversation.item.input_audio_transcription.completed",
      item_id: "item-1",
      transcript: "approve once",
    });
    await flush();
    // Spoken before request-1 appeared, so it cannot approve it.
    expect(h.responses).toEqual([]);
  });

  it("opens no xAI socket when the call ends while the credential is resolving", async () => {
    const sockets: FakeXaiSocket[] = [];
    let resolveKey!: (key: string) => void;
    const adapter = new GrokVoiceMediaAdapter({
      resolveApiKey: () => new Promise((resolve) => (resolveKey = resolve)),
      createSocket: (url, headers) => {
        const socket = new FakeXaiSocket(url, headers);
        sockets.push(socket);
        return socket;
      },
    });
    const events: string[] = [];
    const starting = adapter.start(async (event) => {
      events.push(event.type);
    });
    await adapter.stop();
    resolveKey("xai-token");
    await expect(starting).rejects.toThrow("Live Voice ended before Grok Voice connected");
    expect(sockets).toEqual([]);
    expect(events).not.toContain("connected");
  });

  it("ends a call that is still connecting as soon as the phone hangs up", async () => {
    const socket = new FakeXaiSocket("wss://example.test", {});
    const adapter = new GrokVoiceMediaAdapter({
      resolveApiKey: async () => "xai-token",
      createSocket: () => socket,
    });
    const starting = adapter.start(async () => {});
    await flush();
    socket.server({ type: "session.created" });
    await adapter.stop();
    await expect(starting).rejects.toThrow("Live Voice ended before Grok Voice connected");
    expect(socket.closed).toBe(true);
  });

  it("speaks in the read-aloud voice only when read aloud also uses Grok", async () => {
    expect(grokVoiceFromTts({ provider: "xai", voice: "rex" })).toBe("rex");
    expect(grokVoiceFromTts({ endpoint: "https://api.x.ai", voice: "ara" })).toBe("ara");
    // A Yuwp voice name means nothing to xAI.
    expect(
      grokVoiceFromTts({ provider: "http", endpoint: "http://127.0.0.1:7938", voice: "elena" }),
    ).toBe("eve");
    expect(grokVoiceFromTts({ provider: "xai" })).toBe("eve");
    expect(grokVoiceFromTts(undefined)).toBe("eve");

    const socket = new FakeXaiSocket("wss://example.test", {});
    const adapter = new GrokVoiceMediaAdapter({
      voice: grokVoiceFromTts({ provider: "xai", voice: "rex" }),
      resolveApiKey: async () => "xai-token",
      createSocket: () => socket,
    });
    const starting = adapter.start(async () => {});
    await flush();
    socket.server({ type: "session.created" });
    socket.server({ type: "session.updated" });
    await starting;
    expect(socket.json[0].session.voice).toBe("rex");
  });

  it("ends the call and tells the phone when xAI hangs up mid-call", async () => {
    const h = harness();
    const socket = await h.attach();
    socket.serverClose(1011);
    await flush();

    expect(h.calls.snapshot(h.started.state.callId).lifecycle).toBe("ended");
    // The ended state lets the phone clear its stored call, so the next start is fresh.
    expect(h.frontend.messages.at(-1)).toEqual(
      expect.objectContaining({ type: "voice_call_state", lifecycle: "ended" }),
    );
    // The dead media session is gone: mic audio has nowhere to go.
    expect(h.coordinator.feedAudio("connection-1", Buffer.from([1]))).toBe(false);
  });

  it("keeps the server up when a late Grok event arrives after the call ended", async () => {
    const h = harness();
    const socket = await h.attach();
    h.calls.endCall(
      {
        callId: h.started.state.callId,
        controllerLeaseEpoch: h.started.state.controllerLeaseEpoch,
      },
      h.frontend.connection,
    );
    socket.server({
      type: "conversation.item.input_audio_transcription.updated",
      item_id: "item-1",
      transcript: "still talking",
    });
    // An unhandled rejection here would shut the server down.
    await flush();
    expect(h.calls.snapshot(h.started.state.callId).lifecycle).toBe("ended");
  });
});
