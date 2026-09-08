/**
 * xAI / Grok Speech-to-Text adapter.
 *
 * Official APIs (do not invent OpenAI-compatible paths):
 *   REST batch: POST https://api.x.ai/v1/stt
 *   Streaming:  wss://api.x.ai/v1/stt  (raw PCM frames + JSON events)
 *
 * Dictation uses the WebSocket API with interim_results so live
 * dictation_result ticks are real partials, not a batch replay.
 *
 * Docs: https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
 */

import { WebSocket } from "ws";
import {
  SttSessionCreateError,
  type SttFinalTranscript,
  type SttProvider,
  type SttStartOptions,
  type SttStartResult,
  type SttTranscriptUpdate,
} from "./stt-provider.js";

export const DEFAULT_XAI_STT_ENDPOINT = "https://api.x.ai";
export const DEFAULT_XAI_STT_MODEL = "grok-stt";
export const XAI_KEYTERM_MAX_CHARS = 50;

const START_TIMEOUT_MS = 10_000;
const STOP_TIMEOUT_MS = 10_000;

export interface SttWebSocket {
  readonly readyState: number;
  on(event: "open" | "message" | "error" | "close", listener: (...args: unknown[]) => void): void;
  send(data: Buffer | string): void;
  close(): void;
}

export type SttWebSocketFactory = (url: string, headers: Record<string, string>) => SttWebSocket;

export interface XaiSttOptions {
  endpoint?: string;
  model?: string;
  resolveApiKey: () => string | undefined | Promise<string | undefined>;
  createWebSocket?: SttWebSocketFactory;
}

function normalizeHttpBase(endpoint: string): string {
  return endpoint.trim().replace(/\/+$/, "").replace(/\/v1$/i, "");
}

export function xaiSttWebSocketUrl(endpoint: string, keyterms: readonly string[] = []): string {
  const httpBase = normalizeHttpBase(endpoint);
  const wsBase = httpBase.startsWith("https://")
    ? `wss://${httpBase.slice("https://".length)}`
    : httpBase.startsWith("http://")
      ? `ws://${httpBase.slice("http://".length)}`
      : httpBase;
  const params = new URLSearchParams();
  params.set("sample_rate", "16000");
  params.set("encoding", "pcm");
  params.set("interim_results", "true");
  for (const term of keyterms) params.append("keyterm", term);
  return `${wsBase}/v1/stt?${params.toString()}`;
}

export function xaiKeyterms(contextualStrings: readonly string[] | undefined): string[] {
  if (!contextualStrings || contextualStrings.length === 0) return [];
  return contextualStrings.filter((term) => [...term].length <= XAI_KEYTERM_MAX_CHARS);
}

function wsDataToString(data: unknown): string | undefined {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (Array.isArray(data) && data[0] !== undefined) return wsDataToString(data[0]);
  return undefined;
}

