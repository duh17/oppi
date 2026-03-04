import { WebSocket } from "ws";
import type { ClientMessage, ServerMessage, Session } from "../../src/types.js";

export class FakeWebSocket {
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

  ping(): void {
    // no-op for tests
  }

  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }

  emitMessage(msg: unknown): void {
    const data = Buffer.from(JSON.stringify(msg));
    for (const handler of this.handlers.message) {
      handler(data);
    }
  }

  emitClientMessage(msg: ClientMessage): void {
    this.emitMessage(msg);
  }

  emitClose(code = 1000, reason = ""): void {
    this.readyState = WebSocket.CLOSED;
    const reasonBuffer = Buffer.from(reason);
    for (const handler of this.handlers.close) {
      handler(code, reasonBuffer);
    }
  }
}

export function makeSession(id: string, overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    ...overrides,
  };
}
