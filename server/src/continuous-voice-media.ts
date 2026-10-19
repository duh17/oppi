import { randomUUID } from "node:crypto";

import type { VoiceCallController, VoiceCallFrontendConnection } from "./continuous-voice-call.js";
import type {
  VoiceFrontend,
  VoiceFrontendEventHandler,
  VoiceFrontendSemanticEvent,
} from "./continuous-voice.js";
import type { SttProvider, SttTranscriptUpdate } from "./stt-provider.js";
import { createLogger } from "./logger.js";
import { startSpeech, type SpeechDeps, type TtsConfig } from "./speech-synthesis.js";
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

/** The phone plays Live Voice audio as 16-bit mono PCM at this rate, whatever the backend. */
export const LIVE_VOICE_PLAYBACK_SAMPLE_RATE = 24_000;

/**
 * Injectable TTS for Live Voice. Not the extension voice_speak / audio_presentation path.
 * Yields 16-bit mono PCM at LIVE_VOICE_PLAYBACK_SAMPLE_RATE.
 */
export interface LiveVoiceTtsPort {
  speak(text: string, signal: AbortSignal): AsyncIterable<Buffer>;
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

/**
 * Local Live Voice: streaming ASR in, read-aloud TTS out, the session's agent does the work.
 *
 * A user turn ends at a pause, not at an ASR commit. Streaming ASR (Yuwp R2T2)
 * locks in text every few hundred milliseconds, so a commit is a stable prefix,
 * not the end of what the user is saying. The transcript is cumulative for the
 * call; a turn is the words after the ones already sent to the session.
 */
export class YuwpVoiceMediaAdapter implements VoiceMediaAdapter {
  private handler: VoiceFrontendEventHandler | undefined;
  /** The call's whole transcript as last heard. */
  private transcript = "";
  /** Speech units of `transcript` already handed to Pi (see `speechUnits`). */
  private delegatedUnits = 0;
  private lastTurnText = "";
  private commitInFlight: Promise<void> | undefined;
  private speaking = false;
  private outputSpeaking = false;
  /** Bumped by barge-in and stop; queued speech from an older generation is dropped. */
  private speechGeneration = 0;
  private speechAbort: AbortController | undefined;
  private speechQueue: Promise<void> = Promise.resolve();
  private playbackSink: ((pcm: Buffer) => void) | undefined;
  private turnEndTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly turnEndPauseMs: number;
  private readonly tts: LiveVoiceTtsPort | undefined;

  constructor(
    private readonly stt: SttProvider,
    options: { turnEndPauseMs?: number; tts?: LiveVoiceTtsPort } = {},
  ) {
    this.turnEndPauseMs = options.turnEndPauseMs ?? 1_800;
    this.tts = options.tts;
  }

  setPlaybackSink(sendAudio: (pcm: Buffer) => void): void {
    this.playbackSink = sendAudio;
  }

  async start(handler: VoiceFrontendEventHandler): Promise<void> {
    this.handler = handler;
    this.stt.onToken((update) => {
      this.handleTranscript(update);
    });
    await this.stt.start();
    await handler({ type: "connected" });
  }

  feedAudio(pcm: Buffer): void {
    this.stt.feedAudio(pcm);
  }

  /** The agent's words are said in order; newer ones wait for the one playing instead of cutting it off. */
  speak(raw: string): Promise<void> {
    const text = raw.trim();
    if (!text) return Promise.resolve();
    const generation = this.speechGeneration;
    const run = (): Promise<void> => this.say(text, generation);
    const work = this.speechQueue.then(run, run);
    this.speechQueue = work.catch(() => undefined);
    return work;
  }

  async stop(): Promise<void> {
    this.cancelAssistantSpeech();
    // End can arrive mid-sentence; hand Pi whatever the user said since the last turn.
    this.clearTurnEnd();
    const final = await this.stt.stop().catch(() => undefined);
    if (final?.text.trim()) this.transcript = final.text.trim();
    await this.commitTurn();
    const handler = this.handler;
    this.handler = undefined;
    if (handler) await handler({ type: "disconnected" });
  }

