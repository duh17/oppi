/**
 * Dictation pipeline types.
 *
 * Defines the WS protocol messages (client/server) and server-side
 * configuration for dictation routed through the server ASR stream.
 */

// ─── Config ───

export interface DictationConfig {
  /** Explicit backend. Omitted with a non-empty sttEndpoint means "http". */
  backend?: "http";
  /** STT backend endpoint for the HTTP backend. */
  sttEndpoint?: string;

  /** Model to request from the STT backend. */
  sttModel: string;
}

/** True when HTTP/Yuwp dictation has a non-empty STT endpoint. */
export function isDictationStreamEnabled(
  asr:
    | {
        backend?: string;
        extension?: string;
        sttEndpoint?: string;
      }
    | undefined,
): boolean {
  return typeof asr?.sttEndpoint === "string" && asr.sttEndpoint.trim().length > 0;
}

export const DEFAULT_DICTATION_CONFIG: DictationConfig = {
  sttEndpoint: "http://localhost:7936",
  sttModel: "mlx-community/Qwen3-ASR-1.7B-bf16",
};

// ─── Client -> Server messages ───

export interface DictationStartMessage {
  type: "dictation_start";
}

export interface DictationStopMessage {
  type: "dictation_stop";
}

export interface DictationCancelMessage {
  type: "dictation_cancel";
}

export type DictationClientMessage =
  | DictationStartMessage
  | DictationStopMessage
  | DictationCancelMessage;

// ─── Server -> Client messages ───

export interface DictationReadyMessage {
  type: "dictation_ready";
  /** STT provider identifier reported by the backend (e.g. "streaming-localhost"). */
  sttProvider?: string;
  /** STT model identifier. */
  sttModel?: string;
}

export interface DictationResultMessage {
  type: "dictation_result";
  text: string;
  /** STT-settled prefix already committed by the backend. */
  committedText?: string;
  /** In-flight tail still subject to correction. */
  activeText?: string;
  /** When true, the text is a batch-corrected replacement. Client should snap (no animation). */
  snap?: boolean;
}

export interface DictationFinalMessage {
  type: "dictation_final";
  text: string;
  /** Final committed transcript from the backend, if provided. */
  committedText?: string;
  /** Final active tail from the backend, usually empty on completion. */
  activeText?: string;
}

export interface DictationErrorMessage {
  type: "dictation_error";
  error: string;
  fatal: boolean;
}

export type DictationServerMessage =
  | DictationReadyMessage
  | DictationResultMessage
  | DictationFinalMessage
  | DictationErrorMessage;
