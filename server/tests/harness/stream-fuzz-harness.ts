import { vi } from "vitest";
import { WebSocket } from "ws";

import { UserStreamMux, type StreamContext } from "../../src/stream.js";
import type { ClientMessage, ServerMessage, Session } from "../../src/types.js";
import { flushMicrotasks } from "./async.js";

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

  emitClientMessage(msg: ClientMessage): void {
    const data = Buffer.from(JSON.stringify(msg));
    for (const handler of this.handlers.message) {
      handler(data);
    }
  }

  emitClose(code = 1000, reason = ""): void {
    this.readyState = WebSocket.CLOSED;
    const reasonBuffer = Buffer.from(reason);
    for (const handler of this.handlers.close) {
      handler(code, reasonBuffer);
    }
  }
}

export function makeSession(id: string): Session {
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
  };
}

export interface StreamFuzzHarness {
  mux: UserStreamMux;
  sessionsById: Map<string, Session>;
  sessionCallbacks: Map<string, (msg: ServerMessage) => void>;
}

export function makeStreamFuzzHarness(): StreamFuzzHarness {
  const sessionsById = new Map<string, Session>([["s1", makeSession("s1")]]);
  const sessionCallbacks = new Map<string, (msg: ServerMessage) => void>();

  const handleClientMessage = vi.fn(
    async (_session: Session, msg: ClientMessage, send: (msg: ServerMessage) => void) => {
      if (msg.type === "prompt" || msg.type === "steer" || msg.type === "follow_up") {
        const turnLabel = msg.clientTurnId ?? msg.requestId ?? "unknown-turn";
        send({ type: "agent_start" });
        send({ type: "message_end", role: "assistant", content: `assistant-final:${turnLabel}` });
        send({ type: "agent_end" });
      }

      if ("requestId" in msg) {
        send({
          type: "command_result",
          command: msg.type,
          requestId: msg.requestId,
          success: true,
        });
      }
    },
  );

  const ctx: StreamContext = {
    sessions: {
      startSession: vi.fn(async (sessionId: string) => {
        const session = sessionsById.get(sessionId);
        if (!session) {
          throw new Error(`Session not found: ${sessionId}`);
        }
        return session;
      }),
      subscribe: vi.fn((sessionId: string, cb: (msg: ServerMessage) => void) => {
        sessionCallbacks.set(sessionId, cb);
        return () => {
          if (sessionCallbacks.get(sessionId) === cb) {
            sessionCallbacks.delete(sessionId);
          }
        };
      }),
      getActiveSession: vi.fn((sessionId: string) => sessionsById.get(sessionId)),
      getCurrentSeq: vi.fn(() => 0),
      getCatchUp: vi.fn((_sessionId: string, _sinceSeq: number) => ({
        events: [],
        currentSeq: 0,
        catchUpComplete: true,
      })),
    } as unknown as StreamContext["sessions"],
    storage: {
      getSession: vi.fn((sessionId: string) => sessionsById.get(sessionId)),
      getOwnerName: vi.fn(() => "fuzz-host"),
    } as unknown as StreamContext["storage"],
    gate: {
      getPendingForUser: vi.fn(() => []),
      resolveDecision: vi.fn(() => true),
    } as unknown as StreamContext["gate"],
    ensureSessionContextWindow: (session: Session) => session,
    resolveWorkspaceForSession: () => undefined,
    handleClientMessage,
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  };

  return {
    mux: new UserStreamMux(ctx),
    sessionsById,
    sessionCallbacks,
  };
}

export async function flushStreamQueue(): Promise<void> {
  await flushMicrotasks(4);
}
