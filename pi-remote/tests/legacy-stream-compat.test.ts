import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";
import { Server } from "../src/server.js";
import type { ClientMessage, ServerMessage, Session, User } from "../src/types.js";

function makeSession(id: string, userId = "u1"): Session {
  const now = Date.now();
  return {
    id,
    userId,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    runtime: "host",
  };
}

function makeUser(): User {
  return {
    id: "u1",
    name: "Chen",
    token: "tok",
    createdAt: Date.now(),
  };
}

class FakeWebSocket {
  readyState = WebSocket.OPEN;
  bufferedAmount = 0;
  sent: ServerMessage[] = [];

  private handlers: {
    message: Array<(data: Buffer) => void>;
    close: Array<(code: number, reason: Buffer) => void>;
    error: Array<(err: Error) => void>;
  } = {
    message: [],
    close: [],
    error: [],
  };

  on(event: "message" | "close" | "error", handler: (...args: unknown[]) => void): void {
    if (event === "message") {
      this.handlers.message.push(handler as (data: Buffer) => void);
      return;
    }
    if (event === "close") {
      this.handlers.close.push(handler as (code: number, reason: Buffer) => void);
      return;
    }
    this.handlers.error.push(handler as (err: Error) => void);
  }

  send(data: string, _opts?: { compress?: boolean }): void {
    this.sent.push(JSON.parse(data) as ServerMessage);
  }

  emitMessage(msg: unknown): void {
    const data = Buffer.from(JSON.stringify(msg));
    for (const handler of this.handlers.message) {
      handler(data);
    }
  }
}

async function flushQueue(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("single-session websocket stream behavior", () => {
  it("keeps single-session prompt flow unchanged", async () => {
    const user = makeUser();
    const session = makeSession("s1", user.id);
    const ws = new FakeWebSocket();

    const server = Object.create(Server.prototype) as Server & {
      userConnections: Map<string, Set<WebSocket>>;
    };

    const handleClientMessage = vi.fn(
      async (
        _user: User,
        _session: Session,
        _msg: ClientMessage,
        send: (msg: ServerMessage) => void,
      ) => {
        send({ type: "agent_start" });
      },
    );

    server.userConnections = new Map();

    (server as unknown as {
      ensureSessionContextWindow: (session: Session) => Session;
      resolveWorkspaceForSession: (userId: string, session: Session) => undefined;
      handleClientMessage: typeof handleClientMessage;
      sessions: {
        getCurrentSeq: (userId: string, sessionId: string) => number;
        startSession: (
          userId: string,
          sessionId: string,
          userName?: string,
          workspace?: unknown,
        ) => Promise<Session>;
        subscribe: (
          userId: string,
          sessionId: string,
          callback: (msg: ServerMessage) => void,
        ) => () => void;
      };
      gate: {
        getPendingForUser: (userId: string) => unknown[];
      };
    }).ensureSessionContextWindow = (value: Session) => value;

    (server as unknown as {
      resolveWorkspaceForSession: (userId: string, session: Session) => undefined;
    }).resolveWorkspaceForSession = () => undefined;

    (server as unknown as { handleClientMessage: typeof handleClientMessage }).handleClientMessage =
      handleClientMessage;

    (server as unknown as {
      sessions: {
        getCurrentSeq: (userId: string, sessionId: string) => number;
        startSession: (
          userId: string,
          sessionId: string,
          userName?: string,
          workspace?: unknown,
        ) => Promise<Session>;
        subscribe: (
          userId: string,
          sessionId: string,
          callback: (msg: ServerMessage) => void,
        ) => () => void;
      };
    }).sessions = {
      getCurrentSeq: vi.fn(() => 0),
      startSession: vi.fn(async () => session),
      subscribe: vi.fn(() => () => {}),
    };

    (server as unknown as {
      gate: {
        getPendingForUser: (userId: string) => unknown[];
      };
    }).gate = {
      getPendingForUser: vi.fn(() => []),
    };

    await (server as unknown as {
      handleWebSocket: (ws: WebSocket, user: User, session: Session) => Promise<void>;
    }).handleWebSocket(ws as unknown as WebSocket, user, session);

    const base = ws.sent.length;
    ws.emitMessage({ type: "prompt", message: "hello legacy" });
    await flushQueue();

    expect(handleClientMessage).toHaveBeenCalledTimes(1);

    const forwarded = handleClientMessage.mock.calls[0][2] as ClientMessage;
    expect(forwarded.type).toBe("prompt");
    if (forwarded.type === "prompt") {
      expect((forwarded as { sessionId?: string }).sessionId).toBeUndefined();
    }

    expect(ws.sent.slice(base)).toContainEqual({ type: "agent_start" });
  });
});
