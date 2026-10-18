import { randomUUID } from "node:crypto";

import type { VoiceCallController, VoiceCallFrontendConnection } from "./continuous-voice-call.js";
import type {
  VoiceFrontend,
  VoiceFrontendEventHandler,
  VoiceFrontendSemanticEvent,
  VoiceDelegationUpdate,
} from "./continuous-voice.js";
import type { SttProvider, SttTranscriptUpdate } from "./stt-provider.js";
import { createLogger } from "./logger.js";
import { parseVoiceApprovalDecision } from "./voice-approval-bridge.js";

const log = createLogger({ base: { component: "voice_media" } });

/**
 * Media adapters speak only semantic frontend events. Local Yuwp and Grok Voice
 * swap here; VoiceCallController stays provider-neutral.
 */
export interface VoiceMediaAdapter extends VoiceFrontend {
  feedAudio?(pcm: Buffer): void;
  setPlaybackSink?(sendAudio: (pcm: Buffer) => void): void;
}

/** Injectable TTS for Live Voice. Not the extension voice_speak / audio_presentation path. */
export interface LiveVoiceTtsPort {
  speak(text: string, signal?: AbortSignal): AsyncIterable<Buffer>;
}

/** Production selector: one adapter per attached call. */
export function selectLiveVoiceMediaAdapter(input: {
  liveVoiceBackend?: string;
  sttEndpoint?: string;
  createStt?: () => SttProvider;
  tts?: LiveVoiceTtsPort;
  createGrokVoice?: () => VoiceMediaAdapter;
}): VoiceMediaAdapter {
  const backend = input.liveVoiceBackend ?? "yuwp";
  if (backend === "grok-voice") {
    if (!input.createGrokVoice) throw new Error("Grok Voice is unavailable");
    return input.createGrokVoice();
  }
  if (backend !== "yuwp") {
    throw new Error(`Unknown Live Voice media backend: ${String(input.liveVoiceBackend)}`);
  }
  if (!input.sttEndpoint || !input.createStt) {
    throw new Error("Live Voice ASR is unavailable");
  }
  return new YuwpVoiceMediaAdapter(input.createStt(), { tts: input.tts });
}

export interface VoiceCallMediaAttachInput {
  callId: string;
  controllerLeaseEpoch: number;
  frontend: VoiceCallFrontendConnection;
}

export class YuwpVoiceMediaAdapter implements VoiceMediaAdapter {
  private handler: VoiceFrontendEventHandler | undefined;
  private lastCommitted = "";
  private lastPartial = "";
  private commitInFlight: Promise<void> | undefined;
  private speaking = false;
  private outputSpeaking = false;
  private speechGeneration = 0;
  private speechAbort: AbortController | undefined;
  private playbackSink: ((pcm: Buffer) => void) | undefined;
  private idleTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly idleCommitMs: number;
  private readonly tts: LiveVoiceTtsPort | undefined;

  constructor(
    private readonly stt: SttProvider,
    options: { idleCommitMs?: number; tts?: LiveVoiceTtsPort } = {},
  ) {
    // Yuwp often keeps text in activeText until a long pause or stop. Commit a
    // stable partial so a mid-call pause can delegate without ending the call.
    this.idleCommitMs = options.idleCommitMs ?? 1_800;
    this.tts = options.tts;
  }

  setPlaybackSink(sendAudio: (pcm: Buffer) => void): void {
    this.playbackSink = sendAudio;
  }

  async start(handler: VoiceFrontendEventHandler): Promise<void> {
    this.handler = handler;
    this.lastCommitted = "";
    this.commitInFlight = undefined;
    this.speaking = false;
    this.stt.onToken((update) => {
      this.handleTranscript(update);
    });
    await this.stt.start();
    await handler({ type: "connected" });
  }

  feedAudio(pcm: Buffer): void {
    this.stt.feedAudio(pcm);
  }

