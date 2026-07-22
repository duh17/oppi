import { describe, expect, it, vi } from "vitest";

import {
  bindMirrorOptionalUIContext,
  createMirrorTerminalDialogQueue,
  createMirrorWidgetForwardingComponent,
  createMirrorWidgetForwardingTui,
  MirrorQueueProjection,
  normalizeMirrorAskAnswers,
  parseMirrorAskUIResponse,
  parseMirrorConfirmUIResponse,
  parseMirrorSelectUIResponse,
  parseMirrorTextUIResponse,
  snapshotMirrorWidgetLines,
  snapshotMirrorWidgetNativeSurface,
  terminalAskFallback,
  type MessageQueueState,
} from "../../pi-extensions/oppi-mirror.ts";
import { serializeSessionTree } from "../src/session-tree.js";

async function flushMicrotasks(count = 4): Promise<void> {
  for (let index = 0; index < count; index += 1) {
    await Promise.resolve();
  }
}

function queue(
  version: number,
  steering: string[] = [],
  followUp: string[] = [],
): MessageQueueState {
  return {
    version,
    steering: steering.map((message, index) => ({
      id: `s${index + 1}`,
      message,
      createdAt: index + 1,
    })),
    followUp: followUp.map((message, index) => ({
      id: `f${index + 1}`,
      message,
      createdAt: index + 1,
    })),
  };
}

describe("mirror widget snapshots", () => {
  it("renders callback widget components into mobile-safe line snapshots", () => {
    const lines = snapshotMirrorWidgetLines({
      render: (width: number) => ["\u001b[32m●\u001b[0m Agents", `  running width=${width}`, ""],
    });

    expect(lines).toEqual(["\u001b[32m●\u001b[0m Agents", "  running width=88"]);
  });

  it("strips terminal control sequences while preserving SGR color", () => {
    const lines = snapshotMirrorWidgetLines({
      render: () => ["\u001b]0;title\u0007\u001b[1;32mReady   \u001b[0m\u001b[2K"],
    });

    expect(lines).toEqual(["\u001b[1;32mReady\u001b[0m"]);
  });

  it("limits long widget snapshots", () => {
    const lines = snapshotMirrorWidgetLines({
      render: () => Array.from({ length: 14 }, (_, index) => `line ${index + 1}`),
    });

    expect(lines).toHaveLength(13);
    expect(lines.at(-1)).toBe("… (2 more lines)");
  });

  it("renders callback widget native surfaces when provided", () => {
    const surface = snapshotMirrorWidgetNativeSurface({
      render: () => ["● Agents"],
      renderNative: (context: { target: string; capabilities: string[] }) => ({
        version: 1,
        id: "widget:agents",
        source: "widget",
        presentation: { style: "surfacePanel", title: "Agents" },
        blocks: [
          {
            type: "activityList",
            rows: [{ id: "child-1", title: "Review", state: "running" }],
          },
        ],
        fallback: { lines: [context.target] },
      }),
    });

    expect(surface).toMatchObject({
      version: 1,
      id: "widget:agents",
      source: "widget",
      presentation: { style: "surfacePanel" },
    });
    expect((surface?.fallback as { lines?: string[] } | undefined)?.lines).toEqual([
      "oppi-native-v1",
    ]);
  });

  it("ignores widget native surfaces that do not serialize to JSON objects", () => {
    for (const value of [undefined, () => null, null, ["not", "an", "object"]]) {
      expect(
        snapshotMirrorWidgetNativeSurface({
          render: () => ["● Agents"],
          renderNative: () => value,
        }),
      ).toBeUndefined();
    }
  });

  it("forwards requestRender through a TUI proxy without hiding terminal fields", () => {
    let originalRenderRequests = 0;
    let forwardedRenderRequests = 0;
    const tui = {
      terminal: { columns: 120, rows: 40 },
      requestRender() {
        originalRenderRequests += 1;
      },
    };

    const proxied = createMirrorWidgetForwardingTui(tui, () => {
      forwardedRenderRequests += 1;
    }) as typeof tui;

    expect(proxied.terminal.columns).toBe(120);
    proxied.requestRender();
    expect(originalRenderRequests).toBe(1);
    expect(forwardedRenderRequests).toBe(1);
  });

  it("forwards widget invalidation and disposal through a component proxy", () => {
    let originalInvalidations = 0;
    let originalDisposals = 0;
    let forwardedInvalidations = 0;
    let forwardedDisposals = 0;
    const component = {
      render: () => ["● Agents"],
      invalidate() {
        originalInvalidations += 1;
      },
      dispose() {
        originalDisposals += 1;
      },
    };

    const proxied = createMirrorWidgetForwardingComponent(
      component,
      () => {
        forwardedInvalidations += 1;
      },
      () => {
        forwardedDisposals += 1;
      },
    ) as typeof component;

    expect(proxied.render(88)).toEqual(["● Agents"]);
    proxied.invalidate();
    proxied.dispose();

    expect(originalInvalidations).toBe(1);
    expect(forwardedInvalidations).toBe(1);
    expect(originalDisposals).toBe(1);
    expect(forwardedDisposals).toBe(1);
  });
});

