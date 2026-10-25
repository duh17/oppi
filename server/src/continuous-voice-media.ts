import { randomUUID } from "node:crypto";

import type { VoiceCallController, VoiceCallFrontendConnection } from "./continuous-voice-call.js";
import type { SttProvider, SttSpeechState, SttTranscriptUpdate } from "./stt-provider.js";
import { createLogger, type Logger } from "./logger.js";
import { startSpeech, type SpeechDeps, type TtsConfig } from "./speech-synthesis.js";

const log = createLogger({ base: { component: "voice_media" } });

/** What a call's voice backend reports while it runs. */
export type VoiceMediaEvent =
  | { type: "disconnected"; reason?: string }
  | { type: "user_transcript_partial"; text: string }
  /** A finished user turn that the backend's turn policy sends to the session (local ASR). */
  | { type: "user_utterance_committed"; utteranceId: string; text: string }
  /** The voice model passed this request to the session (Grok Voice). */
  | { type: "delegation_requested"; utteranceId: string; text: string };

export type VoiceMediaEventHandler = (event: VoiceMediaEvent) => void | Promise<void>;

/**
 * A call's voice: hears the caller and says what the session's agent speaks. Local Yuwp and
 * Grok Voice swap here; VoiceCallController stays provider-neutral.
 */
export interface VoiceMediaAdapter {
  start(handler: VoiceMediaEventHandler): void | Promise<void>;
  /**
   * Say the agent's words to the caller, after anything already being said. With
   * `streamsReplies`, `replyId` marks one sentence of a reply still being written; once the
   * caller speaks over that reply, its later sentences are not said.
   */
  speak(text: string, replyId?: string): void | Promise<void>;
  /** Says replies sentence by sentence as they are written; otherwise each is said whole. */
  readonly streamsReplies?: boolean;
  stop(): void | Promise<void>;
  feedAudio?(pcm: Buffer): void;
  setPlaybackSink?(sendAudio: (pcm: Buffer) => void): void;
  /**
   * The phone heard the caller over the agent and already stopped playback: stop sending
   * the reply being said and anything queued behind it, before returning. True when there
   * was something to drop. Turn-taking stays the backend's own.
   */
  bargeIn?(): boolean;
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
  /** The call this adapter serves; local-route telemetry is tagged with it. */
  callId?: string;
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
  return new YuwpVoiceMediaAdapter(input.createStt(), { tts: input.tts, callId: input.callId });
}

export interface VoiceCallMediaAttachInput {
  callId: string;
  controllerLeaseEpoch: number;
  frontend: VoiceCallFrontendConnection;
}

/** Trailing silence after which a Live Voice call asks the ASR backend to mark speech ended. */
export const LIVE_VOICE_ENDPOINTING_MS = 700;
/** Silence after which a turn that already ends a sentence is handed over without waiting for endpointing. */
const SENTENCE_END_SILENCE_MS = 450;
/**
 * Silence after which an unfinished-looking turn is handed over anyway. The backend's end of
 * speech also fires on mid-sentence pauses, so it ends only turns that read as finished.
 */
const UNFINISHED_SILENCE_MS = 1_200;
const SENTENCE_END = /[。？！?.!]$/;
/** Playback is 16-bit mono PCM, so this many bytes make a millisecond of audio. */
const PLAYBACK_BYTES_PER_MS = (LIVE_VOICE_PLAYBACK_SAMPLE_RATE * 2) / 1_000;
/**
 * Consecutive speaking reports that interrupt the assistant. Yuwp reports speech state with
 * every feed (~200 ms), so two in a row normally mean the detector still hears speech one feed
 * later, roughly 200-400 ms of speech rather than a blip (cough, click). It is a heuristic,
 * not a guarantee: a feed too short for a new detector chunk (0.16 s at current settings)
 * repeats the last state, so the floor is about one chunk. A third report would spend another
 * ~200 ms of the ~0.5-0.7 s this saves over waiting for text (measured: speech_active
 * ~400 ms after onset, first text ~1160 ms).
 */
const BARGE_IN_SPEAKING_REPORTS = 2;