  async publish(update: VoiceDelegationUpdate): Promise<void> {
    const text = update.text.trim();
    if (!text) return;

    const previousAbort = this.speechAbort;
    const generation = ++this.speechGeneration;
    const abort = new AbortController();
    this.speechAbort = abort;
    previousAbort?.abort();

    const handler = this.handler;
    if (this.outputSpeaking) {
      this.outputSpeaking = false;
      if (handler) await handler({ type: "assistant_speech_stopped" });
      if (generation !== this.speechGeneration) return;
    }

    this.outputSpeaking = true;
    if (handler) await handler({ type: "assistant_speech_started" });
    if (generation !== this.speechGeneration) return;

    try {
      if (!this.tts) return;
      for await (const chunk of this.tts.speak(text, abort.signal)) {
        if (generation !== this.speechGeneration || abort.signal.aborted) return;
        if (chunk.length === 0) continue;
        this.playbackSink?.(chunk);
      }
    } catch {
      if (abort.signal.aborted || generation !== this.speechGeneration) return;
    } finally {
      if (generation === this.speechGeneration) {
        this.speechAbort = undefined;
        if (this.outputSpeaking) {
          this.outputSpeaking = false;
          if (handler) await handler({ type: "assistant_speech_stopped" });
        }
      }
    }
  }

  async stop(): Promise<void> {
    this.speechGeneration += 1;
    this.speechAbort?.abort();
    this.speechAbort = undefined;
    if (this.outputSpeaking) {
      this.outputSpeaking = false;
      const speakingHandler = this.handler;
      if (speakingHandler) await speakingHandler({ type: "assistant_speech_stopped" });
    }
    // Yuwp often keeps the whole utterance in activeText until VAD silence or
    // session DELETE. Commit that leftover so End still produces a delegation.
    this.clearIdleCommit();
    const final = await this.stt.stop().catch(() => undefined);
    await this.commitTranscript(final?.committedText || final?.text || this.lastPartial);
    const handler = this.handler;
    this.handler = undefined;
    if (handler) await handler({ type: "disconnected" });
  }

  private handleTranscript(update: SttTranscriptUpdate): void {
    const handler = this.handler;
    if (!handler) return;

    const partial = (update.activeText ?? update.text).trim();
    if (partial) {
      if (!this.speaking) {
        this.speaking = true;
        this.abortAssistantSpeech();
        void handler({ type: "user_speech_started" });
      }
      this.lastPartial = partial;
      void handler({ type: "user_transcript_partial", text: partial });
      this.scheduleIdleCommit();
    }

    void this.commitTranscript(update.committedText ?? "");
  }

  private abortAssistantSpeech(): void {
    // Same generation bump as a newer voice_update: abort TTS and emit stopped.
    if (!this.outputSpeaking && !this.speechAbort) return;
    this.speechGeneration += 1;
    this.speechAbort?.abort();
    this.speechAbort = undefined;
    if (!this.outputSpeaking) return;
    this.outputSpeaking = false;
    const handler = this.handler;
    if (handler) void handler({ type: "assistant_speech_stopped" });
  }

  private scheduleIdleCommit(): void {
    this.clearIdleCommit();
    if (this.idleCommitMs <= 0) return;
    this.idleTimer = setTimeout(() => {
      void this.commitTranscript(this.lastPartial);
    }, this.idleCommitMs);
  }

  private clearIdleCommit(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = undefined;
    }
  }

  private commitTranscript(raw: string): Promise<void> {
    // Token, idle-pause, and leftover/stop can overlap. Queue so one claim
    // of lastCommitted happens per distinct segment.
    if (!raw.trim()) return Promise.resolve();
    const perform = async (): Promise<void> => {
      const handler = this.handler;
      if (!handler) return;
      const next = raw.trim();
      const previous = this.lastCommitted;
      if (!next || next === previous) return;
      const segment = next.startsWith(previous) ? next.slice(previous.length).trim() : next;
      if (!segment) return;
      this.lastCommitted = next;
      if (this.speaking) {
        this.speaking = false;
        void handler({ type: "user_speech_ended" });
      }
      await handler({
        type: "user_utterance_committed",
        utteranceId: randomUUID(),
        text: segment,
      });
    };

    const previous = this.commitInFlight;
    const work = previous ? previous.then(perform, perform) : perform();
    this.commitInFlight = work;
    void work.finally(() => {
      if (this.commitInFlight === work) this.commitInFlight = undefined;
    });
    return work;
  }
}