describe("mirror extension UI proxy helpers", () => {
  it("serializes terminal dialogs and skips phone-settled dialogs before their turn", async () => {
    const dialogQueue = createMirrorTerminalDialogQueue();
    const started: string[] = [];
    let finishFirst!: (value: string) => void;
    let finishThird!: (value: string) => void;
    const secondAbort = new AbortController();

    const first = dialogQueue.run(
      () =>
        new Promise<string>((resolve) => {
          started.push("first");
          finishFirst = resolve;
        }),
      { defaultValue: "first-skipped" },
    );
    const second = dialogQueue.run(
      async () => {
        started.push("second");
        return "second";
      },
      { signal: secondAbort.signal, defaultValue: "second-skipped" },
    );
    const third = dialogQueue.run(
      () =>
        new Promise<string>((resolve) => {
          started.push("third");
          finishThird = resolve;
        }),
      { defaultValue: "third-skipped" },
    );

    await flushMicrotasks();
    expect(started).toEqual(["first"]);

    secondAbort.abort();
    finishFirst("first");

    await expect(first).resolves.toBe("first");
    await flushMicrotasks();
    expect(started).toEqual(["first", "third"]);
    await expect(second).resolves.toBe("second-skipped");

    finishThird("third");
    await expect(third).resolves.toBe("third");
  });

  it("binds partial UI contexts without requiring every Pi UI method", async () => {
    const setWidget = vi.fn();
    const original = bindMirrorOptionalUIContext({ setWidget } as never);

    await expect(
      original.ask(
        [
          {
            id: "scope",
            question: "Scope?",
            options: [{ value: "goal", label: "Goal" }],
          },
        ],
        true,
        undefined,
      ),
    ).resolves.toEqual({ answers: {}, allIgnored: true });
    await expect(original.select("Title", ["One"], undefined)).resolves.toBeUndefined();
    await expect(original.confirm("Title", "Message", undefined)).resolves.toBe(false);

    original.setWidget?.("goal", ["Goal visible"], { placement: "aboveEditor" });

    expect(setWidget).toHaveBeenCalledWith("goal", ["Goal visible"], {
      placement: "aboveEditor",
    });
  });

  it("binds terminal working-state UI methods when available", () => {
    const setWorkingMessage = vi.fn();
    const setWorkingIndicator = vi.fn();
    const setWorkingVisible = vi.fn();
    const original = bindMirrorOptionalUIContext({
      setWorkingMessage,
      setWorkingIndicator,
      setWorkingVisible,
    } as never);

    original.setWorkingMessage?.("Tracing logic");
    original.setWorkingIndicator?.({ frames: ["●"], intervalMs: 120 });
    original.setWorkingVisible?.(true);

    expect(setWorkingMessage).toHaveBeenCalledWith("Tracing logic");
    expect(setWorkingIndicator).toHaveBeenCalledWith({ frames: ["●"], intervalMs: 120 });
    expect(setWorkingVisible).toHaveBeenCalledWith(true);
  });
});

