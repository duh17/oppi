import { describe, expect, it, vi } from "vitest";

import {
  assertNoCommandError,
  buildDialogResponse,
  dialogMetaLabels,
  dialogOptionDetails,
  dialogPromptText,
  resolveDialogTarget,
  resolveSendStreamingKind,
  sendSessionInput,
  type DialogSnapshot,
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
    ["steer", { type: "steer", message: "hello" }],
    ["follow_up", { type: "follow_up", message: "hello" }],
  ] as const)("posts encoded %s session input with its delivery behavior", async (kind, body) => {
    const call = vi.fn().mockResolvedValue({ messages: [] });

    const result = await sendSessionInput("session/one", kind, "hello", call);

    expect(result).toEqual({ messages: [] });
    expect(call).toHaveBeenCalledWith("/sessions/session%2Fone/command", {
      method: "POST",
      body,
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

  it("selects a requested dialog or the sole pending dialog", () => {
    const dialogs: DialogSnapshot[] = [
      { id: "one", method: "input" },
      { id: "two", method: "confirm" },
    ];
    expect(resolveDialogTarget(dialogs, "two")).toBe(dialogs[1]);
    expect(resolveDialogTarget([dialogs[0] as DialogSnapshot], undefined)).toBe(dialogs[0]);
    expect(() => resolveDialogTarget(dialogs, undefined)).toThrow("Multiple pending dialogs");
    expect(() => resolveDialogTarget(dialogs, "missing")).toThrow("No pending dialog");
    expect(() => resolveDialogTarget([], undefined)).toThrow("No pending dialogs");
  });

  it.each([
    [
      { id: "confirm", method: "confirm" },
      { confirm: "true" },
      { type: "extension_ui_response", id: "confirm", confirmed: true },
    ],
    [
      { id: "confirm", method: "confirm" },
      { decline: "true" },
      { type: "extension_ui_response", id: "confirm", confirmed: false },
    ],
    [
      { id: "select", method: "select", options: ["one", "two"] },
      { option: "two" },
      { type: "extension_ui_response", id: "select", value: "two" },
    ],
    [
      { id: "input", method: "input" },
      { text: "typed" },
      { type: "extension_ui_response", id: "input", value: "typed" },
    ],
    [
      { id: "cancel", method: "input" },
      { cancel: "true" },
      { type: "extension_ui_response", id: "cancel", cancelled: true },
    ],
  ] satisfies Array<[DialogSnapshot, Record<string, string>, Record<string, unknown>]>)(
    "builds semantic dialog response %#",
    (dialog, flags, expected) => {
      expect(buildDialogResponse(dialog, flags)).toEqual(expected);
    },
  );

  it("builds single and multi-question ask answers", () => {
    const single: DialogSnapshot = {
      id: "ask-1",
      method: "ask",
      questions: [
        {
          id: "approach",
          question: "Which?",
          options: [{ value: "unit", label: "Unit" }],
        },
      ],
      allowCustom: false,
    };
    expect(buildDialogResponse(single, { option: "unit" })).toEqual({
      type: "extension_ui_response",
      id: "ask-1",
      value: JSON.stringify({ approach: "unit" }),
    });

    const multi: DialogSnapshot = {
      id: "ask-2",
      method: "ask",
      questions: [
        { id: "lanes", question: "Lanes?", options: [{ value: "cli" }], multiSelect: true },
        { id: "note", question: "Note?" },
      ],
      allowCustom: true,
    };
    expect(
      buildDialogResponse(multi, { answers: JSON.stringify({ lanes: ["cli"], note: "done" }) }),
    ).toMatchObject({
      type: "extension_ui_response",
      id: "ask-2",
      value: JSON.stringify({ lanes: ["cli"], note: "done" }),
    });
  });

  it.each([
    [{ method: "input" }, { text: "x" }, "missing a request id"],
    [{ id: "c", method: "confirm" }, { text: "x" }, "Confirm dialog requires"],
    [{ id: "s", method: "select", options: ["one"] }, { option: "two" }, "Unknown option"],
    [{ id: "i", method: "input" }, { option: "one" }, "Input dialog requires"],
    [{ id: "u", method: "future" }, { text: "x" }, "Unsupported pending dialog method"],
    [
      { id: "a", method: "ask", questions: [{ id: "q", options: [{ value: "one" }] }] },
      { option: "two" },
      "Unknown option",
    ],
    [
      {
        id: "a",
        method: "ask",
        questions: [{ id: "q", options: [{ value: "one" }] }],
        allowCustom: false,
      },
      { text: "custom" },
      "only accepts listed options",
    ],
    [
      { id: "a", method: "ask", questions: [{ id: "q" }] },
      { answers: "[]" },
      "--answers must be a JSON object",
    ],
    [
      { id: "a", method: "ask", questions: [{ id: "q" }] },
      { answers: JSON.stringify({ other: "x" }) },
      "Unknown question id",
    ],
  ] satisfies Array<[DialogSnapshot, Record<string, string>, string]>)(
    "rejects invalid dialog response %#",
    (dialog, flags, message) => {
      expect(() => buildDialogResponse(dialog, flags)).toThrow(message);
    },
  );

  it("rejects conflicting dialog response flags", () => {
    expect(() =>
      buildDialogResponse({ id: "i", method: "input" }, { text: "x", cancel: "true" }),
    ).toThrow("Choose one dialog response flag");
  });

  it("summarizes partial dialogs without depending on extension names", () => {
    const dialog: DialogSnapshot = {
      method: "ask",
      questions: [
        {
          id: "q",
          question: "Choose",
          options: [{ value: "one", label: "First" }, { label: "Second" }],
        },
      ],
      allowCustom: false,
      timeout: 1_499,
      placeholder: "Other",
    };
    expect(dialogPromptText(dialog)).toBe("Choose");
    expect(dialogMetaLabels(dialog)).toEqual(["options only", "timeout 1s"]);
    expect(dialogOptionDetails(dialog)).toEqual([
      "q: Choose",
      "  - one — First",
      "  - Second",
      "placeholder: Other",
    ]);
  });
});
