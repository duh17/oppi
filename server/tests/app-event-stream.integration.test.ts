import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WebSocket, type RawData } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { buildSessionSummary } from "../src/session-summary.js";
import type { SessionBroadcastEvent } from "../src/session-broadcast.js";
import type { ServerMessage, Session, SessionSummary, Workspace } from "../src/types.js";

type AppEventFrame = Record<string, unknown>;
type FramePredicate = (frame: AppEventFrame) => boolean;

interface SessionEventSource {
  emit(eventName: "session_event", payload: SessionBroadcastEvent): boolean;
}

interface PendingWaiter {
  predicate: FramePredicate;
  resolve: (frame: AppEventFrame) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

class AppStreamClient {
  readonly frames: AppEventFrame[] = [];
  readonly opened: Promise<void>;
  private waiters: PendingWaiter[] = [];

  constructor(readonly ws: WebSocket) {
    this.opened = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        ws.terminate();
        reject(new Error("Timed out waiting for app event stream to open after 30000ms"));
      }, 30_000);
      ws.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      ws.once("unexpected-response", (_req, res) => {
        clearTimeout(timer);
        reject(new Error(`WS upgrade failed with HTTP ${res.statusCode ?? "unknown"}`));
      });
      ws.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });

    ws.on("message", (data) => {
      const frame = JSON.parse(rawDataToString(data)) as AppEventFrame;
      this.frames.push(frame);
      const waiterIndex = this.waiters.findIndex((waiter) => waiter.predicate(frame));
      if (waiterIndex === -1) return;
      const [waiter] = this.waiters.splice(waiterIndex, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(frame);
    });

    ws.on("close", () => {
      const waiters = this.waiters.splice(0);
      for (const waiter of waiters) {
        clearTimeout(waiter.timer);
        waiter.reject(new Error("app event stream closed before expected frame arrived"));
      }
    });
  }

  waitFor(predicate: FramePredicate, timeoutMs = 15_000, fromNow = false): Promise<AppEventFrame> {
    const startIndex = fromNow ? this.frames.length : 0;
    const existing = this.frames.slice(startIndex).find(predicate);
    if (existing) return Promise.resolve(existing);

    return new Promise<AppEventFrame>((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.findIndex((candidate) => candidate.timer === timer);
        if (index !== -1) this.waiters.splice(index, 1);
        reject(new Error(`Timed out waiting for app event frame after ${timeoutMs}ms`));
      }, timeoutMs);
      this.waiters.push({ predicate, resolve, reject, timer });
    });
  }

  async close(): Promise<void> {
    if (this.ws.readyState === WebSocket.CLOSED) {
      return;
    }
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.ws.terminate();
        resolve();
      }, 30_000);
      this.ws.once("close", () => {
        clearTimeout(timer);
        resolve();
      });
      if (this.ws.readyState !== WebSocket.CLOSING) {
        this.ws.close();
      }
    });
  }
}

let dataDir: string;
let storage: Storage;
let server: Server;
let token: string;
let baseUrl: string;
let clients: AppStreamClient[] = [];

beforeEach(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-app-event-stream-"));
  storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "disabled" },
  });
  token = storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `http://127.0.0.1:${server.port}`;
});

afterEach(async () => {
  await Promise.all(clients.map((client) => client.close().catch(() => {})));
  clients = [];
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
});