describe("mirror ask response normalization", () => {
  it("fails fast on malformed ask response JSON", () => {
    expect(() => normalizeMirrorAskAnswers("not json")).toThrow(/Malformed ask response/);
  });

  it("fails fast on invalid ask answer values", () => {
    expect(() => normalizeMirrorAskAnswers(JSON.stringify({ scope: 42 }))).toThrow(
      /Malformed ask response/,
    );
  });

  it("maps phone ask responses to Pi ask results", () => {
    expect(
      parseMirrorAskUIResponse({
        type: "extension_ui_response",
        id: "ask-1",
        value: JSON.stringify({ scope: "unit", targets: ["server", "ios"] }),
      }),
    ).toEqual({
      answers: { scope: "unit", targets: ["server", "ios"] },
      allIgnored: false,
    });

    expect(
      parseMirrorAskUIResponse({
        type: "extension_ui_response",
        id: "ask-1",
        cancelled: true,
      }),
    ).toEqual({ answers: {}, allIgnored: true });
  });

  it("supports multi-select in terminal ask fallback for mirrored sessions", async () => {
    let selectCalls = 0;
    const seenOptions: string[][] = [];
    const result = await terminalAskFallback(
      [
        {
          id: "targets",
          question: "Which targets?",
          options: [
            { value: "server", label: "Server" },
            { value: "ios", label: "iOS" },
          ],
          multiSelect: true,
        },
      ],
      false,
      undefined,
      {
        select: async (_title, options) => {
          seenOptions.push(options);
          selectCalls++;
          if (selectCalls === 1) return options[0];
          if (selectCalls === 2) return options[1];
          return options.find((option) => option.startsWith("Done"));
        },
        input: async () => undefined,
      },
    );

    expect(result).toEqual({
      answers: { targets: ["server", "ios"] },
      allIgnored: false,
    });
    expect(seenOptions[0][0]).toBe("[ ] Server");
    expect(seenOptions[1][0]).toBe("[x] Server");
    expect(seenOptions[2]).toContain("Done (2 selected)");
  });

  it("maps phone dialog responses to Pi-compatible return values", () => {
    expect(
      parseMirrorSelectUIResponse({
        type: "extension_ui_response",
        id: "select-1",
        value: "Allow once",
      }),
    ).toBe("Allow once");
    expect(
      parseMirrorSelectUIResponse({
        type: "extension_ui_response",
        id: "select-1",
        cancelled: true,
      }),
    ).toBeUndefined();

    expect(
      parseMirrorConfirmUIResponse({
        type: "extension_ui_response",
        id: "confirm-1",
        confirmed: true,
      }),
    ).toBe(true);
    expect(
      parseMirrorConfirmUIResponse({
        type: "extension_ui_response",
        id: "confirm-1",
        cancelled: true,
      }),
    ).toBe(false);

    expect(
      parseMirrorTextUIResponse({
        type: "extension_ui_response",
        id: "input-1",
        value: "typed text",
      }),
    ).toBe("typed text");
    expect(
      parseMirrorTextUIResponse({
        type: "extension_ui_response",
        id: "input-1",
        cancelled: true,
      }),
    ).toBeUndefined();
  });
});

