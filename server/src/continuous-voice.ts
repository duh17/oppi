export * from "./voice-approval-bridge.js";

export type VoiceFrontendSemanticEvent =
  | { type: "connected" }
  | { type: "disconnected"; reason?: string }
  | { type: "user_speech_started" }
  | { type: "user_speech_ended" }
  | { type: "user_transcript_partial"; text: string }
  /** A finished user turn that the backend's turn policy sends to the session (local ASR). */
  | { type: "user_utterance_committed"; utteranceId: string; text: string }
  /** The voice model passed this request to the session (Grok Voice). Never approval evidence. */
  | { type: "delegation_requested"; utteranceId: string; text: string }
  /** The user's own finished words. Display and spoken approval only; never a prompt. */
  | { type: "user_transcript_final"; text: string }
  | { type: "assistant_speech_started" }
  | { type: "assistant_speech_stopped" };

export type VoiceDelegationUpdateKind = "acknowledgement" | "progress" | "final" | "blocked";

/** One thing the caller said, sent to the call's session as a message. */
export interface VoiceDelegation {
  callId: string;
  delegationId: string;
  utteranceId: string;
  request: string;
  createdAt: number;
}

export interface VoiceDelegationUpdate {
  delegationId: string;
  kind: VoiceDelegationUpdateKind;
  text: string;
}

export type VoiceFrontendEventHandler = (event: VoiceFrontendSemanticEvent) => void | Promise<void>;

/** A call's voice: hears the caller and says what the session's agent speaks. */
export interface VoiceFrontend {
  start(handler: VoiceFrontendEventHandler): void | Promise<void>;
  /** Say the agent's words to the caller, after anything already being said. */
  speak(text: string): void | Promise<void>;
  stop(): void | Promise<void>;
}
