import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import {
  APP_EVENT_ALLOWED_TYPES,
  APP_EVENT_FORBIDDEN_SERVER_MESSAGE_TYPES,
  AppEventStreamMux,
  isAppEventAllowedType,
} from "../src/app-event-stream.js";
import type { AppEventMessage, ServerMessage, Session, SessionSummary } from "../src/types.js";

const PROTOCOL_DIR = resolve(__dirname, "../../protocol");
const APP_EVENT_SNAPSHOTS_FILE = join(PROTOCOL_DIR, "app-event-messages.json");

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
      agentIcon: "checkmark.shield",
      status: "accepted",
      requestedAt: 1_791_649_999_000,
    },
  };
}

function makeSessionSummary(session = makeSession()): SessionSummary {
  return {
    id: session.id,
    workspaceId: session.workspaceId,
    workspaceName: session.workspaceName,
    name: session.name,
    status: session.status,
    createdAt: session.createdAt,
    lastActivity: session.lastActivity,
    model: session.model,
    messageCount: session.messageCount,
    tokens: session.tokens,
    cost: session.cost,
    firstMessage: session.firstMessage,
    agentId: session.launch?.agentId,
    agentIcon: session.launch?.agentIcon,
    pendingAskCount: 0,
  };
}

function canonicalAppEventMessages(): Record<string, AppEventMessage> {
  const session = makeSession();
  const summary = makeSessionSummary(session);
  const emittedAt = 1_791_650_100_000;
  const sessionBase = {
    sessionId: session.id,
    workspaceId: session.workspaceId,
    emittedAt,
  };
  const controlSummary: SessionSummary = {
    ...summary,
    id: "control-session-1",
    workspaceId: undefined,
    workspaceName: undefined,
    name: "Oppi Control",
    control: {
      domain: "schedules",
      intent: "create",
      targetName: "Nightly review",
    },
  };

  return {
    app_events_connected: {
      type: "app_events_connected",
      serverTime: emittedAt,
      snapshotRequired: true,
    },
    session_created: { type: "session_created", ...sessionBase, summary },
    session_imported: { type: "session_imported", ...sessionBase, summary },
    session_discovered: { type: "session_discovered", ...sessionBase, summary },
    session_summary: { type: "session_summary", ...sessionBase, summary },
    session_summary_control: {
      type: "session_summary",
      sessionId: controlSummary.id,
      emittedAt,
      summary: controlSummary,
    },
    session_deleted: { type: "session_deleted", ...sessionBase },
    session_ended: { type: "session_ended", ...sessionBase, reason: "completed" },
    stop_requested: { type: "stop_requested", ...sessionBase, source: "user" },
    stop_confirmed: { type: "stop_confirmed", ...sessionBase, source: "server" },
    stop_failed: {
      type: "stop_failed",
      ...sessionBase,
      source: "runtime",
      reason: "timeout",
    },
    session_error: {
      type: "session_error",
      ...sessionBase,
      message: "Model API rate limit exceeded",
      code: "rate_limit",
      fatal: false,
    },
    extension_ui_request: {
      type: "extension_ui_request",
      ...sessionBase,
      id: "ui-1",
      method: "ask",
      title: "Approve change",
      message: "Proceed?",
      questions: [
        {
          id: "q1",
          question: "Proceed?",
          options: [{ value: "yes", label: "Yes" }],
        },
      ],
      allowCustom: false,
      timeout: 30_000,
      timeoutAt: emittedAt + 30_000,
    },
    extension_ui_settled: { type: "extension_ui_settled", ...sessionBase, id: "ui-1" },
    extension_ui_notification: {
      type: "extension_ui_notification",
      ...sessionBase,
      method: "setStatus",
      statusKey: "build",
      statusText: "Build passed",
      notifyType: "info",
      message: "Build completed",
    },
    workspace_git_changed: {
      type: "workspace_git_changed",
      workspaceId: "ws-1",
      sessionId: session.id,
      emittedAt,
      reason: "mutation_tool",
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

  it("generates separate canonical app-event snapshots", () => {
    if (!existsSync(PROTOCOL_DIR)) {
      mkdirSync(PROTOCOL_DIR, { recursive: true });
    }

    const messages = canonicalAppEventMessages();
    const snapshot = {
      _meta: {
        description:
          "Canonical AppEventMessage JSON — generated by server/tests/app-event-stream.test.ts",
        generated: "static",
        messageCount: Object.keys(messages).length,
      },
      messages,
    };

    writeFileSync(APP_EVENT_SNAPSHOTS_FILE, JSON.stringify(snapshot, null, 2) + "\n");

    const parsed = JSON.parse(readFileSync(APP_EVENT_SNAPSHOTS_FILE, "utf8")) as {
      messages: Record<string, AppEventMessage>;
    };
    expect(Object.keys(parsed.messages).sort()).toEqual(Object.keys(messages).sort());
    for (const message of Object.values(parsed.messages)) {
      expect(isAppEventAllowedType(message.type), message.type).toBe(true);
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
