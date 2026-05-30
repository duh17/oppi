import { EventEmitter } from "node:events";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";
import { WebSocket } from "ws";

import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import type { Storage } from "../src/storage.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

class FakeBridgeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];
  closeCode?: number;
  closeReason?: string;

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(code?: number, reason?: string): void {
    this.readyState = WebSocket.CLOSED;
    this.closeCode = code;
    this.closeReason = reason;
  }

  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
}

function makeRuntime(
  options: {
    hostMount?: string;
    dataDir?: string;
    isManagedSessionActive?: (sessionId: string) => boolean;
  } = {},
) {
  const workspace: Workspace = {
    id: "w1",
    name: "Workspace",
    skills: [],
    allowedPaths: [],
    allowedExecutables: [],
    hostMount: options.hostMount ?? "/tmp/oppi-mirror-test",
  };
  const sessions = new Map<string, Session>();
  let nextId = 1;

  const storage = {
    getWorkspace: (id: string) => (id === workspace.id ? workspace : null),
    listWorkspaces: () => [workspace],
    listSessions: () => Array.from(sessions.values()),
    getSession: (id: string) => sessions.get(id) ?? null,
    createSession: (name?: string, model?: string) => {
      const now = Date.now();
      const session: Session = {
        id: `sess-${nextId++}`,
        workspaceId: workspace.id,
        workspaceName: workspace.name,
        name,
        model,
        status: "ready",
        createdAt: now,
        lastActivity: now,
        messageCount: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
      };
      sessions.set(session.id, session);
      return session;
    },
    saveSession: (session: Session) => {
      sessions.set(session.id, session);
    },
    getConfig: () => ({ dataDir: options.dataDir ?? "/tmp/oppi-mirror-test-config" }),
    getDataDir: () => options.dataDir ?? "/tmp/oppi-mirror-test-config",
  } as unknown as Storage;

  return {
    runtime: new PiTuiMirrorRuntime(storage, {
      isManagedSessionActive: options.isManagedSessionActive,
    }),
    sessions,
  };
}

function connectBridge(
  runtime: PiTuiMirrorRuntime,
  options: {
    cwd?: string;
    workspaceId?: string | null;
    sessionFile?: string;
    sessionName?: string;
  } = {},
): {
  ws: FakeBridgeWebSocket;
  sessionId: string;
} {
  const ws = new FakeBridgeWebSocket();
  runtime.handleBridgeWebSocket(ws as unknown as WebSocket);
  ws.receive({
    type: "hello",
    protocolVersion: 1,
    bridgeId: "bridge-1",
    ...(options.workspaceId === null ? {} : { workspaceId: options.workspaceId ?? "w1" }),
    cwd: options.cwd ?? "/tmp/oppi-mirror-test",
    state: {
      piSessionId: "pi-1",
      sessionFile: options.sessionFile ?? "/tmp/oppi-mirror-test/session.jsonl",
      sessionName: options.sessionName,
    },
  });
  const ack = ws.sent.find((message) => message.type === "hello_ack");
  expect(ack).toBeTruthy();
  return { ws, sessionId: String(ack?.sessionId) };
}

function latestCommand(ws: FakeBridgeWebSocket): Record<string, unknown> {
  const command = ws.sent.findLast((message) => message.type === "command");
  expect(command).toBeTruthy();
  return command!;
}

async function waitForLatestCommand(ws: FakeBridgeWebSocket): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const command = ws.sent.findLast((message) => message.type === "command");
    if (command) return command;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return latestCommand(ws);
}