describe("WS /app/events/stream", { timeout: 30_000 }, () => {
  it("delivers low-frequency row events for a non-focused session without opening its focused stream", async () => {
    const client = await connectAppStream();
    const connected = await waitForConnected(client);
    expect(connected["snapshotRequired"]).toBe(true);

    const { session } = createStoredSession({ status: "busy", lastMessage: "Working elsewhere" });
    const summary = summaryFor(session, { pendingAskCount: 0 });

    emitSessionEvent(session.id, { type: "session_summary", summary } as ServerMessage);

    const frame = await client.waitFor(
      (candidate) =>
        candidate["type"] === "session_summary" && candidate["sessionId"] === session.id,
    );
    expectSessionScopedAppFrame(frame, "session_summary", session);
    expect(frame["summary"]).toMatchObject({
      id: session.id,
      workspaceId: session.workspaceId,
      lastMessage: "Working elsewhere",
      pendingAskCount: 0,
    });
    expectAppFrameHasNoFocusedReplayFields(frame);
  });

  it("drops focused-stream, queue, dictation, raw git status, and raw error frames", async () => {
    const client = await connectAppStream();
    await waitForConnected(client);
    const { workspace, session } = createStoredSession({ status: "busy" });

    for (const message of forbiddenFocusedMessages(workspace, session)) {
      emitSessionEvent(session.id, message);
    }

    const sentinelActivity = Date.now() + 10_000;
    const sentinel = summaryFor(session, {
      lastActivity: sentinelActivity,
      lastMessage: "allowlist sentinel",
      pendingAskCount: 0,
    });
    emitSessionEvent(session.id, { type: "session_summary", summary: sentinel } as ServerMessage);

    const sentinelFrame = await client.waitFor(
      (candidate) =>
        candidate["type"] === "session_summary" &&
        summaryLastActivity(candidate) === sentinelActivity,
    );
    expectSessionScopedAppFrame(sentinelFrame, "session_summary", session);

    const forbiddenTypes = new Set(
      forbiddenFocusedMessages(workspace, session).map((message) => message.type),
    );
    const leaked = client.frames.filter((frame) => forbiddenTypes.has(String(frame["type"])));
    expect(leaked).toEqual([]);
    for (const frame of client.frames) {
      expectAppFrameHasNoFocusedReplayFields(frame);
    }
  });

  it("delivers extension UI request and settled frames, then accepts summary zero as the badge authority", async () => {
    const client = await connectAppStream();
    await waitForConnected(client);
    const { session } = createStoredSession({ status: "busy" });

    emitSessionEvent(session.id, {
      type: "extension_ui_request",
      id: "ask-1",
      sessionId: session.id,
      method: "ask",
      questions: [
        {
          id: "q1",
          question: "Approve?",
          options: [{ value: "yes", label: "Yes" }],
          multiSelect: false,
        },
      ],
      allowCustom: false,
    } as ServerMessage);

    const requestFrame = await client.waitFor(
      (candidate) => candidate["type"] === "extension_ui_request" && candidate["id"] === "ask-1",
    );
    expectSessionScopedAppFrame(requestFrame, "extension_ui_request", session);
    expect(requestFrame).toMatchObject({ id: "ask-1", method: "ask", allowCustom: false });

    emitSessionEvent(session.id, {
      type: "extension_ui_settled",
      id: "ask-1",
      sessionId: session.id,
    } as ServerMessage);

    const settledFrame = await client.waitFor(
      (candidate) => candidate["type"] === "extension_ui_settled" && candidate["id"] === "ask-1",
    );
    expectSessionScopedAppFrame(settledFrame, "extension_ui_settled", session);

    const summary = summaryFor(session, { pendingAskCount: 0, lastActivity: Date.now() + 20_000 });
    emitSessionEvent(session.id, { type: "session_summary", summary } as ServerMessage);

    const summaryFrame = await client.waitFor(
      (candidate) =>
        candidate["type"] === "session_summary" &&
        summaryLastActivity(candidate) === summary.lastActivity,
    );
    expect(summaryFrame["summary"]).toMatchObject({ id: session.id, pendingAskCount: 0 });
  });

  it("reconnects with snapshotRequired and does not replay missed frames or expose currentSeq", async () => {
    const firstClient = await connectAppStream();
    await waitForConnected(firstClient);
    const { session } = createStoredSession({ status: "busy" });

    const liveSummary = summaryFor(session, {
      lastActivity: Date.now() + 30_000,
      lastMessage: "live",
    });
    emitSessionEvent(session.id, {
      type: "session_summary",
      summary: liveSummary,
    } as ServerMessage);
    await firstClient.waitFor(
      (candidate) =>
        candidate["type"] === "session_summary" &&
        summaryLastActivity(candidate) === liveSummary.lastActivity,
    );

    await firstClient.close();

    const missedActivity = Date.now() + 40_000;
    const missedSession: Session = {
      ...session,
      lastActivity: missedActivity,
      lastMessage: "missed while disconnected",
    };
    storage.saveSession(missedSession);
    const missedSummary = summaryFor(missedSession);
    emitSessionEvent(session.id, {
      type: "session_summary",
      summary: missedSummary,
    } as ServerMessage);

    const secondClient = await connectAppStream();
    const reconnectFrame = await waitForConnected(secondClient);
    expect(reconnectFrame).toMatchObject({ type: "app_events_connected", snapshotRequired: true });
    expectAppFrameHasNoFocusedReplayFields(reconnectFrame);

    const snapshotSummary = await getWorkspaceSessionSummary(
      missedSession.workspaceId!,
      missedSession.id,
      missedActivity,
    );
    expect(snapshotSummary).toMatchObject({
      id: missedSession.id,
      workspaceId: missedSession.workspaceId,
      lastActivity: missedActivity,
      lastMessage: "missed while disconnected",
    });

    const afterReconnectSummary = summaryFor(missedSession, {
      lastActivity: Date.now() + 50_000,
      lastMessage: "after reconnect",
    });
    emitSessionEvent(session.id, {
      type: "session_summary",
      summary: afterReconnectSummary,
    } as ServerMessage);

    await secondClient.waitFor(
      (candidate) =>
        candidate["type"] === "session_summary" &&
        summaryLastActivity(candidate) === afterReconnectSummary.lastActivity,
    );

    const replayedMissedFrames = secondClient.frames.filter(
      (frame) =>
        frame["type"] === "session_summary" &&
        summaryLastActivity(frame) === missedSummary.lastActivity,
    );
    expect(replayedMissedFrames).toEqual([]);
  });
});

