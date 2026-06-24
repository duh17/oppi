import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";
import * as ts from "typescript";

import {
  buildExtensionUINotificationMessage,
  buildExtensionUIRequestMessage,
  buildExtensionUISettledMessage,
  createExtensionUINativeRenderContext,
  EXTENSION_NATIVE_UI_RENDER_NATIVE_CAPABILITIES,
  EXTENSION_NATIVE_UI_SERVER_CAPABILITIES,
  EXTENSION_UI_FIRE_AND_FORGET_METHODS,
  EXTENSION_UI_STATUS_TEXT_MAX_CHARS,
  EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES,
  EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS,
  EXTENSION_UI_WORKING_INDICATOR_MAX_INTERVAL_MS,
  EXTENSION_UI_WORKING_INDICATOR_MIN_INTERVAL_MS,
  EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS,
  extensionUIActivityListBlock,
  extensionUINativeSurface,
  extensionUITextBlock,
  isExtensionUIFireAndForgetMethod,
  normalizeExtensionUINativeSurface,
  normalizeExtensionUINotifyType,
  normalizeExtensionUIWidgetNativeSurface,
  normalizeExtensionUIWidgetPlacement,
  parseExtensionUIAskResponse,
  parseExtensionUIConfirmResponse,
  parseExtensionUISelectResponse,
  parseExtensionUITextResponse,
} from "../src/extension-ui-contract.js";

const piExtensionTypesUrl = new URL(
  "../node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts",
  import.meta.url,
);
const nativeUIContractUrl = new URL("../../docs/extension-native-ui.md", import.meta.url);

function currentPiExtensionUIContextMembers(): string[] {
  const sourceFile = ts.createSourceFile(
    piExtensionTypesUrl.pathname,
    readFileSync(piExtensionTypesUrl, "utf8"),
    ts.ScriptTarget.Latest,
    true,
  );
  const members = new Set<string>();

  function visit(node: ts.Node): void {
    if (ts.isInterfaceDeclaration(node) && node.name.text === "ExtensionUIContext") {
      for (const member of node.members) {
        const name = member.name;
        if (name && ts.isIdentifier(name)) {
          members.add(name.text);
        }
      }
    }
    ts.forEachChild(node, visit);
  }

  visit(sourceFile);
  return [...members];
}

