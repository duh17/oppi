import { describe, expect, it } from "vitest";

import {
  applyForwardedCommandResultToSession,
  runtimeCommandFailure,
  runtimeCommandSuccess,
} from "../src/agent-runtime-transport.js";
import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import { SessionManager } from "../src/sessions.js";
import type { Session } from "../src/types.js";

const COMMAND_METHODS = [
  "sendPrompt",
  "sendSteer",
  "sendFollowUp",
  "getMessageQueue",
  "setMessageQueue",
  "sendAbort",
  "stopSession",
  "getActiveSession",
  "respondToUIRequest",
  "forwardClientCommand",
] as const;

const EVENT_METHODS = [
  "subscribe",
  "getCurrentSeq",
  "getCatchUp",
  "getPendingAskMessage",
  "getPendingUIRequestMessages",
] as const;

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

describe("AgentRuntimeTransport contract", () => {
  for (const [name, prototype] of [
    ["managed SessionManager", SessionManager.prototype],
    ["terminal mirror PiTuiMirrorRuntime", PiTuiMirrorRuntime.prototype],
  ] as const) {
    it(`${name} exposes the canonical command surface`, () => {
      for (const method of COMMAND_METHODS) {
        expect(typeof prototype[method], `${name}.${method}`).toBe("function");
      }
    });

    it(`${name} exposes the canonical event stream surface`, () => {
      for (const method of EVENT_METHODS) {
        expect(typeof prototype[method], `${name}.${method}`).toBe("function");
      }
    });
  }
});

describe("runtime command result helpers", () => {
  it("builds canonical success and failure command_result messages", () => {
    expect(runtimeCommandSuccess("set_model", "req-1", { ok: true })).toEqual({
      type: "command_result",
      command: "set_model",
      requestId: "req-1",
      success: true,
      data: { ok: true },
    });
    expect(runtimeCommandFailure("set_model", "req-2", "nope")).toEqual({
      type: "command_result",
      command: "set_model",
      requestId: "req-2",
      success: false,
      error: "nope",
    });
  });

  it("applies managed and mirror model response shapes to session metadata", () => {
    const managed = makeSession();
    const mirror = makeSession();

    const managedResult = applyForwardedCommandResultToSession({
      session: managed,
      commandType: "set_model",
      request: { type: "set_model" },
      data: { provider: "openai", id: "gpt-5.5", thinkingLevel: "high" },
      contextWindowResolver: () => 272000,
    });
    const mirrorResult = applyForwardedCommandResultToSession({
      session: mirror,
      commandType: "cycle_model",
      request: { type: "cycle_model" },
      data: { model: { provider: "openai", modelId: "gpt-5.5" }, thinkingLevel: "high" },
      contextWindowResolver: () => 272000,
    });

    expect(managedResult).toEqual({ changed: true, shouldBroadcastState: true });
    expect(mirrorResult).toEqual({ changed: true, shouldBroadcastState: true });
    expect(managed).toMatchObject({
      model: "openai/gpt-5.5",
      thinkingLevel: "high",
      contextWindow: 272000,
    });
    expect(mirror).toMatchObject({
      model: "openai/gpt-5.5",
      thinkingLevel: "high",
      contextWindow: 272000,
    });
  });

  it("applies fallback request values for name and explicit thinking-level commands", () => {
    const session = makeSession({ name: "Before", thinkingLevel: "medium" });

    const rename = applyForwardedCommandResultToSession({
      session,
      commandType: "set_session_name",
      request: { type: "set_session_name", name: "After" },
      data: {},
    });
    const thinking = applyForwardedCommandResultToSession({
      session,
      commandType: "set_thinking_level",
      request: { type: "set_thinking_level", level: "xhigh" },
      data: {},
    });

    expect(rename).toEqual({ changed: true, shouldBroadcastState: true });
    expect(thinking).toEqual({ changed: true, shouldBroadcastState: true });
    expect(session.name).toBe("After");
    expect(session.thinkingLevel).toBe("xhigh");
  });
});