function parseWsEvent(data: unknown): Record<string, unknown> | undefined {
  const text = wsDataToString(data);
  if (text === undefined) return undefined;
  try {
    const parsed: unknown = JSON.parse(text);
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

function defaultCreateWebSocket(url: string, headers: Record<string, string>): SttWebSocket {
  return new WebSocket(url, { headers });
}

export class XaiSttProvider implements SttProvider {
  readonly name = "xai";
  readonly model: string;
  private readonly endpoint: string;
  private readonly resolveApiKey: () => string | undefined | Promise<string | undefined>;
  private readonly createWebSocket: SttWebSocketFactory;
  private socket: SttWebSocket | null = null;
  private audioQueue: Buffer[] = [];
  private stopped = false;
  private ready = false;
  private lastText = "";
  private contextApplied = false;
  private tokenCb: ((update: SttTranscriptUpdate) => void) | null = null;
  private startWait: {
    resolve: () => void;
    reject: (error: SttSessionCreateError) => void;
  } | null = null;
  private stopWait: {
    resolve: (result: SttFinalTranscript) => void;
    reject: (error: Error) => void;
  } | null = null;
  private startTimer: ReturnType<typeof setTimeout> | null = null;
  private stopTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(opts: XaiSttOptions) {
    this.endpoint = opts.endpoint?.trim() || DEFAULT_XAI_STT_ENDPOINT;
    this.model = opts.model?.trim() || DEFAULT_XAI_STT_MODEL;
    this.resolveApiKey = opts.resolveApiKey;
    this.createWebSocket = opts.createWebSocket ?? defaultCreateWebSocket;
  }

  async start(options?: SttStartOptions): Promise<SttStartResult> {
    this.resetSession();
    const apiKey = (await this.resolveApiKey())?.trim();
    if (!apiKey) {
      throw new SttSessionCreateError({ category: "auth" });
    }

    const keyterms = xaiKeyterms(options?.contextualStrings);
    this.contextApplied = keyterms.length > 0;
    this.stopped = false;

    const url = xaiSttWebSocketUrl(this.endpoint, keyterms);
    let socket: SttWebSocket;
    try {
      socket = this.createWebSocket(url, { Authorization: `Bearer ${apiKey}` });
    } catch {
      throw new SttSessionCreateError({ category: "network" });
    }
    this.socket = socket;
    socket.on("message", (data) => this.handleMessage(data));
    socket.on("error", () => this.handleSocketFailure("network"));
    socket.on("close", () => this.handleSocketClose());

    await new Promise<void>((resolve, reject) => {
      this.startWait = { resolve, reject };
      this.startTimer = setTimeout(() => {
        this.startTimer = null;
        this.failStart("network");
      }, START_TIMEOUT_MS);
    });

    this.flushAudioQueue();
    return { contextApplied: this.contextApplied };
  }

  feedAudio(pcm: Buffer): void {
    if (this.stopped) return;
    if (this.ready && this.socket && this.socket.readyState === 1) {
      this.socket.send(pcm);
      return;
    }
    this.audioQueue.push(pcm);
  }

  onToken(cb: (update: SttTranscriptUpdate) => void): void {
    this.tokenCb = cb;
  }

  async stop(): Promise<SttFinalTranscript> {
    this.stopped = true;
    this.flushAudioQueue();
    const socket = this.socket;
    if (!socket || socket.readyState !== 1) {
      this.teardownSocket();
      return { text: this.lastText };
    }

    return new Promise<SttFinalTranscript>((resolve, reject) => {
      this.stopWait = { resolve, reject };
      this.stopTimer = setTimeout(() => {
        this.stopTimer = null;
        const result = { text: this.lastText };
        this.teardownSocket();
        resolve(result);
      }, STOP_TIMEOUT_MS);
      try {
        socket.send(JSON.stringify({ type: "audio.done" }));
      } catch {
        this.clearStopTimer();
        this.teardownSocket();
        resolve({ text: this.lastText });
      }
    });
  }

  async dispose(): Promise<void> {
    this.stopped = true;
    this.failStart("network");
    this.teardownSocket();
  }

  private handleMessage(data: unknown): void {
    const event = parseWsEvent(data);
    if (!event) {
      if (this.startWait) this.failStart("invalid_response");
      return;
    }
    const type = event.type;
    if (type === "transcript.created") {
      this.ready = true;
      this.flushAudioQueue();
      this.finishStart();
      return;
    }
    if (type === "error") {
      if (this.startWait) {
        this.failStart("invalid_response");
        return;
      }
      if (this.stopWait) {
        this.finishStop({ text: this.lastText });
      }
      return;
    }
    if (type === "transcript.partial") {
      const text = typeof event.text === "string" ? event.text.trim() : "";
      if (!text) return;
      const isFinal = event.is_final === true;
      if (text === this.lastText && !isFinal) return;
      this.lastText = text;
      this.tokenCb?.({ text, ...(isFinal ? { snap: true } : {}) });
      return;
    }
    if (type === "transcript.done") {
      const text = typeof event.text === "string" ? event.text : this.lastText;
      this.lastText = text;
      this.finishStop({ text });
    }
  }

  private handleSocketFailure(category: "network" | "invalid_response"): void {
    if (this.startWait) {
      this.failStart(category);
      return;
    }
    if (this.stopWait) {
      this.finishStop({ text: this.lastText });
      return;
    }
    this.teardownSocket();
  }

  private handleSocketClose(): void {
    if (this.startWait) {
      this.failStart("network");
      return;
    }
    if (this.stopWait) {
      this.finishStop({ text: this.lastText });
      return;
    }
    this.teardownSocket();
  }

  private flushAudioQueue(): void {
    if (!this.ready || !this.socket || this.socket.readyState !== 1) return;
    for (const chunk of this.audioQueue) this.socket.send(chunk);
    this.audioQueue = [];
  }

  private finishStart(): void {
    if (this.startTimer) {
      clearTimeout(this.startTimer);
      this.startTimer = null;
    }
    const wait = this.startWait;
    this.startWait = null;
    wait?.resolve();
  }

  private failStart(category: "network" | "invalid_response"): void {
    if (this.startTimer) {
      clearTimeout(this.startTimer);
      this.startTimer = null;
    }
    const wait = this.startWait;
    this.startWait = null;
    this.teardownSocket();
    wait?.reject(new SttSessionCreateError({ category }));
  }

  private finishStop(result: SttFinalTranscript): void {
    this.clearStopTimer();
    const wait = this.stopWait;
    this.stopWait = null;
    this.teardownSocket();
    wait?.resolve(result);
  }

  private clearStopTimer(): void {
    if (this.stopTimer) {
      clearTimeout(this.stopTimer);
      this.stopTimer = null;
    }
  }

  private teardownSocket(): void {
    this.ready = false;
    this.audioQueue = [];
    const socket = this.socket;
    this.socket = null;
    if (socket && socket.readyState !== 3) {
      try {
        socket.close();
      } catch {
        // best-effort
      }
    }
  }

  private resetSession(): void {
    this.clearStopTimer();
    if (this.startTimer) {
      clearTimeout(this.startTimer);
      this.startTimer = null;
    }
    if (this.socket) {
      try {
        this.socket.close();
      } catch {
        // best-effort
      }
    }
    this.socket = null;
    this.audioQueue = [];
    this.ready = false;
    this.stopped = false;
    this.lastText = "";
    this.contextApplied = false;
    this.startWait = null;
    this.stopWait = null;
  }
}