/** Yuwp HTTP TTS for Live Voice. Does not use the voice_speak extension. */
export class YuwpLiveVoiceTts implements LiveVoiceTtsPort {
  constructor(
    private readonly options: {
      endpoint: string;
      voice?: string;
      fetch?: typeof fetch;
    },
  ) {}

  async *speak(text: string, signal?: AbortSignal): AsyncIterable<Buffer> {
    const endpoint = this.options.endpoint.replace(/\/$/, "");
    const response = await (this.options.fetch ?? fetch)(`${endpoint}/v1/audio/speech/stream`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/x-ndjson" },
      body: JSON.stringify({
        model: "yuwp-tts",
        voice: this.options.voice ?? "elena",
        input: text,
        response_format: "wav",
        stream: true,
      }),
      signal,
    });
    if (!response.ok || !response.body) {
      throw new Error(await response.text().catch(() => "Live Voice TTS is unavailable"));
    }
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let pending = "";
    while (true) {
      if (signal?.aborted) {
        await reader.cancel().catch(() => undefined);
        return;
      }
      const { value, done } = await reader.read();
      if (done) break;
      pending += decoder.decode(value, { stream: true });
      const lines = pending.split("\n");
      pending = lines.pop() ?? "";
      for (const line of lines) {
        const chunk = pcmChunkFromYuwpLine(line);
        if (chunk) yield chunk;
      }
    }
    const tail = pcmChunkFromYuwpLine(pending);
    if (tail) yield tail;
  }
}

function pcmChunkFromYuwpLine(line: string): Buffer | undefined {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  let event: { event?: string; audio?: string; error?: string };
  try {
    event = JSON.parse(trimmed) as { event?: string; audio?: string; error?: string };
  } catch {
    return undefined;
  }
  if (event.event === "error") {
    throw new Error(event.error ?? "TTS stream error");
  }
  if (event.event !== "audio" || !event.audio) return undefined;
  return Buffer.from(event.audio, "base64");
}

export class VoiceCallMediaCoordinator {
  private readonly sessions = new Map<string, MediaSession>();

  constructor(
    private readonly deps: {
      createAdapter: () => VoiceMediaAdapter;
      calls: VoiceCallController;
      nextUtteranceId?: () => string;
      nextDelegationId?: () => string;
    },
  ) {}

  async attach(input: VoiceCallMediaAttachInput): Promise<void> {
    await this.detach(input.frontend.connectionId);
    const adapter = this.deps.createAdapter();
    if (input.frontend.sendAudio) {
      adapter.setPlaybackSink?.(input.frontend.sendAudio);
    }
    const session: MediaSession = {
      callId: input.callId,
      controllerLeaseEpoch: input.controllerLeaseEpoch,
      frontend: input.frontend,
      adapter,
    };
    this.sessions.set(input.frontend.connectionId, session);
    try {
      await adapter.start((event) =>
        this.handleEvent(session, event).catch((error: unknown) => {
          // A Grok delegation reports its failure back to the model as tool output.
          if (event.type === "delegation_requested") throw error;
          // Media events race End and detach; a stale one must not crash the server.
          log.warn("voice_media.event_failed", {
            callId: session.callId,
            eventType: event.type,
            error: error instanceof Error ? error.message : String(error),
          });
        }),
      );
    } catch (error) {
      this.sessions.delete(input.frontend.connectionId);
      throw error;
    }
  }

  feedAudio(connectionId: string, pcm: Buffer): boolean {
    const session = this.sessions.get(connectionId);
    if (!session) return false;
    session.adapter.feedAudio?.(pcm);
    return true;
  }

  async detach(connectionId: string): Promise<void> {
    const session = this.sessions.get(connectionId);
    if (!session) return;
    this.sessions.delete(connectionId);
    try {
      await session.adapter.stop();
    } catch {
      // Adapter shutdown cannot block detach or lease fencing.
    }
  }

