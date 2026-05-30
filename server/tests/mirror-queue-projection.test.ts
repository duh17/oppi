import { describe, expect, it } from "vitest";

import { MirrorQueueProjection, type MessageQueueState } from "../../pi-extensions/oppi-mirror.ts";

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