  private async say(text: string, generation: number): Promise<void> {
    if (generation !== this.speechGeneration) return;
    const abort = new AbortController();
    this.speechAbort = abort;
    this.outputSpeaking = true;
    const handler = this.handler;
    if (handler) await handler({ type: "assistant_speech_started" });
    try {
      if (!this.tts || abort.signal.aborted) return;
      for await (const chunk of this.tts.speak(text, abort.signal)) {
        if (abort.signal.aborted) return;
        if (chunk.length > 0) this.playbackSink?.(chunk);
      }
    } catch (error) {
      if (!abort.signal.aborted) {
        log.warn("voice_media.tts_failed", {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    } finally {
      // A barge-in already reported the stop and cleared speechAbort.
      if (this.speechAbort === abort) {
        this.speechAbort = undefined;
        this.outputSpeaking = false;
        if (handler) await handler({ type: "assistant_speech_stopped" });
      }
    }
  }

  private handleTranscript(update: SttTranscriptUpdate): void {
    const handler = this.handler;
    if (!handler) return;
    // A recreated ASR session (Yuwp restart, or a long mute outlasting its idle
    // timeout) starts its transcript over; count handed-off units from zero.
    if (update.transcriptRestarted) {
      this.delegatedUnits = 0;
      this.lastTurnText = "";
    }
    this.transcript = update.text.trim();
    const turn = this.pendingTurnText();
    // Repeats of the same text are not new speech and must not push the turn end back.
    if (!turn || turn === this.lastTurnText) return;
    this.lastTurnText = turn;
    if (!this.speaking) {
      this.speaking = true;
      this.cancelAssistantSpeech();
      void handler({ type: "user_speech_started" });
    }
    void handler({ type: "user_transcript_partial", text: turn });
    this.scheduleTurnEnd();
  }

  private pendingTurnText(): string {
    const next = speechUnits(this.transcript)[this.delegatedUnits];
    return next ? this.transcript.slice(next.index).trim() : "";
  }

  /** Barge-in and End: stop the sentence playing and drop queued ones. */
  private cancelAssistantSpeech(): void {
    this.speechGeneration += 1;
    const abort = this.speechAbort;
    if (!abort) return;
    this.speechAbort = undefined;
    abort.abort();
    this.outputSpeaking = false;
    const handler = this.handler;
    if (handler) void handler({ type: "assistant_speech_stopped" });
  }

  private scheduleTurnEnd(): void {
    this.clearTurnEnd();
    this.turnEndTimer = setTimeout(() => {
      this.turnEndTimer = undefined;
      void this.commitTurn();
    }, this.turnEndPauseMs);
  }

  private clearTurnEnd(): void {
    if (this.turnEndTimer) {
      clearTimeout(this.turnEndTimer);
      this.turnEndTimer = undefined;
    }
  }

  private commitTurn(): Promise<void> {
    // A pause and End can overlap. Chain them so each word is handed to Pi once.
    const perform = async (): Promise<void> => {
      const handler = this.handler;
      if (!handler) return;
      const turn = this.pendingTurnText();
      if (!turn) return;
      this.delegatedUnits = speechUnits(this.transcript).length;
      this.lastTurnText = "";
      if (this.speaking) {
        this.speaking = false;
        void handler({ type: "user_speech_ended" });
      }
      await handler({
        type: "user_utterance_committed",
        utteranceId: randomUUID(),
        text: turn,
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

/**
 * What a turn boundary counts in: a word in spaced scripts, a single character in Chinese,
 * Japanese, and Korean (which have no spaces between words). Punctuation does not count,
 * because ASR revises the punctuation and case of earlier text as it hears more.
 */
const SPEECH_UNIT =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]|[^\s\p{P}\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]+/gu;

function speechUnits(text: string): RegExpMatchArray[] {
  return [...text.matchAll(SPEECH_UNIT)];
}

/**
 * Live Voice speaks with the read-aloud engine and voice (`tts` config), converted
 * to the phone's playback format. Not the voice_speak extension.
 */
export class ReadAloudLiveVoiceTts implements LiveVoiceTtsPort {
  constructor(
    private readonly tts: TtsConfig,
    private readonly deps: SpeechDeps = {},
  ) {}

  async *speak(text: string, signal: AbortSignal): AsyncIterable<Buffer> {
    const speech = await startSpeech(this.tts, text, signal, this.deps);
    yield toLiveVoicePcm(speech.first, speech.sampleRate, speech.channels);
    for await (const pcm of speech.rest) {
      yield toLiveVoicePcm(pcm, speech.sampleRate, speech.channels);
    }
  }
}

/** 16-bit PCM at any rate and 1–2 channels to mono at LIVE_VOICE_PLAYBACK_SAMPLE_RATE (linear interpolation). */
export function toLiveVoicePcm(pcm: Buffer, sampleRate: number, channels: number): Buffer {
  const frames = Math.floor(pcm.length / (2 * channels));
  if (sampleRate === LIVE_VOICE_PLAYBACK_SAMPLE_RATE && channels === 1) {
    return pcm.subarray(0, frames * 2);
  }
  const sample = (frame: number): number => {
    let sum = 0;
    for (let channel = 0; channel < channels; channel++) {
      sum += pcm.readInt16LE((frame * channels + channel) * 2);
    }
    return sum / channels;
  };
  const outFrames = Math.floor((frames * LIVE_VOICE_PLAYBACK_SAMPLE_RATE) / sampleRate);
  const out = Buffer.alloc(outFrames * 2);
  const step = sampleRate / LIVE_VOICE_PLAYBACK_SAMPLE_RATE;
  for (let i = 0; i < outFrames; i++) {
    const position = i * step;
    const index = Math.floor(position);
    const fraction = position - index;
    const a = sample(index);
    const b = index + 1 < frames ? sample(index + 1) : a;
    out.writeInt16LE(Math.round(a + (b - a) * fraction), i * 2);
  }
  return out;
}

export class VoiceCallMediaCoordinator {
  private readonly sessions = new Map<string, MediaSession>();

  constructor(
    private readonly deps: {
      createAdapter: () => VoiceMediaAdapter;
      calls: VoiceCallController;
      nextUtteranceId?: () => string;
      nextDelegationId?: () => string;
      /** Calls with media on this session started or stopped: its agent can speak or not. */
      onSessionMediaChanged?: (sessionId: string, attached: boolean) => void;
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
      sessionId: this.deps.calls.snapshot(input.callId).controlSessionId,
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
    this.sessionMediaChanged(session.sessionId);
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
      // Stopping commits what the caller said last, so the session still hears it.
      await session.adapter.stop();
    } catch {
      // Adapter shutdown cannot block detach or lease fencing.
    }
    this.sessionMediaChanged(session.sessionId);
  }

  /** Calls with media running on this session: each one hears what its agent says. */
  callIdsForSession(sessionId: string): string[] {
    const callIds = new Set<string>();
    for (const session of this.sessions.values()) {
      if (session.sessionId === sessionId) callIds.add(session.callId);
    }
    return [...callIds];
  }

  /** Say the agent's words on the call. */
  speak(callId: string, text: string): Promise<void> {
    for (const session of this.sessions.values()) {
      if (session.callId !== callId) continue;
      return Promise.resolve(session.adapter.speak(text));
    }
    return Promise.resolve();
  }

  private sessionMediaChanged(sessionId: string): void {
    const attached = this.callIdsForSession(sessionId).length > 0;
    try {
      this.deps.onSessionMediaChanged?.(sessionId, attached);
    } catch (error) {
      // Attach and detach own sockets and paid backends; the agent side cannot break them.
      log.warn("voice_media.session_media_changed_failed", {
        sessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
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
        this.sessionMediaChanged(session.sessionId);
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
  /** The session the call talks to. */
  sessionId: string;
  controllerLeaseEpoch: number;
  frontend: VoiceCallFrontendConnection;
  adapter: VoiceMediaAdapter;
  /** Challenges pending when the current user turn began. */
  challengesHeard?: Set<string>;
}
