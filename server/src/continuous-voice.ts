import { StringEnum } from "@earendil-works/pi-ai";
import type {
  ExtensionAPI,
  ExtensionContext,
  InlineExtension,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export * from "./voice-approval-bridge.js";

export type VoiceConnectionState = "disconnected" | "connecting" | "connected";
export type VoiceInputState = "idle" | "listening" | "speaking";
export type VoiceOutputState = "idle" | "speaking";

export type VoiceFrontendSemanticEvent =
  | { type: "connected" }
  | { type: "disconnected"; reason?: string }
  | { type: "user_speech_started" }
  | { type: "user_speech_ended" }
  | { type: "user_transcript_partial"; text: string }
  | { type: "user_utterance_committed"; utteranceId: string; text: string }
  | { type: "assistant_speech_started" }
  | { type: "assistant_speech_stopped" };

export type VoiceDelegationUpdateKind = "acknowledgement" | "progress" | "final" | "blocked";

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

export type VoiceDelegationState =
  | "delegated"
  | "acknowledged"
  | "working"
  | "blocked"
  | "completed";

export interface VoiceDelegationSnapshot extends VoiceDelegation {
  state: VoiceDelegationState;
  latestText?: string;
  updates: readonly VoiceDelegationUpdate[];
}

export interface ContinuousVoiceSnapshot {
  callId: string;
  connection: VoiceConnectionState;
  input: VoiceInputState;
  output: VoiceOutputState;
  partialTranscript?: string;
  delegations: readonly VoiceDelegationSnapshot[];
}

export type VoiceFrontendEventHandler = (event: VoiceFrontendSemanticEvent) => void | Promise<void>;

export interface VoiceFrontend {
  start(handler: VoiceFrontendEventHandler): void | Promise<void>;
  publish(update: VoiceDelegationUpdate): void | Promise<void>;
  stop(): void | Promise<void>;
}

export interface VoiceControlBridge {
  dispatch(delegation: VoiceDelegation): void | Promise<void>;
  subscribe(listener: (update: VoiceDelegationUpdate) => void): () => void;
}

/** Routes Live Voice utterances into the hidden voice-control Pi session. */
export class VoiceControlBridgeRegistry {
  private readonly bridges = new Map<
    string,
    { bridge: VoiceControlBridge; unsubscribe: () => void }
  >();
  private updateHandler: ((sessionId: string, update: VoiceDelegationUpdate) => void) | undefined;

  setUpdateHandler(handler: (sessionId: string, update: VoiceDelegationUpdate) => void): void {
    this.updateHandler = handler;
  }

  register(sessionId: string, bridge: VoiceControlBridge): () => void {
    this.unregister(sessionId);
    const unsubscribe = bridge.subscribe((update) => {
      this.updateHandler?.(sessionId, update);
    });
    this.bridges.set(sessionId, { bridge, unsubscribe });
    return () => this.unregister(sessionId, bridge);
  }

  dispatch(sessionId: string, delegation: VoiceDelegation): void {
    const entry = this.bridges.get(sessionId);
    if (!entry) throw new Error("Voice Pi control extension is not connected");
    void entry.bridge.dispatch(delegation);
  }

  private unregister(sessionId: string, expected?: VoiceControlBridge): void {
    const entry = this.bridges.get(sessionId);
    if (!entry) return;
    if (expected && entry.bridge !== expected) return;
    entry.unsubscribe();
    this.bridges.delete(sessionId);
  }
}

/**
 * Provider-neutral call state for Stage 1.
 *
 * Media adapters emit semantic frontend events; the Pi bridge sees only typed
 * delegations and typed updates. No provider identifiers or wire details enter
 * this state machine.
 */
export class ContinuousVoiceSession {
  private connection: VoiceConnectionState = "disconnected";
  private input: VoiceInputState = "idle";
  private output: VoiceOutputState = "idle";
  private partialTranscript: string | undefined;
  private readonly delegations = new Map<string, MutableDelegation>();
  private unsubscribeBridge: (() => void) | undefined;
  private started = false;
  private readonly now: () => number;

  constructor(
    private readonly options: {
      callId: string;
      frontend: VoiceFrontend;
      bridge: VoiceControlBridge;
      nextDelegationId: () => string;
      now?: () => number;
    },
  ) {
    this.now = options.now ?? Date.now;
  }

  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    this.connection = "connecting";
    this.unsubscribeBridge = this.options.bridge.subscribe((update) => {
      this.applyDelegationUpdate(update);
    });
    await this.options.frontend.start((event) => this.handleFrontendEvent(event));
  }

  async stop(): Promise<void> {
    if (!this.started) return;
    this.started = false;
    this.unsubscribeBridge?.();
    this.unsubscribeBridge = undefined;
    await this.options.frontend.stop();
    this.connection = "disconnected";
    this.input = "idle";
    this.output = "idle";
  }

  snapshot(): ContinuousVoiceSnapshot {
    return {
      callId: this.options.callId,
      connection: this.connection,
      input: this.input,
      output: this.output,
      ...(this.partialTranscript !== undefined
        ? { partialTranscript: this.partialTranscript }
        : {}),
      delegations: [...this.delegations.values()].map((delegation) => ({
        callId: delegation.callId,
        delegationId: delegation.delegationId,
        utteranceId: delegation.utteranceId,
        request: delegation.request,
        createdAt: delegation.createdAt,
        state: delegation.state,
        ...(delegation.latestText !== undefined ? { latestText: delegation.latestText } : {}),
        updates: [...delegation.updates],
      })),
    };
  }

  private async handleFrontendEvent(event: VoiceFrontendSemanticEvent): Promise<void> {
    switch (event.type) {
      case "connected":
        this.connection = "connected";
        this.input = "listening";
        return;
      case "disconnected":
        this.connection = "disconnected";
        this.input = "idle";
        this.output = "idle";
        return;
      case "user_speech_started":
        this.input = "speaking";
        return;
      case "user_speech_ended":
        this.input = "listening";
        return;
      case "user_transcript_partial":
        this.partialTranscript = event.text;
        return;
      case "assistant_speech_started":
        this.output = "speaking";
        return;
      case "assistant_speech_stopped":
        this.output = "idle";
        return;
      case "user_utterance_committed": {
        const request = event.text.trim();
        if (!request) return;
        const delegationId = this.options.nextDelegationId();
        if (!delegationId.trim() || this.delegations.has(delegationId)) {
          throw new Error(`Duplicate or empty voice delegation id: ${delegationId}`);
        }
        const delegation: VoiceDelegation = {
          callId: this.options.callId,
          delegationId,
          utteranceId: event.utteranceId,
          request,
          createdAt: this.now(),
        };
        this.partialTranscript = undefined;
        this.delegations.set(delegationId, {
          ...delegation,
          state: "delegated",
          updates: [],
        });
        await this.options.bridge.dispatch(delegation);
        return;
      }
    }
  }

  private applyDelegationUpdate(update: VoiceDelegationUpdate): void {
    const delegation = this.delegations.get(update.delegationId);
    if (!delegation) {
      throw new Error(`Unknown voice delegation: ${update.delegationId}`);
    }
    if (delegation.state === "completed") {
      throw new Error(`Voice delegation ${update.delegationId} is already completed`);
    }

    delegation.state = stateForUpdate(update.kind);
    delegation.latestText = update.text;
    delegation.updates.push({ ...update });
    void Promise.resolve(this.options.frontend.publish({ ...update })).catch(() => {
      // Frontend delivery can be retried by the call owner. It must not mutate
      // or roll back the authoritative delegation state owned by Oppi.
    });
  }
}

