/**
 * Grok Voice as the Live Voice media backend.
 *
 * One xAI realtime session (`wss://api.x.ai/v1/realtime`) per attached call. Grok owns
 * listening, turn-taking, and barge-in. Anything about the user's work goes to the call's
 * Pi session when Grok calls `delegate_to_pi`; transcripts never become prompts on their
 * own. What Pi says with its `speak` tool comes back through `speak` and Grok says it.
 *
 * Media keeps the Live Voice client contract: 16 kHz s16le mono in, 24 kHz s16le mono
 * out, both as raw binary frames on the xAI socket.
 */
import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";

import type { VoiceMediaAdapter, VoiceMediaEventHandler } from "./continuous-voice-media.js";
import { createLogger } from "./logger.js";
import { resolveTtsProvider } from "./speech-synthesis.js";
import type { ServerConfig } from "./types.js";

const log = createLogger({ base: { component: "grok_live_voice" } });

export const GROK_VOICE_ENDPOINT = "wss://api.x.ai/v1/realtime";
export const GROK_VOICE_DEFAULT_MODEL = "grok-voice-latest";
export const GROK_VOICE_DEFAULT_VOICE = "eve";
const INPUT_SAMPLE_RATE = 16_000;
const OUTPUT_SAMPLE_RATE = 24_000;
/** s16le mono at the input and output rates. */
const INPUT_BYTES_PER_MS = (INPUT_SAMPLE_RATE * 2) / 1000;
/** Output gaps longer than this are a pause between replies, not network jitter. */
const REPLY_GAP_MS = 1_000;
const OUTPUT_BYTES_PER_MS = (OUTPUT_SAMPLE_RATE * 2) / 1000;
const START_TIMEOUT_MS = 10_000;
const DELEGATE_TOOL = "delegate_to_pi";
const ENDED_BEFORE_READY = "Live Voice ended before Grok Voice connected";
/** Marks this adapter's responses in the metadata xAI echoes back on `response.created`. */
const RESPONSE_SOURCE_KEY = "oppi_source";
const OWN_RESPONSE_SOURCE = "pi_update";
const RESPONSE_ID_KEY = "oppi_response";
/** How long to wait for xAI's reply to a user turn, or to our own create, before moving on. */
const TURN_REPLY_WAIT_MS = 5_000;
/**
 * Silence that ends a user turn. xAI's default cuts a ~1.2 s pause mid-thought, turning one
 * request into several turns and delegations. Not in xAI's docs, but it accepts and echoes it.
 */
const TURN_SILENCE_MS = 1_500;

export const GROK_VOICE_INSTRUCTIONS = [
  "You are the voice of Pi, the user's coding agent, on a phone call. Pi does the thinking and the work; you are its ears and mouth.",
  "You cannot see files, sessions, or anything on the computer, and you do not know what Pi knows.",
  `Pass everything the user asks, tells, or wants done to Pi with ${DELEGATE_TOOL}, in the user's own words: questions about their work, code, sessions, status, plans, and follow-ups to what Pi said. After you pass something to Pi, say nothing at all: no "okay", no "on it". Pi answers out loud itself. Only answer yourself for a greeting or a pure social reply.`,
  "Messages that begin with [Pi says] are Pi talking to the user. Say that text to the user as written, in your voice, without adding to it. Never pass [Pi says] text, or anything else Pi said, to Pi: only the user's own spoken words go to Pi.",
  "You cannot approve permission requests. If Pi is blocked on an approval, tell the user to answer it on screen.",
].join(" ");

/**
 * Grok's voice for a call: the read-aloud voice when read aloud also speaks through Grok,
 * so replies and calls sound the same. An http voice (a Yuwp name) means nothing to xAI.
 */
export function grokVoiceFromTts(tts: ServerConfig["tts"]): string {
  const voice = tts?.voice?.trim();
  return voice && resolveTtsProvider(tts) === "xai" ? voice : GROK_VOICE_DEFAULT_VOICE;
}