  publish(callId: string, update: VoiceDelegationUpdate): Promise<void> {
    for (const session of this.sessions.values()) {
      if (session.callId !== callId) continue;
      return Promise.resolve(session.adapter.publish(update));
    }
    return Promise.resolve();
  }

  private async handleEvent(
    session: MediaSession,
    event: VoiceFrontendSemanticEvent,
  ): Promise<void> {
    switch (event.type) {
      case "user_transcript_partial": {
        const state = this.deps.calls.setPartialTranscript(session.callId, event.text);
        session.frontend.send({ type: "voice_call_state", ...state });
        return;
      }
      case "user_utterance_committed": {
        const request = event.text.trim();
        if (!request) return;
        // A pending voice_approval_required challenge owns the next committed
        // utterance. Exact Stage 1 phrases go to submitApprovalTranscript;
        // anything else fails closed instead of becoming a Pi delegation.
        const pending = this.pendingChallengeId(session);
        if (pending) {
          await this.answerApproval(session, pending, request);
          return;
        }
        this.delegate(session, event.utteranceId, request);
        return;
      }
      case "user_speech_started":
        // Only a challenge the user could have heard before speaking may take this turn.
        session.challengesHeard = new Set(
          this.deps.calls.snapshot(session.callId).pendingApprovals.map((p) => p.challengeId),
        );
        return;
      case "user_transcript_final": {
        // The user's own words can answer a challenge; they never start Pi work.
        const heard = session.challengesHeard;
        session.challengesHeard = undefined; // one answer per turn
        const pending = this.deps.calls
          .snapshot(session.callId)
          .pendingApprovals.find((p) => heard?.has(p.challengeId));
        if (pending) await this.answerApproval(session, pending.challengeId, event.text.trim());
        return;
      }
      case "disconnected": {
        // Our own detach unregisters first; a registered session means the backend hung up.
        const connectionId = session.frontend.connectionId;
        if (this.sessions.get(connectionId) !== session) return;
        this.sessions.delete(connectionId);
        log.warn("voice_media.backend_disconnected", {
          callId: session.callId,
          reason: event.reason,
        });
        // The ended state, like End, clears the phone's stored call so its next start is fresh.
        const state = this.deps.calls.endCall(
          { callId: session.callId, controllerLeaseEpoch: session.controllerLeaseEpoch },
          session.frontend,
        );
        session.frontend.send({ type: "voice_call_state", ...state });
        return;
      }
      case "delegation_requested": {
        // The voice model composed this request, so it is work, never approval evidence.
        const request = event.text.trim();
        if (request) this.delegate(session, event.utteranceId, request);
        return;
      }
      default:
        return;
    }
  }

  private pendingChallengeId(session: MediaSession): string | undefined {
    return this.deps.calls.snapshot(session.callId).pendingApprovals[0]?.challengeId;
  }

  /** Only exact decision phrases reach the approval authority; anything else is dropped. */
  private async answerApproval(
    session: MediaSession,
    challengeId: string,
    transcript: string,
  ): Promise<void> {
    if (!transcript || !parseVoiceApprovalDecision(transcript)) return;
    await this.deps.calls.submitApprovalTranscript(
      {
        callId: session.callId,
        controllerLeaseEpoch: session.controllerLeaseEpoch,
        challengeId,
        transcript,
      },
      session.frontend,
    );
  }

  private delegate(session: MediaSession, utteranceId: string, request: string): void {
    this.deps.calls.commitFrontendUtterance({
      callId: session.callId,
      controllerLeaseEpoch: session.controllerLeaseEpoch,
      frontendConnectionId: session.frontend.connectionId,
      utteranceId: this.deps.nextUtteranceId?.() ?? utteranceId,
      delegationId: this.deps.nextDelegationId?.() ?? randomUUID(),
      request,
    });
  }
}

interface MediaSession {
  callId: string;
  controllerLeaseEpoch: number;
  frontend: VoiceCallFrontendConnection;
  adapter: VoiceMediaAdapter;
  /** Challenges pending when the current user turn began. */
  challengesHeard?: Set<string>;
}
