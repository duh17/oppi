import { describe, expect, it, vi } from "vitest";

import { authenticatedVoiceDeviceId, VoiceCallController } from "../src/continuous-voice-call.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeHandler(session: Session) {
  const voiceCalls = new VoiceCallController({ nextCallId: () => "call-1" });
  const sent: ServerMessage[] = [];
  const handler = new WsMessageHandler({
    sessions: {
      getActiveSession: vi.fn(() => undefined),
      supportsLiveVoice: () => session.runtime !== "pi-tui",
    } as unknown as WsMessageHandlerDeps["sessions"],
    ensureSessionContextWindow: (value) => value,
    voiceCalls,
  });
  return {
    voiceCalls,
    sent,
    dispatch: (
      msg: ClientMessage,
      meta: { connId?: string; authenticatedDeviceId?: string } = {
        connId: "connection-1",
        authenticatedDeviceId: "paired-device-1",
      },
    ) => handler.handleClientMessage(session, msg, (message) => sent.push(message), meta),
  };
}

describe("Live Voice calls on ordinary sessions", () => {
  it("gives voice-controller identity only to paired-device principals", () => {
    expect(authenticatedVoiceDeviceId({ kind: "device", deviceId: "phone" })).toBe("phone");
    expect(authenticatedVoiceDeviceId({ kind: "owner" })).toBeUndefined();
  });

  it("starts, detaches, and reattaches a call on the workspace session it was started from", async () => {
    const harness = makeHandler(makeSession());

    await harness.dispatch({ type: "voice_call_start", clientCallId: "client-1", requestId: "s" });
    expect(harness.sent).toContainEqual(
      expect.objectContaining({
        type: "voice_call_state",
        callId: "call-1",
        controlSessionId: "sess-1",
        lifecycle: "active",
        frontend: "attached",
      }),
    );

    const started = harness.voiceCalls.snapshot("call-1");
    harness.sent.length = 0;
    await harness.dispatch({
      type: "voice_call_detach",
      callId: "call-1",
      controllerLeaseEpoch: started.controllerLeaseEpoch,
      requestId: "d",
    });
    expect(harness.sent).toContainEqual(
      expect.objectContaining({ type: "voice_call_state", frontend: "detached" }),
    );

    harness.sent.length = 0;
    await harness.dispatch(
      { type: "voice_call_attach", callId: "call-1", lastEventSeq: 0, requestId: "a" },
      { connId: "connection-2", authenticatedDeviceId: "paired-device-1" },
    );
    expect(harness.sent).toContainEqual(
      expect.objectContaining({ type: "voice_call_state", frontend: "attached" }),
    );
    expect(harness.voiceCalls.snapshot("call-1").controllerLeaseEpoch).toBeGreaterThan(
      started.controllerLeaseEpoch,
    );
  });

  it("will not attach a call to a different session than the one it belongs to", async () => {
    const first = makeHandler(makeSession());
    await first.dispatch({ type: "voice_call_start", clientCallId: "client-1", requestId: "s" });
    const other = new WsMessageHandler({
      sessions: {
        getActiveSession: vi.fn(() => undefined),
        supportsLiveVoice: () => true,
      } as unknown as WsMessageHandlerDeps["sessions"],
      ensureSessionContextWindow: (value) => value,
      voiceCalls: first.voiceCalls,
    });
    const sent: ServerMessage[] = [];
    await other.handleClientMessage(
      makeSession({ id: "sess-2" }),
      { type: "voice_call_attach", callId: "call-1", requestId: "a" },
      (message) => sent.push(message),
      { connId: "connection-2", authenticatedDeviceId: "paired-device-1" },
    );
    expect(sent).toContainEqual(
      expect.objectContaining({
        type: "command_result",
        success: false,
        error: "Voice call belongs to a different session",
      }),
    );
  });

  it("refuses a call on a session whose runtime cannot answer out loud", async () => {
    const harness = makeHandler(makeSession({ runtime: "pi-tui" }));
    await harness.dispatch({ type: "voice_call_start", clientCallId: "client-1", requestId: "s" });
    expect(harness.sent).toEqual([
      expect.objectContaining({
        type: "command_result",
        success: false,
        error: "Live Voice works in sessions Oppi runs, not terminal mirrors",
      }),
    ]);
  });

  it("rejects owner-token streams that have no paired-device identity", async () => {
    const harness = makeHandler(makeSession());
    await harness.dispatch(
      { type: "voice_call_start", clientCallId: "client-1", requestId: "owner" },
      { connId: "connection-owner" },
    );
    expect(harness.sent).toEqual([
      expect.objectContaining({
        type: "command_result",
        command: "voice_call_start",
        success: false,
        error: "Continuous voice requires an authenticated paired device",
      }),
    ]);
  });
});