/** The subset of a `ws` socket the adapter uses; tests supply a fake. */
export interface GrokVoiceSocket {
  readonly readyState: number;
  on(event: "open", listener: () => void): void;
  on(event: "message", listener: (data: Buffer, isBinary: boolean) => void): void;
  on(event: "error", listener: (error: Error) => void): void;
  on(event: "close", listener: (code: number, reason: Buffer) => void): void;
  send(data: Buffer | string): void;
  close(): void;
}

export interface GrokVoiceOptions {
  /** xAI bearer: the owner's Grok sign-in or API key. Resolved per call. */
  resolveApiKey: () => Promise<string | undefined>;
  model?: string;
  voice?: string;
  endpoint?: string;
  createSocket?: (url: string, headers: Record<string, string>) => GrokVoiceSocket;
  now?: () => number;
}

type XaiEvent = {
  type?: string;
  item_id?: string;
  call_id?: string;
  name?: string;
  arguments?: string;
  transcript?: string;
  delta?: string;
  response_id?: string;
  response?: { metadata?: Record<string, unknown> | null; status?: string };
  error?: { message?: string; code?: string };
};

const OPEN = 1;

export class GrokVoiceMediaAdapter implements VoiceMediaAdapter {
  private socket: GrokVoiceSocket | undefined;
  private handler: VoiceMediaEventHandler | undefined;
  private playbackSink: ((pcm: Buffer) => void) | undefined;
  private ready = false;
  private stopped = false;
  /** Between `response.created` and `response.done`. */
  private responseActive = false;
  /** The user finished a turn and xAI's own server-VAD reply has not been created yet. */
  private replyExpected = false;
  private responseWanted = false;
  private responseTimer: ReturnType<typeof setTimeout> | undefined;
  /** When audio already sent to the phone should finish playing. */
  private playbackEndsAt = 0;
  /** xAI's latest transcript per item, as received (cumulative; see `withoutEarlierTurns`). */
  private readonly transcripts = new Map<string, string>();
  /**
   * xAI prefixes an item's transcript with the transcripts of the turns committed since Grok
   * last spoke. Per item: the last committed item when it first appeared, whose transcript
   * is the text to strip. Undefined when none (the first turn, or Grok spoke since).
   */
  private readonly earlierItems = new Map<string, string | undefined>();
  /** The latest committed item since Grok last spoke; a spoken reply resets xAI's transcript. */
  private lastCommittedItem: string | undefined;
  private readonly committedItems = new Set<string>();
  /** Between `speech_started` and the turn commit; Grok must not start talking over it. */
  private userSpeaking = false;
  /**
   * The phone heard the caller over the current response and stopped it: its remaining audio
   * is not sent. The next `response.created` is new speech.
   */
  private dropResponseAudio = false;
  /**
   * The id of this adapter's `response.create` (Pi update, tool error) until xAI creates it.
   * Flow control only: at most one is in flight. Which response is ours comes from the
   * metadata xAI echoes on `response.created`, never from timing. xAI silently drops a create
   * sent while another response runs, and does not echo our `event_id` on errors.
   */
  private ownCreateId: string | undefined;
  private ownCreateTimer: ReturnType<typeof setTimeout> | undefined;
  private ownCreateSequence = 0;
  /** Ends the wait for xAI's own reply to a user turn if that reply never comes. */
  private turnReplyTimer: ReturnType<typeof setTimeout> | undefined;
  /** The in-flight response answers a Pi update, not the user, so it cannot start Pi work. */
  private responseFromAdapter = false;
  /** Rejects a start still waiting for xAI, so a hang-up mid-connect ends it at once. */
  private abortStart: ((error: Error) => void) | undefined;
  private readonly now: () => number;
  /** Logged once when the call's Grok session ends; see `logCallSummary`. */
  private readonly stats = {
    readyAt: 0,
    inputBytes: 0,
    userTurns: 0,
    xaiReplies: 0,
    piUpdateReplies: 0,
    cancelledReplies: 0,
    /** Responses whose remaining audio was dropped because the phone heard the caller first. */
    localBargeIns: 0,
    delegations: 0,
    outputBytes: 0,
    /** Longest wait between two audio chunks of one reply, as sent to the phone. */
    maxOutputGapMs: 0,
    lastOutputAt: 0,
    /**
     * How far one reply's audio fell behind real time: the playback buffer a phone needs
     * to play that reply without a gap. Measured from the reply's first chunk.
     */
    maxNeededBufferMs: 0,
    replyFirstOutputAt: 0,
    replyOutputMs: 0,
    /** Time from the user's turn ending to the first reply audio, worst case. */
    maxReplyLatencyMs: 0,
    turnEndedAt: 0,
  };

