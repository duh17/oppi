import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, join } from "node:path";

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
  private sendWaiters: Array<() => void> = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
    const waiters = this.sendWaiters.splice(0);
    for (const resolve of waiters) resolve();
  }

  waitForSend(timeoutMs = 1_000): Promise<void> {
    return new Promise((resolve, reject) => {
      const resolveAndCleanup = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        const index = this.sendWaiters.indexOf(resolveAndCleanup);
        if (index >= 0) this.sendWaiters.splice(index, 1);
        reject(new Error("Timed out waiting for bridge WebSocket send"));
      }, timeoutMs);
      this.sendWaiters.push(resolveAndCleanup);
    });
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
    includeDefaultWorkspace?: boolean;
    isOppiSessionActive?: (sessionId: string) => boolean;
    stopOppiSession?: (sessionId: string) => Promise<void>;
  } = {},
) {
  const defaultWorkspace: Workspace = {
    id: "w1",
    name: "Workspace",
    hostMount: options.hostMount ?? "/tmp/oppi-mirror-test",
  };
  const workspaces = new Map<string, Workspace>();
  if (options.includeDefaultWorkspace !== false) {
    workspaces.set(defaultWorkspace.id, defaultWorkspace);
  }
  const sessions = new Map<string, Session>();
  let nextId = 1;
  let nextWorkspaceId = 2;

  const storage = {
    getWorkspace: (id: string) => workspaces.get(id) ?? null,
    listWorkspaces: () => Array.from(workspaces.values()),
    createWorkspace: (req: {
      name: string;
      description?: string;
      icon?: string;
      skills: string[];
      systemPrompt?: string;
      systemPromptMode?: "append";
      hostMount?: string;
      defaultModel?: string;
      tools?: string[];
      extensions?: string[];
      gitStatusEnabled?: boolean;
      runtime?: "host" | "sandbox";
    }) => {
      const now = Date.now();
      const workspace: Workspace = {
        id: `w${nextWorkspaceId++}`,
        name: req.name,
        description: req.description,
        icon: req.icon,
        skills: req.skills,
        systemPrompt: req.systemPrompt,
        systemPromptMode: req.systemPromptMode ?? "append",
        hostMount: req.hostMount,
        defaultModel: req.defaultModel,
        tools: req.tools,
        extensions: req.extensions,
        gitStatusEnabled: req.gitStatusEnabled,
        runtime: req.runtime,
        createdAt: now,
        updatedAt: now,
      };
      workspaces.set(workspace.id, workspace);
      return workspace;
    },
    listSessions: () => Array.from(sessions.values()),
    getSession: (id: string) => sessions.get(id) ?? null,
    createSession: (name?: string, model?: string) => {
      const now = Date.now();
      const session: Session = {
        id: `sess-${nextId++}`,
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
      isOppiSessionActive: options.isOppiSessionActive,
      stopOppiSession: options.stopOppiSession,
    }),
    sessions,
    workspaces,
  };
}

