import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { MobileRendererRegistry, resolveToolDisplay } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import { McpService } from "../src/mcp-service.js";
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
  it("resolves display identity from live definition, then result facts, then MCP naming", () => {
    const name = "mcp__coros__getActivityDetail";
    expect(
      resolveToolDisplay(
        name,
        { label: "configured/get-activity", namespace: { name: "mcp__configured" } },
        { server: "ignored", tool: "ignored", serverInfo: { name: "mcp-server" } },
      ),
    ).toEqual({ title: "get-activity", group: "configured" });
    expect(
      resolveToolDisplay(name, undefined, { server: "coros", tool: "getActivityDetail" }),
    ).toEqual({ title: "getActivityDetail", group: "coros" });
    expect(resolveToolDisplay(name)).toEqual({ title: "getActivityDetail", group: "coros" });
    expect(resolveToolDisplay("plain")).toBeUndefined();
    expect(resolveToolDisplay("mcp__incomplete")).toBeUndefined();
    expect(resolveToolDisplay("mcp____tool")).toBeUndefined();
    expect(
      resolveToolDisplay("mcp__dev_radius__getActivityDetail", undefined, undefined, [
        "dev-radius",
        "dev_radius",
      ]),
    ).toEqual({ title: "getActivityDetail", group: "dev_radius" });
  });
  it("emits matching display facts on live, streamed and nested calls without changing raw names", () => {
    const ctx = context();
    ctx.getToolDefinition = () => ({
      label: "coros/getActivityDetail",
      namespace: { name: "mcp__coros" },
    });
    const name = "mcp__coros__getActivityDetail";
    const display = { title: "getActivityDetail", group: "coros" };
    expect(
      translate(
        { type: "tool_execution_start", toolCallId: "d", toolName: name, args: { labelId: "123" } },
        ctx,
      )[0],
    ).toMatchObject({ tool: name, display });
    expect(
      translate(
        {
          type: "message_update",
          assistantMessageEvent: {
            type: "toolcall_end",
            toolCall: { id: "d", name, arguments: { labelId: "1234" } },
          },
        },
        ctx,
      )[0],
    ).toMatchObject({ type: "tool_update", tool: name, display });
    const rawNested = { calls: [{ ...nested.calls[0], name }], complete: true };
    expect(
      translate(
        {
          type: "message_end",
          message: {
            role: "toolResult",
            toolName: "codemode",
            toolCallId: "parent",
            content: [],
            nestedCalls: rawNested,
          },
        },
        ctx,
      ),
    ).toEqual([
      {
        type: "tool_end",
        tool: "codemode",
        toolCallId: "parent",
        isError: undefined,
        nestedCalls: { ...rawNested, calls: [{ ...rawNested.calls[0], display }] },
      },
    ]);
  });
  it("enriches an existing live call when result metadata restores a sanitized MCP identity", () => {
    const ctx = context();
    ctx.toolArgs = new Map();
    const name = "mcp__dev_tools__get_activity";
    translate(
      { type: "tool_execution_start", toolCallId: "d", toolName: name, args: { id: 42 } },
      ctx,
    );
    const messages = translate(
      {
        type: "tool_execution_end",
        toolCallId: "d",
        toolName: name,
        result: { content: [], details: { server: "dev-tools", tool: "get-activity" } },
      },
      ctx,
    );
    expect(messages[0]).toEqual({
      type: "tool_update",
      tool: name,
      toolCallId: "d",
      args: { id: 42 },
      display: { title: "get-activity", group: "dev-tools" },
    });
    expect(messages[1]).toMatchObject({ type: "tool_end", toolCallId: "d" });
  });
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
  it("forwards unknown Pi statuses without changing completeness", () => {
    const calls = [{ id: "future", name: "tool", status: "queued" }];
    for (const complete of [true, false]) {
      expect(validatedNestedCalls({ calls, complete })).toEqual({ calls, complete });
    }
  });
  it("drops malformed records and retains Pi argument/count bounds", () => {
    const result = validatedNestedCalls({
      calls: [
        null,
        { id: "bad", name: "tool", status: 42 },
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
    expect(result?.complete).toBe(true);
    expect(result?.calls).toHaveLength(2);
    expect(result?.calls[0]).toEqual(nested.calls[0]);
    expect(result?.calls[1].arguments).toBeUndefined();
    expect(result?.calls[1].argumentsBytes).toBeGreaterThan(8192);
    expect(result?.calls[1].error).toHaveLength(500);
    const bounded = validatedNestedCalls({
      calls: Array(300).fill(nested.calls[0]),
      complete: true,
    });
    expect(bounded?.calls).toHaveLength(256);
    expect(bounded?.complete).toBe(true);
  });
  it("produces identical live and raw/mobile trace metadata", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-document-trace-"));
    try {
      const path = join(dir, "session.jsonl");
      writeFileSync(
        join(dir, "mcp.json"),
        JSON.stringify({ mcpServers: { "dev-radius": { command: "unused" } } }),
      );
      const mcp = new McpService({ agentDir: dir, listWorkspaces: () => [] });
      const nestedHyphenated = {
        calls: [{ ...nested.calls[0], name: "mcp__dev_radius__getActivityDetail" }],
        complete: true,
      };
      const liveContext = context();
      liveContext.getToolDefinition = () => ({
        label: "dev-radius/getActivityDetail",
        namespace: { name: "mcp__dev-radius" },
      });
      const live = translate(
        {
          type: "message_end",
          message: {
            role: "toolResult",
            toolName: "codemode",
            toolCallId: "t",
            content: [],
            nestedCalls: nestedHyphenated,
          },
        },
        liveContext,
      )[0];
      expect(live).toMatchObject({
        nestedCalls: { calls: [{ display: { title: "getActivityDetail", group: "dev-radius" } }] },
      });
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
                {
                  type: "toolCall",
                  id: "direct",
                  name: "mcp__coros__getActivityDetail",
                  arguments: { labelId: "123" },
                },
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
              nestedCalls: nestedHyphenated,
            },
          },
          {
            type: "message",
            id: "c",
            parentId: "b",
            timestamp: "2026-09-30T15:20:02Z",
            message: {
              role: "toolResult",
              toolCallId: "direct",
              toolName: "mcp__coros__getActivityDetail",
              content: [{ type: "text", text: "ok" }],
              details: { server: "coros", tool: "getActivityDetail" },
              nestedCalls: {
                calls: [{ ...nested.calls[0], name: "mcp__coros__getActivityDetail" }],
                complete: true,
              },
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
        getMcpServerNames: (s) => mcp.configuredServerNames(s.workspaceId),
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
        expect(trace.find((e) => e.type === "toolResult")?.nestedCalls).toEqual(
          live.type === "tool_end" ? live.nestedCalls : undefined,
        );
        expect(trace.find((e) => e.id === "direct")?.display).toEqual(
          resolveToolDisplay("mcp__coros__getActivityDetail", {
            label: "coros/getActivityDetail",
            namespace: { name: "mcp__coros" },
          }),
        );
        expect(trace.find((e) => e.toolCallId === "direct")?.nestedCalls?.calls[0]).toMatchObject({
          name: "mcp__coros__getActivityDetail",
          display: { title: "getActivityDetail", group: "coros" },
        });
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
