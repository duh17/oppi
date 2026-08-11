import { EventEmitter } from "node:events";
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import {
  APP_EVENT_MESSAGES_FIXTURE_DESCRIPTION,
  APP_EVENT_MESSAGES_SNAPSHOT_FILE,
  assertProtocolFixtureBytes,
  buildCanonicalAppEventMessages,
  serializeProtocolFixture,
} from "./protocol-fixtures.js";
import {
  APP_EVENT_ALLOWED_TYPES,
  APP_EVENT_FORBIDDEN_SERVER_MESSAGE_TYPES,
  AppEventStreamMux,
  isAppEventAllowedType,
} from "../src/app-event-stream.js";
import type { AppEventMessage, ServerMessage, Session } from "../src/types.js";

const canonicalMessages = buildCanonicalAppEventMessages();
const expectedCanonicalSnapshot = serializeProtocolFixture(
  APP_EVENT_MESSAGES_FIXTURE_DESCRIPTION,
  canonicalMessages,
);

function makeSession(id = "sess-1", workspaceId = "ws-1"): Session {
  return {
    id,
    workspaceId,
    workspaceName: "Workspace One",
    name: "Test session",
    status: "ready",
    createdAt: 1_791_650_000_000,
    lastActivity: 1_791_650_010_000,
    model: "anthropic/claude-sonnet-4-20250514",
    messageCount: 1,
    tokens: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0 },
    cost: 0.001,
    firstMessage: "Hello",
    launch: {
      source: "agent",
      agentId: "agent-reviewer",
      agentVersion: 4,
      agentIcon: { kind: "symbol", name: "checkmark.shield" },
      status: "accepted",
      requestedAt: 1_791_649_999_000,
    },
  };
}

class FakeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: AppEventMessage[] = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as AppEventMessage);
  }

  ping(): void {}

  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }

  close(code = 1000): void {
    this.readyState = WebSocket.CLOSED;
    this.emit("close", code, Buffer.from(""));
  }

  receiveJson(value: unknown): void {
    this.emit("message", Buffer.from(JSON.stringify(value)), false);
  }
}

function makeMux(): {
  mux: AppEventStreamMux;
  session: Session;
  pendingMessages: ServerMessage[];
  trackConnection: ReturnType<typeof vi.fn>;
  untrackConnection: ReturnType<typeof vi.fn>;
} {
  const session = makeSession();
  const sessions = new Map([[session.id, session]]);
  const pendingMessages: ServerMessage[] = [];
  const trackConnection = vi.fn();
  const untrackConnection = vi.fn();
  const mux = new AppEventStreamMux({
    storage: {
      getSession: (sessionId: string) => sessions.get(sessionId),
    },
    sessionRuntimes: {
      getActiveSessionIds: () => new Set([session.id]),
      getActiveSession: (sessionId: string) => sessions.get(sessionId),
      getSessionSnapshot: (sessionId: string) => sessions.get(sessionId),
      getPendingUIRequestMessages: (sessionId: string) =>
        sessionId === session.id ? [...pendingMessages] : [],
    },
    ensureSessionContextWindow: (value) => value,
    trackConnection,
    untrackConnection,
    now: () => 1_791_650_100_000,
  });

  return { mux, session, pendingMessages, trackConnection, untrackConnection };
}

describe("AppEventMessage protocol", () => {
  it("keeps an explicit app-event allowlist", () => {
    expect(APP_EVENT_ALLOWED_TYPES).toEqual([
      "session_created",
      "session_imported",
      "session_discovered",
      "session_summary",
      "session_deleted",
      "session_ended",
      "stop_requested",
      "stop_confirmed",
      "stop_failed",
      "session_error",
      "extension_ui_request",
      "extension_ui_settled",
      "extension_ui_notification",
      "workspace_git_changed",
    ]);

    for (const type of APP_EVENT_ALLOWED_TYPES) {
      expect(isAppEventAllowedType(type)).toBe(true);
    }
  });

  it("reports app-event fixture drift without writing tracked fixtures", () => {
    const tracked = readFileSync(APP_EVENT_MESSAGES_SNAPSHOT_FILE, "utf8");
    const drifted = tracked.replace('"message": "Build completed"', '"message": "Build changed"');

    expect(drifted).not.toBe(tracked);
    expect(() => assertProtocolFixtureBytes("app-event-messages.json", tracked, drifted)).toThrow(
      /app-event-messages\.json at byte \d+/,
    );
    expect(readFileSync(APP_EVENT_MESSAGES_SNAPSHOT_FILE, "utf8")).toBe(tracked);
  });

  it("matches the committed app-event fixture byte-for-byte", () => {
    const tracked = readFileSync(APP_EVENT_MESSAGES_SNAPSHOT_FILE, "utf8");

    expect(() =>
      assertProtocolFixtureBytes("app-event-messages.json", expectedCanonicalSnapshot, tracked),
    ).not.toThrow();

    const parsed = JSON.parse(tracked) as { messages?: Record<string, unknown> };
    expect(parsed.messages).toBeDefined();
    expect(Object.keys(parsed.messages ?? {})).toHaveLength(Object.keys(canonicalMessages).length);

    for (const [key, value] of Object.entries(canonicalMessages)) {
      const message = value as { type?: unknown; seq?: unknown; currentSeq?: unknown };
      expect(message.type, key).toBeTypeOf("string");
      expect(isAppEventAllowedType(message.type as string), key).toBe(true);
      expect("seq" in message).toBe(false);
      expect("currentSeq" in message).toBe(false);
    }
  });
});