async function connectAppStream(): Promise<AppStreamClient> {
  const wsUrl = `${baseUrl.replace(/^http:/, "ws:")}/app/events/stream`;
  const client = new AppStreamClient(
    new WebSocket(wsUrl, {
      headers: { Authorization: `Bearer ${token}` },
    }),
  );
  clients.push(client);
  await client.opened;
  return client;
}

async function waitForConnected(client: AppStreamClient): Promise<AppEventFrame> {
  const frame = await client.waitFor((candidate) => candidate["type"] === "app_events_connected");
  expect(frame["serverTime"]).toBeTypeOf("number");
  expect(frame["snapshotRequired"]).toBe(true);
  expectAppFrameHasNoFocusedReplayFields(frame);
  return frame;
}

async function getWorkspaceSessionSummary(
  workspaceId: string,
  sessionId: string,
  untilMs: number,
): Promise<Record<string, unknown>> {
  const response = await fetch(
    `${baseUrl}/workspaces/${workspaceId}/sessions?status=active,stopped&sinceMs=0&untilMs=${untilMs + 1}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  expect(response.status).toBe(200);
  const body = (await response.json()) as Record<string, unknown>;
  const summaries = [body["active"], body["stopped"]].filter(Array.isArray).flat() as Array<
    Record<string, unknown>
  >;
  const summary = summaries.find((candidate) => candidate["id"] === sessionId);
  expect(summary).toBeTruthy();
  return summary!;
}

function createStoredSession(overrides: Partial<Session> = {}): {
  workspace: Workspace;
  session: Session;
} {
  const workspace = storage.createWorkspace({
    name: `app-stream-${Date.now()}`,
    hostMount: dataDir,
  });
  const created = storage.createSession(
    overrides.name ?? "Non-focused app stream test",
    overrides.model,
  );
  const session: Session = {
    ...created,
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    status: "ready",
    ...overrides,
  };
  storage.saveSession(session);
  return { workspace, session };
}

function summaryFor(session: Session, overrides: Partial<SessionSummary> = {}): SessionSummary {
  return { ...buildSessionSummary(session), ...overrides };
}

function emitSessionEvent(sessionId: string, event: ServerMessage, durable = false): void {
  const eventSource = (server as unknown as { sessions: SessionEventSource }).sessions;
  eventSource.emit("session_event", { sessionId, event, durable });
}

function expectSessionScopedAppFrame(frame: AppEventFrame, type: string, session: Session): void {
  expect(frame["type"]).toBe(type);
  expect(frame["sessionId"]).toBe(session.id);
  expect(frame["workspaceId"]).toBe(session.workspaceId);
  expect(frame["emittedAt"]).toBeTypeOf("number");
  expectAppFrameHasNoFocusedReplayFields(frame);
}

function expectAppFrameHasNoFocusedReplayFields(frame: AppEventFrame): void {
  expect(frame["seq"]).toBeUndefined();
  expect(frame["currentSeq"]).toBeUndefined();
  expect(frame["catchUpComplete"]).toBeUndefined();
  expect(frame["events"]).toBeUndefined();

  const summary = recordValue(frame["summary"]);
  if (summary) {
    expect(summary["piSessionFile"]).toBeUndefined();
    expect(summary["piSessionFiles"]).toBeUndefined();
  }
}

function summaryLastActivity(frame: AppEventFrame): number | undefined {
  const summary = recordValue(frame["summary"]);
  return typeof summary?.["lastActivity"] === "number" ? summary["lastActivity"] : undefined;
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}

function rawDataToString(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}

function forbiddenFocusedMessages(workspace: Workspace, session: Session): ServerMessage[] {
  return [
    { type: "connected", session, currentSeq: 9 } as ServerMessage,
    {
      type: "stream_connected",
      userName: "owner",
      serverDictationAvailable: true,
    } as ServerMessage,
    { type: "state", session } as ServerMessage,
    { type: "agent_start" } as ServerMessage,
    { type: "agent_end" } as ServerMessage,
    { type: "message_end", role: "assistant", content: "done" } as ServerMessage,
    { type: "text_delta", delta: "nope" } as ServerMessage,
    { type: "thinking_delta", delta: "private" } as ServerMessage,
    { type: "tool_start", tool: "bash", args: { command: "echo nope" } } as ServerMessage,
    { type: "tool_update", tool: "bash", args: { command: "echo nope" } } as ServerMessage,
    { type: "tool_output", output: "secret output" } as ServerMessage,
    { type: "tool_end", tool: "bash" } as ServerMessage,
    {
      type: "command_result",
      command: "get_state",
      requestId: "cmd-1",
      success: true,
      data: { state: "raw" },
    } as ServerMessage,
    {
      type: "turn_ack",
      command: "prompt",
      clientTurnId: "turn-1",
      stage: "accepted",
    } as ServerMessage,
    { type: "queue_state", queue: { version: 1, steering: [], followUp: [] } } as ServerMessage,
    {
      type: "queue_item_started",
      kind: "follow_up",
      item: { id: "q1", message: "queued", createdAt: 1 },
      queueVersion: 2,
    } as ServerMessage,
    {
      type: "audio_stream",
      kind: "audio-stream",
      id: "audio-1",
      event: "chunk",
      mimeType: "audio/wav",
      audioBase64: "AAAA",
    } as ServerMessage,
    { type: "dictation_ready", sttProvider: "test", sttModel: "mock" } as ServerMessage,
    { type: "dictation_result", text: "partial" } as ServerMessage,
    { type: "dictation_final", text: "final" } as ServerMessage,
    { type: "dictation_error", error: "dictation failed", fatal: false } as ServerMessage,
    { type: "error", error: "raw focused error", fatal: false } as ServerMessage,
    {
      type: "git_status",
      workspaceId: workspace.id,
      status: {
        isGitRepo: true,
        branch: "main",
        headSha: "abc1234",
        ahead: 0,
        behind: 0,
        dirtyCount: 1,
        untrackedCount: 0,
        stagedCount: 0,
        files: [{ status: " M", path: "secret.txt", addedLines: 1, removedLines: 0 }],
        totalFiles: 1,
        addedLines: 1,
        removedLines: 0,
        stashCount: 0,
        lastCommitMessage: "test",
        lastCommitDate: "2026-06-11T00:00:00.000Z",
        recentCommits: [],
      },
    } as ServerMessage,
  ];
}
