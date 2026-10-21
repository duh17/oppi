import type { VoiceCallFrontendConnection } from "../../src/continuous-voice-call.js";
import type { ServerMessage } from "../../src/types.js";

/** Deterministic transport/frontend fixture for provider-free controller tests. */
export class DeterministicVoiceCallFrontend {
  readonly messages: ServerMessage[] = [];
  readonly audio: Buffer[] = [];
  readonly connection: VoiceCallFrontendConnection;

  constructor(input: { connectionId: string; authenticatedDeviceId: string }) {
    this.connection = {
      ...input,
      send: (message) => this.messages.push(structuredClone(message)),
      sendAudio: (pcm) => this.audio.push(Buffer.from(pcm)),
    };
  }
}