describe("mirror session tree serialization", () => {
  it("does not expose custom persistence identifiers in tree snapshots", () => {
    const entries = new Map([
      [
        "user-1",
        {
          id: "user-1",
          parentId: null,
          type: "message",
          timestamp: "2026-01-01T00:00:00.000Z",
          message: { role: "user", content: "Start here" },
        },
      ],
      [
        "custom-1",
        {
          id: "custom-1",
          parentId: "user-1",
          type: "custom",
          timestamp: "2026-01-01T00:00:01.000Z",
          customType: "private-extension-state",
          data: { secret: "internal" },
        },
      ],
    ]);
    const tree = [
      {
        entry: entries.get("user-1")!,
        children: [{ entry: entries.get("custom-1")!, children: [] }],
      },
    ];

    const snapshot = serializeSessionTree(
      {
        getTree: () => tree,
        getLeafId: () => "custom-1",
        getEntry: (id: string) => entries.get(id),
      },
      "all",
    );

    const customNode = snapshot.nodes.find((node) => node.id === "custom-1");
    expect(customNode).toEqual(expect.objectContaining({ id: "custom-1", type: "custom" }));
    expect(customNode).not.toHaveProperty("textPreview");
    expect(JSON.stringify(snapshot)).not.toContain("private-extension-state");
    expect(JSON.stringify(snapshot)).not.toContain("internal");
  });

  it("serializes terminal session trees into mobile outline snapshots", () => {
    const entries = new Map([
      [
        "user-1",
        {
          id: "user-1",
          parentId: null,
          type: "message",
          timestamp: "2026-01-01T00:00:00.000Z",
          message: { role: "user", content: "Start here" },
        },
      ],
      [
        "assistant-1",
        {
          id: "assistant-1",
          parentId: "user-1",
          type: "message",
          timestamp: "2026-01-01T00:00:01.000Z",
          message: {
            role: "assistant",
            content: [
              { type: "toolCall", id: "tool-1", name: "read", arguments: { path: "/tmp/a.ts" } },
            ],
          },
        },
      ],
      [
        "tool-result-1",
        {
          id: "tool-result-1",
          parentId: "assistant-1",
          type: "message",
          timestamp: "2026-01-01T00:00:02.000Z",
          message: { role: "toolResult", toolCallId: "tool-1", content: "file contents" },
        },
      ],
    ]);
    const tree = [
      {
        entry: entries.get("user-1")!,
        children: [
          {
            entry: entries.get("assistant-1")!,
            children: [{ entry: entries.get("tool-result-1")!, children: [] }],
          },
        ],
      },
    ];

    const snapshot = serializeSessionTree(
      {
        getTree: () => tree,
        getLeafId: () => "tool-result-1",
        getEntry: (id: string) => entries.get(id),
      },
      "default",
    );

    expect(snapshot.leafId).toBe("tool-result-1");
    expect(snapshot.nodes).toEqual([
      expect.objectContaining({
        id: "user-1",
        depth: 0,
        isLeafPath: true,
        role: "user",
        textPreview: "Start here",
      }),
      expect.objectContaining({ id: "assistant-1", depth: 1, isLeafPath: true }),
      expect.objectContaining({
        id: "tool-result-1",
        depth: 2,
        isLeafPath: true,
        role: "toolResult",
        textPreview: "[read: /tmp/a.ts]",
      }),
    ]);
  });
});

