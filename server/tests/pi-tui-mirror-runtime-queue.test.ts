import { EventEmitter } from "node:events";

import { describe, expect, it } from "vitest";
import { WebSocket } from "ws";

import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import type { Storage } from "../src/storage.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

class FakeBridgeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(): void {
    this.readyState = WebSocket.CLOSED;
  }

  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
}

function makeRuntime() {
  const workspace: Workspace = {
    id: "w1",
    name: "Workspace",
    skills: [],
    allowedPaths: [],
    allowedExecutables: [],
    hostMount: "/tmp/oppi-mirror-test",
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
  } as unknown as Storage;

  return { runtime: new PiTuiMirrorRuntime(storage), sessions };
}

function connectBridge(runtime: PiTuiMirrorRuntime): {
  ws: FakeBridgeWebSocket;
  sessionId: string;
} {
  const ws = new FakeBridgeWebSocket();
  runtime.handleBridgeWebSocket(ws as unknown as WebSocket);
  ws.receive({
    type: "hello",
    protocolVersion: 1,
    bridgeId: "bridge-1",
    workspaceId: "w1",
    cwd: "/tmp/oppi-mirror-test",
    state: { piSessionId: "pi-1", sessionFile: "/tmp/oppi-mirror-test/session.jsonl" },
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

describe("PiTuiMirrorRuntime queue bridge", () => {
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
});
