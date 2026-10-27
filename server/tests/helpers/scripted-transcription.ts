import type {
  LiveTranscription,
  LiveTranscriptionClosedReason,
  LiveTranscriptionEvents,
  LiveTurnEndReason,
} from "../../src/realtime-transcription.js";

/**
 * A call's listening half driven by the test: the test plays the ASR server's part
 * (speech started, streamed words, finished items, socket loss) and the adapter under test
 * reacts as it does to the real realtime transcription client.
 */
export class ScriptedTranscription implements LiveTranscription {
  stopped = false;
  fed: Buffer[] = [];
  startError?: Error;
  /** Turns `stop()` hands over before it resolves: the caller's last words, cut at End. */
  flushOnStop: string[] = [];
  private events?: LiveTranscriptionEvents;

  async start(events: LiveTranscriptionEvents): Promise<void> {
    if (this.startError) throw this.startError;
    this.events = events;
  }

  feedAudio(pcm: Buffer): void {
    this.fed.push(pcm);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    for (const text of this.flushOnStop) this.turn(text, "call_stop");
  }

  /** The server's VAD heard the caller start. */
  speechStarted(): void {
    this.events?.speechStarted();
  }

  /** The caller's words so far, for items not yet turns. */
  partial(text: string): void {
    this.events?.partial(text);
  }

  /** One finished item: the server's completed transcript ("" for a failed or silent item). */
  turn(text: string, reason: LiveTurnEndReason = "server_vad"): void {
    this.events?.turn({ text, reason, finalMs: 120 });
  }

  /** The caller said `text` and the server ended the turn. */
  say(text: string): void {
    this.speechStarted();
    this.partial(text);
    this.turn(text);
    this.partial("");
  }

  close(reason: LiveTranscriptionClosedReason = "socket_closed", code?: number): void {
    this.events?.closed(reason, { code });
  }
}