  constructor(private readonly options: GrokVoiceOptions) {
    this.now = options.now ?? Date.now;
  }

  setPlaybackSink(sendAudio: (pcm: Buffer) => void): void {
    this.playbackSink = sendAudio;
  }

  async start(handler: VoiceMediaEventHandler): Promise<void> {
    this.handler = handler;
    const apiKey = (await this.options.resolveApiKey())?.trim();
    if (!apiKey) throw new Error("Grok Voice needs an xAI sign-in or API key");
    if (this.stopped) throw new Error(ENDED_BEFORE_READY);
    const model = this.options.model ?? GROK_VOICE_DEFAULT_MODEL;
    const url = `${this.options.endpoint ?? GROK_VOICE_ENDPOINT}?model=${encodeURIComponent(model)}`;
    const createSocket = this.options.createSocket ?? defaultCreateSocket;
    const socket = createSocket(url, { Authorization: `Bearer ${apiKey}` });
    this.socket = socket;

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(
        () => fail(new Error("Grok Voice did not start in time")),
        START_TIMEOUT_MS,
      );
      let settled = false;
      const fail = (error: Error): void => {
        if (settled) return;
        settled = true;
        this.abortStart = undefined;
        clearTimeout(timer);
        this.closeSocket();
        reject(error);
      };
      const done = (): void => {
        if (settled) return;
        settled = true;
        this.abortStart = undefined;
        clearTimeout(timer);
        resolve();
      };
      this.abortStart = fail;
      socket.on("message", (data, isBinary) => {
        if (this.socket !== socket) return;
        if (isBinary) {
          this.handleOutputAudio(data);
          return;
        }
        const event = parseEvent(data);
        if (!event) return;
        if (!this.ready) {
          if (event.type === "session.created") this.configureSession(socket);
          else if (event.type === "session.updated") {
            this.ready = true;
            this.stats.readyAt = this.now();
            done();
          } else if (event.type === "error") {
            fail(
              new Error(
                `Grok Voice rejected the session: ${event.error?.message ?? "unknown error"}`,
              ),
            );
          }
          return;
        }
        this.handleEvent(event).catch((error: unknown) => logEventFailure(event.type, error));
      });
      socket.on("error", (error) => {
        if (this.socket !== socket) return;
        if (!this.ready) fail(new Error(`Grok Voice connection failed: ${error.message}`));
        else log.warn("grok_voice.socket_error", { error: error.message });
      });
      socket.on("close", (code) => {
        if (this.socket !== socket) return;
        if (!this.ready) {
          fail(new Error(`Grok Voice closed before it was ready (${code})`));
          return;
        }
        this.socket = undefined;
        if (!this.stopped) {
          this.endFromRemote(`Grok Voice disconnected (${code})`).catch((error: unknown) =>
            logEventFailure("close", error),
          );
        }
      });
    });
    if (this.stopped) throw new Error(ENDED_BEFORE_READY);
  }

  feedAudio(pcm: Buffer): void {
    if (!this.ready || this.stopped || pcm.length === 0) return;
    const socket = this.socket;
    if (socket?.readyState !== OPEN) return;
    this.stats.inputBytes += pcm.length;
    socket.send(pcm);
  }

  /** Adds what Pi said to the conversation and asks Grok to say it once it has finished speaking. */
  speak(raw: string): void {
    const text = raw.trim();
    if (!text || !this.ready) return;
    this.sendEvent({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: `[Pi says] ${text}` }],
      },
    });
    this.requestResponse();
  }

  /**
   * The phone heard the caller over Grok and stopped playback. xAI's server VAD hears the same
   * mic and cancels the response itself ("In VAD mode, interruptions are automatic"), so no
   * `response.cancel` is sent and turn-taking stays xAI's; only the rest of this response's
   * audio is withheld, so the phone does not resume it before xAI's VAD catches up.
   */
  bargeIn(): boolean {
    if (!this.responseActive || this.dropResponseAudio) return false;
    this.dropResponseAudio = true;
    this.playbackEndsAt = this.now();
    this.stats.localBargeIns += 1;
    return true;
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.logCallSummary("stopped");
    this.abortStart?.(new Error(ENDED_BEFORE_READY));
    this.clearResponseTimer();
    this.closeSocket();
    const handler = this.handler;
    this.handler = undefined;
    if (!handler) return;
    await handler({ type: "disconnected" });
  }

  private configureSession(socket: GrokVoiceSocket): void {
    socket.send(
      JSON.stringify({
        type: "session.update",
        session: {
          instructions: GROK_VOICE_INSTRUCTIONS,
          voice: this.options.voice ?? GROK_VOICE_DEFAULT_VOICE,
          turn_detection: { type: "server_vad", silence_duration_ms: TURN_SILENCE_MS },
          audio: {
            input: {
              format: { type: "audio/pcm", rate: INPUT_SAMPLE_RATE },
              transport: "binary",
              // Live captions: cumulative `input_audio_transcription.updated` events.
              transcription: { model: "grok-transcribe" },
            },
            output: {
              format: { type: "audio/pcm", rate: OUTPUT_SAMPLE_RATE },
              transport: "binary",
            },
          },
          tools: [
            {
              type: "function",
              name: DELEGATE_TOOL,
              description:
                "Pass what the user said to Pi, the coding agent on the user's computer. Pi answers with [Pi says] messages.",
              parameters: {
                type: "object",
                properties: {
                  request: {
                    type: "string",
                    description:
                      "What the user said, in their words, complete enough to stand alone.",
                  },
                },
                required: ["request"],
              },
            },
          ],
        },
      }),
    );
  }

  private async handleEvent(event: XaiEvent): Promise<void> {
    const handler = this.handler;
    if (!handler) return;
    switch (event.type) {
      case "input_audio_buffer.speech_started":
        // Grok cancels its own response; the phone must drop audio it already queued.
        // A non-empty partial is the client's barge-in signal, so show one at once.
        this.playbackEndsAt = this.now();
        this.userSpeaking = true;
        this.stats.userTurns += 1;
        await handler({ type: "user_transcript_partial", text: "…" });
        return;
      case "input_audio_buffer.speech_stopped":
        this.userSpeaking = false;
        this.stats.turnEndedAt = this.now();
        // xAI commits the turn and answers it itself (server VAD); wait for that reply.
        this.awaitTurnReply();
        return;
      case "conversation.item.input_audio_transcription.updated":
      case "conversation.item.input_audio_transcription.completed": {
        const text = event.transcript?.trim();
        if (!text || !event.item_id) return;
        this.noteItem(event.item_id);
        this.transcripts.set(event.item_id, text);
        // A committed item's later corrections stay on record for the next item's repeated
        // words, and are not shown as new speech.
        if (this.committedItems.has(event.item_id)) return;
        const fresh = this.newWords(event.item_id, text);
        if (fresh) await handler({ type: "user_transcript_partial", text: fresh });
        return;
      }
      case "input_audio_buffer.committed": {
        if (!event.item_id) return;
        this.noteItem(event.item_id);
        this.lastCommittedItem = event.item_id;
        this.committedItems.add(event.item_id);
        this.userSpeaking = false;
        // xAI's own reply to this turn is coming (it may already be active); a held
        // Pi update follows its response.done.
        if (!this.responseActive) this.awaitTurnReply();
        await handler({ type: "user_transcript_partial", text: "" });
        return;
      }
      case "response.created": {
        this.responseActive = true;
        this.dropResponseAudio = false;
        this.stats.lastOutputAt = 0; // gaps are measured within one reply
        this.stats.replyFirstOutputAt = 0;
        this.stats.replyOutputMs = 0;
        const metadata = event.response?.metadata;
        const ours = metadata?.[RESPONSE_SOURCE_KEY] === OWN_RESPONSE_SOURCE;
        this.responseFromAdapter = ours;
        if (ours) this.stats.piUpdateReplies += 1;
        else this.stats.xaiReplies += 1;
        const current = ours && metadata?.[RESPONSE_ID_KEY] === this.ownCreateId;
        if (!ours) {
          // xAI's own reply to the user's turn.
          this.replyExpected = false;
          this.clearTurnReplyTimer();
        }
        // Any other response that starts first (xAI's own, or a late reply to an older create)
        // makes xAI drop our create in flight: queue the Pi update again for its response.done.
        if (current) this.clearOwnCreate();
        else if (this.ownCreateId) {
          this.clearOwnCreate();
          this.responseWanted = true;
        }
        return;
      }
      case "response.function_call_arguments.done":
        await this.handleFunctionCall(event);
        return;
      case "response.done":
        this.responseActive = false;
        // A reply that only called a tool must not stretch the latency to a later reply.
        this.stats.turnEndedAt = 0;
        if (event.response?.status === "cancelled") this.stats.cancelledReplies += 1;
        this.flushResponseRequest();
        return;
      case "error":
        // Most realtime errors are recoverable; the session stays open.
        log.warn("grok_voice.event_error", {
          code: event.error?.code,
          error: event.error?.message,
        });
        return;
      default:
        return;
    }
  }

  private handleOutputAudio(pcm: Buffer): void {
    if (pcm.length === 0 || this.stopped) return;
    // Grok speaking resets what xAI repeats in the next transcript.
    this.lastCommittedItem = undefined;
    // xAI still said it, but the caller talked over it and the phone stopped it.
    if (this.dropResponseAudio) return;
    const now = this.now();
    this.stats.outputBytes += pcm.length;
    const gap = now - this.stats.lastOutputAt;
    if (this.stats.lastOutputAt > 0 && gap < REPLY_GAP_MS) {
      this.stats.maxOutputGapMs = Math.max(this.stats.maxOutputGapMs, gap);
    }
    if (this.stats.turnEndedAt > 0) {
      this.stats.maxReplyLatencyMs = Math.max(
        this.stats.maxReplyLatencyMs,
        now - this.stats.turnEndedAt,
      );
      this.stats.turnEndedAt = 0;
    }
    this.stats.lastOutputAt = now;
    if (this.stats.replyFirstOutputAt === 0) this.stats.replyFirstOutputAt = now;
    const behind = now - this.stats.replyFirstOutputAt - this.stats.replyOutputMs;
    this.stats.maxNeededBufferMs = Math.max(this.stats.maxNeededBufferMs, behind);
    this.stats.replyOutputMs += pcm.length / OUTPUT_BYTES_PER_MS;
    this.playbackEndsAt = Math.max(this.playbackEndsAt, now) + pcm.length / OUTPUT_BYTES_PER_MS;
    this.playbackSink?.(pcm);
  }

  private async handleFunctionCall(event: XaiEvent): Promise<void> {
    const callId = event.call_id;
    if (!callId) return;
    let output: Record<string, string>;
    if (this.responseFromAdapter) {
      // A reply to a Pi update or tool error: Pi's own output must not start more Pi work.
      output = { status: "error", message: "Only the user can start Pi work. Ask them first." };
    } else if (event.name !== DELEGATE_TOOL) {
      output = { status: "error", message: `Unknown tool ${event.name ?? ""}`.trim() };
    } else {
      const asked = parseDelegateRequest(event.arguments);
      const request = asked && this.delegatedWords(asked);
      if (!request) {
        output = { status: "error", message: "request must be a non-empty string" };
      } else {
        try {
          await this.handler?.({
            type: "delegation_requested",
            utteranceId: randomUUID(),
            text: request,
          });
          this.stats.delegations += 1;
          output = {
            status: "delegated",
            note: "Pi has it and answers out loud itself. Say nothing.",
          };
        } catch (error) {
          output = {
            status: "error",
            message: error instanceof Error ? error.message : String(error),
          };
        }
      }
    }
    this.sendEvent({
      type: "conversation.item.create",
      item: { type: "function_call_output", call_id: callId, output: JSON.stringify(output) },
    });
    // A handed-off request needs no reply from Grok: the session's agent acknowledges it out
    // loud first. Only a failed handoff asks Grok to say so. A refused adapter reply gets no
    // follow-up, so Pi output cannot loop through Grok.
    if (this.responseFromAdapter) return;
    if (output.status === "error") this.requestResponse();
  }

  /** Waits for the current response and the phone's queued audio before speaking again. */
  private requestResponse(): void {
    this.responseWanted = true;
    this.flushResponseRequest();
  }

  private flushResponseRequest(): void {
    if (!this.responseWanted || this.stopped) return;
    if (this.responseActive || this.replyExpected || this.ownCreateId || this.userSpeaking) {
      return;
    }
    const wait = this.playbackEndsAt - this.now();
    if (wait > 0) {
      if (!this.responseTimer) {
        this.responseTimer = setTimeout(() => {
          this.responseTimer = undefined;
          this.flushResponseRequest();
        }, wait);
      }
      return;
    }
    this.responseWanted = false;
    const id = `oppi-response-${++this.ownCreateSequence}`;
    this.ownCreateId = id;
    this.sendEvent({
      type: "response.create",
      // xAI echoes this on response.created: the reply to a Pi update is labeled exactly.
      response: { metadata: { [RESPONSE_SOURCE_KEY]: OWN_RESPONSE_SOURCE, [RESPONSE_ID_KEY]: id } },
    });
    this.ownCreateTimer = setTimeout(() => {
      // Never created (dropped or refused without a word): stop holding later updates back.
      this.ownCreateTimer = undefined;
      this.ownCreateId = undefined;
      this.flushResponseRequest();
    }, TURN_REPLY_WAIT_MS);
  }

  private clearOwnCreate(): void {
    this.ownCreateId = undefined;
    if (this.ownCreateTimer) clearTimeout(this.ownCreateTimer);
    this.ownCreateTimer = undefined;
  }

  /** Remembers which earlier turns xAI will repeat in this item's transcript. */
  private noteItem(itemId: string): void {
    if (!this.earlierItems.has(itemId)) this.earlierItems.set(itemId, this.lastCommittedItem);
  }

  private earlierWords(itemId: string): string | undefined {
    const earlier = this.earlierItems.get(itemId);
    return earlier ? this.transcripts.get(earlier) : undefined;
  }

  /** The item's transcript without the earlier turns xAI repeats; empty when nothing is new. */
  private newWords(itemId: string, raw: string): string {
    const earlier = this.earlierWords(itemId);
    return (earlier ? withoutEarlierTurns(raw, earlier) : undefined) ?? raw;
  }

  /**
   * Grok copies the cumulative transcript into `delegate_to_pi`. Strip the earlier turns
   * from the latest committed item; a request that is only old words stays as Grok wrote it.
   */
  private delegatedWords(request: string): string {
    const item = this.lastCommittedItem;
    const earlier = item ? this.earlierWords(item) : undefined;
    return (earlier ? withoutEarlierTurns(request, earlier) : undefined) || request;
  }

  private awaitTurnReply(): void {
    this.replyExpected = true;
    this.clearTurnReplyTimer();
    this.turnReplyTimer = setTimeout(() => {
      this.turnReplyTimer = undefined;
      // No reply was created (an empty turn): stop waiting so a held Pi update can speak.
      this.replyExpected = false;
      this.flushResponseRequest();
    }, TURN_REPLY_WAIT_MS);
  }

  private clearTurnReplyTimer(): void {
    if (this.turnReplyTimer) clearTimeout(this.turnReplyTimer);
    this.turnReplyTimer = undefined;
  }

  private clearResponseTimer(): void {
    this.clearTurnReplyTimer();
    this.clearOwnCreate();
    if (this.responseTimer) clearTimeout(this.responseTimer);
    this.responseTimer = undefined;
  }

  private sendEvent(event: Record<string, unknown>): void {
    const socket = this.socket;
    if (socket?.readyState === OPEN) socket.send(JSON.stringify(event));
  }

  private async endFromRemote(reason: string): Promise<void> {
    this.stopped = true;
    this.logCallSummary(reason);
    this.clearResponseTimer();
    const handler = this.handler;
    this.handler = undefined;
    if (handler) await handler({ type: "disconnected", reason });
  }

  /** One line per Grok session: enough to tell echo barge-in, network gaps, and slow replies apart. */
  private logCallSummary(ended: string): void {
    const st = this.stats;
    log.info("grok_voice.call_summary", {
      ended,
      connectedMs: st.readyAt > 0 ? this.now() - st.readyAt : 0,
      inputMs: Math.round(st.inputBytes / INPUT_BYTES_PER_MS),
      outputMs: Math.round(st.outputBytes / OUTPUT_BYTES_PER_MS),
      userTurns: st.userTurns,
      xaiReplies: st.xaiReplies,
      piUpdateReplies: st.piUpdateReplies,
      cancelledReplies: st.cancelledReplies,
      localBargeIns: st.localBargeIns,
      delegations: st.delegations,
      maxOutputGapMs: Math.round(st.maxOutputGapMs),
      maxNeededBufferMs: Math.round(st.maxNeededBufferMs),
      maxReplyLatencyMs: Math.round(st.maxReplyLatencyMs),
    });
  }

  private closeSocket(): void {
    const socket = this.socket;
    this.socket = undefined;
    try {
      socket?.close();
    } catch {
      // Teardown cannot block stop.
    }
  }
}