describe("PiTuiMirrorRuntime queue bridge", () => {
  it("matches home-relative workspace mounts against terminal cwd", () => {
    const cwd = `${homedir()}/workspace/oppi/server`;
    const { runtime } = makeRuntime({ hostMount: "~/workspace/oppi" });

    const { sessionId } = connectBridge(runtime, {
      cwd,
      workspaceId: null,
      sessionFile: `${cwd}/session.jsonl`,
    });

    expect(runtime.getActiveSession(sessionId)?.workspaceId).toBe("w1");
  });

  it("rejects workspaceId bridge hellos when cwd is outside the workspace mount", () => {
    const { runtime } = makeRuntime({ hostMount: "/tmp/oppi-mirror-test" });
    const ws = new FakeBridgeWebSocket();
    runtime.handleBridgeWebSocket(ws as unknown as WebSocket);

    ws.receive({
      type: "hello",
      protocolVersion: 1,
      bridgeId: "bridge-1",
      workspaceId: "w1",
      cwd: "/tmp/not-in-a-workspace",
      state: { piSessionId: "pi-1" },
    });

    expect(ws.sent.at(-1)).toMatchObject({
      type: "error",
      error: expect.stringContaining("Terminal cwd is outside Oppi workspace hostMount"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ws.closeCode).toBe(1008);
  });

  it("closes the bridge when hello registration fails", () => {
    const { runtime } = makeRuntime({ hostMount: "/tmp/oppi-mirror-test" });
    const ws = new FakeBridgeWebSocket();
    runtime.handleBridgeWebSocket(ws as unknown as WebSocket);

    ws.receive({
      type: "hello",
      protocolVersion: 1,
      bridgeId: "bridge-1",
      cwd: "/tmp/not-in-a-workspace",
      state: { piSessionId: "pi-1" },
    });

    expect(ws.sent.at(-1)).toMatchObject({
      type: "error",
      error: expect.stringContaining("No Oppi workspace hostMount contains terminal cwd"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ws.closeCode).toBe(1008);
  });

  it("reports managed-runtime ownership conflicts as structured retryable bridge errors", () => {
    const { runtime, sessions } = makeRuntime({
      hostMount: "/tmp/oppi-mirror-test",
      isManagedSessionActive: (sessionId) => sessionId === "managed-1",
    });
    sessions.set("managed-1", {
      id: "managed-1",
      workspaceId: "w1",
      workspaceName: "Workspace",
      status: "busy",
      createdAt: 1,
      lastActivity: 1,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      piSessionId: "pi-1",
      piSessionFile: "/tmp/oppi-mirror-test/session.jsonl",
    });
    const ws = new FakeBridgeWebSocket();
    runtime.handleBridgeWebSocket(ws as unknown as WebSocket);

    ws.receive({
      type: "hello",
      protocolVersion: 1,
      bridgeId: "bridge-1",
      workspaceId: "w1",
      cwd: "/tmp/oppi-mirror-test",
      state: {
        piSessionId: "pi-1",
        sessionFile: "/tmp/oppi-mirror-test/session.jsonl",
      },
    });
    ws.receive({ type: "heartbeat", state: { piSessionId: "pi-1" } });

    expect(ws.sent).toHaveLength(1);
    expect(ws.sent[0]).toMatchObject({
      type: "error",
      code: "managed_runtime_active",
      sessionId: "managed-1",
      retryAfterMs: 10_000,
      error: expect.stringContaining("already owned by the managed Oppi runtime"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ws.closeCode).toBe(1008);
  });

  it("marks the iOS mirror session stopped when the terminal session shuts down", () => {
    const { runtime, sessions } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const session = sessions.get(sessionId);
    if (!session) throw new Error("expected mirrored session");
    session.status = "busy";
    session.currentTurnStartedAt = Date.now();

    ws.receive({
      type: "goodbye",
      reason: "session_shutdown",
      state: { isIdle: true },
    });

    const stopped = sessions.get(sessionId);
    expect(stopped?.status).toBe("stopped");
    expect(stopped?.currentTurnStartedAt).toBeUndefined();
    expect(stopped?.mirror?.status).toBe("disconnected");
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ws.closeCode).toBe(1000);
  });

  it("backfills the first user message from the terminal session file", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-title-"));
    const sessionFile = join(root, "session.jsonl");
    await writeFile(
      sessionFile,
      `${JSON.stringify({
        type: "message",
        message: { role: "user", content: "review mirror mode titles" },
      })}\n`,
    );
    const { runtime } = makeRuntime({ hostMount: root });

    const { sessionId } = connectBridge(runtime, {
      cwd: root,
      sessionFile,
      sessionName: "Session LyOQX5NA",
    });

    const session = runtime.getActiveSession(sessionId);
    expect(session?.name).toBeUndefined();
    expect(session?.firstMessage).toBe("review mirror mode titles");
  });

  it("captures terminal-origin user messages as the first message", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    ws.receive({
      type: "event",
      event: {
        type: "message_end",
        message: { role: "user", content: "terminal asks from the TUI" },
      },
    });

    const session = runtime.getActiveSession(sessionId);
    expect(session?.firstMessage).toBe("terminal asks from the TUI");
    expect(session?.messageCount).toBe(1);
  });

  it("broadcasts terminal-origin user message_end events to live subscribers", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "event",
      event: {
        type: "message_end",
        message: { role: "user", content: "typed directly in the TUI" },
      },
    });

    expect(received).toContainEqual(
      expect.objectContaining({
        type: "message_end",
        role: "user",
        content: "typed directly in the TUI",
      }),
    );
  });

  it("broadcasts terminal-origin assistant message_end events to finalize thinking blocks", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "event",
      event: {
        type: "message_end",
        message: {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "plan before tool" },
            { type: "text", text: "done" },
          ],
        },
      },
    });

    expect(received).toContainEqual(
      expect.objectContaining({
        type: "message_end",
        role: "assistant",
        content: "done",
      }),
    );
  });

  it("broadcasts terminal-origin compaction events", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "event",
      event: { type: "compaction_start", reason: "threshold" },
    });
    ws.receive({
      type: "event",
      event: {
        type: "compaction_end",
        reason: "threshold",
        result: { summary: "Summarized context", tokensBefore: 180000 },
        aborted: false,
        willRetry: false,
      },
    });

    expect(received).toContainEqual(
      expect.objectContaining({ type: "compaction_start", reason: "threshold" }),
    );
    expect(received).toContainEqual(
      expect.objectContaining({
        type: "compaction_end",
        aborted: false,
        willRetry: false,
        summary: "Summarized context",
        tokensBefore: 180000,
      }),
    );
    expect(runtime.getActiveSession(sessionId)?.changeStats?.compactionCount).toBe(1);
  });

  it("hydrates get_queue from the terminal bridge", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    const queuePromise = runtime.getMessageQueue(sessionId);
    const command = latestCommand(ws);
    expect(command.command).toMatchObject({ type: "get_queue" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: {
        queue: {
          version: 4,
          steering: [{ id: "s1", message: "steer", createdAt: 1 }],
          followUp: [{ id: "f1", message: "follow", createdAt: 2 }],
        },
      },
    });

    await expect(queuePromise).resolves.toEqual({
      version: 4,
      steering: [{ id: "s1", message: "steer", createdAt: 1 }],
      followUp: [{ id: "f1", message: "follow", createdAt: 2 }],
    });
  });

  it("rejects get_queue bridge failures instead of returning stale cached queue", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    ws.receive({
      type: "queue_state",
      queue: {
        version: 9,
        steering: [{ id: "stale", message: "stale steer", createdAt: 1 }],
        followUp: [],
      },
    });

    const queuePromise = runtime.getMessageQueue(sessionId);
    const command = latestCommand(ws);
    expect(command.command).toMatchObject({ type: "get_queue" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: false,
      error: "bridge queue unavailable",
    });

    await expect(queuePromise).rejects.toThrow("bridge queue unavailable");
  });

  it("rejects malformed get_queue command results", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    const queuePromise = runtime.getMessageQueue(sessionId);
    const command = latestCommand(ws);

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { queue: { version: 1, steering: "bad", followUp: [] } },
    });

    await expect(queuePromise).rejects.toThrow("Terminal mirror did not return queue state");
  });

  it("forwards set_queue and broadcasts the returned queue state", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    const setPromise = runtime.setMessageQueue(sessionId, {
      baseVersion: 0,
      steering: [{ id: "s1", message: "edited steer" }],
      followUp: [],
    });
    const command = latestCommand(ws);
    expect(command.command).toMatchObject({
      type: "set_queue",
      baseVersion: 0,
      steering: [{ id: "s1", message: "edited steer" }],
      followUp: [],
    });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: {
        queue: {
          version: 1,
          steering: [{ id: "s1", message: "edited steer", createdAt: 10 }],
          followUp: [],
        },
      },
    });

    await expect(setPromise).resolves.toMatchObject({ version: 1 });
    expect(received).toContainEqual({
      type: "queue_state",
      queue: {
        version: 1,
        steering: [{ id: "s1", message: "edited steer", createdAt: 10 }],
        followUp: [],
      },
    });
  });

  it("routes /reload prompts to the terminal reload command without starting a turn", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    const reloadPromise = runtime.sendPrompt(sessionId, "/reload", {
      clientTurnId: "turn-reload",
      requestId: "req-reload",
      timestamp: Date.now(),
    });
    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "reload" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { reloading: true },
    });

    await expect(reloadPromise).resolves.toBeUndefined();
    expect(received.some((message) => message.type === "turn_ack")).toBe(false);
  });

  it("waits for the terminal user event before recording a mirrored prompt", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    const promptPromise = runtime.sendPrompt(sessionId, "hello from phone", {
      clientTurnId: "turn-phone",
      requestId: "req-phone",
      timestamp: Date.now(),
    });
    const command = await waitForLatestCommand(ws);
    expect(command.command).toEqual({
      type: "prompt",
      message: "hello from phone",
      requestId: "req-phone",
      clientTurnId: "turn-phone",
    });
    expect(runtime.getActiveSession(sessionId)?.messageCount).toBe(0);

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { queue: { version: 0, steering: [], followUp: [] } },
    });
    await expect(promptPromise).resolves.toBeUndefined();
    expect(runtime.getActiveSession(sessionId)?.messageCount).toBe(0);

    ws.receive({
      type: "event",
      event: {
        type: "message_end",
        message: { role: "user", content: "hello from phone" },
      },
    });
    expect(runtime.getActiveSession(sessionId)?.messageCount).toBe(1);
    expect(runtime.getActiveSession(sessionId)?.lastMessage).toBe("hello from phone");
  });

  it("preserves returned queue state after remote abort", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "queue_state",
      queue: {
        version: 7,
        steering: [{ id: "s1", message: "do not lose this steer", createdAt: 1 }],
        followUp: [{ id: "f1", message: "do not lose this follow-up", createdAt: 2 }],
      },
    });

    const abortPromise = runtime.sendAbort(sessionId);
    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "abort" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: {
        aborted: true,
        queue: {
          version: 8,
          steering: [{ id: "s1", message: "do not lose this steer", createdAt: 1 }],
          followUp: [{ id: "f1", message: "do not lose this follow-up", createdAt: 2 }],
        },
      },
    });

    await expect(abortPromise).resolves.toBeUndefined();
    expect(received).toContainEqual({
      type: "queue_state",
      queue: {
        version: 8,
        steering: [{ id: "s1", message: "do not lose this steer", createdAt: 1 }],
        followUp: [{ id: "f1", message: "do not lose this follow-up", createdAt: 2 }],
      },
    });
  });

  it("applies forwarded metadata command results and broadcasts canonical command_result", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    const commandPromise = runtime.forwardClientCommand(
      sessionId,
      { type: "set_session_name", name: "Requested Name" },
      "req-name",
    );
    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "set_session_name", name: "Requested Name" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { name: "Terminal Name" },
    });

    await expect(commandPromise).resolves.toBeUndefined();
    expect(runtime.getActiveSession(sessionId)?.name).toBe("Terminal Name");
    expect(received).toContainEqual({
      type: "command_result",
      command: "set_session_name",
      requestId: "req-name",
      success: true,
      data: { name: "Terminal Name" },
    });
    expect(received).toContainEqual(
      expect.objectContaining({
        type: "state",
        session: expect.objectContaining({ name: "Terminal Name" }),
      }),
    );
  });

  it("forwards supported terminal-control commands through the bridge", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    const commandPromise = runtime.forwardClientCommand(
      sessionId,
      { type: "set_auto_retry", enabled: false },
      "req-retry-mode",
    );
    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "set_auto_retry", enabled: false });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { enabled: false },
    });

    await expect(commandPromise).resolves.toBeUndefined();
    expect(received).toContainEqual({
      type: "command_result",
      command: "set_auto_retry",
      requestId: "req-retry-mode",
      success: true,
      data: { enabled: false },
    });
  });

  it("reports unsupported mirror commands through the runtime command_result contract", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    await expect(
      runtime.forwardClientCommand(sessionId, { type: "fork", entryId: "entry-1" }, "req-fork"),
    ).resolves.toBeUndefined();

    expect(ws.sent.filter((message) => message.type === "command")).toHaveLength(0);
    expect(received).toContainEqual({
      type: "command_result",
      command: "fork",
      requestId: "req-fork",
      success: false,
      error:
        "terminal mirror runtime does not support command: fork (session-file replacement is terminal-owned; fork from the terminal)",
    });
  });

  it("removes a queued message when the terminal starts that user message", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "queue_state",
      queue: {
        version: 2,
        steering: [{ id: "s1", message: "please steer", createdAt: 1 }],
        followUp: [],
      },
    });
    ws.receive({
      type: "event",
      event: {
        type: "message_start",
        message: { role: "user", content: "please steer" },
      },
    });

    expect(received).toContainEqual({
      type: "queue_item_started",
      kind: "steer",
      item: { id: "s1", message: "please steer", createdAt: 1 },
      queueVersion: 3,
    });
    expect(received).toContainEqual({
      type: "queue_state",
      queue: { version: 3, steering: [], followUp: [] },
    });
  });

  it("materializes workspace attachments before forwarding a prompt", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-attachments-"));
    await writeFile(join(root, "note.txt"), "hello from attachment");
    const { runtime } = makeRuntime({ hostMount: root });
    const { ws, sessionId } = connectBridge(runtime, {
      cwd: root,
      sessionFile: join(root, "session.jsonl"),
    });

    const promptPromise = runtime.sendPrompt(sessionId, "read this", {
      attachments: [
        {
          type: "attachment",
          id: "att-1",
          source: "workspace",
          name: "note.txt",
          mimeType: "text/plain",
          sizeBytes: 21,
          workspacePath: "note.txt",
        },
      ],
      clientTurnId: "turn-attachment",
      requestId: "req-attachment",
      timestamp: Date.now(),
    });

    const command = await waitForLatestCommand(ws);
    const forwarded = command.command as Record<string, unknown>;
    expect(forwarded).toEqual({
      type: "prompt",
      message: `read this\n\nAttached files:\n- note.txt: .pi/attachments/${sessionId}/turn-attachment/note.txt`,
      requestId: "req-attachment",
      clientTurnId: "turn-attachment",
    });
    await expect(
      readFile(join(root, ".pi", "attachments", sessionId, "turn-attachment", "note.txt"), "utf8"),
    ).resolves.toBe("hello from attachment");

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { queue: { version: 0, steering: [], followUp: [] } },
    });
    await expect(promptPromise).resolves.toBeUndefined();
  });

  it("materializes legacy voice audio details from mirrored tool events", async () => {
    const dataDir = await mkdtemp(join(tmpdir(), "oppi-mirror-audio-"));
    const { runtime } = makeRuntime({ dataDir });
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "event",
      event: {
        type: "tool_execution_end",
        toolCallId: "voice-tool-1",
        toolName: "voice_speak",
        result: {
          content: [{ type: "text", text: "Phone playback should work." }],
          details: {
            serverUrl: "http://127.0.0.1:7937",
            message: "Phone playback should work.",
            audio: {
              kind: "audio",
              mimeType: "audio/wav",
              base64: Buffer.from("RIFFtest-audio").toString("base64"),
              fileName: "reply.wav",
            },
          },
        },
        isError: false,
      },
    });

    const toolEnd = received.find((message) => message.type === "tool_end") as Extract<
      ServerMessage,
      { type: "tool_end" }
    >;
    expect(toolEnd?.details).toMatchObject({
      kind: "audio_presentation",
      text: "Phone playback should work.",
      message: "Phone playback should work.",
      audio: {
        kind: "audio",
        mimeType: "audio/wav",
        id: expect.stringContaining("att_voice-tool-1_"),
        storageKey: expect.stringContaining(`${sessionId}/`),
      },
    });
    expect(
      (toolEnd.details as { audio?: { base64?: string; path?: string } }).audio?.base64,
    ).toBeUndefined();
    expect(
      (toolEnd.details as { audio?: { base64?: string; path?: string } }).audio?.path,
    ).toBeUndefined();
  });

  it("forwards materialized image attachments with streaming input", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-image-"));
    const imageBytes = Buffer.from("fake image bytes");
    await writeFile(join(root, "shot.png"), imageBytes);
    const { runtime } = makeRuntime({ hostMount: root });
    const { ws, sessionId } = connectBridge(runtime, {
      cwd: root,
      sessionFile: join(root, "session.jsonl"),
    });
    const session = runtime.getActiveSession(sessionId);
    if (!session) throw new Error("expected active mirror session");
    session.status = "busy";

    const steerPromise = runtime.sendSteer(sessionId, "look at this", {
      attachments: [
        {
          type: "attachment",
          id: "att-image",
          source: "workspace",
          name: "shot.png",
          mimeType: "image/png",
          sizeBytes: imageBytes.length,
          workspacePath: "shot.png",
        },
      ],
      clientTurnId: "turn-image",
      requestId: "req-image",
    });

    const command = await waitForLatestCommand(ws);
    expect(command.command).toEqual({
      type: "steer",
      message: `look at this\n\nAttached files:\n- shot.png: .pi/attachments/${sessionId}/turn-image/shot.png`,
      requestId: "req-image",
      clientTurnId: "turn-image",
      images: [{ type: "image", data: imageBytes.toString("base64"), mimeType: "image/png" }],
    });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { queue: { version: 0, steering: [], followUp: [] } },
    });
    await expect(steerPromise).resolves.toBeUndefined();
  });
});
