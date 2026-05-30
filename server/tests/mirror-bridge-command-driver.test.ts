import { EventEmitter } from "node:events";

import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import {
  MirrorBridgeCommandDriver,
  type MirrorBridgeCommandConnection,
} from "../src/mirror-bridge-command-driver.js";

class FakeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];
  send(data: string, cb?: (error?: Error) => void): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
    cb?.();
  }
}

function makeConnection(ws = new FakeWebSocket()): MirrorBridgeCommandConnection {
  return {
    bridgeId: "bridge-1",
    sessionId: "session-1",
    ws: ws as unknown as WebSocket,
    pendingCommands: new Map(),
  };
}

describe("MirrorBridgeCommandDriver", () => {
  it("dispatches commands and resolves matching command results", async () => {
    const driver = new MirrorBridgeCommandDriver();
    const ws = new FakeWebSocket();
    const connection = makeConnection(ws);

    const promise = driver.dispatch(connection, { type: "get_state" });
    const sent = ws.sent.at(-1)!;
    expect(sent).toMatchObject({ type: "command", command: { type: "get_state" } });

    expect(
      driver.resolveResult(connection, {
        id: String(sent.id),
        success: true,
        data: { ok: true },
      }),
    ).toBe(true);

    await expect(promise).resolves.toEqual({ ok: true });
    expect(connection.pendingCommands.size).toBe(0);
  });

  it("rejects all pending commands on disconnect", async () => {
    const driver = new MirrorBridgeCommandDriver();
    const connection = makeConnection();

    const promise = driver.dispatch(connection, { type: "get_queue" });
    driver.rejectPending(connection, new Error("Terminal mirror disconnected"));

    await expect(promise).rejects.toThrow("Terminal mirror disconnected");
    expect(connection.pendingCommands.size).toBe(0);
  });

  it("times out commands without a matching result", async () => {
    vi.useFakeTimers();
    try {
      const driver = new MirrorBridgeCommandDriver(25);
      const connection = makeConnection();
      const promise = driver.dispatch(connection, { type: "get_queue" });

      vi.advanceTimersByTime(25);
      await expect(promise).rejects.toThrow("Terminal mirror command timed out: get_queue");
      expect(connection.pendingCommands.size).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });
});
