/**
 * Tests for tool event translation: toolCallId plumbing and
 * partialResult delta computation.
 *
 * Since translateEvent is private on SessionManager, we test the delta
 * computation logic directly and verify the protocol types.
 */
import { describe, it, expect } from "vitest";
import type { ServerMessage } from "../src/types.js";

// ─── Delta computation (mirrors sessions.ts translateEvent logic) ───

/**
 * Compute delta from accumulated partialResult text.
 * This is the same logic used in SessionManager.translateEvent for
 * tool_execution_update events.
 */
function computeDelta(
  partialResults: Map<string, string>,
  toolCallId: string | undefined,
  fullText: string,
): string {
  const key = toolCallId ?? "";
  const lastText = partialResults.get(key) ?? "";
  partialResults.set(key, fullText);
  return fullText.slice(lastText.length);
}

describe("tool_output delta computation", () => {
  it("first update returns full text as delta", () => {
    const partialResults = new Map<string, string>();
    const delta = computeDelta(partialResults, "tc-1", "line1\n");
    expect(delta).toBe("line1\n");
  });

  it("subsequent updates return only new content", () => {
    const partialResults = new Map<string, string>();

    const d1 = computeDelta(partialResults, "tc-1", "line1\n");
    const d2 = computeDelta(partialResults, "tc-1", "line1\nline2\n");
    const d3 = computeDelta(partialResults, "tc-1", "line1\nline2\nline3\n");

    expect(d1).toBe("line1\n");
    expect(d2).toBe("line2\n");
    expect(d3).toBe("line3\n");

    // Concatenation of deltas equals the final full text
    expect(d1 + d2 + d3).toBe("line1\nline2\nline3\n");
  });

  it("identical partialResult produces empty delta (suppressed)", () => {
    const partialResults = new Map<string, string>();

    computeDelta(partialResults, "tc-1", "data");
    const d2 = computeDelta(partialResults, "tc-1", "data");
    expect(d2).toBe("");
  });

  it("different toolCallIds are tracked independently", () => {
    const partialResults = new Map<string, string>();

    const d1 = computeDelta(partialResults, "tc-1", "hello");
    const d2 = computeDelta(partialResults, "tc-2", "world");

    expect(d1).toBe("hello");
    expect(d2).toBe("world");

    // Further updates on tc-1 compute delta from its own history
    const d3 = computeDelta(partialResults, "tc-1", "hello, world");
    expect(d3).toBe(", world");
  });

  it("undefined toolCallId uses empty string key", () => {
    const partialResults = new Map<string, string>();

    const d1 = computeDelta(partialResults, undefined, "abc");
    const d2 = computeDelta(partialResults, undefined, "abcdef");
    expect(d1).toBe("abc");
    expect(d2).toBe("def");
  });
});

// ─── Protocol type checks ───

describe("tool event protocol types", () => {
  it("tool_start includes optional toolCallId", () => {
    const msg: ServerMessage = {
      type: "tool_start",
      tool: "bash",
      args: { command: "ls" },
      toolCallId: "tc-42",
    };
    expect(msg.type).toBe("tool_start");
    if (msg.type === "tool_start") {
      expect(msg.toolCallId).toBe("tc-42");
    }
  });

  it("tool_start works without toolCallId", () => {
    const msg: ServerMessage = {
      type: "tool_start",
      tool: "bash",
      args: {},
    };
    if (msg.type === "tool_start") {
      expect(msg.toolCallId).toBeUndefined();
    }
  });

  it("tool_output includes optional toolCallId", () => {
    const msg: ServerMessage = {
      type: "tool_output",
      output: "file.txt",
      toolCallId: "tc-42",
    };
    if (msg.type === "tool_output") {
      expect(msg.toolCallId).toBe("tc-42");
    }
  });

  it("tool_end includes optional toolCallId", () => {
    const msg: ServerMessage = {
      type: "tool_end",
      tool: "bash",
      toolCallId: "tc-42",
    };
    if (msg.type === "tool_end") {
      expect(msg.toolCallId).toBe("tc-42");
    }
  });
});

// ─── Image content block handling ───

/**
 * Mirrors the image handling logic added to translateEvent in sessions.ts.
 * Image content blocks are encoded as data URIs in tool_output messages
 * so iOS ImageExtractor can detect and render them.
 */
function translateContentBlocks(
  contents: Array<{ type: string; text?: string; data?: string; mimeType?: string }>,
  partialResults: Map<string, string>,
  toolCallId: string | undefined,
): ServerMessage[] {
  const messages: ServerMessage[] = [];

  for (const block of contents) {
    if (block.type === "text" && block.text) {
      const key = toolCallId ?? "";
      const lastText = partialResults.get(key) ?? "";
      partialResults.set(key, block.text);
      const delta = block.text.slice(lastText.length);
      if (delta) {
        messages.push({ type: "tool_output", output: delta, toolCallId } as any);
      }
    } else if (block.type === "image" && block.data) {
      const mime = block.mimeType || "image/png";
      const dataUri = `data:${mime};base64,${block.data}`;
      messages.push({ type: "tool_output", output: dataUri, toolCallId } as any);
    } else if (block.type === "audio" && block.data) {
      const mime = block.mimeType || "audio/wav";
      const dataUri = `data:${mime};base64,${block.data}`;
      messages.push({ type: "tool_output", output: dataUri, toolCallId } as any);
    }
  }

  return messages;
}