function connectBridge(
  runtime: PiTuiMirrorRuntime,
  options: {
    bridgeId?: string;
    cwd?: string;
    workspaceId?: string | null;
    createWorkspace?: boolean;
    takeoverConfirmationSessionId?: string;
    piSessionId?: string;
    sessionFile?: string | null;
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
    bridgeId: options.bridgeId ?? "bridge-1",
    ...(options.workspaceId === null ? {} : { workspaceId: options.workspaceId ?? "w1" }),
    ...(options.createWorkspace ? { createWorkspace: true } : {}),
    ...(options.takeoverConfirmationSessionId
      ? { takeoverConfirmation: { sessionId: options.takeoverConfirmationSessionId } }
      : {}),
    cwd: options.cwd ?? "/tmp/oppi-mirror-test",
    state: {
      piSessionId: options.piSessionId ?? "pi-1",
      ...(options.sessionFile === null
        ? {}
        : { sessionFile: options.sessionFile ?? "/tmp/oppi-mirror-test/session.jsonl" }),
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
    await ws.waitForSend();
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

  it("reports a missing workspace with the suggested git-root workspace", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-missing-workspace-"));
    const cwd = join(root, "packages", "app");
    await mkdir(cwd, { recursive: true });
    await writeFile(join(root, ".git"), "gitdir: .git-test\n");
    const { runtime, workspaces } = makeRuntime({ includeDefaultWorkspace: false });
    const ws = new FakeBridgeWebSocket();
    runtime.handleBridgeWebSocket(ws as unknown as WebSocket);

    ws.receive({
      type: "hello",
      protocolVersion: 1,
      bridgeId: "bridge-1",
      cwd,
      state: { piSessionId: "pi-1", sessionFile: join(cwd, "session.jsonl") },
    });

    expect(ws.sent.at(-1)).toMatchObject({
      type: "error",
      code: "workspace_missing",
      cwd,
      suggestedHostMount: root,
      suggestedName: basename(root),
      error: expect.stringContaining("No Oppi workspace hostMount contains terminal cwd"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(workspaces.size).toBe(0);
  });

  it("creates a mirror workspace when the terminal requests creation", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-create-workspace-"));
    const { runtime, workspaces } = makeRuntime({ includeDefaultWorkspace: false });

    const { sessionId } = connectBridge(runtime, {
      cwd: root,
      workspaceId: null,
      createWorkspace: true,
      sessionFile: join(root, "session.jsonl"),
    });

    const created = Array.from(workspaces.values())[0];
    expect(created).toMatchObject({
      name: basename(root),
      description: "Created from an interactive Pi terminal session.",
      hostMount: root,
      gitStatusEnabled: true,
      runtime: "host",
    });
    expect(runtime.getActiveSession(sessionId)?.workspaceId).toBe(created?.id);
    expect(runtime.getActiveSession(sessionId)?.workspaceName).toBe(created?.name);
  });

  it("uses the nearest git root for requested mirror workspaces", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-git-workspace-"));
    const cwd = join(root, "packages", "app");
    await mkdir(cwd, { recursive: true });
    await writeFile(join(root, ".git"), "gitdir: .git-test\n");
    const { runtime, workspaces } = makeRuntime({ includeDefaultWorkspace: false });

    const { sessionId } = connectBridge(runtime, {
      cwd,
      workspaceId: null,
      createWorkspace: true,
      sessionFile: join(cwd, "session.jsonl"),
    });

    const created = Array.from(workspaces.values())[0];
    expect(created?.hostMount).toBe(root);
    expect(created?.name).toBe(basename(root));
    expect(runtime.getActiveSession(sessionId)?.workspaceId).toBe(created?.id);
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

  it("closes the bridge when hello registration fails", async () => {
    const { runtime } = makeRuntime({ hostMount: "/tmp/oppi-mirror-test" });
    const ws = new FakeBridgeWebSocket();
    const missingCwd = await mkdtemp(join(tmpdir(), "oppi-mirror-missing-cwd-"));
    await rm(missingCwd, { recursive: true, force: true });
    runtime.handleBridgeWebSocket(ws as unknown as WebSocket);

    ws.receive({
      type: "hello",
      protocolVersion: 1,
      bridgeId: "bridge-1",
      cwd: missingCwd,
      state: { piSessionId: "pi-1" },
    });

    expect(ws.sent.at(-1)).toMatchObject({
      type: "error",
      error: expect.stringContaining("Terminal cwd is not an existing directory"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ws.closeCode).toBe(1008);
  });

  it("does not register no-trace Pi Agent task records as openable mirror sessions", () => {
    const { runtime, sessions, workspaces } = makeRuntime({ includeDefaultWorkspace: false });
    const ws = new FakeBridgeWebSocket();
    runtime.handleBridgeWebSocket(ws as unknown as WebSocket);

    ws.receive({
      type: "hello",
      protocolVersion: 1,
      bridgeId: "bridge-task",
      cwd: "/tmp/oppi-mirror-test",
      state: {
        piSessionId: "pi-task",
        sessionName: "general-purpose#738f21e6",
      },
    });

    expect(ws.sent.at(-1)).toMatchObject({
      type: "error",
      code: "pi_tui_task_record_not_openable",
      sessionName: "general-purpose#738f21e6",
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(sessions.size).toBe(0);
    expect(workspaces.size).toBe(0);
  });

  it("requires terminal confirmation before taking over a stopped Oppi session", () => {
    const { runtime, sessions } = makeRuntime({ hostMount: "/tmp/oppi-mirror-test" });
    sessions.set("oppi-1", {
      id: "oppi-1",
      workspaceId: "w1",
      workspaceName: "Workspace",
      name: "Research WWDC Announcements",
      runtime: "oppi",
      status: "ready",
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

    expect(ws.sent).toHaveLength(1);
    expect(ws.sent[0]).toMatchObject({
      type: "error",
      code: "oppi_takeover_confirmation_required",
      sessionId: "oppi-1",
      sessionName: "Research WWDC Announcements",
      sessionStatus: "ready",
      error: expect.stringContaining("Confirm taking over Oppi session oppi-1"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(sessions.get("oppi-1")?.runtime).toBe("oppi");
  });

  it("promotes a stopped Oppi session after terminal confirmation", () => {
    const { runtime, sessions } = makeRuntime({ hostMount: "/tmp/oppi-mirror-test" });
    sessions.set("oppi-1", {
      id: "oppi-1",
      workspaceId: "w1",
      workspaceName: "Workspace",
      runtime: "oppi",
      status: "ready",
      createdAt: 1,
      lastActivity: 1,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      piSessionId: "pi-1",
      piSessionFile: "/tmp/oppi-mirror-test/session.jsonl",
    });

    const { sessionId } = connectBridge(runtime, {
      takeoverConfirmationSessionId: "oppi-1",
      piSessionId: "pi-1",
      sessionFile: "/tmp/oppi-mirror-test/session.jsonl",
    });

    expect(sessionId).toBe("oppi-1");
    expect(sessions.get("oppi-1")?.runtime).toBe("pi-tui");
    expect(sessions.get("oppi-1")?.mirror?.status).toBe("connected");
  });

  it("does not treat heartbeat-only mirror state as session activity", () => {
    const { runtime, sessions } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const session = runtime.getActiveSession(sessionId);
    expect(session).toBeTruthy();
    session!.lastActivity = 1;
    session!.mirror = {
      ...(session!.mirror ?? { status: "connected" }),
      status: "connected",
      terminal: {
        ...(session!.mirror?.terminal ?? {}),
        lastSeenAt: 1,
      },
    };
    sessions.set(sessionId, session!);

    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "heartbeat",
      state: {
        piSessionId: "pi-1",
        sessionFile: "/tmp/oppi-mirror-test/session.jsonl",
      },
    });

    const updated = runtime.getActiveSession(sessionId);
    expect(updated?.lastActivity).toBe(1);
    expect(updated?.mirror?.terminal?.lastSeenAt).toBe(1);
    expect(received.some((message) => message.type === "state")).toBe(false);
  });

  it("requires terminal confirmation before taking over an active Oppi session", () => {
    const { runtime, sessions } = makeRuntime({
      hostMount: "/tmp/oppi-mirror-test",
      isOppiSessionActive: (sessionId) => sessionId === "oppi-1",
    });
    sessions.set("oppi-1", {
      id: "oppi-1",
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
      code: "oppi_takeover_confirmation_required",
      sessionId: "oppi-1",
      sessionStatus: "busy",
      requiresStop: true,
      error: expect.stringContaining("Confirm taking over Oppi session oppi-1"),
    });
    expect(ws.readyState).toBe(WebSocket.CLOSED);
    expect(ws.closeCode).toBe(1008);
  });

  it("stops an active Oppi SDK session after terminal takeover confirmation", async () => {
    let oppiActive = true;
    const stoppedSessions: string[] = [];
    const { runtime, sessions } = makeRuntime({
      hostMount: "/tmp/oppi-mirror-test",
      isOppiSessionActive: (sessionId) => oppiActive && sessionId === "oppi-1",
      stopOppiSession: async (sessionId) => {
        stoppedSessions.push(sessionId);
        oppiActive = false;
      },
    });
    sessions.set("oppi-1", {
      id: "oppi-1",
      workspaceId: "w1",
      workspaceName: "Workspace",
      runtime: "oppi",
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
      takeoverConfirmation: { sessionId: "oppi-1" },
      cwd: "/tmp/oppi-mirror-test",
      state: {
        piSessionId: "pi-1",
        sessionFile: "/tmp/oppi-mirror-test/session.jsonl",
      },
    });
    await ws.waitForSend();

    const ack = ws.sent.find((message) => message.type === "hello_ack");
    expect(ack).toMatchObject({ sessionId: "oppi-1" });
    expect(stoppedSessions).toEqual(["oppi-1"]);
    expect(sessions.get("oppi-1")?.runtime).toBe("pi-tui");
    expect(sessions.get("oppi-1")?.status).toBe("ready");
    expect(sessions.get("oppi-1")?.mirror?.status).toBe("connected");
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

  it("sends stop to pi-tui and waits for the terminal to shut down", async () => {
    const { runtime, sessions } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const session = sessions.get(sessionId);
    if (!session) throw new Error("expected mirrored session");
    session.status = "busy";

    const stopPromise = runtime.stopSession(sessionId);
    const command = await waitForLatestCommand(ws);
    expect(command.command).toEqual({ type: "stop" });

    ws.receive({
      type: "goodbye",
      reason: "stopped",
      state: { isIdle: true },
    });

    await expect(stopPromise).resolves.toBeUndefined();
    expect(runtime.getActiveSession(sessionId)?.status).toBe("stopped");
    expect(ws.readyState).toBe(WebSocket.CLOSED);
  });

  it("rejects stop promptly when pi-tui reports a stop command failure", async () => {
    const { runtime, sessions } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const session = sessions.get(sessionId);
    if (!session) throw new Error("expected mirrored session");
    session.status = "busy";

    const stopPromise = runtime.stopSession(sessionId);
    const command = await waitForLatestCommand(ws);
    expect(command.command).toEqual({ type: "stop" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: false,
      error: "emptyQueue is not defined",
    });

    await expect(stopPromise).rejects.toThrow("emptyQueue is not defined");
    expect(ws.readyState).toBe(WebSocket.OPEN);
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
    const catchUp = runtime.getCatchUp(sessionId, 0);
    expect(catchUp?.currentSeq).toBe(2);
    expect(catchUp?.events.map((event) => event.type)).toEqual([
      "compaction_start",
      "compaction_end",
    ]);
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

    await expect(queuePromise).rejects.toThrow("pi-tui did not return queue state");
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

  it("does not route stale session commands after a bridge id is reused", async () => {
    const { runtime } = makeRuntime();
    const first = connectBridge(runtime, {
      bridgeId: "bridge-reused",
      piSessionId: "pi-first",
      sessionFile: "/tmp/oppi-mirror-test/first.jsonl",
      sessionName: "First terminal session",
    });
    const second = connectBridge(runtime, {
      bridgeId: "bridge-reused",
      piSessionId: "pi-second",
      sessionFile: "/tmp/oppi-mirror-test/second.jsonl",
      sessionName: "Second terminal session",
    });

    expect(second.sessionId).not.toBe(first.sessionId);
    expect(runtime.isSessionConnected(first.sessionId)).toBe(false);
    expect(runtime.isSessionConnected(second.sessionId)).toBe(true);

    await expect(
      runtime.sendPrompt(first.sessionId, "must not reach second terminal", {
        clientTurnId: "turn-stale",
        requestId: "req-stale",
        timestamp: Date.now(),
      }),
    ).rejects.toThrow("pi-tui is not connected");
    expect(
      second.ws.sent.some(
        (message) =>
          message.type === "command" &&
          (message.command as { message?: string } | undefined)?.message ===
            "must not reach second terminal",
      ),
    ).toBe(false);

    const promptPromise = runtime.sendPrompt(second.sessionId, "reach second terminal", {
      clientTurnId: "turn-second",
      requestId: "req-second",
      timestamp: Date.now(),
    });
    const command = await waitForLatestCommand(second.ws);
    expect(command.command).toMatchObject({
      type: "prompt",
      message: "reach second terminal",
      requestId: "req-second",
      clientTurnId: "turn-second",
    });

    second.ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { queue: { version: 0, steering: [], followUp: [] } },
    });
    await expect(promptPromise).resolves.toBeUndefined();
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

  it("forwards session tree reads through the bridge", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    const commandPromise = runtime.forwardClientCommand(
      sessionId,
      { type: "get_session_tree", filterMode: "no-tools" },
      "req-tree",
    );
    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "get_session_tree", filterMode: "no-tools" });

    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: {
        leafId: "user-1",
        tree: [
          {
            entry: {
              id: "user-1",
              parentId: null,
              type: "message",
              timestamp: "2026-01-01T00:00:00.000Z",
              message: { role: "user", content: "Start here" },
            },
            children: [],
          },
        ],
      },
    });

    await expect(commandPromise).resolves.toBeUndefined();
    expect(received).toContainEqual({
      type: "command_result",
      command: "get_session_tree",
      requestId: "req-tree",
      success: true,
      data: {
        leafId: "user-1",
        nodes: [
          expect.objectContaining({
            id: "user-1",
            parentId: null,
            type: "message",
            depth: 0,
            isLeafPath: true,
            role: "user",
            textPreview: "Start here",
          }),
        ],
      },
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
        "pi-tui runtime does not support command: fork (session-file replacement is terminal-owned; fork from the terminal)",
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

describe("PiTuiMirrorRuntime extension UI bridge", () => {
  it("forwards mirrored callback widgets as extension UI notifications", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-1",
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: ["Goal tick 0"],
      widgetPlacement: "belowEditor",
    });

    expect(received.at(-1)).toEqual({
      type: "extension_ui_notification",
      method: "setWidget",
      message: undefined,
      notifyType: undefined,
      statusKey: undefined,
      statusText: undefined,
      title: undefined,
      text: undefined,
      widgetKey: "goal",
      widgetLines: ["Goal tick 0"],
      widgetPlacement: "belowEditor",
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "goal",
        widgetLines: ["Goal tick 0"],
      }),
    ]);
  });

  it("forwards native surfaces from mirrored callback widgets", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-native-1",
      method: "setWidget",
      widgetKey: "subagents",
      widgetLines: ["● Agents", "  Running Review"],
      widgetPlacement: "aboveEditor",
      nativeSurface: {
        version: 1,
        id: "extension-chosen-id",
        source: "widget",
        presentation: { style: "surfacePanel", title: "Agents" },
        blocks: [
          {
            type: "activityList",
            id: "agents",
            rows: [{ id: "child-1", title: "Review", state: "running" }],
          },
        ],
      },
    });

    expect(received.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setWidget",
      widgetKey: "subagents",
      widgetLines: ["● Agents", "  Running Review"],
      widgetPlacement: "aboveEditor",
      nativeSurface: {
        id: "widget:subagents",
        source: "widget",
      },
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "subagents",
        nativeSurface: expect.objectContaining({ id: "widget:subagents", source: "widget" }),
      }),
    ]);
  });

  it("drops invalid mirrored widget native surfaces while preserving line fallback", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-invalid-native",
      method: "setWidget",
      widgetKey: "subagents",
      widgetLines: ["● Agents", "  Running Review"],
      nativeSurface: {
        version: 1,
        id: "extension-chosen-id",
        source: "widget",
        presentation: { style: "inlineCard", title: "Agents" },
        blocks: [],
      },
    });

    expect(received.at(-1)).toEqual({
      type: "extension_ui_notification",
      method: "setWidget",
      message: undefined,
      notifyType: undefined,
      statusKey: undefined,
      statusText: undefined,
      title: undefined,
      text: undefined,
      widgetKey: "subagents",
      widgetLines: ["● Agents", "  Running Review"],
      widgetPlacement: undefined,
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "subagents",
        widgetLines: ["● Agents", "  Running Review"],
      }),
    ]);
    expect(runtime.getPendingUIRequestMessages(sessionId)[0]).not.toHaveProperty("nativeSurface");
  });

  it("promotes mirrored OSC-8 widget fallback links into native terminal surfaces", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-osc8-link",
      method: "setWidget",
      widgetKey: "links",
      widgetLines: ["Open \x1b]8;;oppi://session/child-1\x07child\x1b]8;;\x07 now"],
    });

    expect(received.at(-1)).toMatchObject({
      type: "extension_ui_notification",
      method: "setWidget",
      widgetKey: "links",
      widgetLines: ["Open child now"],
      nativeSurface: {
        id: "widget:links",
        source: "widget",
        blocks: [
          {
            type: "terminal",
            lines: [
              [
                { text: "Open " },
                { text: "child", link: "oppi://session/child-1" },
                { text: " now" },
              ],
            ],
          },
        ],
      },
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)[0]).toMatchObject({
      widgetLines: ["Open child now"],
      nativeSurface: expect.objectContaining({ id: "widget:links" }),
    });
  });

  it("forwards mirrored working-state requests as timeline notifications", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-working-message-1",
      method: "setWorkingMessage",
      message: "\u001b]0;title\u0007Tracing the logic · thinking\u001b[2K",
    });
    ws.receive({
      type: "extension_ui_request",
      id: "ui-working-indicator-1",
      method: "setWorkingIndicator",
      workingIndicator: { frames: ["\u001b[32m●\u001b[0m"], intervalMs: 120 },
    });

    expect(received).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWorkingMessage",
        message: "Tracing the logic · thinking",
      }),
    );
    expect(received).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWorkingIndicator",
        workingIndicator: { frames: ["●"], intervalMs: 120 },
      }),
    );
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWorkingMessage",
        message: "Tracing the logic · thinking",
      }),
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWorkingIndicator",
        workingIndicator: { frames: ["●"], intervalMs: 120 },
      }),
    ]);
  });

  it("replays mirrored clear notifications after explicit clears", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-1",
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: ["Goal active"],
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toHaveLength(1);

    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-clear",
      method: "setWidget",
      widgetKey: "goal",
    });

    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "goal",
        widgetLines: undefined,
      }),
    ]);
  });

  it("clears persistent mirrored surfaces when the bridge disconnects", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-status-1",
      method: "setStatus",
      statusKey: "review",
      statusText: "running",
    });
    ws.receive({
      type: "extension_ui_request",
      id: "ui-widget-1",
      method: "setWidget",
      widgetKey: "goal",
      widgetLines: ["Goal active"],
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toHaveLength(2);

    ws.readyState = WebSocket.CLOSED;
    ws.emit("close");

    expect(received).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "review",
        statusText: undefined,
      }),
    );
    expect(received).toContainEqual(
      expect.objectContaining({
        type: "extension_ui_notification",
        method: "setWidget",
        widgetKey: "goal",
        widgetLines: undefined,
      }),
    );
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([]);
  });

  it("ingests bridge UI requests and replays pending dialogs", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-1",
      method: "select",
      title: "Choose",
      options: ["A", "B"],
      timeout: 5_000,
      timeoutAt: 123_000,
    });

    expect(received.at(-1)).toEqual({
      type: "extension_ui_request",
      id: "ui-1",
      sessionId,
      method: "select",
      title: "Choose",
      options: ["A", "B"],
      message: undefined,
      placeholder: undefined,
      prefill: undefined,
      timeout: 5_000,
      timeoutAt: 123_000,
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([received.at(-1)]);
  });

  it("routes phone UI responses back to the bridge with first-wins settlement", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-1",
      method: "input",
      title: "Name",
    });

    const handled = runtime.respondToUIRequest(sessionId, {
      type: "extension_ui_response",
      id: "ui-1",
      value: "Ada",
    });

    expect(handled).toBe(true);
    expect(ws.sent.at(-1)).toEqual({
      type: "extension_ui_response",
      id: "ui-1",
      value: "Ada",
      confirmed: undefined,
      cancelled: undefined,
    });
    expect(received.at(-1)).toEqual({
      type: "extension_ui_settled",
      id: "ui-1",
      sessionId,
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([]);
    expect(
      runtime.respondToUIRequest(sessionId, {
        type: "extension_ui_response",
        id: "ui-1",
        value: "Grace",
      }),
    ).toBe(false);
  });

  it("settles terminal-won bridge UI requests idempotently", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-1",
      method: "confirm",
      title: "Proceed?",
      message: "Terminal will answer this.",
    });
    ws.receive({ type: "extension_ui_request_settled", id: "ui-1" });
    ws.receive({ type: "extension_ui_request_settled", id: "ui-1" });

    expect(received.filter((message) => message.type === "extension_ui_settled")).toEqual([
      { type: "extension_ui_settled", id: "ui-1", sessionId },
    ]);
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([]);
    expect(
      runtime.respondToUIRequest(sessionId, {
        type: "extension_ui_response",
        id: "ui-1",
        confirmed: true,
      }),
    ).toBe(false);
  });

  it("settles pending bridge UI requests when the bridge disconnects", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ui-disconnect",
      method: "input",
      title: "Name",
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toHaveLength(1);

    ws.readyState = WebSocket.CLOSED;
    ws.emit("close");

    expect(received.filter((message) => message.type === "extension_ui_settled")).toEqual([
      { type: "extension_ui_settled", id: "ui-disconnect", sessionId },
    ]);
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([]);
    expect(
      runtime.respondToUIRequest(sessionId, {
        type: "extension_ui_response",
        id: "ui-disconnect",
        value: "Ada",
      }),
    ).toBe(false);
  });

  it("keeps ask replay separate from generic extension dialogs", () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);

    ws.receive({
      type: "extension_ui_request",
      id: "ask-1",
      method: "ask",
      allowCustom: false,
      questions: [
        {
          id: "q1",
          question: "Pick one",
          options: [{ value: "a", label: "A" }],
        },
      ],
    });

    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([
      expect.objectContaining({
        type: "extension_ui_request",
        id: "ask-1",
        sessionId,
        method: "ask",
        allowCustom: false,
        questions: [expect.objectContaining({ id: "q1", question: "Pick one" })],
      }),
    ]);
  });

  it("cancels pending ask UI before mirrored abort", async () => {
    const { runtime } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ask-abort",
      method: "ask",
      questions: [
        {
          id: "q1",
          question: "Pick one",
          options: [{ value: "a", label: "A" }],
        },
      ],
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toHaveLength(1);

    const abortPromise = runtime.sendAbort(sessionId);

    expect(ws.sent).toContainEqual({
      type: "extension_ui_response",
      id: "ask-abort",
      cancelled: true,
    });
    expect(received).toContainEqual({
      type: "extension_ui_settled",
      id: "ask-abort",
      sessionId,
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([]);

    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "abort" });
    ws.receive({
      type: "command_result",
      id: command.id,
      success: true,
      data: { queue: { version: 0, steering: [], followUp: [] } },
    });

    await expect(abortPromise).resolves.toBeUndefined();
  });

  it("cancels pending ask UI before mirrored stop", async () => {
    const { runtime, sessions } = makeRuntime();
    const { ws, sessionId } = connectBridge(runtime);
    const session = sessions.get(sessionId);
    if (!session) throw new Error("expected mirrored session");
    session.status = "busy";
    const received: ServerMessage[] = [];
    runtime.subscribe(sessionId, (message) => received.push(message));

    ws.receive({
      type: "extension_ui_request",
      id: "ask-stop",
      method: "ask",
      questions: [
        {
          id: "q1",
          question: "Pick one",
          options: [{ value: "a", label: "A" }],
        },
      ],
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toHaveLength(1);

    const stopPromise = runtime.stopSession(sessionId);

    expect(ws.sent).toContainEqual({
      type: "extension_ui_response",
      id: "ask-stop",
      cancelled: true,
    });
    expect(received).toContainEqual({
      type: "extension_ui_settled",
      id: "ask-stop",
      sessionId,
    });
    expect(runtime.getPendingUIRequestMessages(sessionId)).toEqual([]);

    const command = latestCommand(ws);
    expect(command.command).toEqual({ type: "stop" });
    ws.receive({
      type: "goodbye",
      reason: "stopped",
      state: { isIdle: true },
    });

    await expect(stopPromise).resolves.toBeUndefined();
  });
});
