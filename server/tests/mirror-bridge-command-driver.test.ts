import { EventEmitter } from "node:events";

import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import {
  MirrorBridgeCommandDriver,
  type MirrorBridgeCommandConnection,
  type MirrorBridgeCommandDriverEvent,
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

  it("rejects command results when state reconciliation throws", async () => {
    const driver = new MirrorBridgeCommandDriver();
    const ws = new FakeWebSocket();
    const connection = makeConnection(ws);

    const promise = driver.dispatch(connection, { type: "get_state" });
    const sent = ws.sent.at(-1)!;

    expect(
      driver.resolveResult(
        connection,
        {
          id: String(sent.id),
          success: true,
          data: { ok: true },
        },
        () => {
          throw new Error("storage failed");
        },
      ),
    ).toBe(true);

    await expect(promise).rejects.toThrow("storage failed");
    expect(connection.pendingCommands.size).toBe(0);
  });

  it("rejects unserializable commands without registering pending work", async () => {
    const events: MirrorBridgeCommandDriverEvent[] = [];
    const driver = new MirrorBridgeCommandDriver(undefined, {
      onCommandEvent: (event) => events.push(event),
    });
    const ws = new FakeWebSocket();
    const connection = makeConnection(ws);

    const promise = driver.dispatch(connection, {
      type: "get_state",
      unsafe: 1n,
    });

    await expect(promise).rejects.toThrow("Failed to serialize terminal mirror command get_state");
    expect(ws.sent).toHaveLength(0);
    expect(connection.pendingCommands.size).toBe(0);
    expect(events[0]).toMatchObject({
      phase: "send_failed",
      commandType: "get_state",
      error: expect.stringContaining("Failed to serialize terminal mirror command get_state"),
    });
  });

  it("clears pending commands when websocket send throws synchronously", async () => {
    class ThrowingWebSocket extends FakeWebSocket {
      send(_data: string, _cb?: (error?: Error) => void): void {
        throw new Error("send exploded");
      }
    }

    const driver = new MirrorBridgeCommandDriver();
    const connection = makeConnection(new ThrowingWebSocket());

    const promise = driver.dispatch(connection, { type: "get_state" });

    await expect(promise).rejects.toThrow("send exploded");
    expect(connection.pendingCommands.size).toBe(0);
  });

  it("emits structured command lifecycle events", async () => {
    const events: MirrorBridgeCommandDriverEvent[] = [];
    const driver = new MirrorBridgeCommandDriver(undefined, {
      onCommandEvent: (event) => events.push(event),
    });
    const ws = new FakeWebSocket();
    const connection = makeConnection(ws);

    const promise = driver.dispatch(connection, {
      type: "set_model",
      requestId: "req-1",
      clientTurnId: "turn-1",
    });
    const sent = ws.sent.at(-1)!;

    expect(events[0]).toMatchObject({
      phase: "sent",
      bridgeId: "bridge-1",
      sessionId: "session-1",
      commandId: sent.id,
      commandType: "set_model",
      requestId: "req-1",
      clientTurnId: "turn-1",
    });

    expect(
      driver.resolveResult(connection, {
        id: String(sent.id),
        success: true,
        data: { ok: true },
      }),
    ).toBe(true);

    await expect(promise).resolves.toEqual({ ok: true });
    expect(events[1]).toMatchObject({
      phase: "result",
      bridgeId: "bridge-1",
      sessionId: "session-1",
      commandId: sent.id,
      commandType: "set_model",
      requestId: "req-1",
      clientTurnId: "turn-1",
      success: true,
    });
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
