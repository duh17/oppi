import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import { validatedNestedCalls } from "../src/tool-nested-calls.js";
import type { Session } from "../src/types.js";

const nested = {
  calls: [
    {
      id: "t/1",
      name: "mcp__example",
      status: "ok",
      arguments: { labelId: "480696530943115366", sportType: 103 },
      durationMs: 1528,
    },
  ],
  complete: true,
};
function context(): TranslationContext {
  return {
    sessionId: "s",
    partialResults: new Map(),
    streamedAssistantText: "",
    toolNames: new Map(),
    shellPreviewLastSent: new Map(),
    streamingToolUpdatesSeen: new Map(),
    mobileRenderers: new MobileRendererRegistry(),
  };
}
function translate(event: unknown, ctx: TranslationContext) {
  return translatePiEvent(event as AgentSessionEvent, ctx);
}

describe("tool call document producer", () => {
  it("emits static code hints on start and streaming arguments", () => {
    const ctx = context();
    expect(
      translate(
        {
          type: "tool_execution_start",
          toolCallId: "t",
          toolName: "codemode",
          args: { code: "text(1)" },
        },
        ctx,
      )[0],
    ).toMatchObject({
      inputPresentation: { fields: { code: { role: "code", language: "javascript" } } },
    });
    expect(
      translate(
        {
          type: "message_update",
          assistantMessageEvent: {
            type: "toolcall_end",
            toolCall: { id: "t2", name: "codemode", arguments: { code: "text(2)" } },
          },
        },
        ctx,
      )[0],
    ).toMatchObject({
      type: "tool_update",
      inputPresentation: { fields: { code: { role: "code", language: "javascript" } } },
    });
    expect(
      translate(
        { type: "tool_execution_start", toolCallId: "t3", toolName: "unknown", args: {} },
        ctx,
      )[0],
    ).not.toHaveProperty("inputPresentation");
  });
  it("forwards Pi result-message nestedCalls without duplicating output", () => {
    const ctx = context();
    const result = translate(
      {
        type: "message_end",
        message: {
          role: "toolResult",
          toolName: "codemode",
          toolCallId: "t",
          content: [{ type: "text", text: "output" }],
          nestedCalls: nested,
          isError: false,
        },
      },
      ctx,
    );
    expect(result).toEqual([
      { type: "tool_end", tool: "codemode", toolCallId: "t", nestedCalls: nested, isError: false },
    ]);
  });
  it("validates sidecar hints, including modules loaded from disk", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-input-hints-"));
    try {
      const path = join(dir, "renderer.mjs");
      writeFileSync(
        path,
        `export default { custom: { inputPresentation: { fields: { source: { role: "code", language: "python" } } }, renderCall() { return [] }, renderResult() { return [] } } };`,
      );
      const registry = new MobileRendererRegistry();
      expect((await registry.loadRenderer(path)).errors).toEqual([]);
      expect(registry.inputPresentation("custom")).toEqual({
        fields: { source: { role: "code", language: "python" } },
      });
      registry.register("bad", {
        inputPresentation: { fields: { source: { role: "code", language: "python\n```" } } },
        renderCall: () => [],
        renderResult: () => [],
      });
      expect(registry.inputPresentation("bad")).toBeUndefined();
      for (const fields of [
        { source: { role: "command", language: "bash" } },
        { source: "python" },
      ]) {
        registry.register("bad-role", {
          inputPresentation: { fields } as never,
          renderCall: () => [],
          renderResult: () => [],
        });
        expect(registry.inputPresentation("bad-role")).toBeUndefined();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it("drops malformed records and retains Pi argument/count bounds", () => {
    const result = validatedNestedCalls({
      calls: [
        null,
        { id: "bad", name: "tool", status: "unknown" },
        ...nested.calls,
        {
          id: "big",
          name: "tool",
          status: "error",
          arguments: { data: "x".repeat(9000) },
          error: "e".repeat(700),
        },
      ],
      complete: true,
    });
    expect(result?.complete).toBe(false);
    expect(result?.calls).toHaveLength(2);
    expect(result?.calls[0]).toEqual(nested.calls[0]);
    expect(result?.calls[1].arguments).toBeUndefined();
    expect(result?.calls[1].argumentsBytes).toBeGreaterThan(8192);
    expect(result?.calls[1].error).toHaveLength(500);
    expect(
      validatedNestedCalls({ calls: Array(300).fill(nested.calls[0]), complete: true })?.calls,
    ).toHaveLength(256);
  });
  it("produces identical live and raw/mobile trace metadata", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-document-trace-"));
    try {
      const path = join(dir, "session.jsonl");
      writeFileSync(
        path,
        [
          {
            type: "message",
            id: "a",
            parentId: null,
            timestamp: "2026-09-30T15:20:00Z",
            message: {
              role: "assistant",
              content: [
                { type: "toolCall", id: "t", name: "codemode", arguments: { code: "text(1)" } },
              ],
            },
          },
          {
            type: "message",
            id: "b",
            parentId: "a",
            timestamp: "2026-09-30T15:20:01Z",
            message: {
              role: "toolResult",
              toolCallId: "t",
              toolName: "codemode",
              content: [{ type: "text", text: "ok" }],
              nestedCalls: nested,
            },
          },
        ]
          .map((entry) => JSON.stringify(entry))
          .join("\n"),
      );
      const session = { id: "s", piSessionFile: path, status: "stopped" } as Session;
      const service = new SessionTraceService({
        storage: {
          getDataDir: () => dir,
          getSession: () => session,
          getWorkspace: () => undefined,
          listWorkspaces: () => [],
        },
        sessionRuntimes: {
          refreshSessionState: async () => null,
          getToolFullOutputPath: () => null,
        },
        ensureSessionContextWindow: (s) => s,
      });
      const raw = await service.getSessionWithTrace({ session });
      const mobile = await service.getSessionWithTrace({
        session,
        includePresentationSegments: true,
      });
      for (const trace of [raw.trace, mobile.trace]) {
        expect(trace.find((e) => e.type === "toolCall")?.inputPresentation).toEqual({
          fields: { code: { role: "code", language: "javascript" } },
        });
        expect(trace.find((e) => e.type === "toolResult")?.nestedCalls).toEqual(nested);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
