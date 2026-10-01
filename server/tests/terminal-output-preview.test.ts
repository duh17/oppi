import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { translatePiEvent, type TranslationContext } from "../src/session-protocol.js";
import { createSessionTraceRouteHandlers } from "../src/routes/session-trace-handlers.js";
import { SessionTraceService } from "../src/session-trace-service.js";
import type { Session } from "../src/types.js";
import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

// Above Oppi's 8 KB threshold but below Pi's 50 KB / 2000-line limits.
const full = Array.from({ length: 300 }, (_, i) => `row-${i} ${"x".repeat(61)} 🙂\n`).join("");

describe("terminal preview source handoff", () => {
  it("never exposes a Pi-truncated live snapshot as full output", () => {
    const registry = new MobileRendererRegistry();
    const ctx: TranslationContext = {
      sessionId: "s",
      toolOutputSnapshots: new ToolOutputSnapshots(),
      streamedAssistantText: "",
      mobileRenderers: registry,
      toolNames: new Map(),
      shellPreviewLastSent: new Map(),
      streamingToolUpdatesSeen: new Map(),
    };
    translatePiEvent(
      {
        type: "tool_execution_start",
        toolCallId: "tc",
        toolName: "bash",
        args: {},
      } as AgentSessionEvent,
      ctx,
    );
    const partialResult = {
      content: [{ type: "text", text: full }],
      details: { truncation: { truncated: true, totalBytes: 200000 } },
    };
    translatePiEvent(
      {
        type: "tool_execution_update",
        toolCallId: "tc",
        toolName: "bash",
        partialResult,
      } as AgentSessionEvent,
      ctx,
    );
    expect(ctx.toolOutputSnapshots.previous("tc")).toBe(full);
    expect(ctx.toolOutputSnapshots.fullOutput("tc")).toBeNull();
    translatePiEvent(
      {
        type: "tool_execution_end",
        toolCallId: "tc",
        toolName: "bash",
        result: partialResult,
      } as AgentSessionEvent,
      ctx,
    );
    expect(ctx.toolOutputSnapshots.fullOutput("tc")).toBeNull();
  });
  it.each(["bash", "run_thing"])(
    "keeps %s full output reachable during preview, completion and trace reload",
    async (toolName) => {
      const root = mkdtempSync(join(tmpdir(), "oppi-preview-source-"));
      roots.push(root);
      const jsonl = join(root, "session.jsonl");
      writeFileSync(jsonl, "");
      const registry = new MobileRendererRegistry();
      if (toolName !== "bash")
        registry.register(toolName, {
          outputPresentation: { kind: "terminal" },
          inputPresentation: { fields: { script: { role: "command", language: "shell" } } },
          renderCall: () => [],
          renderResult: () => [],
        });
      const ctx: TranslationContext = {
        sessionId: "sess-1",
        toolOutputSnapshots: new ToolOutputSnapshots(),
        streamedAssistantText: "",
        currentThinkingContentIndex: undefined,
        mobileRenderers: registry,
        toolNames: new Map(),
        toolArgs: new Map(),
        shellPreviewLastSent: new Map(),
        streamingToolUpdatesSeen: new Map(),
      };
      const session = {
        id: "sess-1",
        workspaceId: "w1",
        status: "busy",
        piSessionFile: jsonl,
      } as Session;
      const runtimes = {
        getToolFullOutputPath: () => null,
        getToolPartialOutput: (_sessionId: string, id: string) =>
          ctx.toolOutputSnapshots.fullOutput(id),
        refreshSessionState: async () => session,
      };
      const storage = {
        getDataDir: () => root,
        getSession: () => session,
        getWorkspace: () => undefined,
      };
      const service = new SessionTraceService({
        storage,
        sessionRuntimes: runtimes,
        ensureSessionContextWindow: (s) => s,
        mobileRenderers: registry,
      });
      const helpers = {
        error: (res: ServerResponse, status: number, error: string) => {
          res.writeHead(status);
          res.end(error);
        },
        compressedJson: (_req: IncomingMessage, res: ServerResponse, value: unknown) => {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify(value));
        },
      };
      const handlers = createSessionTraceRouteHandlers(
        {
          storage,
          sessionRuntimes: runtimes,
          sessions: { mobileRenderer: registry },
          ensureSessionContextWindow: (s: Session) => s,
        } as never,
        helpers as never,
        () => session,
        () => session,
      );
      const server = createServer((req, res) => {
        void handlers
          .handleGetFullToolOutput("w1", "sess-1", "tc", req, res, req.method)
          .catch((error) => res.destroy(error));
      });
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      const address = server.address();
      if (!address || typeof address === "string") throw new Error("Missing HTTP address");
      const url = `http://127.0.0.1:${address.port}/full`;
      const emit = (event: unknown) => translatePiEvent(event as AgentSessionEvent, ctx);
      try {
        emit({
          type: "tool_execution_start",
          toolName,
          toolCallId: "tc",
          args: { script: "emit fixture" },
        });
        const update = emit({
          type: "tool_execution_update",
          toolName,
          toolCallId: "tc",
          partialResult: {
            content: [
              { type: "text", text: full.slice(0, Math.floor(full.length / 2)) },
              { type: "text", text: full.slice(Math.floor(full.length / 2)) },
            ],
            details: {},
          },
        });
        const head = await fetch(url, { method: "HEAD" });
        expect(head.status).toBe(200);
        expect(Number(head.headers.get("content-length"))).toBe(Buffer.byteLength(full));
        const window = await fetch(url, { headers: { Range: "bytes=0-131071" } });
        expect(window.status).toBe(206);
        expect(await window.text()).toBe(full);
        const splitCodepoint = await fetch(url, { headers: { Range: "bytes=69-75" } });
        expect(splitCodepoint.status).toBe(206);
        expect(await splitCodepoint.text()).not.toContain("\uFFFD");
        expect(await (await fetch(url)).json()).toEqual({ toolCallId: "tc", output: full });
        const preview = update.find((message) => message.type === "tool_output");
        expect(preview).toMatchObject({
          mode: "replace",
          truncated: true,
          outputAvailability: {
            complete: false,
            totalBytes: Buffer.byteLength(full),
            source: "sidecar",
          },
        });
        expect(preview?.output).not.toBe(full);

        const end = emit({
          type: "tool_execution_end",
          toolName,
          toolCallId: "tc",
          result: { content: [{ type: "text", text: full }], details: {} },
        });
        expect(end.find((message) => message.type === "tool_output")).toMatchObject({
          output: full,
          mode: "replace",
          truncated: false,
          outputAvailability: { complete: true },
        });
        const endFact = end.find((message) => message.type === "tool_end")?.outputAvailability;
        expect(endFact).toEqual({ complete: true });
        // Exercise the interval after tool_end and before Pi appends its result.
        expect(await service.getFullToolOutput(session.id, "tc")).toEqual({
          toolCallId: "tc",
          output: full,
        });
        writeFileSync(
          jsonl,
          [
            {
              type: "message",
              id: "a",
              timestamp: "2026-09-30T00:00:00Z",
              message: {
                role: "assistant",
                content: [
                  {
                    type: "toolCall",
                    id: "tc",
                    name: toolName,
                    arguments: { script: "emit fixture" },
                  },
                ],
              },
            },
            {
              type: "message",
              id: "r",
              parentId: "a",
              timestamp: "2026-09-30T00:00:01Z",
              message: {
                role: "toolResult",
                toolName,
                toolCallId: "tc",
                content: [{ type: "text", text: full }],
                details: {},
              },
            },
          ]
            .map((entry) => JSON.stringify(entry))
            .join("\n"),
        );
        emit({ type: "turn_end", turnIndex: 0 });
        expect(ctx.toolOutputSnapshots.size).toBe(0);
        expect(await (await fetch(url)).json()).toEqual({ toolCallId: "tc", output: full });
        session.status = "stopped";
        const replay = await service.getSessionWithTrace({ session, includeSegments: false });
        const result = replay?.trace?.find((event) => event.type === "toolResult");
        expect(result?.output).toBe(full);
        expect(result?.outputAvailability).toEqual(endFact);
        expect(await service.getFullToolOutput(session.id, "tc")).toEqual({
          toolCallId: "tc",
          output: full,
        });
      } finally {
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        );
      }
    },
  );
});