describe("extension UI contract", () => {
  it("accounts for every current Pi ExtensionUIContext member in the native contract", () => {
    const piMembers = currentPiExtensionUIContextMembers();
    expect(piMembers).toEqual([
      "select",
      "confirm",
      "input",
      "notify",
      "onTerminalInput",
      "setStatus",
      "setWorkingMessage",
      "setWorkingVisible",
      "setWorkingIndicator",
      "setHiddenThinkingLabel",
      "setWidget",
      "setFooter",
      "setHeader",
      "setTitle",
      "custom",
      "pasteToEditor",
      "setEditorText",
      "getEditorText",
      "editor",
      "addAutocompleteProvider",
      "setEditorComponent",
      "getEditorComponent",
      "theme",
      "getAllThemes",
      "getTheme",
      "setTheme",
      "getToolsExpanded",
      "setToolsExpanded",
    ]);

    const contract = readFileSync(nativeUIContractUrl, "utf8");
    for (const member of piMembers) {
      expect(contract, `Missing native contract mapping for ctx.ui.${member}`).toContain(
        `ctx.ui.${member}`,
      );
    }
  });

  it("pins fire-and-forget methods and leaves blocking UI requests pending", () => {
    expect([...EXTENSION_UI_FIRE_AND_FORGET_METHODS].sort()).toEqual([
      "notify",
      "setHiddenThinkingLabel",
      "setStatus",
      "setTitle",
      "setToolsExpanded",
      "setWidget",
      "setWorkingIndicator",
      "setWorkingMessage",
      "setWorkingVisible",
      "set_editor_text",
    ]);
    expect(isExtensionUIFireAndForgetMethod("setStatus")).toBe(true);
    expect(isExtensionUIFireAndForgetMethod("select")).toBe(false);
    expect(isExtensionUIFireAndForgetMethod("ask")).toBe(false);
  });

  it("advertises only implemented native UI capability levels", () => {
    expect([...EXTENSION_NATIVE_UI_SERVER_CAPABILITIES]).toEqual([
      "extension-native-ui:v1:text-fallback",
      "extension-native-ui:v1:prompt-native",
      "extension-native-ui:v1:surface-native",
      "extension-native-ui:v1:osc8-links",
    ]);
    expect([...EXTENSION_NATIVE_UI_RENDER_NATIVE_CAPABILITIES]).toEqual([
      "extension-native-ui:v1:text-fallback",
      "extension-native-ui:v1:surface-native",
    ]);
    expect(EXTENSION_NATIVE_UI_SERVER_CAPABILITIES).not.toContain(
      "extension-native-ui:v1:interactive-native",
    );
    expect(EXTENSION_NATIVE_UI_SERVER_CAPABILITIES).not.toContain(
      "extension-native-ui:v1:timeline-native",
    );
  });

  it("exports small authoring helpers for renderNative widget surfaces", () => {
    expect(createExtensionUINativeRenderContext()).toEqual({
      target: "oppi-native-v1",
      capabilities: [
        "extension-native-ui:v1:text-fallback",
        "extension-native-ui:v1:surface-native",
      ],
      locale: undefined,
    });

    const surface = extensionUINativeSurface({
      id: "widget:agents",
      presentation: { style: "surfacePanel", title: "Agents" },
      blocks: [
        extensionUITextBlock("Ready", { id: "headline" }),
        extensionUIActivityListBlock(
          [
            {
              id: "child-1",
              title: "Review",
              subtitle: "Running",
              state: "running",
              link: "oppi://session/child-1",
            },
          ],
          { id: "agents" },
        ),
      ],
      fallback: { lines: ["Ready"] },
    });

    expect(surface).toEqual({
      version: 1,
      id: "widget:agents",
      source: "widget",
      presentation: { style: "surfacePanel", title: "Agents" },
      blocks: [
        { type: "text", id: "headline", spans: [{ text: "Ready" }] },
        {
          type: "activityList",
          id: "agents",
          rows: [
            {
              id: "child-1",
              title: "Review",
              subtitle: "Running",
              state: "running",
              link: "oppi://session/child-1",
            },
          ],
        },
      ],
      fallback: { lines: ["Ready"] },
    });
    expect(normalizeExtensionUINativeSurface(surface)).toEqual(surface);
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
        nativeSurface: {
          version: 1,
          id: "request:ignored",
          source: "widget",
          presentation: { style: "surfacePanel" },
          blocks: [{ type: "text", spans: [{ text: "Request-native surfaces are ignored" }] }],
        },
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

  it("sanitizes display-facing dialog text while preserving response values", () => {
    expect(
      buildExtensionUIRequestMessage("sess-1", {
        id: "ui-ansi-1",
        method: "editor",
        title: "\x1b]0;window\x07\x1b[1mEdit plan\x1b[0m",
        message: "\x1b[33mReview before submitting\x1b[0m",
        placeholder: "\x1b[2mPlan text\x1b[0m",
        prefill: "\x1b[32mkeep literal editor text\x1b[0m",
      }),
    ).toMatchObject({
      type: "extension_ui_request",
      id: "ui-ansi-1",
      method: "editor",
      title: "Edit plan",
      message: "Review before submitting",
      placeholder: "Plan text",
      prefill: "\x1b[32mkeep literal editor text\x1b[0m",
    });

    expect(
      buildExtensionUIRequestMessage("sess-1", {
        id: "ui-select-ansi-1",
        method: "select",
        title: "\x1b[1mPick one\x1b[0m",
        options: ["\x1b[32mraw option value\x1b[0m"],
      }),
    ).toMatchObject({
      title: "Pick one",
      options: ["\x1b[32mraw option value\x1b[0m"],
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

  it("sanitizes ask display labels without changing option values", () => {
    expect(
      buildExtensionUIRequestMessage("sess-1", {
        id: "ask-ansi-1",
        method: "ask",
        allowCustom: false,
        questions: [
          {
            id: "q1",
            question: "\x1b[1mProceed?\x1b[0m",
            multiSelect: true,
            options: [
              {
                value: "\x1b[32myes\x1b[0m",
                label: "\x1b[32mYes\x1b[0m",
                description: "\x1b[2mRun the command\x1b[0m",
              },
            ],
          },
        ],
      }),
    ).toMatchObject({
      type: "extension_ui_request",
      id: "ask-ansi-1",
      questions: [
        {
          id: "q1",
          question: "Proceed?",
          multiSelect: true,
          options: [
            {
              value: "\x1b[32myes\x1b[0m",
              label: "Yes",
              description: "Run the command",
            },
          ],
        },
      ],
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
          nativeSurface: {
            version: 1,
            id: "status-native",
            source: "widget",
            presentation: { style: "surfacePanel" },
            blocks: [{ type: "text", spans: [{ text: "Ignored for non-widget notifications" }] }],
          },
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

  it("canonicalizes forwarded widget native surface ids for reliable clearing", () => {
    expect(
      buildExtensionUINotificationMessage({
        id: "widget-1",
        method: "setWidget",
        widgetKey: "agents",
        widgetLines: ["Agents"],
        nativeSurface: {
          version: 1,
          id: "extension-chosen-id",
          source: "widget",
          presentation: { style: "surfacePanel" },
          blocks: [],
        },
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setWidget",
      widgetKey: "agents",
      nativeSurface: {
        id: "widget:agents",
        source: "widget",
      },
    });
  });

  it("drops invalid widget native surfaces at the shared translation boundary", () => {
    expect(
      buildExtensionUINotificationMessage({
        id: "widget-1",
        method: "setWidget",
        widgetKey: "agents",
        widgetLines: ["Agents"],
        nativeSurface: {
          version: 1,
          id: "extension-chosen-id",
          source: "widget",
          presentation: { style: "inlineCard" },
          blocks: [],
        },
      }),
    ).toEqual({
      type: "extension_ui_notification",
      method: "setWidget",
      message: undefined,
      notifyType: undefined,
      statusKey: undefined,
      statusText: undefined,
      title: undefined,
      text: undefined,
      widgetKey: "agents",
      widgetLines: ["Agents"],
      widgetPlacement: undefined,
    });
  });

  it("promotes OSC-8 widget fallback links into a generic native terminal surface", () => {
    const message = buildExtensionUINotificationMessage({
      id: "widget-link-1",
      method: "setWidget",
      widgetKey: "links",
      widgetLines: ["Open \x1b]8;;oppi://session/child-1\x07child\x1b]8;;\x07 now"],
    });

    expect(message.widgetLines).toEqual(["Open child now"]);
    expect(message.nativeSurface).toMatchObject({
      version: 1,
      id: "widget:links",
      source: "widget",
      presentation: {
        style: "surfacePanel",
        title: "links",
      },
      blocks: [
        {
          type: "terminal",
          id: "terminal-fallback",
          lines: [
            [
              { text: "Open " },
              { text: "child", link: "oppi://session/child-1" },
              { text: " now" },
            ],
          ],
        },
      ],
      fallback: { lines: ["Open child now"] },
    });
  });

  it("sanitizes non-link terminal control sequences without replacing ordinary widgets", () => {
    const message = buildExtensionUINotificationMessage({
      id: "widget-ansi-1",
      method: "setWidget",
      widgetKey: "plain",
      widgetLines: ["\x1b]0;window\x07\x1b[1;32mReady\x1b[0m"],
    });

    expect(message.widgetLines).toEqual(["Ready"]);
    expect(message.nativeSurface).toBeUndefined();
  });

  it("sanitizes display-facing notification text without changing editor handoff text", () => {
    expect(
      buildExtensionUINotificationMessage({
        id: "notify-ansi-1",
        method: "notify",
        message: "\x1b]0;window\x07\x1b[33mNeeds review\x1b[0m",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "notify",
      message: "Needs review",
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "status-ansi-1",
        method: "setStatus",
        statusKey: "build",
        statusText: "\x1b[32mRunning\x1b[0m",
        title: "\x1b[1mBuild status\x1b[0m",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setStatus",
      statusKey: "build",
      statusText: "Running",
      title: "Build status",
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "editor-text-1",
        method: "set_editor_text",
        text: "\x1b[32mkeep literal editor text\x1b[0m",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "set_editor_text",
      text: "\x1b[32mkeep literal editor text\x1b[0m",
    });
  });

  it("normalizes working-row notifications for native timeline rendering", () => {
    expect(
      buildExtensionUINotificationMessage({
        id: "working-message-1",
        method: "setWorkingMessage",
        message: "\x1b[33mRunning checks\x1b[0m",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setWorkingMessage",
      message: "Running checks",
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "working-visible-1",
        method: "setWorkingVisible",
        workingVisible: false,
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setWorkingVisible",
      workingVisible: false,
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "working-indicator-1",
        method: "setWorkingIndicator",
        workingIndicator: {
          frames: ["\x1b[32m●\x1b[0m", "\x1b[32m○\x1b[0m"],
          intervalMs: 125.4,
        },
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setWorkingIndicator",
      workingIndicator: {
        frames: ["●", "○"],
        intervalMs: 125,
      },
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "thinking-label-1",
        method: "setHiddenThinkingLabel",
        hiddenThinkingLabel: "\x1b[35mPrivate reasoning\x1b[0m",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setHiddenThinkingLabel",
      hiddenThinkingLabel: "Private reasoning",
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "tools-expanded-1",
        method: "setToolsExpanded",
        toolsExpanded: true,
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      method: "setToolsExpanded",
      toolsExpanded: true,
    });
  });

  it("bounds working-row and status payloads before native rendering", () => {
    const longFrame = "x".repeat(EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS + 8);
    const frames = Array.from(
      { length: EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES + 8 },
      (_, index) => `${longFrame}${index}`,
    );

    const boundedLow = buildExtensionUINotificationMessage({
      id: "working-indicator-bounds-1",
      method: "setWorkingIndicator",
      workingIndicator: {
        frames,
        intervalMs: 1,
      },
    });
    expect(boundedLow).toMatchObject({
      workingIndicator: {
        frames: expect.arrayContaining([
          `${"x".repeat(EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS - 1)}…`,
        ]),
        intervalMs: EXTENSION_UI_WORKING_INDICATOR_MIN_INTERVAL_MS,
      },
    });
    if (boundedLow.type !== "extension_ui_notification") {
      throw new Error("expected extension UI notification");
    }
    expect(boundedLow.workingIndicator?.frames).toHaveLength(
      EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES,
    );

    expect(
      buildExtensionUINotificationMessage({
        id: "working-indicator-bounds-3",
        method: "setWorkingIndicator",
        workingIndicator: {
          frames: ["●"],
          intervalMs: EXTENSION_UI_WORKING_INDICATOR_MAX_INTERVAL_MS + 10_000,
        },
      }),
    ).toMatchObject({
      workingIndicator: {
        intervalMs: EXTENSION_UI_WORKING_INDICATOR_MAX_INTERVAL_MS,
      },
    });

    const boundedWorkingMessage = buildExtensionUINotificationMessage({
      id: "working-message-bounds-1",
      method: "setWorkingMessage",
      message: "w".repeat(EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS + 20),
    });
    if (boundedWorkingMessage.type !== "extension_ui_notification") {
      throw new Error("expected extension UI notification");
    }
    expect(boundedWorkingMessage.message).toHaveLength(EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS);

    const boundedStatus = buildExtensionUINotificationMessage({
      id: "status-bounds-1",
      method: "setStatus",
      statusKey: "working-words",
      statusText: "s".repeat(EXTENSION_UI_STATUS_TEXT_MAX_CHARS + 20),
    });
    if (boundedStatus.type !== "extension_ui_notification") {
      throw new Error("expected extension UI notification");
    }
    expect(boundedStatus.statusText).toHaveLength(EXTENSION_UI_STATUS_TEXT_MAX_CHARS);
  });

  it("normalizes notification metadata to Pi-shaped values", () => {
    expect(normalizeExtensionUINotifyType("warning")).toBe("warning");
    expect(normalizeExtensionUINotifyType("success")).toBeUndefined();
    expect(normalizeExtensionUIWidgetPlacement("aboveEditor")).toBe("aboveEditor");
    expect(normalizeExtensionUIWidgetPlacement("above-editor")).toBeUndefined();

    expect(
      buildExtensionUINotificationMessage({
        id: "widget-meta-1",
        method: "setWidget",
        widgetKey: "review",
        widgetLines: ["Review active"],
        notifyType: "warning",
        widgetPlacement: "aboveEditor",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      notifyType: "warning",
      widgetPlacement: "aboveEditor",
    });

    expect(
      buildExtensionUINotificationMessage({
        id: "widget-meta-2",
        method: "setWidget",
        widgetKey: "review",
        widgetLines: ["Review active"],
        notifyType: "success",
        widgetPlacement: "above-editor",
      }),
    ).toMatchObject({
      type: "extension_ui_notification",
      notifyType: undefined,
      widgetPlacement: undefined,
    });
  });

  it("normalizes only the current widget native surface envelope", () => {
    expect(
      normalizeExtensionUINativeSurface({
        version: 1,
        id: "widget:agents",
        source: "widget",
        presentation: { style: "surfacePanel", title: "Agents" },
        blocks: [{ type: "activityList", rows: [] }],
      }),
    ).toMatchObject({
      id: "widget:agents",
      source: "widget",
      presentation: { style: "surfacePanel", title: "Agents" },
    });

    expect(
      normalizeExtensionUINativeSurface({
        version: 1,
        id: "request:plan",
        source: "custom",
        presentation: { style: "sheet" },
        blocks: [],
      }),
    ).toBeUndefined();
    expect(
      normalizeExtensionUINativeSurface({
        version: 1,
        id: "widget:agents",
        source: "widget",
        presentation: { style: "inlineCard" },
        blocks: [],
      }),
    ).toBeUndefined();
    expect(
      normalizeExtensionUINativeSurface(
        {
          version: 1,
          id: "widget:agents",
          source: "widget",
          presentation: { style: "surfacePanel" },
          blocks: [{ type: "text", spans: [{ text: "too large" }] }],
        },
        { maxBytes: 16 },
      ),
    ).toBeUndefined();
  });

  it("keeps bounded future native blocks forward-compatible", () => {
    expect(
      normalizeExtensionUINativeSurface({
        version: 1,
        id: "widget:future",
        source: "widget",
        presentation: { style: "surfacePanel", title: "Future" },
        blocks: [{ type: "futureBlock", id: "f1" }],
        fallback: { lines: ["future fallback"] },
      }),
    ).toMatchObject({
      id: "widget:future",
      blocks: [{ type: "futureBlock", id: "f1" }],
      fallback: { lines: ["future fallback"] },
    });
  });

  it("enforces explicit native surface structural limits", () => {
    const baseSurface = {
      version: 1,
      id: "widget:limited",
      source: "widget",
      presentation: { style: "surfacePanel" },
    };

    expect(
      normalizeExtensionUINativeSurface(
        {
          ...baseSurface,
          blocks: [{ type: "divider" }, { type: "divider" }],
        },
        { maxBlocks: 1 },
      ),
    ).toBeUndefined();

    expect(
      normalizeExtensionUINativeSurface(
        {
          ...baseSurface,
          blocks: [
            {
              type: "section",
              blocks: [{ type: "text", spans: [{ text: "nested" }] }],
            },
          ],
        },
        { maxDepth: 1 },
      ),
    ).toBeUndefined();

    expect(
      normalizeExtensionUINativeSurface(
        {
          ...baseSurface,
          blocks: [{ type: "text", spans: [{ text: "one" }, { text: "two" }] }],
        },
        { maxSpans: 1 },
      ),
    ).toBeUndefined();

    expect(
      normalizeExtensionUINativeSurface(
        {
          ...baseSurface,
          blocks: [{ type: "markdown", markdown: "too much text" }],
        },
        { maxTextBytes: 4 },
      ),
    ).toBeUndefined();

    expect(
      normalizeExtensionUINativeSurface(
        {
          ...baseSurface,
          blocks: [
            {
              type: "terminal",
              lines: [[{ text: "one" }], [{ text: "two" }]],
            },
          ],
        },
        { maxTerminalLines: 1 },
      ),
    ).toBeUndefined();

    expect(
      normalizeExtensionUINativeSurface(
        {
          ...baseSurface,
          blocks: [
            {
              type: "activityList",
              rows: [
                { id: "one", title: "One" },
                { id: "two", title: "Two" },
              ],
            },
          ],
        },
        { maxActivityRows: 1 },
      ),
    ).toBeUndefined();
  });

  it("normalizes and canonicalizes widget native surface ids at the translation boundary", () => {
    expect(
      normalizeExtensionUIWidgetNativeSurface(
        {
          version: 1,
          id: "extension-chosen-id",
          source: "widget",
          presentation: { style: "surfacePanel", title: "Agents" },
          blocks: [{ type: "activityList", rows: [] }],
        },
        "agents",
      ),
    ).toMatchObject({
      id: "widget:agents",
      source: "widget",
      presentation: { style: "surfacePanel", title: "Agents" },
    });

    expect(
      normalizeExtensionUIWidgetNativeSurface(
        {
          version: 1,
          id: "widget:agents",
          source: "widget",
          presentation: { style: "inlineCard" },
          blocks: [],
        },
        "agents",
      ),
    ).toBeUndefined();
    expect(
      normalizeExtensionUIWidgetNativeSurface(
        {
          version: 1,
          id: "widget:agents",
          source: "widget",
          presentation: { style: "surfacePanel" },
          blocks: [],
        },
        undefined,
      ),
    ).toBeUndefined();
  });

  it("maps ask responses to Pi-compatible ask results", () => {
    expect(
      parseExtensionUIAskResponse({
        id: "ask-1",
        value: JSON.stringify({ scope: "small", tools: ["jest", "vitest"] }),
      }),
    ).toEqual({
      answers: { scope: "small", tools: ["jest", "vitest"] },
      allIgnored: false,
    });

    expect(parseExtensionUIAskResponse({ id: "ask-1", cancelled: true })).toEqual({
      answers: {},
      allIgnored: true,
    });

    expect(() => parseExtensionUIAskResponse({ id: "ask-1", value: "not-json" })).toThrow(
      /Malformed ask response:/,
    );
  });

  it("maps dialog responses to Pi-compatible return values", () => {
    expect(parseExtensionUISelectResponse({ id: "select-1", value: "Allow once" })).toBe(
      "Allow once",
    );
    expect(parseExtensionUISelectResponse({ id: "select-1", cancelled: true })).toBeUndefined();

    expect(parseExtensionUIConfirmResponse({ id: "confirm-1", confirmed: true })).toBe(true);
    expect(parseExtensionUIConfirmResponse({ id: "confirm-1", cancelled: true })).toBe(false);

    expect(parseExtensionUITextResponse({ id: "input-1", value: "typed text" })).toBe("typed text");
    expect(parseExtensionUITextResponse({ id: "input-1", cancelled: true })).toBeUndefined();
  });
});