/** An event that outlives its call (a late Grok event after End) must not crash the server. */
function logEventFailure(eventType: string | undefined, error: unknown): void {
  log.warn("grok_voice.event_failed", {
    eventType,
    error: error instanceof Error ? error.message : String(error),
  });
}

function parseEvent(data: Buffer): XaiEvent | undefined {
  try {
    const parsed = JSON.parse(data.toString("utf8")) as unknown;
    return parsed && typeof parsed === "object" ? (parsed as XaiEvent) : undefined;
  } catch {
    return undefined;
  }
}

const WORD_CHAR = /[\p{L}\p{N}]/u;

/**
 * `text` without a leading copy of `earlier`, or undefined when `text` does not start with
 * all of it. Case, punctuation, and whitespace do not count, and the match is per character
 * so languages written without spaces work. xAI re-punctuates and re-cases earlier turns,
 * and Grok retypes them, so an exact prefix match would miss. Empty when nothing follows.
 */
function withoutEarlierTurns(text: string, earlier: string): string | undefined {
  let target = "";
  for (const ch of earlier) if (WORD_CHAR.test(ch)) target += ch.toLowerCase();
  if (!target) return undefined;
  let matched = 0;
  let end = 0;
  for (const ch of text) {
    if (matched === target.length) break;
    end += ch.length;
    if (!WORD_CHAR.test(ch)) continue;
    const lower = ch.toLowerCase();
    if (!target.startsWith(lower, matched)) return undefined;
    matched += lower.length;
  }
  if (matched < target.length) return undefined;
  return text.slice(end).replace(/^[^\p{L}\p{N}]+/u, "");
}

function parseDelegateRequest(args: string | undefined): string | undefined {
  if (!args) return undefined;
  try {
    const parsed = JSON.parse(args) as { request?: unknown };
    return typeof parsed.request === "string" && parsed.request.trim()
      ? parsed.request.trim()
      : undefined;
  } catch {
    return undefined;
  }
}

function defaultCreateSocket(url: string, headers: Record<string, string>): GrokVoiceSocket {
  return new WebSocket(url, { headers }) as unknown as GrokVoiceSocket;
}