describe("MirrorQueueProjection", () => {
  it("treats the runtime text queue as authoritative while preserving metadata", () => {
    const projection = new MirrorQueueProjection({
      version: 5,
      steering: [
        {
          id: "existing",
          message: "keep metadata",
          images: [{ data: "base64", mimeType: "image/png" }],
          createdAt: 10,
        },
      ],
      followUp: [],
    });

    const result = projection.reconcileRuntimeSnapshot({
      steering: ["keep metadata", "new from terminal"],
      followUp: [],
    });

    expect(result.changed).toBe(true);
    expect(result.queue.version).toBe(6);
    expect(result.queue.steering[0]).toEqual({
      id: "existing",
      message: "keep metadata",
      images: [{ data: "base64", mimeType: "image/png" }],
      createdAt: 10,
    });
    expect(result.queue.steering[1]).toMatchObject({ message: "new from terminal" });

    const unchanged = projection.reconcileRuntimeSnapshot({
      steering: ["keep metadata", "new from terminal"],
      followUp: [],
    });
    expect(unchanged.changed).toBe(false);
    expect(unchanged.queue.version).toBe(6);
  });

  it("does not duplicate phone optimistic queue items when runtime later reports them", () => {
    const projection = new MirrorQueueProjection();

    const optimistic = projection.enqueueOptimistic("steer", "queued from phone", [
      { data: "img", mimeType: "image/png" },
    ]);
    const optimisticItem = optimistic.queue.steering[0]!;

    const reconciled = projection.reconcileRuntimeSnapshot({
      steering: ["queued from phone"],
      followUp: [],
    });

    expect(reconciled.changed).toBe(false);
    expect(reconciled.queue.steering).toHaveLength(1);
    expect(reconciled.queue.steering[0]).toEqual(optimisticItem);
  });

  it("removes the started duplicate before reconciling so stale twins do not resurrect", () => {
    const projection = new MirrorQueueProjection({
      version: 3,
      steering: [
        { id: "first", message: "same text", createdAt: 1 },
        { id: "second", message: "same text", createdAt: 2 },
      ],
      followUp: [],
    });

    const started = projection.markStarted("same text");
    expect(started?.item.id).toBe("first");
    expect(started?.queue.steering.map((item) => item.id)).toEqual(["second"]);

    const reconciled = projection.reconcileRuntimeSnapshot({
      steering: ["same text"],
      followUp: [],
    });
    expect(reconciled.changed).toBe(false);
    expect(reconciled.queue.steering.map((item) => item.id)).toEqual(["second"]);
  });

  it("clears stale iOS queue chips when the terminal runtime queue is empty", () => {
    const projection = new MirrorQueueProjection(queue(8, ["old steer"], ["old follow"]));

    const reconciled = projection.reconcileRuntimeSnapshot({ steering: [], followUp: [] });

    expect(reconciled.changed).toBe(true);
    expect(reconciled.queue).toEqual({ version: 9, steering: [], followUp: [] });
  });

  it("clears queued items for shutdown without calling an external helper", () => {
    const projection = new MirrorQueueProjection(queue(8, ["old steer"], ["old follow"]));

    const cleared = projection.clear();

    expect(cleared.changed).toBe(true);
    expect(cleared.queue).toEqual({ version: 9, steering: [], followUp: [] });
    expect(projection.clear()).toEqual({
      changed: false,
      queue: { version: 9, steering: [], followUp: [] },
    });
  });

  it("builds set_queue replacements from the current projection version", () => {
    const projection = new MirrorQueueProjection(queue(4, ["existing"]));

    const replacement = projection.queueFromDrafts(
      4,
      [{ id: "edited", message: "edited steer", createdAt: 12 }],
      [{ id: "follow", message: "edited follow", createdAt: 13 }],
    );
    projection.replace(replacement);

    expect(projection.snapshot()).toEqual({
      version: 5,
      steering: [{ id: "edited", message: "edited steer", createdAt: 12 }],
      followUp: [{ id: "follow", message: "edited follow", createdAt: 13 }],
    });
  });

  it("reaches MAX_SAFE_INTEGER once, then rejects stale and current retries without overflow", () => {
    const maxVersion = Number.MAX_SAFE_INTEGER;
    const projection = new MirrorQueueProjection(queue(maxVersion - 1, ["before max"]));

    const atMax = projection.queueFromDrafts(
      maxVersion - 1,
      [{ id: "at-max", message: "at max", createdAt: 2 }],
      [],
    );
    projection.replace(atMax);
    expect(projection.snapshot()).toEqual({
      version: maxVersion,
      steering: [{ id: "at-max", message: "at max", createdAt: 2 }],
      followUp: [],
    });

    expect(() =>
      projection.queueFromDrafts(maxVersion - 1, [{ id: "stale", message: "stale" }], []),
    ).toThrow(`Queue version mismatch: expected ${maxVersion}, got ${maxVersion - 1}`);

    for (const id of ["exhausted", "exhausted-retry"]) {
      expect(() => projection.queueFromDrafts(maxVersion, [{ id, message: id }], [])).toThrow(
        `Queue version exhausted at ${maxVersion}; start a new session to reset the queue counter`,
      );
      expect(projection.snapshot()).toEqual({
        version: maxVersion,
        steering: [{ id: "at-max", message: "at max", createdAt: 2 }],
        followUp: [],
      });
    }
  });

  it.each([
    [
      "runtime reconciliation",
      (projection: MirrorQueueProjection) =>
        projection.reconcileRuntimeSnapshot({ steering: ["changed"], followUp: [] }),
    ],
    ["clear", (projection: MirrorQueueProjection) => projection.clear()],
    [
      "optimistic enqueue",
      (projection: MirrorQueueProjection) => projection.enqueueOptimistic("steer", "changed"),
    ],
    ["started item", (projection: MirrorQueueProjection) => projection.markStarted("at max")],
  ] as const)("rejects %s at version exhaustion before mutating projection", (_name, mutate) => {
    const maxVersion = Number.MAX_SAFE_INTEGER;
    const initial = queue(maxVersion, ["at max"]);
    const projection = new MirrorQueueProjection(initial);

    expect(() => mutate(projection)).toThrow(
      `Queue version exhausted at ${maxVersion}; start a new session to reset the queue counter`,
    );
    expect(projection.snapshot()).toEqual(initial);
  });

  it("rejects unsafe replacement and initial queue versions", () => {
    const unsafe = queue(Number.MAX_SAFE_INTEGER + 1, ["unsafe"]);
    expect(() => new MirrorQueueProjection(unsafe)).toThrow(
      "Queue version must be a nonnegative safe integer",
    );

    const projection = new MirrorQueueProjection(queue(1, ["trusted"]));
    expect(() => projection.replace(unsafe)).toThrow(
      "Queue version must be a nonnegative safe integer",
    );
    expect(projection.snapshot()).toEqual(queue(1, ["trusted"]));
  });
});
