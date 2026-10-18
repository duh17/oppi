import { describe, expect, it, vi } from "vitest";

import {
  ContinuousVoiceSession,
  DeterministicVoiceFrontend,
  VoiceControlBridgeRegistry,
  VoicePiControlBridge,
  type VoiceDelegationUpdate,
} from "../src/continuous-voice.js";

type RegisteredTool = {
  name: string;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
  ) => Promise<{ content: Array<{ type: string; text: string }>; details?: unknown }>;
};

type SessionContext = {
  isIdle(): boolean;
};

function bindPiBridge(bridge: VoicePiControlBridge) {
  const tools = new Map<string, RegisteredTool>();
  const handlers = new Map<string, (event: unknown, ctx: SessionContext) => void>();
  const sendMessage = vi.fn();
  const api = {
    registerTool(tool: RegisteredTool) {
      tools.set(tool.name, tool);
    },
    on(name: string, handler: (event: unknown, ctx: SessionContext) => void) {
      handlers.set(name, handler);
    },
    sendMessage,
  };

  bridge.extension.factory(api as never);
  handlers.get("session_start")?.({}, { isIdle: () => true });
  return { tools, handlers, sendMessage };
}

describe("continuous voice Stage 1 vertical slice", () => {
  it("registry dispatches utterances to the registered Pi bridge", async () => {
    const bridge = new VoicePiControlBridge();
    const pi = bindPiBridge(bridge);
    const registry = new VoiceControlBridgeRegistry();
    const unregister = registry.register("voice-session-1", bridge);
    registry.dispatch("voice-session-1", {
      callId: "call-1",
      delegationId: "delegation-1",
      utteranceId: "utterance-1",
      request: "list open sessions",
      createdAt: 1_000,
    });
    expect(pi.sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        customType: "oppi.voice.delegation",
        content: "list open sessions",
      }),
      expect.objectContaining({ triggerTurn: true }),
    );
    const updates: VoiceDelegationUpdate[] = [];
    registry.setUpdateHandler((_sessionId, update) => {
      updates.push(update);
    });
    const voiceUpdate = pi.tools.get("voice_update");
    await voiceUpdate?.execute("tool-1", {
      delegationId: "delegation-1",
      kind: "progress",
      text: "Looking at the inbox",
    });
    expect(updates).toEqual([
      {
        delegationId: "delegation-1",
        kind: "progress",
        text: "Looking at the inbox",
      },
    ]);
    unregister();
    expect(() =>
      registry.dispatch("voice-session-1", {
        callId: "call-1",
        delegationId: "delegation-2",
        utteranceId: "utterance-2",
        request: "should fail",
        createdAt: 1_001,
      }),
    ).toThrow("Voice Pi control extension is not connected");
  });

  it("keeps multiple delegation identities independent through acknowledgement, progress, blocked, and final", async () => {
    const frontend = new DeterministicVoiceFrontend();
    const bridge = new VoicePiControlBridge();
    const pi = bindPiBridge(bridge);
    const ids = ["delegation-a", "delegation-b"];
    const session = new ContinuousVoiceSession({
      callId: "call-1",
      frontend,
      bridge,
      nextDelegationId: () => ids.shift() ?? "unexpected",
    });

    await session.start();
    await frontend.run([
      { type: "connected" },
      { type: "user_speech_started" },
      {
        type: "user_utterance_committed",
        utteranceId: "utterance-a",
        text: "Fix the resume test",
      },
      {
        type: "user_utterance_committed",
        utteranceId: "utterance-b",
        text: "Also inspect the reconnect race",
      },
    ]);

    expect(pi.sendMessage).toHaveBeenCalledTimes(2);
    expect(pi.sendMessage.mock.calls.map((call) => call[0])).toEqual([
      expect.objectContaining({
        customType: "oppi.voice.delegation",
        content: "Fix the resume test",
        details: expect.objectContaining({
          callId: "call-1",
          delegationId: "delegation-a",
          utteranceId: "utterance-a",
        }),
      }),
      expect.objectContaining({
        customType: "oppi.voice.delegation",
        content: "Also inspect the reconnect race",
        details: expect.objectContaining({
          callId: "call-1",
          delegationId: "delegation-b",
          utteranceId: "utterance-b",
        }),
      }),
    ]);

    const update = pi.tools.get("voice_update");
    if (!update) throw new Error("voice_update was not registered");

    const updates: VoiceDelegationUpdate[] = [
      {
        delegationId: "delegation-a",
        kind: "acknowledgement",
        text: "Got it.",
      },
      {
        delegationId: "delegation-b",
        kind: "acknowledgement",
        text: "I’ll inspect that too.",
      },
      {
        delegationId: "delegation-a",
        kind: "progress",
        text: "The focused test now passes.",
      },
      {
        delegationId: "delegation-b",
        kind: "blocked",
        text: "Approval is required to continue.",
      },
      {
        delegationId: "delegation-a",
        kind: "final",
        text: "The resume fix is complete.",
      },
      {
        delegationId: "delegation-b",
        kind: "final",
        text: "The reconnect race is documented.",
      },
    ];
    for (const candidate of updates) {
      await update.execute(`tool-${candidate.delegationId}-${candidate.kind}`, candidate);
    }

    expect(frontend.outputs).toEqual(updates);
    expect(session.snapshot().delegations).toEqual([
      expect.objectContaining({
        delegationId: "delegation-a",
        state: "completed",
        latestText: "The resume fix is complete.",
      }),
      expect.objectContaining({
        delegationId: "delegation-b",
        state: "completed",
        latestText: "The reconnect race is documented.",
      }),
    ]);
  });

  it("rejects updates for unknown or completed delegations without disturbing other work", async () => {
    const frontend = new DeterministicVoiceFrontend();
    const bridge = new VoicePiControlBridge();
    const pi = bindPiBridge(bridge);
    const session = new ContinuousVoiceSession({
      callId: "call-2",
      frontend,
      bridge,
      nextDelegationId: () => "delegation-known",
    });
    await session.start();
    await frontend.run([
      {
        type: "user_utterance_committed",
        utteranceId: "utterance-known",
        text: "Run the focused check",
      },
    ]);

    const update = pi.tools.get("voice_update");
    if (!update) throw new Error("voice_update was not registered");
    await expect(
      update.execute("unknown", {
        delegationId: "delegation-unknown",
        kind: "progress",
        text: "Should not be accepted",
      }),
    ).rejects.toThrow("Unknown voice delegation");

    await update.execute("final", {
      delegationId: "delegation-known",
      kind: "final",
      text: "Done",
    });
    await expect(
      update.execute("late", {
        delegationId: "delegation-known",
        kind: "progress",
        text: "Late progress",
      }),
    ).rejects.toThrow("already completed");

    expect(frontend.outputs).toEqual([
      { delegationId: "delegation-known", kind: "final", text: "Done" },
    ]);
  });

  it("uses follow-up delivery for independent work while Pi is busy", async () => {
    const bridge = new VoicePiControlBridge();
    const pi = bindPiBridge(bridge);
    pi.handlers.get("session_start")?.({}, { isIdle: () => false });

    await bridge.dispatch({
      callId: "call-busy",
      delegationId: "delegation-busy",
      utteranceId: "utterance-busy",
      request: "Queue this independent task",
      createdAt: 1,
    });

    expect(pi.sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ customType: "oppi.voice.delegation" }),
      { deliverAs: "followUp", triggerTurn: true },
    );
  });
});
