import { describe, expect, it } from "vitest";

import { parseClientCommand } from "../src/session-command-parse.js";

describe("parseClientCommand", () => {
  it.each([
    {
      name: "navigate_tree missing targetId",
      body: { type: "navigate_tree", requestId: "req-nav" },
      code: "invalid_field",
      error: "Invalid payload: expected targetId",
      command: "navigate_tree",
      requestId: "req-nav",
    },
    {
      name: "navigate_tree blank targetId",
      body: { type: "navigate_tree", targetId: "   ", requestId: "req-nav" },
      code: "invalid_field",
      error: "Invalid payload: expected targetId",
      command: "navigate_tree",
      requestId: "req-nav",
    },
    {
      name: "set_model with only a combined model id",
      body: { type: "set_model", model: "anthropic/claude-sonnet-4-0", requestId: "req-model" },
      code: "invalid_field",
      error: "Invalid payload: expected provider",
      command: "set_model",
      requestId: "req-model",
    },
    {
      name: "set_model provider without modelId",
      body: { type: "set_model", provider: "anthropic", requestId: "req-model" },
      code: "invalid_field",
      error: "Invalid payload: expected modelId",
      command: "set_model",
      requestId: "req-model",
    },
    {
      name: "set_model blank provider+modelId",
      body: { type: "set_model", provider: "  ", modelId: "  ", requestId: "req-model" },
      code: "invalid_field",
      error: "Invalid payload: expected provider",
      command: "set_model",
      requestId: "req-model",
    },
    {
      name: "set_auto_compaction string enabled",
      body: { type: "set_auto_compaction", enabled: "false", requestId: "req-compact" },
      code: "invalid_field",
      error: "Invalid payload: expected enabled",
      command: "set_auto_compaction",
      requestId: "req-compact",
    },
    {
      name: "set_auto_retry missing enabled",
      body: { type: "set_auto_retry", requestId: "req-retry" },
      code: "invalid_field",
      error: "Invalid payload: expected enabled",
      command: "set_auto_retry",
      requestId: "req-retry",
    },
    {
      name: "set_steering_mode unknown mode",
      body: { type: "set_steering_mode", mode: "some", requestId: "req-mode" },
      code: "invalid_field",
      error: "Invalid payload: expected mode",
      command: "set_steering_mode",
      requestId: "req-mode",
    },
    {
      name: "set_follow_up_mode missing mode",
      body: { type: "set_follow_up_mode", requestId: "req-mode" },
      code: "invalid_field",
      error: "Invalid payload: expected mode",
      command: "set_follow_up_mode",
      requestId: "req-mode",
    },
    {
      name: "set_thinking_level unknown level",
      body: { type: "set_thinking_level", level: "turbo", requestId: "req-think" },
      code: "invalid_field",
      error: "Invalid payload: expected level",
      command: "set_thinking_level",
      requestId: "req-think",
    },
    {
      name: "set_session_name missing name",
      body: { type: "set_session_name", requestId: "req-name" },
      code: "invalid_field",
      error: "Invalid payload: expected name",
      command: "set_session_name",
      requestId: "req-name",
    },
    {
      name: "set_session_name blank name",
      body: { type: "set_session_name", name: "\t", requestId: "req-name" },
      code: "invalid_field",
      error: "Invalid payload: expected name",
      command: "set_session_name",
      requestId: "req-name",
    },
    {
      name: "set_thinking_level missing level",
      body: { type: "set_thinking_level", requestId: "req-think" },
      code: "invalid_field",
      error: "Invalid payload: expected level",
      command: "set_thinking_level",
      requestId: "req-think",
    },
    {
      name: "set_thinking_level blank level",
      body: { type: "set_thinking_level", level: " ", requestId: "req-think" },
      code: "invalid_field",
      error: "Invalid payload: expected level",
      command: "set_thinking_level",
      requestId: "req-think",
    },
    {
      name: "fork missing entryId",
      body: { type: "fork", requestId: "req-fork" },
      code: "invalid_field",
      error: "Invalid payload: expected entryId",
      command: "fork",
      requestId: "req-fork",
    },
    {
      name: "fork non-string entryId",
      body: { type: "fork", entryId: 12, requestId: "req-fork" },
      code: "invalid_field",
      error: "Invalid payload: expected entryId",
      command: "fork",
      requestId: "req-fork",
    },
    {
      name: "prompt missing message",
      body: { type: "prompt", requestId: "req-prompt" },
      code: "invalid_field",
      error: "Invalid payload: expected message",
      command: "prompt",
      requestId: "req-prompt",
    },
    {
      name: "extension_ui_response missing id",
      body: { type: "extension_ui_response", requestId: "req-ui" },
      code: "invalid_field",
      error: "Invalid payload: expected id",
      command: "extension_ui_response",
      requestId: "req-ui",
    },
    {
      name: "voice_call_start missing clientCallId",
      body: { type: "voice_call_start", requestId: "req-voice" },
      code: "invalid_field",
      error: "Invalid payload: expected clientCallId",
      command: "voice_call_start",
      requestId: "req-voice",
    },
    {
      name: "voice_call_end missing controllerLeaseEpoch",
      body: { type: "voice_call_end", callId: "call-1", requestId: "req-voice" },
      code: "invalid_field",
      error: "Invalid payload: expected controllerLeaseEpoch",
      command: "voice_call_end",
      requestId: "req-voice",
    },
    {
      name: "voice_approval_response missing transcript",
      body: {
        type: "voice_approval_response",
        callId: "call-1",
        controllerLeaseEpoch: 1,
        challengeId: "challenge-1",
        requestId: "req-voice",
      },
      code: "invalid_field",
      error: "Invalid payload: expected transcript",
      command: "voice_approval_response",
      requestId: "req-voice",
    },
  ])("rejects malformed required fields: $name", ({ body, code, error, command, requestId }) => {
    expect(parseClientCommand(body)).toEqual({
      ok: false,
      code,
      error,
      command,
      requestId,
    });
  });

  it.each([
    {
      name: "unknown command type",
      body: { type: "future_command_v99", requestId: "req-unknown" },
      code: "unknown_type",
      error: "Unsupported command type: future_command_v99",
      command: "future_command_v99",
      requestId: "req-unknown",
    },
    {
      name: "missing type",
      body: { requestId: "req-type" },
      code: "missing_type",
      error: "Message type is required",
      requestId: "req-type",
    },
    {
      name: "blank type",
      body: { type: "   ", requestId: "req-type" },
      code: "missing_type",
      error: "Message type is required",
      requestId: "req-type",
    },
    {
      name: "non-object payload",
      body: ["prompt"],
      code: "not_object",
      error: "Message payload must be a JSON object",
    },
    {
      name: "null payload",
      body: null,
      code: "not_object",
      error: "Message payload must be a JSON object",
    },
  ])(
    "rejects unknown or untyped command bodies: $name",
    ({ body, code, error, command, requestId }) => {
      expect(parseClientCommand(body)).toEqual({
        ok: false,
        code,
        error,
        ...(command ? { command } : {}),
        ...(requestId ? { requestId } : {}),
      });
    },
  );

  it.each([
    {
      name: "navigate_tree",
      body: { type: "navigate_tree", targetId: "entry-1", summarize: true, requestId: "ok" },
    },
    {
      name: "set_model provider+modelId",
      body: { type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-0" },
    },
    {
      name: "set_model persist true",
      body: {
        type: "set_model",
        provider: "anthropic",
        modelId: "claude-sonnet-4-0",
        persist: true,
      },
    },
    {
      name: "set_session_name",
      body: { type: "set_session_name", name: "Planning" },
    },
    {
      name: "set_thinking_level",
      body: { type: "set_thinking_level", level: "high" },
    },
    {
      name: "set_thinking_level persist true",
      body: { type: "set_thinking_level", level: "high", persist: true },
    },
    {
      name: "set_auto_compaction off",
      body: { type: "set_auto_compaction", enabled: false },
    },
    {
      name: "set_follow_up_mode one-at-a-time",
      body: { type: "set_follow_up_mode", mode: "one-at-a-time" },
    },
    {
      name: "fork",
      body: { type: "fork", entryId: "entry-9" },
    },
    {
      name: "prompt with empty message",
      body: { type: "prompt", message: "" },
    },
    {
      name: "reload",
      body: { type: "reload" },
    },
    {
      name: "share_session",
      body: { type: "share_session" },
    },
    {
      name: "dictation_start",
      body: { type: "dictation_start" },
    },
    {
      name: "voice_call_start",
      body: { type: "voice_call_start", clientCallId: "client-call-1" },
    },
    {
      name: "voice_call_attach",
      body: { type: "voice_call_attach", callId: "call-1", lastEventSeq: 12 },
    },
    {
      name: "voice_call_end",
      body: { type: "voice_call_end", callId: "call-1", controllerLeaseEpoch: 4 },
    },
    {
      name: "voice_approval_response",
      body: {
        type: "voice_approval_response",
        callId: "call-1",
        controllerLeaseEpoch: 4,
        challengeId: "challenge-1",
        transcript: "approve once",
      },
    },
  ])("accepts a valid $name command body", ({ body }) => {
    const parsed = parseClientCommand(body);
    expect(parsed).toEqual({ ok: true, message: body });
  });
});
