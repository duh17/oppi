import { ToolOutputSnapshots } from "../src/tool-output-sidecar.js";
import { EventEmitter } from "node:events";

import type { AgentSessionEvent } from "@earendil-works/pi-coding-agent";
import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import type { SessionBackendEvent } from "../src/pi-events.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "../src/session-agent-events.js";
import { SessionEventProcessor } from "../src/session-events.js";
import type { Storage } from "../src/storage.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

class FakeBridgeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];

  send(data: string, cb?: (err?: Error) => void): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
    cb?.();
  }

  close(): void {
    this.readyState = WebSocket.CLOSED;
  }

  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
}

function makeSession(id = "sess-1"): Session {
  return {
    id,
    workspaceId: "w1",
    workspaceName: "Workspace",
    status: "busy",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function makeActiveSession(): SessionAgentEventState {
  return {
    session: makeSession(),
    pendingUIRequests: new Map(),
    toolOutputSnapshots: new ToolOutputSnapshots(),
    streamedAssistantText: "",
    toolNames: new Map(),
    streamingToolUpdatesSeen: new Map(),
    turnCache: new TurnDedupeCache(),
    pendingTurnStarts: [],
    sdkBackend: { sessionTree: () => undefined, toolDefinition: () => undefined } as never,
    subscribers: new Set(),
    toolFullOutputPaths: new Map(),
  };
}

function makeManagedHarness(mobileRenderers: MobileRendererRegistry): {
  received: ServerMessage[];
  session: Session;
  ingest: (event: AgentSessionEvent) => void;
} {
  const active = makeActiveSession();
  const received: ServerMessage[] = [];
  const eventProcessor = new SessionEventProcessor({
    mobileRenderers,
    storage: { getWorkspace: vi.fn(() => null) } as unknown as Storage,
    broadcast: (_key, message) => received.push(message),
    persistSessionNow: vi.fn(),
    markSessionDirty: vi.fn(),
  });
  const coordinator = new SessionAgentEventCoordinator({
    getActiveSession: vi.fn(() => active),
    eventProcessor,
    stopCoordinator: { finishPendingStopOnAgentEnd: vi.fn() } as never,
    turnCoordinator: { markNextTurnStarted: vi.fn() } as never,
    broadcast: (_key, message) => received.push(message),
    resetIdleTimer: vi.fn(),
  });

  return {
    received,
    session: active.session,
    ingest: (event) => coordinator.handlePiEvent(active.session.id, event as SessionBackendEvent),
  };
}

function makeMirrorHarness(mobileRenderers: MobileRendererRegistry): {
  received: ServerMessage[];
  session: () => Session;
  ingest: (event: AgentSessionEvent) => void;
} {
  const workspace: Workspace = {
    id: "w1",
    name: "Workspace",
    hostMount: "/tmp/oppi-runtime-parity",
  };
  const sessions = new Map<string, Session>();
  const storage = {
    getWorkspace: vi.fn((id: string) => (id === workspace.id ? workspace : null)),
    listWorkspaces: vi.fn(() => [workspace]),
    listSessions: vi.fn(() => Array.from(sessions.values())),
    getSession: vi.fn((id: string) => sessions.get(id) ?? null),
    createSession: vi.fn(() => {
      const session = makeSession();
      sessions.set(session.id, session);
      return session;
    }),
    saveSession: vi.fn((session: Session) => {
      sessions.set(session.id, structuredClone(session));
    }),
    getConfig: vi.fn(() => ({ dataDir: "/tmp/oppi-runtime-parity-config" })),
    getDataDir: vi.fn(() => "/tmp/oppi-runtime-parity-config"),
  } as unknown as Storage;
  const runtime = new PiTuiMirrorRuntime(storage, { mobileRenderers });
  const ws = new FakeBridgeWebSocket();
  runtime.handleBridgeWebSocket(ws as unknown as WebSocket);
  ws.receive({
    type: "hello",
    protocolVersion: 2,
    bridgeId: "bridge-1",
    workspaceId: "w1",
    cwd: "/tmp/oppi-runtime-parity",
    capabilities: ["input_preflight:v1"],
    state: {
      piSessionId: "pi-1",
      sessionFile: "/tmp/oppi-runtime-parity/session.jsonl",
      isIdle: false,
    },
  });
  const ack = ws.sent.find((message) => message.type === "hello_ack");
  const sessionId = String(ack?.sessionId);
  const received: ServerMessage[] = [];
  runtime.subscribe(sessionId, (message) => received.push(message));

  return {
    received,
    session: () => runtime.getActiveSession(sessionId)!,
    ingest: (event) => ws.receive({ type: "event", event }),
  };
}

function normalizeSessionForParity(session: Session): Session {
  const clone = structuredClone(session) as Session;
  delete clone.runtime;
  delete clone.mirror;
  delete clone.piSessionFile;
  delete clone.piSessionFiles;
  delete clone.piSessionId;
  delete clone.currentTurnStartedAt;
  delete clone.firstMessage;
  delete clone.lastActivity;
  delete clone.lastAgentReplyAt;
  return clone;
}

function normalizeMessages(messages: ServerMessage[]): ServerMessage[] {
  return messages.map((message) => {
    const clone = structuredClone(message) as ServerMessage & { seq?: number };
    delete clone.seq;
    if (clone.type === "state" || clone.type === "connected") {
      clone.session = normalizeSessionForParity(clone.session);
    } else if (clone.type === "session_summary") {
      const summary = clone.summary as Session & { changeStats?: Session["changeStats"] };
      clone.summary = normalizeSessionForParity(summary);
    }
    return clone;
  });
}

function expectRuntimeParity(
  events: AgentSessionEvent[],
  mobileRenderers = new MobileRendererRegistry(),
): {
  managed: ReturnType<typeof makeManagedHarness>;
  mirror: ReturnType<typeof makeMirrorHarness>;
} {
  const managed = makeManagedHarness(mobileRenderers);
  const mirror = makeMirrorHarness(mobileRenderers);

  for (const event of events) {
    managed.ingest(event);
    mirror.ingest(event);
  }

  expect(normalizeMessages(mirror.received)).toEqual(normalizeMessages(managed.received));
  return { managed, mirror };
}

describe("managed and mirror runtime event parity", () => {
  it("projects interactive facts for any exact declared name without streaming answer output", () => {
    const registry = new MobileRendererRegistry();
    registry.register("choose_next", {
      outputPresentation: { kind: "interactive" },
      renderCall: () => [],
      renderResult: () => [],
    });
    for (const toolName of ["ask", "choose_next"]) {
      const { managed } = expectRuntimeParity(
        [
          {
            type: "tool_execution_start",
            toolCallId: "q",
            toolName,
            args: { questions: [{ id: "q", question: "Continue?" }] },
          },
          {
            type: "tool_execution_update",
            toolCallId: "q",
            toolName,
            partialResult: { content: [{ type: "text", text: "LLM-only answer" }] },
          },
          {
            type: "tool_execution_end",
            toolCallId: "q",
            toolName,
            result: {
              content: [{ type: "text", text: "LLM-only answer" }],
              details: { answers: { q: "yes" } },
            },
            isError: false,
          },
        ] as AgentSessionEvent[],
        registry,
      );
      expect(managed.received.filter((m) => m.type === "tool_output")).toEqual([]);
      expect(
        managed.received
          .filter((m) => m.type === "tool_start" || m.type === "tool_end")
          .map((m) => m.outputPresentation),
      ).toEqual([{ kind: "interactive" }, { kind: "interactive" }]);
    }
    expect(registry.outputPresentation("functions.ask")).toBeUndefined();
  });

  it("preserves nested parent identity on start, metadata update, output and end in both runtimes", () => {
    const events: AgentSessionEvent[] = [
      {
        type: "tool_execution_start",
        toolCallId: "parent",
        toolName: "codemode",
        args: { code: "await Promise.all([a(), b()])" },
      } as AgentSessionEvent,
    ];
    for (const [index, toolName] of ["mcp__alpha__a", "mcp__beta__b"].entries()) {
      const toolCallId = `child-${index}`;
      events.push(
        ...([
          {
            type: "tool_execution_start",
            toolCallId,
            parentToolCallId: "parent",
            toolName,
            args: { query: "first" },
          },
          {
            type: "tool_execution_update",
            toolCallId,
            parentToolCallId: "parent",
            toolName,
            args: { query: "updated" },
            partialResult: { content: [{ type: "text", text: "running" }] },
          },
          {
            type: "tool_execution_end",
            toolCallId,
            parentToolCallId: "parent",
            toolName,
            result: { content: [{ type: "text", text: "done" }] },
            isError: false,
          },
        ] as AgentSessionEvent[]),
      );
    }
    const { managed } = expectRuntimeParity(events);
    for (const id of ["child-0", "child-1"]) {
      const messages = managed.received.filter((m) => "toolCallId" in m && m.toolCallId === id);
      expect(messages.map((m) => m.type)).toEqual([
        "tool_start",
        "tool_update",
        "tool_output",
        "tool_output",
        "tool_end",
      ]);
      expect(
        messages.every((m) => "parentToolCallId" in m && m.parentToolCallId === "parent"),
      ).toBe(true);
    }
  });
  it("projects compaction lifecycle events identically", () => {
    const { managed, mirror } = expectRuntimeParity([
      { type: "compaction_start", reason: "threshold" },
      {
        type: "compaction_end",
        reason: "threshold",
        result: {
          summary: "Summarized context",
          firstKeptEntryId: "entry-1",
          tokensBefore: 180000,
        },
        aborted: false,
        willRetry: false,
      },
    ] as AgentSessionEvent[]);

    expect(mirror.session().changeStats?.compactionCount).toBe(
      managed.session.changeStats?.compactionCount,
    );
  });

  it("projects retry lifecycle events identically", () => {
    expectRuntimeParity([
      {
        type: "auto_retry_start",
        attempt: 1,
        maxAttempts: 3,
        delayMs: 500,
        errorMessage: "provider overloaded",
      },
      { type: "auto_retry_end", success: true, attempt: 1 },
    ] as AgentSessionEvent[]);
  });

  it("projects streamed thinking and assistant finalization identically", () => {
    const { managed, mirror } = expectRuntimeParity([
      {
        type: "message_update",
        message: {},
        assistantMessageEvent: { type: "thinking_delta", delta: "plan", contentIndex: 0 },
      },
      {
        type: "message_end",
        message: {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "plan" },
            { type: "text", text: "done" },
          ],
          usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0 },
        },
      },
    ] as AgentSessionEvent[]);

    expect(mirror.session().messageCount).toBe(managed.session.messageCount);
    expect(mirror.session().lastMessage).toBe(managed.session.lastMessage);
  });

  it("projects tool lifecycle events identically", () => {
    expectRuntimeParity([
      {
        type: "tool_execution_start",
        toolCallId: "tool-1",
        toolName: "bash",
        args: { command: "echo hi" },
      },
      {
        type: "tool_execution_update",
        toolCallId: "tool-1",
        toolName: "bash",
        args: { command: "echo hi" },
        partialResult: { content: [{ type: "text", text: "running" }] },
      },
      {
        type: "tool_execution_end",
        toolCallId: "tool-1",
        toolName: "bash",
        result: {
          content: [{ type: "text", text: "hi" }],
          details: { exitCode: 0, durationMs: 25 },
        },
        isError: false,
      },
    ] as AgentSessionEvent[]);
  });

  it("streams terminal output bytes and publishes terminal facts in both runtimes", () => {
    const output = "terminal output line\n".repeat(600);
    const { managed, mirror } = expectRuntimeParity([
      {
        type: "tool_execution_start",
        toolCallId: "terminal-1",
        toolName: "bash",
        args: { command: "emit logs" },
      },
      {
        type: "tool_execution_update",
        toolCallId: "terminal-1",
        toolName: "bash",
        partialResult: { content: [{ type: "text", text: output }] },
      },
      {
        type: "tool_execution_end",
        toolCallId: "terminal-1",
        toolName: "bash",
        isError: false,
        result: {
          content: [{ type: "text", text: output }],
          details: {
            truncation: { truncated: true, totalBytes: 100_000 },
            fullOutputPath: "/tmp/runtime-parity-full.log",
          },
        },
      },
    ] as AgentSessionEvent[]);
    for (const harness of [managed, mirror]) {
      expect(harness.received.find((message) => message.type === "tool_start")).toMatchObject({
        outputPresentation: { kind: "terminal" },
      });
      const outputs = harness.received.filter((message) => message.type === "tool_output");
      // The Pi file is unreadable here, so the stream carries only the text it saw.
      expect(outputs).toEqual([
        {
          type: "tool_output",
          toolCallId: "terminal-1",
          output,
          outputStream: { epoch: 1, offset: 0, bytes: Buffer.byteLength(output) },
        },
      ]);
      expect(harness.received.find((message) => message.type === "tool_end")).toMatchObject({
        outputPresentation: { kind: "terminal" },
        outputAvailability: { complete: false, totalBytes: 100_000, source: "sidecar" },
        outputStream: { epoch: 1, totalBytes: Buffer.byteLength(output) },
      });
    }
  });

  it.each(["read", "write", "edit", "put_file"])(
    "projects %s file facts identically in managed and mirror sessions",
    (name) => {
      const registry = new MobileRendererRegistry();
      registry.register("put_file", {
        inputPresentation: registry.inputPresentation("write"),
        outputPresentation: registry.outputPresentation("write"),
        renderCall: (args) => registry.renderCall("write", args) ?? [],
        renderResult: (details, error) => registry.renderResult("write", details, error) ?? [],
      });
      const args = {
        path: "main.ts",
        content: "requested",
        edits: [{ oldText: "a", newText: "b" }],
        offset: 3,
        limit: 7,
      };
      const { managed } = expectRuntimeParity(
        [
          { type: "tool_execution_start", toolCallId: "file-1", toolName: name, args },
          {
            type: "tool_execution_update",
            toolCallId: "file-1",
            toolName: name,
            partialResult: { content: [{ type: "text", text: "partial" }] },
          },
          {
            type: "tool_execution_end",
            toolCallId: "file-1",
            toolName: name,
            isError: false,
            result: {
              content: [{ type: "text", text: "result" }],
              details: { diff: "-42 old\n+42 actual" },
            },
          },
        ] as AgentSessionEvent[],
        registry,
      );
      expect(managed.received.find((event) => event.type === "tool_start")).toMatchObject({
        inputPresentation: registry.inputPresentation(name),
        outputPresentation: registry.outputPresentation(name),
      });
      expect(managed.received.find((event) => event.type === "tool_end")).toMatchObject({
        outputPresentation: registry.outputPresentation(name),
        outputAvailability: { complete: true },
      });
    },
  );

  it.each(["voice_reply_mode", "unrelated"])(
    "projects %s setting authority identically",
    (toolName) => {
      const registry = new MobileRendererRegistry();
      const { managed } = expectRuntimeParity(
        [
          { type: "tool_execution_start", toolCallId: "setting", toolName, args: {} },
          {
            type: "tool_execution_end",
            toolCallId: "setting",
            toolName,
            result: {
              content: [],
              details: {
                kind: "voice_reply_mode",
                mode: "manual",
                outputPresentation: { kind: "structured", settingEffect: "voiceReplyMode" },
              },
            },
          },
        ] as AgentSessionEvent[],
        registry,
      );
      expect(
        managed.received.find((event) => event.type === "tool_end")?.outputPresentation,
      ).toEqual({
        kind: "structured",
        ...(toolName === "voice_reply_mode" ? { settingEffect: "voiceReplyMode" } : {}),
      });
    },
  );

  it("projects assistant error finalization identically", () => {
    expectRuntimeParity([
      {
        type: "message_end",
        message: {
          role: "assistant",
          content: [],
          stopReason: "error",
          errorMessage:
            'Codex error: {"type":"error","error":{"type":"service_unavailable_error","message":"try later"}}',
        },
      },
    ] as unknown as AgentSessionEvent[]);
  });
});