describe("AppEventStreamMux", () => {
  it("delivers the app stream vertical slice and never forwards focused frames", () => {
    const { mux, session, pendingMessages, trackConnection, untrackConnection } = makeMux();
    const ws = new FakeWebSocket();

    mux.handleWebSocket(ws as unknown as WebSocket);
    expect(trackConnection).toHaveBeenCalledWith(ws);
    expect(ws.sent).toEqual([
      { type: "app_events_connected", serverTime: 1_791_650_100_000, snapshotRequired: true },
    ]);

    mux.emitSessionCreated(session);

    session.status = "busy";
    session.lastActivity += 1;
    mux.handleSessionBroadcastEvent({
      sessionId: session.id,
      durable: false,
      event: { type: "state", session },
    });

    mux.handleSessionBroadcastEvent({
      sessionId: session.id,
      durable: true,
      event: { type: "text_delta", delta: "hidden" },
    });
    mux.handleSessionBroadcastEvent({
      sessionId: session.id,
      durable: true,
      event: { type: "tool_start", tool: "bash", args: { command: "echo nope" } },
    });
    mux.handleSessionBroadcastEvent({
      sessionId: session.id,
      durable: true,
      event: { type: "message_end", role: "assistant", content: "done" },
    });

    const request: ServerMessage = {
      type: "extension_ui_request",
      id: "ask-1",
      sessionId: session.id,
      method: "ask",
      title: "Approve?",
      questions: [
        {
          id: "q1",
          question: "Approve?",
          options: [{ value: "yes", label: "Yes" }],
        },
      ],
      allowCustom: false,
    };
    pendingMessages.push(request);
    mux.handleSessionBroadcastEvent({ sessionId: session.id, durable: false, event: request });

    pendingMessages.length = 0;
    mux.handleSessionBroadcastEvent({
      sessionId: session.id,
      durable: false,
      event: { type: "extension_ui_settled", id: "ask-1", sessionId: session.id },
    });

    ws.receiveJson({ type: "prompt", message: "client frames are ignored" });

    const types = ws.sent.map((message) => message.type);
    expect(types).toEqual([
      "app_events_connected",
      "session_created",
      "session_summary",
      "extension_ui_request",
      "session_summary",
      "extension_ui_settled",
      "session_summary",
    ]);

    for (const forbidden of APP_EVENT_FORBIDDEN_SERVER_MESSAGE_TYPES) {
      expect(types).not.toContain(forbidden);
    }
    for (const message of ws.sent) {
      expect("seq" in message).toBe(false);
      expect("currentSeq" in message).toBe(false);
    }

    const created = ws.sent.find(
      (message): message is Extract<AppEventMessage, { type: "session_created" }> =>
        message.type === "session_created",
    );
    expect(created?.summary.pendingAskCount).toBe(0);

    const summaries = ws.sent.filter(
      (message): message is Extract<AppEventMessage, { type: "session_summary" }> =>
        message.type === "session_summary",
    );
    expect(summaries.map((message) => message.summary.pendingAskCount)).toEqual([0, 1, 0]);

    ws.close();
    expect(untrackConnection).toHaveBeenCalledWith(ws);
  });

  it("converts focused git_status to invalidation-only workspace_git_changed", () => {
    const { mux, session } = makeMux();
    const ws = new FakeWebSocket();
    mux.handleWebSocket(ws as unknown as WebSocket);

    mux.handleSessionBroadcastEvent({
      sessionId: session.id,
      durable: false,
      event: {
        type: "git_status",
        workspaceId: "ws-1",
        worktreeId: "wt_feature",
        status: {
          isGitRepo: true,
          branch: "main",
          headSha: "abc",
          ahead: 0,
          behind: 0,
          dirtyCount: 1,
          untrackedCount: 0,
          stagedCount: 0,
          files: [{ status: "M", path: "README.md", addedLines: 2, removedLines: 1 }],
          totalFiles: 1,
          addedLines: 2,
          removedLines: 1,
          stashCount: 0,
          lastCommitMessage: null,
          lastCommitDate: null,
        },
      },
    });

    const gitChanged = ws.sent.find(
      (message): message is Extract<AppEventMessage, { type: "workspace_git_changed" }> =>
        message.type === "workspace_git_changed",
    );
    expect(gitChanged).toEqual({
      type: "workspace_git_changed",
      workspaceId: "ws-1",
      worktreeId: "wt_feature",
      sessionId: session.id,
      emittedAt: 1_791_650_100_000,
      reason: "mutation_tool",
    });
    expect(gitChanged).not.toHaveProperty("status");
    expect(gitChanged).not.toHaveProperty("files");
    expect(gitChanged).not.toHaveProperty("addedLines");
    expect(gitChanged).not.toHaveProperty("removedLines");
  });
});
