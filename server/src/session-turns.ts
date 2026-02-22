import { computeTurnPayloadHash, type TurnDedupeCache } from "./turn-cache.js";
import type { ServerMessage, TurnAckStage, TurnCommand } from "./types.js";

export interface TurnSessionState {
  turnCache: TurnDedupeCache;
  pendingTurnStarts: string[];
}

export interface SessionTurnCoordinatorDeps {
  broadcast: (key: string, message: ServerMessage) => void;
}

export class SessionTurnCoordinator {
  constructor(private readonly deps: SessionTurnCoordinatorDeps) {}

  private emitTurnAck(
    key: string,
    payload: {
      command: TurnCommand;
      clientTurnId: string;
      stage: TurnAckStage;
      requestId?: string;
      duplicate?: boolean;
    },
  ): void {
    this.deps.broadcast(key, {
      type: "turn_ack",
      command: payload.command,
      clientTurnId: payload.clientTurnId,
      stage: payload.stage,
      requestId: payload.requestId,
      duplicate: payload.duplicate,
    });
  }

  beginTurnIntent(
    key: string,
    active: TurnSessionState,
    command: TurnCommand,
    payload: unknown,
    clientTurnId?: string,
    requestId?: string,
  ): { clientTurnId?: string; duplicate: boolean } {
    if (!clientTurnId) {
      return { duplicate: false };
    }

    const payloadHash = computeTurnPayloadHash(command, payload);
    const existing = active.turnCache.get(clientTurnId);
    if (existing) {
      if (existing.command !== command || existing.payloadHash !== payloadHash) {
        throw new Error(`clientTurnId conflict: ${clientTurnId}`);
      }

      this.emitTurnAck(key, {
        command,
        clientTurnId,
        stage: existing.stage,
        requestId,
        duplicate: true,
      });

      return { clientTurnId, duplicate: true };
    }

    const now = Date.now();
    active.turnCache.set(clientTurnId, {
      command,
      payloadHash,
      stage: "accepted",
      acceptedAt: now,
      updatedAt: now,
    });

    this.emitTurnAck(key, {
      command,
      clientTurnId,
      stage: "accepted",
      requestId,
    });

    return { clientTurnId, duplicate: false };
  }

  markTurnDispatched(
    key: string,
    active: TurnSessionState,
    command: TurnCommand,
    turn: { clientTurnId?: string; duplicate: boolean },
    requestId?: string,
  ): void {
    const clientTurnId = turn.clientTurnId;
    if (!clientTurnId || turn.duplicate) {
      return;
    }

    active.turnCache.updateStage(clientTurnId, "dispatched");
    active.pendingTurnStarts.push(clientTurnId);

    this.emitTurnAck(key, {
      command,
      clientTurnId,
      stage: "dispatched",
      requestId,
    });
  }

  markNextTurnStarted(key: string, active: TurnSessionState): void {
    while (active.pendingTurnStarts.length > 0) {
      const clientTurnId = active.pendingTurnStarts.shift();
      if (!clientTurnId) {
        break;
      }

      const record = active.turnCache.updateStage(clientTurnId, "started");
      if (!record) {
        continue;
      }

      this.emitTurnAck(key, {
        command: record.command,
        clientTurnId,
        stage: "started",
      });
      break;
    }
  }
}
