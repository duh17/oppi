import { describe, expect, it } from "vitest";

import { sessionTreeWire } from "../../pi-extensions/oppi-mirror/extensions/oppi-mirror.ts";

describe("oppi mirror session tree", () => {
  it("returns compact node snapshots instead of raw session tree entries", () => {
    const largeToolOutput = "x".repeat(2_000_000);
    const toolCallEntry = {
      id: "assistant-tools",
      parentId: "root",
      type: "message",
      timestamp: "2026-06-18T01:01:00.000Z",
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "tool-call-1",
            name: "read",
            arguments: { path: "/tmp/large-output.txt" },
          },
        ],
      },
    };
    const toolResultEntry = {
      id: "tool-result",
      parentId: "assistant-tools",
      type: "message",
      timestamp: "2026-06-18T01:02:00.000Z",
      message: {
        role: "toolResult",
        toolCallId: "tool-call-1",
        toolName: "read",
        content: largeToolOutput,
      },
    };
    const rootEntry = {
      id: "root",
      parentId: null,
      type: "message",
      timestamp: "2026-06-18T01:00:00.000Z",
      message: { role: "user", content: "Show me the large file" },
    };
    const byId = new Map([
      [rootEntry.id, rootEntry],
      [toolCallEntry.id, toolCallEntry],
      [toolResultEntry.id, toolResultEntry],
    ]);
    const ctx = {
      sessionManager: {
        getLeafId: () => "tool-result",
        getEntry: (id: string) => byId.get(id),
        getTree: () => [
          {
            entry: rootEntry,
            children: [
              {
                entry: toolCallEntry,
                children: [{ entry: toolResultEntry, children: [] }],
              },
            ],
          },
        ],
      },
    };

    const snapshot = sessionTreeWire(ctx as never, "no-tools");
    const encoded = JSON.stringify(snapshot);

    expect(snapshot).not.toHaveProperty("tree");
    expect(encoded).not.toContain(largeToolOutput.slice(0, 100));
    expect(encoded.length).toBeLessThan(10_000);
    expect(snapshot.nodes).toContainEqual(
      expect.objectContaining({
        id: "tool-result",
        role: "toolResult",
        textPreview: "[read: /tmp/large-output.txt]",
        matchesFilter: false,
      }),
    );
  });
});
