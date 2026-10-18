/**
 * Grok Voice as the Live Voice media backend.
 *
 * One xAI realtime session (`wss://api.x.ai/v1/realtime`) per attached call. Grok owns
 * listening, turn-taking, spoken replies, and barge-in. Work goes to the hidden Pi
 * voice-control session only when Grok calls `delegate_to_pi`; ordinary speech and
 * transcripts never become Pi prompts. Pi's `voice_update` results come back through
 * `publish` and are added to Grok's conversation so it can relay them in speech.
 *
 * Media keeps the Live Voice client contract: 16 kHz s16le mono in, 24 kHz s16le mono
 * out, both as raw binary frames on the xAI socket.
 *
 * Approval authority stays out of the model: only the user's own transcript reaches the
 * approval path (`user_transcript_final`), never a delegation Grok composed.
 */
import { randomUUID } from "node:crypto";
import { WebSocket } from "ws";

import type { VoiceDelegationUpdate, VoiceFrontendEventHandler } from "./continuous-voice.js";
import type { VoiceMediaAdapter } from "./continuous-voice-media.js";
import { createLogger } from "./logger.js";
import { resolveTtsProvider } from "./speech-synthesis.js";
import type { ServerConfig } from "./types.js";

const log = createLogger({ base: { component: "grok_live_voice" } });

export const GROK_VOICE_ENDPOINT = "wss://api.x.ai/v1/realtime";
export const GROK_VOICE_DEFAULT_MODEL = "grok-voice-latest";
export const GROK_VOICE_DEFAULT_VOICE = "eve";
const INPUT_SAMPLE_RATE = 16_000;
const OUTPUT_SAMPLE_RATE = 24_000;
/** s16le mono at the output rate. */
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

export const GROK_VOICE_INSTRUCTIONS = [
  "You are Oppi Live Voice, a hands-free voice front end for Pi, a coding agent running on the user's computer.",
  "Speak briefly and naturally, like a phone call. No markdown, lists, code, or file paths read aloud character by character.",
  "You cannot see files, run commands, or check anything yourself.",
  `When the user asks for anything that needs the computer (code, files, sessions, builds, tests, research, running things), call ${DELEGATE_TOOL} once with a complete, self-contained request, then say in a few words that Pi is on it. Do not call it for small talk or questions you can answer from general knowledge.`,
  "Messages that begin with [Pi update] come from Pi, not the user. Relay each one in one or two spoken sentences. Never claim work is done, failed, or approved unless a Pi update says so.",
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
  response?: { metadata?: Record<string, unknown> | null };
  error?: { message?: string; code?: string };
};

const OPEN = 1;

export class GrokVoiceMediaAdapter implements VoiceMediaAdapter {
  private socket: GrokVoiceSocket | undefined;
  private handler: VoiceFrontendEventHandler | undefined;
  private playbackSink: ((pcm: Buffer) => void) | undefined;
  private ready = false;
  private stopped = false;
  /** Between `response.created` and `response.done`. */
  private responseActive = false;
  /** The user finished a turn and xAI's own server-VAD reply has not been created yet. */
  private replyExpected = false;
  /** The in-flight response produced speech, so a delegation needs no second acknowledgement. */
  private respondedWithSpeech = false;
  private assistantSpeaking = false;
  private responseWanted = false;
  private responseTimer: ReturnType<typeof setTimeout> | undefined;
  /** When audio already sent to the phone should finish playing. */
  private playbackEndsAt = 0;
  private readonly transcripts = new Map<string, string>();
  private readonly committedItems = new Set<string>();
  /** Items whose final transcript went out. Later corrections never reach approval. */
  private readonly finalItems = new Set<string>();
  /** Between `speech_started` and the turn commit; Grok must not start talking over it. */
  private userSpeaking = false;
  /**
   * The id of this adapter's `response.create` (Pi update, tool error) until xAI creates it.
   * Flow control only: at most one is in flight. Which response is ours comes from the
   * metadata xAI echoes on `response.created`, never from timing. xAI silently drops a create
   * sent while another response runs, and does not echo our `event_id` on errors.
   */
  private ownCreateId: string | undefined;
  private ownCreateTimer: ReturnType<typeof setTimeout> | undefined;
  private ownCreateSequence = 0;
  /** Counts user turns; a final belongs to the turn its item was committed in. */
  private turn = 0;
  private readonly itemTurns = new Map<string, number>();
  /** Ends the wait for xAI's own reply to a user turn if that reply never comes. */
  private turnReplyTimer: ReturnType<typeof setTimeout> | undefined;
  /** The in-flight response answers a Pi update, not the user, so it cannot start Pi work. */
  private responseFromAdapter = false;
  /** Rejects a start still waiting for xAI, so a hang-up mid-connect ends it at once. */
  private abortStart: ((error: Error) => void) | undefined;
  private readonly now: () => number;

  constructor(private readonly options: GrokVoiceOptions) {
    this.now = options.now ?? Date.now;
  }

  setPlaybackSink(sendAudio: (pcm: Buffer) => void): void {
    this.playbackSink = sendAudio;
  }

  async start(handler: VoiceFrontendEventHandler): Promise<void> {
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
    await handler({ type: "connected" });
  }