interface MutableDelegation extends VoiceDelegation {
  state: VoiceDelegationState;
  latestText?: string;
  updates: VoiceDelegationUpdate[];
}

function stateForUpdate(kind: VoiceDelegationUpdateKind): VoiceDelegationState {
  switch (kind) {
    case "acknowledgement":
      return "acknowledged";
    case "progress":
      return "working";
    case "blocked":
      return "blocked";
    case "final":
      return "completed";
  }
}

/** Deterministic, hardware-free frontend used by Stage 1 conformance tests. */
export class DeterministicVoiceFrontend implements VoiceFrontend {
  readonly outputs: VoiceDelegationUpdate[] = [];
  private handler: VoiceFrontendEventHandler | undefined;

  start(handler: VoiceFrontendEventHandler): void {
    this.handler = handler;
  }

  publish(update: VoiceDelegationUpdate): void {
    this.outputs.push({ ...update });
  }

  stop(): void {
    this.handler = undefined;
  }

  async run(events: readonly VoiceFrontendSemanticEvent[]): Promise<void> {
    if (!this.handler) throw new Error("Deterministic voice frontend is not started");
    for (const event of events) {
      await this.handler(event);
    }
  }
}

const VoiceUpdateParams = Type.Object({
  delegationId: Type.String({ minLength: 1, maxLength: 128 }),
  kind: StringEnum(["acknowledgement", "progress", "final", "blocked"] as const),
  text: Type.String({ minLength: 1, maxLength: 2_000 }),
});

