import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import { SessionTurnCoordinator } from "../src/session-turns.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import { UserStreamMux, type StreamContext } from "../src/stream.js";
import type { ClientMessage, ServerMessage, Session, TurnAckStage, TurnCommand } from "../src/types.js";
import { flushMicrotasks } from "./harness/async.js";
import { messagesOfType } from "./harness/ws-harness.js";

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let t = Math.imul(state ^ (state >>> 15), state | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeSession(id: string): Session {
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

async function flushQueue(): Promise<void> {
  await flushMicrotasks(4);
}

interface StreamHarness {
  mux: UserStreamMux;
  sessionsById: Map<string, Session>;
  sessionCallbacks: Map<string, (msg: ServerMessage) => void>;
}

function makeStreamHarness(): StreamHarness {
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

function formatRepro(seed: number, steps: string[]): string {
  return `seed=${seed}; steps=${steps.join(" -> ")}`;
}

describe("protocol fuzz invariants", () => {
  it("seeded stream programs stay crash-free and preserve request/ordering invariants", async () => {
    const seeds = [101, 202, 303, 404, 505, 606, 707, 808];

    for (const seed of seeds) {
      const rng = mulberry32(seed);
      const steps: string[] = [];
      const harness = makeStreamHarness();
      const ws = new FakeWebSocket();
      await harness.mux.handleWebSocket(ws as unknown as WebSocket);

      const initialType = ws.sent[0]?.type;
      if (initialType !== "stream_connected") {
        throw new Error(`Missing stream_connected during bootstrap: ${formatRepro(seed, steps)}`);
      }

      let req = 0;
      let turn = 0;

      for (let i = 0; i < 40; i += 1) {
        const roll = rng();
        const requestId = `seed-${seed}-req-${req++}`;

        if (roll < 0.30) {
          const level = rng() < 0.55 ? "full" : "notifications";
          const nearValidSince = rng() < 0.15 ? -1 : undefined;
          steps.push(`subscribe(${level}${nearValidSince !== undefined ? ",since=-1" : ""})`);
          ws.emitClientMessage({
            type: "subscribe",
            sessionId: "s1",
            level,
            sinceSeq: nearValidSince,
            requestId,
          });
        } else if (roll < 0.45) {
          steps.push("unsubscribe");
          ws.emitClientMessage({ type: "unsubscribe", sessionId: "s1", requestId });
        } else if (roll < 0.80) {
          const commandRoll = rng();
          const command: "prompt" | "steer" | "follow_up" =
            commandRoll < 0.34 ? "prompt" : commandRoll < 0.67 ? "steer" : "follow_up";
          const clientTurnId = `seed-${seed}-turn-${turn++}`;
          steps.push(`${command}(${clientTurnId})`);
          ws.emitClientMessage({
            type: command,
            sessionId: "s1",
            message: `payload-${i}`,
            requestId,
            clientTurnId,
          });
        } else {
          steps.push("get_state");
          ws.emitClientMessage({ type: "get_state", sessionId: "s1", requestId });
        }

        await flushQueue();
      }

      const perRequestResults = new Map<string, number>();
      for (const result of messagesOfType(ws.sent, "command_result")) {
        if (!result.requestId) continue;
        perRequestResults.set(result.requestId, (perRequestResults.get(result.requestId) ?? 0) + 1);
      }

      for (const [requestId, count] of perRequestResults) {
        if (count !== 1) {
          throw new Error(
            `Expected exactly one command_result for requestId=${requestId}, got ${count}; ${formatRepro(seed, steps)}`,
          );
        }
      }

      const assistantTerminalCounts = new Map<string, number>();
      for (const msg of ws.sent) {
        if (msg.type === "message_end" && msg.role === "assistant") {
          assistantTerminalCounts.set(msg.content, (assistantTerminalCounts.get(msg.content) ?? 0) + 1);
        }
      }

      for (const [turnLabel, count] of assistantTerminalCounts) {
        if (count !== 1) {
          throw new Error(
            `Duplicate assistant terminal state for ${turnLabel}: ${count}; ${formatRepro(seed, steps)}`,
          );
        }
      }

      const subscribeResults = messagesOfType(ws.sent, "command_result").filter(
        (msg) => msg.command === "subscribe" && msg.success,
      );
      for (const result of subscribeResults) {
        const commandIndex = ws.sent.indexOf(result);
        const stateIndex = ws.sent.findIndex(
          (msg, idx) => idx < commandIndex && msg.type === "state" && msg.sessionId === result.sessionId,
        );

        if (stateIndex === -1) {
          throw new Error(
            `Subscribe success without preceding state event for session=${result.sessionId}; ${formatRepro(seed, steps)}`,
          );
        }
      }

      ws.emitClose();
    }
  }, 20_000);

  it("seeded turn-ack programs keep stage monotonic and id-correlated", () => {
    const seeds = [17, 34, 51, 68, 85, 102, 119, 136];

    for (const seed of seeds) {
      const rng = mulberry32(seed);
      const steps: string[] = [];
      const emitted: Array<Extract<ServerMessage, { type: "turn_ack" }>> = [];
      const coordinator = new SessionTurnCoordinator({
        broadcast: (_key: string, message: ServerMessage) => {
          if (message.type === "turn_ack") {
            emitted.push(message);
          }
        },
      });

      const state = {
        turnCache: new TurnDedupeCache(256, 60_000),
        pendingTurnStarts: [] as string[],
      };

      const knownTurns: string[] = [];
      const turnCommand = new Map<string, TurnCommand>();

      for (let i = 0; i < 120; i += 1) {
        const chooseExisting = knownTurns.length > 0 && rng() < 0.55;
        const clientTurnId = chooseExisting
          ? knownTurns[Math.floor(rng() * knownTurns.length)]
          : `seed-${seed}-turn-${knownTurns.length}`;

        if (!chooseExisting) {
          knownTurns.push(clientTurnId);
        }

        const generatedCommand: TurnCommand =
          rng() < 0.5 ? "prompt" : rng() < 0.5 ? "steer" : "follow_up";
        const command = turnCommand.get(clientTurnId) ?? generatedCommand;
        turnCommand.set(clientTurnId, command);

        const requestId = `seed-${seed}-req-${i}`;

        steps.push(`begin(${command},${clientTurnId})`);
        const turn = coordinator.beginTurnIntent(
          "s1",
          state,
          command,
          { message: `payload-${clientTurnId}` },
          clientTurnId,
          requestId,
        );

        if (!turn.duplicate && rng() < 0.85) {
          steps.push(`dispatch(${clientTurnId})`);
          coordinator.markTurnDispatched("s1", state, command, turn, requestId);
        }

        if (rng() < 0.60) {
          steps.push("started(next)");
          coordinator.markNextTurnStarted("s1", state);
        }
      }

      const stageOrder: Record<TurnAckStage, number> = {
        accepted: 1,
        dispatched: 2,
        started: 3,
      };

      const maxStagePerTurn = new Map<string, number>();
      for (const ack of emitted) {
        const next = stageOrder[ack.stage];
        const prior = maxStagePerTurn.get(ack.clientTurnId) ?? 0;
        if (next < prior) {
          throw new Error(
            `Non-monotonic turn_ack stage for ${ack.clientTurnId}: ${ack.stage}; ${formatRepro(seed, steps)}`,
          );
        }
        maxStagePerTurn.set(ack.clientTurnId, Math.max(prior, next));
      }

      for (const ack of emitted) {
        if (ack.duplicate && !ack.requestId) {
          throw new Error(
            `Duplicate turn_ack missing requestId for turn=${ack.clientTurnId}; ${formatRepro(seed, steps)}`,
          );
        }
      }

      const acceptedByTurn = new Map<string, number>();
      for (const ack of emitted) {
        if (ack.stage !== "accepted" || ack.duplicate) {
          continue;
        }
        acceptedByTurn.set(ack.clientTurnId, (acceptedByTurn.get(ack.clientTurnId) ?? 0) + 1);
      }

      for (const [turnId, acceptedCount] of acceptedByTurn) {
        if (acceptedCount !== 1) {
          throw new Error(
            `Expected exactly one non-duplicate accepted ack for ${turnId}, got ${acceptedCount}; ${formatRepro(seed, steps)}`,
          );
        }
      }
    }
  });
});
