import { describe, expect, it, vi } from "vitest";

import {
  assertNoCommandError,
  resolveSendStreamingKind,
  sendSessionInput,
} from "../src/cli/commands/session-interactions.js";

describe("session interaction command contract", () => {
  it.each([
    [{}, undefined],
    [{ steer: "true" }, "steer"],
    [{ "follow-up": "true" }, "follow_up"],
  ])("resolves streaming send flags %#", (flags, expected) => {
    expect(resolveSendStreamingKind(flags)).toBe(expected);
  });

  it("rejects conflicting streaming send flags", () => {
    expect(() => resolveSendStreamingKind({ steer: "true", "follow-up": "true" })).toThrow(
      "cannot be used together",
    );
  });

  it.each([
    ["prompt", { type: "prompt", message: "hello", streamingBehavior: "steer" }],
    ["steer", { type: "prompt", message: "hello", streamingBehavior: "steer" }],
    ["follow_up", { type: "prompt", message: "hello", streamingBehavior: "followUp" }],
  ] as const)("posts encoded %s session input as a prompt with its busy-session behavior", async (kind, body) => {
    const call = vi.fn().mockResolvedValue({ messages: [] });

    const result = await sendSessionInput("session/one", kind, "hello", call);

    expect(result).toEqual({ messages: [] });
    expect(call).toHaveBeenCalledWith("/sessions/session%2Fone/command", {
      method: "POST",
      body,
    });
  });

  it("keeps the caller's turn id on a follow-up so a retry is the same turn", async () => {
    const call = vi.fn().mockResolvedValue({ messages: [] });

    await sendSessionInput("s", "follow_up", "later", call, "turn-9");

    expect(call).toHaveBeenCalledWith("/sessions/s/command", {
      method: "POST",
      body: {
        type: "prompt",
        message: "later",
        clientTurnId: "turn-9",
        requestId: "turn-9",
        streamingBehavior: "followUp",
      },
    });
  });

  it("adds steering guidance only to idle-session prompt failures", async () => {
    const promptError = new Error("Prompt requires an idle session");
    await expect(
      sendSessionInput("s", "prompt", "hello", vi.fn().mockRejectedValue(promptError)),
    ).rejects.toThrow(/--steer.*--follow-up/);

    const steerError = new Error("Prompt requires an idle session");
    await expect(
      sendSessionInput("s", "steer", "hello", vi.fn().mockRejectedValue(steerError)),
    ).rejects.toThrow("Prompt requires an idle session");
    expect(steerError.message).not.toContain("--steer");
  });

  it("maps command error records to failures and ignores partial non-error records", () => {
    expect(() =>
      assertNoCommandError({ messages: [null, {}, { type: "command_result" }] }),
    ).not.toThrow();
    expect(() => assertNoCommandError({ messages: [{ type: "error" }] })).toThrow(
      "Session command was rejected",
    );
    expect(() =>
      assertNoCommandError(
        { messages: [{ type: "error", error: "requires an idle session" }] },
        true,
      ),
    ).toThrow(/--steer/);
  });
});
