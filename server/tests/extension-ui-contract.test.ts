import { describe, expect, it } from "vitest";

import {
  buildExtensionUINotificationMessage,
  buildExtensionUIRequestMessage,
  buildExtensionUISettledMessage,
  EXTENSION_UI_DIALOG_METHODS,
  EXTENSION_UI_FIRE_AND_FORGET_METHODS,
  isExtensionUIFireAndForgetMethod,
} from "../src/extension-ui-contract.js";

describe("extension UI contract", () => {
  it("pins the supported dialog and fire-and-forget method sets", () => {
    expect([...EXTENSION_UI_DIALOG_METHODS].sort()).toEqual([
      "ask",
      "confirm",
      "editor",
      "input",
      "select",
    ]);
    expect([...EXTENSION_UI_FIRE_AND_FORGET_METHODS].sort()).toEqual([
      "notify",
      "setStatus",
      "setTitle",
      "setWidget",
      "set_editor_text",
    ]);
    expect(isExtensionUIFireAndForgetMethod("setStatus")).toBe(true);
    expect(isExtensionUIFireAndForgetMethod("select")).toBe(false);
  });

  it("builds the canonical dialog request payload seen by all Apple clients", () => {
    expect(
      buildExtensionUIRequestMessage("sess-1", {
        id: "ui-1",
        method: "select",
        title: "Choose",
        options: ["A", "B"],
        message: "Pick one",
        placeholder: "choice",
        prefill: "A",
        timeout: 10_000,
        timeoutAt: 123_456,
      }),
    ).toEqual({
      type: "extension_ui_request",
      id: "ui-1",
      sessionId: "sess-1",
      method: "select",
      title: "Choose",
      options: ["A", "B"],
      message: "Pick one",
      placeholder: "choice",
      prefill: "A",
      timeout: 10_000,
      timeoutAt: 123_456,
    });
  });

  it("keeps ask requests on the ask-specific payload shape", () => {
    expect(
      buildExtensionUIRequestMessage("sess-1", {
        id: "ask-1",
        method: "ask",
        allowCustom: false,
        questions: [
          {
            id: "q1",
            question: "Proceed?",
            options: [{ value: "yes", label: "Yes" }],
          },
        ],
      }),
    ).toEqual({
      type: "extension_ui_request",
      id: "ask-1",
      sessionId: "sess-1",
      method: "ask",
      questions: [
        {
          id: "q1",
          question: "Proceed?",
          options: [{ value: "yes", label: "Yes" }],
        },
      ],
      allowCustom: false,
      timeout: undefined,
      timeoutAt: undefined,
    });
  });

  it("builds canonical fire-and-forget notification and settlement payloads", () => {
    expect(
      buildExtensionUINotificationMessage(
        {
          id: "status-1",
          method: "setStatus",
          statusKey: "build",
          statusText: "Running",
        },
        { statusText: undefined },
      ),
    ).toEqual({
      type: "extension_ui_notification",
      method: "setStatus",
      message: undefined,
      notifyType: undefined,
      statusKey: "build",
      statusText: undefined,
      title: undefined,
      text: undefined,
      widgetKey: undefined,
      widgetLines: undefined,
      widgetPlacement: undefined,
    });

    expect(buildExtensionUISettledMessage("sess-1", "ui-1")).toEqual({
      type: "extension_ui_settled",
      id: "ui-1",
      sessionId: "sess-1",
    });
  });
});
