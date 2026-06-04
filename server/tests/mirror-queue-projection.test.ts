import { describe, expect, it } from "vitest";

import {
  createMirrorWidgetForwardingComponent,
  createMirrorWidgetForwardingTui,
  MirrorQueueProjection,
  serializeSessionTree,
  snapshotMirrorWidgetLines,
  type MessageQueueState,
} from "../../pi-extensions/oppi-mirror.ts";

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

    expect(lines).toEqual(["● Agents", "  running width=88"]);
  });

  it("limits long widget snapshots", () => {
    const lines = snapshotMirrorWidgetLines({
      render: () => Array.from({ length: 14 }, (_, index) => `line ${index + 1}`),
    });

    expect(lines).toHaveLength(13);
    expect(lines.at(-1)).toBe("… (2 more lines)");
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

describe("mirror session tree serialization", () => {
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
      2,
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
});
