import { vi } from "vitest";

import { UserStreamMux, type StreamContext } from "../../src/stream.js";
import type { ClientMessage, ServerMessage, Session } from "../../src/types.js";
import { flushMicrotasks } from "./async.js";
import { makeSession } from "./stream-test-primitives.js";
export { FakeWebSocket, makeSession } from "./stream-test-primitives.js";

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
