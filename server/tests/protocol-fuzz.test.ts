import { describe, it } from "vitest";
import { WebSocket } from "ws";

import { SessionTurnCoordinator } from "../src/session-turns.js";
import { TurnDedupeCache } from "../src/turn-cache.js";
import type { ServerMessage, TurnAckStage, TurnCommand } from "../src/types.js";
import { formatSeededRepro, mulberry32 } from "./harness/fuzz.js";
import { messagesOfType } from "./harness/ws-harness.js";
import { FakeWebSocket, flushStreamQueue, makeStreamFuzzHarness } from "./harness/stream-fuzz-harness.js";

describe("protocol fuzz invariants", () => {
  it("seeded stream programs stay crash-free and preserve request/ordering invariants", async () => {
    const seeds = [101, 202, 303, 404, 505, 606, 707, 808];

    for (const seed of seeds) {
      const rng = mulberry32(seed);
      const steps: string[] = [];
      const harness = makeStreamFuzzHarness();
      const ws = new FakeWebSocket();
      await harness.mux.handleWebSocket(ws as unknown as WebSocket);

      const initialType = ws.sent[0]?.type;
      if (initialType !== "stream_connected") {
        throw new Error(`Missing stream_connected during bootstrap: ${formatSeededRepro(seed, steps)}`);
      }

      let req = 0;
      let turn = 0;

      for (let i = 0; i < 40; i += 1) {
        const roll = rng();
        const requestId = `seed-${seed}-req-${req++}`;

        if (roll < 0.3) {
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
        } else if (roll < 0.8) {
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

        await flushStreamQueue();
      }

      const perRequestResults = new Map<string, number>();
      for (const result of messagesOfType(ws.sent, "command_result")) {
        if (!result.requestId) continue;
        perRequestResults.set(result.requestId, (perRequestResults.get(result.requestId) ?? 0) + 1);
      }

      for (const [requestId, count] of perRequestResults) {
        if (count !== 1) {
          throw new Error(
            `Expected exactly one command_result for requestId=${requestId}, got ${count}; ${formatSeededRepro(seed, steps)}`,
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
            `Duplicate assistant terminal state for ${turnLabel}: ${count}; ${formatSeededRepro(seed, steps)}`,
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
            `Subscribe success without preceding state event for session=${result.sessionId}; ${formatSeededRepro(seed, steps)}`,
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

        if (rng() < 0.6) {
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
            `Non-monotonic turn_ack stage for ${ack.clientTurnId}: ${ack.stage}; ${formatSeededRepro(seed, steps)}`,
          );
        }
        maxStagePerTurn.set(ack.clientTurnId, Math.max(prior, next));
      }

      for (const ack of emitted) {
        if (ack.duplicate && !ack.requestId) {
          throw new Error(
            `Duplicate turn_ack missing requestId for turn=${ack.clientTurnId}; ${formatSeededRepro(seed, steps)}`,
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
            `Expected exactly one non-duplicate accepted ack for ${turnId}, got ${acceptedCount}; ${formatSeededRepro(seed, steps)}`,
          );
        }
      }
    }
  });
});
