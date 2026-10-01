import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import type { Session } from "../src/types.js";

const inputPresentation = { fields: { command: { role: "command" as const, language: "shell" } } };
const outputPresentation = { kind: "terminal" as const };
const details = {
  truncation: { truncated: true, totalBytes: 9000 },
  fullOutputPath: "/private/tool-output.log",
};
const availability = { complete: false, totalBytes: 9000, source: "sidecar" };

function registry() {
  const value = new MobileRendererRegistry();
  value.register("run_thing", {
    inputPresentation,
    outputPresentation,
    renderCall: (args) => [
      { text: "$ ", style: "bold" },
      { text: String(args.command), style: "accent" },
    ],
    renderResult: () => [],
  });
  return value;
}
function context(mobileRenderers: MobileRendererRegistry): TranslationContext {
  return {
    sessionId: "s1",
    mobileRenderers,
    partialResults: new Map(),
    toolNames: new Map(),
    toolArgs: new Map(),
    streamingToolUpdatesSeen: new Map(),
    shellPreviewLastSent: new Map(),
    streamedAssistantText: "",
  };
}

describe("terminal inspection facts", () => {
  it.each(["bash", "run_thing"])(
    "projects %s through partial args, start, deltas, tail replace and end",
    (toolName) => {
      const ctx = context(registry());
      const project = (event: unknown) => translatePiEvent(event as AgentSessionEvent, ctx);
      const partial = project({
        type: "message_update",
        message: {
          content: [{ type: "toolCall", id: "tc", name: toolName, arguments: { command: "ec" } }],
        },
        assistantMessageEvent: { type: "toolcall_delta", contentIndex: 0, delta: "ec" },
      });
      expect(partial).toEqual([
        expect.objectContaining({
          type: "tool_update",
          args: { command: "ec" },
          inputPresentation,
          outputPresentation,
        }),
      ]);
      const start = project({
        type: "tool_execution_start",
        toolCallId: "tc",
        toolName,
        args: { command: "echo hello" },
      });
      expect(start).toEqual([
        expect.objectContaining({ type: "tool_start", inputPresentation, outputPresentation }),
      ]);
      const update = (text: string) =>
        project({
          type: "tool_execution_update",
          toolCallId: "tc",
          toolName,
          partialResult: { content: [{ type: "text", text }] },
        });
      expect(update("hello")).toEqual([{ type: "tool_output", output: "hello", toolCallId: "tc" }]);
      expect(update("hello\nworld")).toEqual([
        { type: "tool_output", output: "\nworld", toolCallId: "tc" },
      ]);
      const large = "x".repeat(9000);
      expect(update(large)).toEqual([
        expect.objectContaining({
          type: "tool_output",
          mode: "replace",
          truncated: true,
          totalBytes: 9000,
        }),
      ]);
      const end = project({
        type: "tool_execution_end",
        toolCallId: "tc",
        toolName,
        isError: false,
        result: { content: [{ type: "text", text: large }], details },
      });
      expect(end.at(-1)).toMatchObject({
        type: "tool_end",
        outputPresentation,
        outputAvailability: availability,
      });
      expect(JSON.stringify(end.at(-1)?.outputAvailability)).not.toContain("/private/");
    },
  );

  it.each(["bash", "run_thing"])(
    "reloads %s facts identically from stopped history without requesting segments",
    async (toolName) => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-terminal-inspection-"));
      try {
        const path = join(dataDir, "trace.jsonl");
        writeFileSync(
          path,
          [
            {
              type: "message",
              id: "a1",
              parentId: null,
              timestamp: "2026-09-30T00:00:00Z",
              message: {
                role: "assistant",
                content: [
                  {
                    type: "toolCall",
                    id: "tc",
                    name: toolName,
                    arguments: { command: "echo hello" },
                  },
                ],
              },
            },
            {
              type: "message",
              id: "r1",
              parentId: "a1",
              timestamp: "2026-09-30T00:00:01Z",
              message: {
                role: "toolResult",
                toolCallId: "tc",
                toolName,
                content: [{ type: "text", text: "x".repeat(9000) }],
                details,
                isError: false,
              },
            },
          ]
            .map((entry) => JSON.stringify(entry))
            .join("\n") + "\n",
        );
        const session = { id: "s1", status: "stopped", piSessionFile: path } as Session;
        const service = new SessionTraceService({
          storage: {
            getDataDir: () => dataDir,
            getSession: () => session,
            getWorkspace: () => undefined,
          },
          sessionRuntimes: {
            refreshSessionState: async () => null,
            getToolFullOutputPath: () => null,
          },
          ensureSessionContextWindow: (s) => s,
          mobileRenderers: registry(),
        });
        const replay = await service.getSessionWithTrace({ session });
        expect(replay.trace.find((event) => event.type === "toolCall")).toMatchObject({
          inputPresentation,
          outputPresentation,
        });
        expect(replay.trace.find((event) => event.type === "toolResult")).toMatchObject({
          outputPresentation,
          outputAvailability: availability,
        });
        expect(replay.trace.every((event) => event.callSegments === undefined)).toBe(true);
        const liveEnd = translatePiEvent(
          {
            type: "tool_execution_end",
            toolCallId: "tc",
            toolName,
            result: { content: [], details },
            isError: false,
          } as AgentSessionEvent,
          context(registry()),
        ).at(-1);
        expect(
          replay.trace.find((event) => event.type === "toolResult")?.outputAvailability,
        ).toEqual(liveEnd?.outputAvailability);
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    },
  );

  it("honors explicit result facts and rejects aliases and malformed declarations", () => {
    const r = registry();
    expect(r.outputPresentation("functions.bash")).toBeUndefined();
    expect(r.inputPresentation("Bash")).toBeUndefined();
    expect(r.outputPresentation("bash", { outputPresentation: { kind: "structured" } })).toEqual({
      kind: "structured",
    });
    expect(
      r.outputPresentation("bash", { expandedText: "# Result", presentationFormat: "markdown" }),
    ).toEqual({ kind: "structured" });
    expect(r.outputPresentation("unknown", { outputPresentation })).toEqual(outputPresentation);
    expect(r.outputAvailability({ truncation: { truncated: true, totalBytes: -1 } })).toEqual({
      complete: false,
    });
    expect(r.outputAvailability(undefined)).toEqual({ complete: true });
  });
});