/** Why a user turn was handed to the session. Telemetry only; never carries what was said. */
type TurnEndReason =
  /** The backend's end of speech, on a turn that ends a sentence. */
  | "speech_final"
  /** Enough trailing silence after a turn that ends a sentence. */
  | "sentence_end_silence"
  /** Long trailing silence after a turn that does not read as finished. */
  | "unfinished_silence"
  /** Nothing new arrived for `turnEndPauseMs`. */
  | "watchdog"
  /** The call ended with words not yet handed over. */
  | "call_stop";

/**
 * Counters for one local call, logged once as `voice_media.call_summary`. Counts, durations,
 * and reasons only.
 */
interface CallStats {
  startedAt: number;
  turns: number;
  endReasons: Partial<Record<TurnEndReason, number>>;
  bargeIns: number;
  /** Of `bargeIns`, the ones the phone heard first (`voice_call_barge_in`). */
  localBargeIns: number;
  ttsItems: number;
  ttsAborted: number;
  ttsFailures: number;
  firstAudioMs: number[];
  turnToVoiceMs: number[];
  asrRestarts: number;
}

/** Nearest-rank percentile of `values`; undefined when empty. */
function percentile(values: readonly number[], fraction: number): number | undefined {
  if (values.length === 0) return undefined;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

/**
 * Local Live Voice: streaming ASR in, read-aloud TTS out, the session's agent does the work.
 *
 * A user turn ends at a pause, not at an ASR commit. Streaming ASR (Yuwp R2T2)
 * locks in text every few hundred milliseconds, so a commit is a stable prefix,
 * not the end of what the user is saying. The transcript is cumulative for the
 * call; a turn is the words after the ones already sent to the session.
 *
 * When the backend reports speech state (endpointing), the audio decides the pause: a
 * turn that ends a sentence is handed over at the backend's end of speech or after a short
 * silence; one that does not waits for a longer silence, since people pause mid-sentence.
 * Either way, a turn ends once nothing new (text or speech state) has arrived for
 * `turnEndPauseMs`: while the user talks, reports arrive with every feed and keep it from
 * firing, and when they stop (mute, a stalled upload, a backend error) the turn still ends.
 * Without endpointing that is the only rule, and it can fire mid-sentence when recognition
 * lags.
 *
 * The user can talk over the assistant: sustained speaking reports (or, failing that, the
 * first new words) stop the sentence playing, drop queued ones, and tell the phone to drop
 * the audio it has buffered.
 */
export class YuwpVoiceMediaAdapter implements VoiceMediaAdapter {
  readonly streamsReplies = true;
  private handler: VoiceMediaEventHandler | undefined;
  /** The call's whole transcript as last heard. */
  private transcript = "";
  /** Speech units of `transcript` already handed to Pi (see `speechUnits`). */
  private delegatedUnits = 0;
  private lastTurnText = "";
  private commitInFlight: Promise<void> | undefined;
  private speaking = false;
  /** Bumped by barge-in and stop; queued speech from an older generation is dropped. */
  private speechGeneration = 0;
  private speechAbort: AbortController | undefined;
  private speechQueue: Promise<void> = Promise.resolve();
  /** The reply whose sentences are arriving, and the speech generation its first one found. */
  private reply: { id: string; generation: number } | undefined;
  private playbackSink: ((pcm: Buffer) => void) | undefined;
  private turnEndTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly turnEndPauseMs: number;
  private readonly tts: LiveVoiceTtsPort | undefined;
  private readonly now: () => number;
  private readonly log: Logger;
  private readonly stats: CallStats;
  private summarized = false;
  /** When the user's pending turn first showed text; unset between turns. */
  private turnStartedAt: number | undefined;
  /** The ASR transcript restarted while the pending turn was being said. */
  private turnRestarted = false;
  /** Trailing silence in the backend's latest speech report; unset before one and after a commit. */
  private lastTrailingSilenceMs: number | undefined;
  /** When the newest turn was committed and no assistant audio has reached the phone since. */
  private awaitingVoiceSince: number | undefined;
  /** Assistant speech queued or playing since the last barge-in: items, first queued, audio sent. */
  private queuedSpeechItems = 0;
  private speechQueuedSince: number | undefined;
  private speechAudioBytes = 0;
  /**
   * When the phone should finish playing what was sent. TTS runs faster than real time, so
   * the phone keeps playing buffered audio long after the queue has drained.
   */
  private playbackEndsAt = 0;
  /** Speaking reports in a row since the last silent one. */
  private speakingReports = 0;
  /** The "…" barge-in placeholder is the visible partial; real turn text or a clear replaces it. */
  private placeholderShowing = false;

  constructor(
    private readonly stt: SttProvider,
    options: {
      turnEndPauseMs?: number;
      tts?: LiveVoiceTtsPort;
      callId?: string;
      now?: () => number;
    } = {},
  ) {
    this.turnEndPauseMs = options.turnEndPauseMs ?? 1_800;
    this.tts = options.tts;
    this.now = options.now ?? Date.now;
    this.log = log.child({ callId: options.callId });
    this.stats = {
      startedAt: this.now(),
      turns: 0,
      endReasons: {},
      bargeIns: 0,
      localBargeIns: 0,
      ttsItems: 0,
      ttsAborted: 0,
      ttsFailures: 0,
      firstAudioMs: [],
      turnToVoiceMs: [],
      asrRestarts: 0,
    };
  }

  setPlaybackSink(sendAudio: (pcm: Buffer) => void): void {
    this.playbackSink = sendAudio;
  }

  async start(handler: VoiceMediaEventHandler): Promise<void> {
    this.handler = handler;
    this.stats.startedAt = this.now();
    this.stt.onToken((update) => {
      this.handleTranscript(update);
    });
    this.stt.onSpeechState?.((state) => {
      this.handleSpeechState(state);
    });
    await this.stt.start();
  }

  feedAudio(pcm: Buffer): void {
    this.stt.feedAudio(pcm);
  }

  /** The agent's words are said in order; newer ones wait for the one playing instead of cutting it off. */
  speak(raw: string, replyId?: string): Promise<void> {
    const text = raw.trim();
    if (!text) return Promise.resolve();
    const generation = this.speechGeneration;
    if (replyId !== undefined) {
      if (this.reply?.id !== replyId) this.reply = { id: replyId, generation };
      // The caller spoke over this reply: the rest of it stays unsaid.
      else if (this.reply.generation !== generation) return Promise.resolve();
    }
    const queuedAt = this.now();
    this.queuedSpeechItems += 1;
    this.speechQueuedSince ??= queuedAt;
    const run = (): Promise<void> => this.say(text, generation, queuedAt);
    const work = this.speechQueue.then(run, run);
    this.speechQueue = work.catch(() => undefined);
    return work;
  }

  /**
   * The phone heard the caller first. Like the speech detector's barge-in, it counts while
   * speech is queued or the phone may still be playing what was sent (it just stopped). The
   * cancel ends both, so the detector or transcript barge-in for the same speech finds
   * nothing left, and this is a no-op after theirs.
   */
  bargeIn(): boolean {
    if (this.queuedSpeechItems === 0 && this.now() >= this.playbackEndsAt) return false;
    this.logBargeIn("local");
    this.cancelAssistantSpeech();
    return true;
  }

  async stop(): Promise<void> {
    this.cancelAssistantSpeech();
    // End can arrive mid-sentence; hand Pi whatever the user said since the last turn.
    this.clearTurnEnd();
    const final = await this.stt.stop().catch(() => undefined);
    if (final?.text.trim()) this.transcript = final.text.trim();
    await this.commitTurn("call_stop");
    this.logCallSummary();
    const handler = this.handler;
    this.handler = undefined;
    if (handler) await handler({ type: "disconnected" });
  }

  private async say(text: string, generation: number, queuedAt: number): Promise<void> {
    const abort = new AbortController();
    const startedAt = this.now();
    let firstAudioMs: number | undefined;
    let outcome: "completed" | "aborted" | "failed" = "completed";
    try {
      if (generation !== this.speechGeneration) {
        outcome = "aborted";
        return;
      }
      this.speechAbort = abort;
      if (!this.tts) return;
      for await (const chunk of this.tts.speak(text, abort.signal)) {
        if (abort.signal.aborted) {
          outcome = "aborted";
          return;
        }
        if (chunk.length === 0) continue;
        firstAudioMs ??= this.now() - startedAt;
        if (this.playbackSink) {
          this.playbackEndsAt =
            Math.max(this.playbackEndsAt, this.now()) + chunk.length / PLAYBACK_BYTES_PER_MS;
          this.playbackSink(chunk);
          this.speechAudioBytes += chunk.length;
          this.noteVoiceStarted();
        }
      }
      if (abort.signal.aborted) outcome = "aborted";
    } catch (error) {
      if (abort.signal.aborted) {
        outcome = "aborted";
      } else {
        outcome = "failed";
        this.log.warn("voice_media.tts_failed", {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    } finally {
      // A barge-in already cleared speechAbort and the queue counters.
      if (this.speechAbort === abort) this.speechAbort = undefined;
      if (generation === this.speechGeneration) {
        this.queuedSpeechItems = Math.max(0, this.queuedSpeechItems - 1);
        if (this.queuedSpeechItems === 0) this.endSpeechRun();
      }
      if (this.tts) this.logTtsItem(text.length, outcome, queuedAt, startedAt, firstAudioMs);
    }
  }

  /** The queue drained: the next item starts a fresh run for barge-in's "how long". */
  private endSpeechRun(): void {
    this.speechQueuedSince = undefined;
    this.speechAudioBytes = 0;
  }

  private logTtsItem(
    chars: number,
    outcome: "completed" | "aborted" | "failed",
    queuedAt: number,
    startedAt: number,
    firstAudioMs: number | undefined,
  ): void {
    const stats = this.stats;
    stats.ttsItems += 1;
    if (outcome === "aborted") stats.ttsAborted += 1;
    if (outcome === "failed") stats.ttsFailures += 1;
    if (firstAudioMs !== undefined) stats.firstAudioMs.push(firstAudioMs);
    this.log.info("voice_media.tts_item", {
      outcome,
      chars,
      queuedMs: startedAt - queuedAt,
      firstAudioMs,
      totalMs: this.now() - startedAt,
    });
  }

  /** The first assistant audio after a committed turn reaches the phone: the reply's latency. */
  private noteVoiceStarted(): void {
    const since = this.awaitingVoiceSince;
    if (since === undefined) return;
    this.awaitingVoiceSince = undefined;
    const latencyMs = this.now() - since;
    this.stats.turnToVoiceMs.push(latencyMs);
    this.log.info("voice_media.turn_to_voice", { latencyMs });
  }

  /**
   * The user spoke over the assistant: log how long it had been speaking or queued, and how
   * much audio the phone still had to play. TTS outruns playback, so most barge-ins land
   * after the queue drained, while the phone is still playing. `source` says who noticed:
   * this adapter's transcript, its speech detector (`vad`), or the phone's own mic (`local`).
   * Every path cancels, which drains the queue and ends playback, so the second path to hear
   * the same speech logs nothing.
   */
  private logBargeIn(source: "transcript" | "vad" | "local" = "transcript"): void {
    const now = this.now();
    const playbackRemainingMs = Math.max(0, Math.round(this.playbackEndsAt - now));
    if (this.queuedSpeechItems === 0 && playbackRemainingMs === 0) return;
    this.stats.bargeIns += 1;
    if (source === "local") this.stats.localBargeIns += 1;
    this.log.info("voice_media.barge_in", {
      source,
      assistantActiveMs:
        this.speechQueuedSince === undefined ? undefined : now - this.speechQueuedSince,
      queuedItems: this.queuedSpeechItems,
      audioSentMs: Math.round(this.speechAudioBytes / PLAYBACK_BYTES_PER_MS),
      playbackRemainingMs,
    });
  }

  private logCallSummary(): void {
    if (this.summarized) return;
    this.summarized = true;
    const st = this.stats;
    this.log.info("voice_media.call_summary", {
      ended: "stop",
      durationMs: this.now() - st.startedAt,
      turns: st.turns,
      endReasons: st.endReasons,
      bargeIns: st.bargeIns,
      localBargeIns: st.localBargeIns,
      ttsItems: st.ttsItems,
      ttsAborted: st.ttsAborted,
      ttsFailures: st.ttsFailures,
      asrRestarts: st.asrRestarts,
      firstAudioP50Ms: percentile(st.firstAudioMs, 0.5),
      firstAudioMaxMs: percentile(st.firstAudioMs, 1),
      turnToVoiceP50Ms: percentile(st.turnToVoiceMs, 0.5),
      turnToVoiceMaxMs: percentile(st.turnToVoiceMs, 1),
    });
  }

  private handleTranscript(update: SttTranscriptUpdate): void {
    const handler = this.handler;
    if (!handler) return;
    // A recreated ASR session (Yuwp restart, or a long mute outlasting its idle
    // timeout) starts its transcript over; count handed-off units from zero.
    if (update.transcriptRestarted) {
      this.delegatedUnits = 0;
      this.lastTurnText = "";
      this.turnRestarted = true;
      this.stats.asrRestarts += 1;
    }
    this.transcript = update.text.trim();
    const turn = this.pendingTurnText();
    // Repeats of the same text are not new speech and must not push the turn end back.
    if (!turn || turn === this.lastTurnText) return;
    this.lastTurnText = turn;
    this.placeholderShowing = false;
    this.turnStartedAt ??= this.now();
    if (!this.speaking) {
      this.speaking = true;
      this.logBargeIn();
      this.cancelAssistantSpeech();
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
    this.queuedSpeechItems = 0;
    this.endSpeechRun();
    // The phone drops what it buffered when the partial changes (or the call ends).
    this.playbackEndsAt = this.now();
    const abort = this.speechAbort;
    if (!abort) return;
    this.speechAbort = undefined;
    abort.abort();
  }

  /**
   * Sustained speech while the assistant is audible or about to be: still generating, or the
   * phone may still be playing what was sent. Otherwise an ordinary turn would flash "…".
   */
  private bargeInOnSpeech(): void {
    if (this.queuedSpeechItems === 0 && this.now() >= this.playbackEndsAt) return;
    this.logBargeIn("vad");
    this.cancelAssistantSpeech();
    // A non-empty partial is the phone's barge-in signal (it drops audio already buffered),
    // as with Grok. Words already showing flush the phone on their next change, and "…"
    // would hide them.
    if (this.placeholderShowing || this.pendingTurnText()) return;
    this.placeholderShowing = true;
    // The phone no longer shows the last words; if ASR retracts them and they return, they
    // must count as new.
    this.lastTurnText = "";
    void this.handler?.({ type: "user_transcript_partial", text: "…" });
  }

  private handleSpeechState(state: SttSpeechState): void {
    this.lastTrailingSilenceMs = state.trailingSilenceMs;
    // The speaking run ended without any words (cough, noise), or endpointing was released.
    // Clear the placeholder, or the next barge-in's identical "…" would not flush the phone.
    if (
      this.placeholderShowing &&
      (state.speechFinal || (!state.speechActive && state.trailingSilenceMs === undefined))
    ) {
      this.placeholderShowing = false;
      void this.handler?.({ type: "user_transcript_partial", text: "" });
    }
    // While the user talks a speaking report arrives with every feed and restarts the
    // watchdog, so the turn cannot end however long the text stalls. Silent reports leave
    // it running: the silence rules below or the watchdog end the turn.
    if (state.speechActive) {
      this.speakingReports += 1;
      if (this.speakingReports >= BARGE_IN_SPEAKING_REPORTS) this.bargeInOnSpeech();
      this.scheduleTurnEnd();
      return;
    }
    this.speakingReports = 0;
    const turn = this.pendingTurnText();
    if (!turn) return;
    const silence = state.trailingSilenceMs ?? 0;
    const endsSentence = SENTENCE_END.test(turn);
    const finished = endsSentence && (state.speechFinal || silence >= SENTENCE_END_SILENCE_MS);
    if (finished || silence >= UNFINISHED_SILENCE_MS) {
      this.clearTurnEnd();
      const reason: TurnEndReason = !finished
        ? "unfinished_silence"
        : state.speechFinal
          ? "speech_final"
          : "sentence_end_silence";
      void this.commitTurn(reason);
    }
  }

  private scheduleTurnEnd(): void {
    this.clearTurnEnd();
    this.turnEndTimer = setTimeout(() => {
      this.turnEndTimer = undefined;
      void this.commitTurn("watchdog");
    }, this.turnEndPauseMs);
  }

  private clearTurnEnd(): void {
    if (this.turnEndTimer) {
      clearTimeout(this.turnEndTimer);
      this.turnEndTimer = undefined;
    }
  }

  /** One line per user turn: what ended it and how long it took. Never the words. */
  private logTurnCommitted(
    turn: string,
    reason: TurnEndReason,
    trailingSilenceMs: number | undefined,
    committedAt: number,
  ): void {
    const stats = this.stats;
    stats.turns += 1;
    stats.endReasons[reason] = (stats.endReasons[reason] ?? 0) + 1;
    this.log.info("voice_media.turn_committed", {
      reason,
      trailingSilenceMs,
      endsSentence: SENTENCE_END.test(turn),
      units: speechUnits(turn).length,
      turnMs: this.turnStartedAt === undefined ? undefined : committedAt - this.turnStartedAt,
      asrRestarted: this.turnRestarted,
    });
    this.turnStartedAt = undefined;
    this.turnRestarted = false;
    this.lastTrailingSilenceMs = undefined;
  }

  private commitTurn(reason: TurnEndReason): Promise<void> {
    const trailingSilenceMs = this.lastTrailingSilenceMs;
    // A pause and End can overlap. Chain them so each word is handed to Pi once.
    const perform = async (): Promise<void> => {
      const handler = this.handler;
      if (!handler) return;
      const turn = this.pendingTurnText();
      if (!turn) return;
      const committedAt = this.now();
      this.logTurnCommitted(turn, reason, trailingSilenceMs, committedAt);
      this.delegatedUnits = speechUnits(this.transcript).length;
      this.lastTurnText = "";
      this.speaking = false;
      this.awaitingVoiceSince = committedAt;
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
      createAdapter: (call: { callId: string }) => VoiceMediaAdapter;
      calls: VoiceCallController;
      nextUtteranceId?: () => string;
      nextDelegationId?: () => string;
      /** Calls with media on this session started or stopped: its agent can speak or not. */
      onSessionMediaChanged?: (sessionId: string, attached: boolean) => void;
    },
  ) {}

  async attach(input: VoiceCallMediaAttachInput): Promise<void> {
    await this.detach(input.frontend.connectionId);
    // The socket can close while the old adapter stops; its detach found nothing, so a
    // new adapter here would outlive the caller.
    if (!this.deps.calls.isCallConnection(input.frontend.connectionId)) {
      log.info("voice_media.attach_skipped", {
        callId: input.callId,
        reason: "connection_closed",
      });
      return;
    }
    const adapter = this.deps.createAdapter({ callId: input.callId });
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

  /**
   * The caller's phone stopped playback because it heard them: drop the reply on that
   * connection's media. A repeated `requestId` is a no-op, so a duplicate cannot cut off a
   * reply that started after the first one. True when speech was dropped.
   */
  bargeIn(connectionId: string, requestId: string): boolean {
    const session = this.sessions.get(connectionId);
    if (!session || session.lastBargeInRequestId === requestId) return false;
    session.lastBargeInRequestId = requestId;
    return session.adapter.bargeIn?.() ?? false;
  }

  /** Say the agent's words on the call. */
  speak(callId: string, text: string, replyId?: string): Promise<void> {
    const adapter = this.adapterFor(callId);
    return Promise.resolve(adapter?.speak(text, replyId));
  }

  streamsReplies(callId: string): boolean {
    return this.adapterFor(callId)?.streamsReplies === true;
  }

  private adapterFor(callId: string): VoiceMediaAdapter | undefined {
    for (const session of this.sessions.values()) {
      if (session.callId === callId) return session.adapter;
    }
    return undefined;
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

  private async handleEvent(session: MediaSession, event: VoiceMediaEvent): Promise<void> {
    switch (event.type) {
      case "user_transcript_partial": {
        const state = this.deps.calls.setPartialTranscript(session.callId, event.text);
        session.frontend.send({ type: "voice_call_state", ...state });
        return;
      }
      case "user_utterance_committed": {
        const request = event.text.trim();
        if (request) this.delegate(session, event.utteranceId, request);
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
        const request = event.text.trim();
        if (request) this.delegate(session, event.utteranceId, request);
        return;
      }
      default:
        return;
    }
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
  /** The phone's latest `voice_call_barge_in`, so a repeat of it changes nothing. */
  lastBargeInRequestId?: string;
}
