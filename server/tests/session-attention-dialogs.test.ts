import { describe, expect, it } from "vitest";

import { pendingDialogSnapshots } from "../src/session-attention.js";
import type { ServerMessage } from "../src/types.js";

describe("pendingDialogSnapshots", () => {
  it("summarizes only user-reply dialogs from semantic protocol metadata", () => {
    const messages: ServerMessage[] = [
      {
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "k",
        statusText: "live",
      },
      {
        type: "extension_ui_request",
        id: "ask-1",
        sessionId: "s1",
        method: "ask",
        questions: [{ id: "approach", question: "Which?", options: [{ value: "a", label: "A" }] }],
        allowCustom: false,
        timeout: 45_000,
      },
      {
        type: "extension_ui_request",
        id: "sel-1",
        sessionId: "s1",
        method: "select",
        title: "Pick",
        options: ["a", "b"],
      },
      {
        type: "extension_ui_request",
        id: "conf-1",
        sessionId: "s1",
        method: "confirm",
        message: "Sure?",
      },
      {
        type: "extension_ui_request",
        id: "input-1",
        sessionId: "s1",
        method: "input",
        placeholder: "name",
      },
      // ask without questions is not a pending user-reply request.
      { type: "extension_ui_request", id: "ask-empty", sessionId: "s1", method: "ask" },
    ];

    const dialogs = pendingDialogSnapshots(messages);

    expect(dialogs.map((dialog) => dialog.id)).toEqual(["ask-1", "sel-1", "conf-1", "input-1"]);
    expect(dialogs[0]).toMatchObject({ method: "ask", allowCustom: false, timeout: 45_000 });
    expect(dialogs[0]).not.toHaveProperty("sessionId");
    expect(dialogs[0]?.questions).toHaveLength(1);
    expect(dialogs[1]).toMatchObject({ method: "select", title: "Pick", options: ["a", "b"] });
    expect(dialogs[2]).toMatchObject({ method: "confirm", message: "Sure?" });
    expect(dialogs[3]).toMatchObject({ method: "input", placeholder: "name" });
  });

  it("dedupes repeated request ids", () => {
    const messages: ServerMessage[] = [
      { type: "extension_ui_request", id: "x", sessionId: "s1", method: "confirm", message: "a" },
      { type: "extension_ui_request", id: "x", sessionId: "s1", method: "confirm", message: "b" },
    ];

    expect(pendingDialogSnapshots(messages)).toHaveLength(1);
  });
});