describe("media content block handling", () => {
  it("encodes image block as data URI in tool_output", () => {
    const partialResults = new Map<string, string>();
    const messages = translateContentBlocks(
      [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }],
      partialResults,
      "tc-img",
    );

    expect(messages).toHaveLength(1);
    expect((messages[0] as any).output).toBe("data:image/png;base64,iVBORw0KGgo=");
    expect((messages[0] as any).toolCallId).toBe("tc-img");
  });

  it("encodes audio block as data URI in tool_output", () => {
    const partialResults = new Map<string, string>();
    const messages = translateContentBlocks(
      [{ type: "audio", data: "UklGRiQAAABXQVZF", mimeType: "audio/wav" }],
      partialResults,
      "tc-audio",
    );

    expect(messages).toHaveLength(1);
    expect((messages[0] as any).output).toBe("data:audio/wav;base64,UklGRiQAAABXQVZF");
    expect((messages[0] as any).toolCallId).toBe("tc-audio");
  });

  it("defaults mimeType to image/png when image mime is omitted", () => {
    const partialResults = new Map<string, string>();
    const messages = translateContentBlocks(
      [{ type: "image", data: "R0lGODlh" }],
      partialResults,
      "tc-img",
    );

    expect(messages).toHaveLength(1);
    expect((messages[0] as any).output).toContain("data:image/png;base64,");
  });

  it("defaults mimeType to audio/wav when audio mime is omitted", () => {
    const partialResults = new Map<string, string>();
    const messages = translateContentBlocks(
      [{ type: "audio", data: "UklGRiQAAABXQVZF" }],
      partialResults,
      "tc-audio",
    );

    expect(messages).toHaveLength(1);
    expect((messages[0] as any).output).toContain("data:audio/wav;base64,");
  });

  it("handles mixed text, image, and audio content blocks", () => {
    const partialResults = new Map<string, string>();
    const messages = translateContentBlocks(
      [
        { type: "text", text: "Reading media file..." },
        { type: "image", data: "iVBORw0KGgo=", mimeType: "image/jpeg" },
        { type: "audio", data: "UklGRiQAAABXQVZF", mimeType: "audio/wav" },
      ],
      partialResults,
      "tc-mixed",
    );

    expect(messages).toHaveLength(3);
    expect((messages[0] as any).output).toBe("Reading media file...");
    expect((messages[1] as any).output).toBe("data:image/jpeg;base64,iVBORw0KGgo=");
    expect((messages[2] as any).output).toBe("data:audio/wav;base64,UklGRiQAAABXQVZF");
  });

  it("skips media blocks with no data", () => {
    const partialResults = new Map<string, string>();
    const messages = translateContentBlocks(
      [{ type: "audio" }],  // no data field
      partialResults,
      "tc-empty",
    );

    expect(messages).toHaveLength(0);
  });
});

// ─── End-to-end simulation ───

describe("end-to-end tool event simulation", () => {
  it("simulates pi RPC events through delta conversion", () => {
    const partialResults = new Map<string, string>();
    const clientOutput: string[] = [];

    // Simulate pi RPC events for a bash command with incremental output
    const toolCallId = "toolu_01ABC";

    // tool_execution_start
    const startMsg: ServerMessage = {
      type: "tool_start",
      tool: "bash",
      args: { command: "cat file.txt" },
      toolCallId,
    };
    expect(startMsg.type).toBe("tool_start");

    // tool_execution_update 1: partialResult = "line1\n"
    const delta1 = computeDelta(partialResults, toolCallId, "line1\n");
    clientOutput.push(delta1);

    // tool_execution_update 2: partialResult = "line1\nline2\n" (accumulated)
    const delta2 = computeDelta(partialResults, toolCallId, "line1\nline2\n");
    clientOutput.push(delta2);

    // tool_execution_update 3: partialResult = "line1\nline2\nline3\n" (accumulated)
    const delta3 = computeDelta(partialResults, toolCallId, "line1\nline2\nline3\n");
    clientOutput.push(delta3);

    // tool_execution_end
    partialResults.delete(toolCallId);

    // Client concatenates all deltas — should equal the final output
    const finalOutput = clientOutput.join("");
    expect(finalOutput).toBe("line1\nline2\nline3\n");

    // No duplication
    expect(finalOutput.split("line1").length - 1).toBe(1);
    expect(finalOutput.split("line2").length - 1).toBe(1);
    expect(finalOutput.split("line3").length - 1).toBe(1);
  });
});