/**
 * Narrow Pi extension bridge for a hidden tool-capable control session.
 *
 * The extension receives typed custom messages and exposes only `voice_update`.
 * It intentionally has no approval operation: approvals remain a separate
 * server authority path through VoiceApprovalBridge.
 */
export class VoicePiControlBridge implements VoiceControlBridge {
  readonly extension: InlineExtension;
  private pi: ExtensionAPI | undefined;
  private context: ExtensionContext | undefined;
  private readonly knownDelegations = new Set<string>();
  private readonly listeners = new Set<(update: VoiceDelegationUpdate) => void>();

  constructor() {
    this.extension = {
      name: "oppi-continuous-voice-control",
      factory: (pi) => this.bindExtension(pi),
    };
  }

  subscribe(listener: (update: VoiceDelegationUpdate) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  dispatch(delegation: VoiceDelegation): void {
    const pi = this.pi;
    const context = this.context;
    if (!pi || !context) throw new Error("Voice Pi control extension is not connected");
    if (this.knownDelegations.has(delegation.delegationId)) {
      throw new Error(`Duplicate voice delegation: ${delegation.delegationId}`);
    }
    this.knownDelegations.add(delegation.delegationId);
    try {
      pi.sendMessage(
        {
          customType: "oppi.voice.delegation",
          content: delegation.request,
          display: true,
          details: {
            callId: delegation.callId,
            delegationId: delegation.delegationId,
            utteranceId: delegation.utteranceId,
            createdAt: delegation.createdAt,
          },
        },
        {
          deliverAs: context.isIdle() ? "steer" : "followUp",
          triggerTurn: true,
        },
      );
    } catch (error) {
      this.knownDelegations.delete(delegation.delegationId);
      throw error;
    }
  }

  private bindExtension(pi: ExtensionAPI): void {
    this.pi = pi;
    pi.on("session_start", (_event, ctx) => {
      this.context = ctx;
    });
    pi.on("session_shutdown", () => {
      if (this.pi === pi) {
        this.pi = undefined;
        this.context = undefined;
      }
    });
    pi.registerTool<typeof VoiceUpdateParams>({
      name: "voice_update",
      label: "Voice Update",
      description:
        "Report a concise acknowledgement, progress update, final result, or blocker for one Oppi voice delegation.",
      promptSnippet:
        "Report acknowledgement, progress, final, or blocked status for a specific voice delegation ID.",
      promptGuidelines: [
        "Use voice_update with the exact delegationId from the Oppi voice request; never invent or reuse a different delegation ID.",
        "Use voice_update acknowledgement promptly, progress sparingly, blocked when user action is required, and final exactly once when work is complete.",
        "voice_update reports status only and cannot approve permission requests; leave approvals to Oppi's structured permission gate.",
      ],
      parameters: VoiceUpdateParams,
      executionMode: "sequential",
      execute: async (_toolCallId, params) => {
        const delegationId = params.delegationId.trim();
        const text = params.text.trim();
        if (!delegationId || !text) throw new Error("voice_update fields must not be empty");
        if (!this.knownDelegations.has(delegationId)) {
          throw new Error(`Unknown voice delegation: ${delegationId}`);
        }
        const update: VoiceDelegationUpdate = {
          delegationId,
          kind: params.kind,
          text,
        };
        for (const listener of this.listeners) listener(update);
        return {
          content: [{ type: "text" as const, text: `Voice ${params.kind} recorded.` }],
          details: update,
        };
      },
    });
  }
}