  feedAudio(pcm: Buffer): void {
    if (!this.ready || this.stopped || pcm.length === 0) return;
    const socket = this.socket;
    if (socket?.readyState === OPEN) socket.send(pcm);
  }

  /** Adds a Pi result to the conversation and asks Grok to say it once it has finished speaking. */
  publish(update: VoiceDelegationUpdate): void {
    const text = update.text.trim();
    if (!text || !this.ready) return;
    this.sendEvent({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: `[Pi update, ${update.kind}] ${text}` }],
      },
    });
    this.requestResponse();
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.abortStart?.(new Error(ENDED_BEFORE_READY));
    this.clearResponseTimer();
    this.closeSocket();
    const handler = this.handler;
    this.handler = undefined;
    if (!handler) return;
    if (this.assistantSpeaking) {
      this.assistantSpeaking = false;
      await handler({ type: "assistant_speech_stopped" });
    }
    await handler({ type: "disconnected" });
  }

  private configureSession(socket: GrokVoiceSocket): void {
    socket.send(
      JSON.stringify({
        type: "session.update",
        session: {
          instructions: GROK_VOICE_INSTRUCTIONS,
          voice: this.options.voice ?? GROK_VOICE_DEFAULT_VOICE,
          turn_detection: { type: "server_vad" },
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
                "Hand a task to Pi, the coding agent on the user's computer. Pi reports back with [Pi update] messages.",
              parameters: {
                type: "object",
                properties: {
                  request: {
                    type: "string",
                    description: "The complete, self-contained task for Pi, in the user's words.",
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
        this.turn += 1;
        if (this.assistantSpeaking) {
          this.assistantSpeaking = false;
          await handler({ type: "assistant_speech_stopped" });
        }
        await handler({ type: "user_speech_started" });
        await handler({ type: "user_transcript_partial", text: "…" });
        return;
      case "input_audio_buffer.speech_stopped":
        this.userSpeaking = false;
        // xAI commits the turn and answers it itself (server VAD); wait for that reply.
        this.awaitTurnReply();
        await handler({ type: "user_speech_ended" });
        return;
      case "conversation.item.input_audio_transcription.updated":
      case "conversation.item.input_audio_transcription.completed": {
        const text = event.transcript?.trim();
        if (!text || !event.item_id) return;
        this.transcripts.set(event.item_id, text);
        if (this.committedItems.has(event.item_id)) {
          await this.emitFinal(event.item_id, text);
          return;
        }
        await handler({ type: "user_transcript_partial", text });
        return;
      }
      case "input_audio_buffer.committed": {
        if (!event.item_id) return;
        this.committedItems.add(event.item_id);
        this.itemTurns.set(event.item_id, this.turn);
        this.userSpeaking = false;
        // xAI's own reply to this turn is coming (it may already be active); a held
        // Pi update follows its response.done.
        if (!this.responseActive) this.awaitTurnReply();
        const text = this.transcripts.get(event.item_id);
        await handler({ type: "user_transcript_partial", text: "" });
        if (text) await this.emitFinal(event.item_id, text);
        return;
      }
      case "response.created": {
        this.responseActive = true;
        this.respondedWithSpeech = false;
        const metadata = event.response?.metadata;
        const ours = metadata?.[RESPONSE_SOURCE_KEY] === OWN_RESPONSE_SOURCE;
        this.responseFromAdapter = ours;
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
      case "response.output_audio_transcript.delta":
        this.respondedWithSpeech = true;
        return;
      case "response.function_call_arguments.done":
        await this.handleFunctionCall(event);
        return;
      case "response.done":
        this.responseActive = false;
        if (this.assistantSpeaking) {
          this.assistantSpeaking = false;
          await handler({ type: "assistant_speech_stopped" });
        }
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
    if (!this.assistantSpeaking) {
      this.assistantSpeaking = true;
      this.handler?.({ type: "assistant_speech_started" })?.catch((error: unknown) =>
        logEventFailure("audio", error),
      );
    }
    const now = this.now();
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
      const request = parseDelegateRequest(event.arguments);
      if (!request) {
        output = { status: "error", message: "request must be a non-empty string" };
      } else {
        try {
          await this.handler?.({
            type: "delegation_requested",
            utteranceId: randomUUID(),
            text: request,
          });
          output = {
            status: "delegated",
            note: "Pi is working; results arrive as [Pi update] messages.",
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
    // Grok usually says "on it" in the same response; a second response would repeat it.
    // A refused adapter reply gets no follow-up, so Pi output cannot loop through Grok.
    if (this.responseFromAdapter) return;
    if (!this.respondedWithSpeech || output.status === "error") this.requestResponse();
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

  /** One final per user turn: a later, corrected transcript must not answer a second challenge. */
  private async emitFinal(itemId: string, text: string): Promise<void> {
    if (this.finalItems.has(itemId)) return;
    // Words from an earlier turn arriving after the user spoke again: the coordinator's
    // "heard before speaking" set belongs to the newer turn, so fail closed.
    if (this.itemTurns.get(itemId) !== this.turn) return;
    this.finalItems.add(itemId);
    await this.handler?.({ type: "user_transcript_final", text });
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
    this.clearResponseTimer();
    const handler = this.handler;
    this.handler = undefined;
    if (handler) await handler({ type: "disconnected", reason });
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
