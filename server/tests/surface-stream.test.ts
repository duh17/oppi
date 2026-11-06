import { EventEmitter } from "node:events";
import { tmpdir } from "node:os";
import { WebSocket } from "ws";
import { describe, expect, it, vi } from "vitest";

import {
  EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
  EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
  EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
} from "../src/extension-ui-contract.js";
import { readExtensionUISurface } from "../src/extension-surface.js";
import type { ExtensionUISurfaceAudience } from "../src/extension-surface-runtime.js";
import { SessionSurfaces } from "../src/session-surfaces.js";
import { BoundSessionStreamMux, type StreamContext } from "../src/stream.js";
import type { ClientMessage, ExtensionUISurface, ServerMessage, Session } from "../src/types.js";
import { WsMessageHandler, type WsSessionCommands } from "../src/ws-message-handler.js";
import { buildSurfaceFixtures } from "./surface-fixtures.js";

const fixtures = buildSurfaceFixtures();

function makeSession(id: string, workspaceId?: string): Session {
  return {
    id,
    workspaceId,
    status: "ready",
    createdAt: Date.now(),
    lastActivity: Date.now(),
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function surfaceOf(): ExtensionUISurface {
  const read = readExtensionUISurface(JSON.parse(JSON.stringify(fixtures["status-card.json"])));
  if ("problem" in read) throw new Error(read.problem);
  return read.surface;
}

class FakeWebSocket extends EventEmitter {
  readyState: number = WebSocket.OPEN;
  sent: ServerMessage[] = [];
  closeCode?: number;

  send(data: string): void {
    this.sent.push(JSON.parse(data) as ServerMessage);
  }

  ping(): void {}

  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }

  receive(msg: ClientMessage): void {
    this.emit("message", Buffer.from(JSON.stringify(msg)), false);
  }

  sentOfType<T extends ServerMessage["type"]>(type: T): Array<Extract<ServerMessage, { type: T }>> {
    return this.sent.filter((message) => message.type === type) as Array<
      Extract<ServerMessage, { type: T }>
    >;
  }

  close(code = 1000): void {
    this.readyState = WebSocket.CLOSED;
    this.emit("close", code, Buffer.from(""));
  }
}

/** A deferred session start, so a test can act while the stream is still bootstrapping. */
function deferredStart(): { promise: Promise<Session>; resolve: (session: Session) => void } {
  let resolve: ((session: Session) => void) | undefined;
  const promise = new Promise<Session>((settle) => {
    resolve = settle;
  });
  return { promise, resolve: (session) => resolve?.(session) };
}

/**
 * A session stream over the real surface loop: `SessionSurfaces` publishes into the session's
 * subscribers, the mux filters each frame by the shape a socket draws, and a real
 * `WsMessageHandler` takes the socket's commands with the surface manager behind it.
 */
function streamHarness(session: Session) {
  const subscribers = new Set<
    (message: ServerMessage, audience?: ExtensionUISurfaceAudience) => void
  >();
  const broadcast = (message: ServerMessage, audience?: ExtensionUISurfaceAudience): void => {
    for (const subscriber of subscribers) subscriber(message, audience);
  };
  const surfaces = new SessionSurfaces({
    sessionId: session.id,
    emit: (message, audience) => broadcast(message, audience),
  });
  const start = deferredStart();
  const startSession = vi.fn(async () => start.promise);

  const handler = new WsMessageHandler({
    sessions: {
      getActiveSession: () => session,
      subscribe: () => () => {},
    } as unknown as WsSessionCommands,
    surfaces: {
      canAct: (sessionId) => sessionId === session.id && surfaces.canAct(),
      act: (sessionId, message, clientId) =>
        sessionId === session.id ? surfaces.act(message, clientId) : Promise.resolve(false),
      declare: (sessionId, clientId, capabilities) =>
        sessionId === session.id ? surfaces.declare(clientId, capabilities) : [],
    },
    ensureSessionContextWindow: (target) => target,
    getModelCatalog: () => [],
  });

  const ctx = {
    storage: {
      getOwnerName: () => "test-user",
      getSession: (id: string) => (id === session.id ? session : undefined),
      saveSession: () => {},
      getDataDir: () => tmpdir(),
    },
    sessions: {
      startSession,
      subscribe: (id: string, callback: (message: ServerMessage) => void) => {
        if (id !== session.id) return () => {};
        const subscriber = callback as (
          message: ServerMessage,
          audience?: ExtensionUISurfaceAudience,
        ) => void;
        subscribers.add(subscriber);
        return () => subscribers.delete(subscriber);
      },
      getActiveSession: () => session,
      getCurrentSeq: () => 0,
      getCatchUp: () => ({ events: [], currentSeq: 0, session, catchUpComplete: true }),
      getPendingUIRequestMessages: () => [],
      surfaceAudience: (id: string, clientId: string) =>
        id === session.id ? surfaces.audience(clientId) : "v1-projection",
      getSurfaceMessages: (id: string, clientId: string) =>
        id === session.id ? surfaces.messages(clientId) : [],
      declareSurfaceCapabilities: (id: string, clientId: string, capabilities: string[]) =>
        id === session.id ? surfaces.declare(clientId, capabilities) : [],
      forgetSurfaceAudience: (id: string, clientId: string) => {
        if (id === session.id) surfaces.forget(clientId);
      },
    },
    sessionRuntimes: {
      isSessionConnected: () => true,
      getSessionSnapshot: () => session,
      getActiveSession: () => session,
      getCurrentSeq: () => 0,
      getCatchUp: () => ({ events: [], currentSeq: 0, session, catchUpComplete: true }),
      subscribe: (id: string, callback: (message: ServerMessage) => void) => {
        const subscriber = callback as (
          message: ServerMessage,
          audience?: ExtensionUISurfaceAudience,
        ) => void;
        subscribers.add(subscriber);
        return () => subscribers.delete(subscriber);
      },
      getPendingUIRequestMessages: () => [],
      subscribeStartupUI: () => () => {},
      stopSession: vi.fn(async () => {}),
      stopSessionIfActive: vi.fn(async () => {}),
    },
    ensureSessionContextWindow: (target: Session) => target,
    resolveWorkspaceForSession: () => undefined,
    handleClientMessage: vi.fn(
      async (
        target: Session,
        message: ClientMessage,
        send: (frame: ServerMessage) => void,
        meta?: { connId?: string },
      ) => handler.handleClientMessage(target, message, send, meta),
    ),
    handleConnectionClosed: vi.fn(),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  } as unknown as StreamContext;

  return { ctx, surfaces, start, startSession };
}

/** Let every queued promise and the socket's inbound queue run. */
async function flush(): Promise<void> {
  for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0));
}

async function until(condition: () => boolean): Promise<void> {
  for (let i = 0; i < 200 && !condition(); i++) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  expect(condition()).toBe(true);
}

describe("session stream surfaces", () => {
  it("takes the socket's next message while an action is still running", async () => {
    const session = makeSession("sess-action", "w1");
    const { ctx, surfaces, start, startSession } = streamHarness(session);
    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    const opening = mux.handleWebSocket("w1", session.id, ws as unknown as WebSocket);
    await until(() => startSession.mock.calls.length === 1);
    start.resolve(session);
    await opening;

    const pending: { release?: () => void } = {};
    let ran = 0;
    surfaces.publisher.publish(surfaceOf(), () => {
      ran += 1;
      return new Promise((resolve) => {
        pending.release = () => resolve({ patch: {} });
      });
    });
    const connId = mux.connectionIdFor(ws as unknown as WebSocket) ?? "";
    ws.receive({
      type: "client_capabilities",
      capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY],
    });
    await flush();
    expect(surfaces.audience(connId)).toBe("composites");

    ws.receive({
      type: "extension_ui_action",
      surfaceId: "deploy",
      compositeId: "status",
      actionId: "retry",
      revision: 1,
      requestId: "tap-1",
    });
    await until(() => ran === 1);
    // The panel's handler has not answered; the socket is not waiting on it.
    expect(ws.sentOfType("extension_ui_settled")).toEqual([]);

    const statesBefore = ws.sentOfType("state").length;
    ws.receive({ type: "get_state" });
    await flush();
    expect(ws.sentOfType("state")).toHaveLength(statesBefore + 1);

    pending.release?.();
    await flush();
    expect(ws.sentOfType("extension_ui_settled").map((message) => message.id)).toEqual(["tap-1"]);
    ws.close();
  });

  it("replays in the shape a socket declares before the replay runs", async () => {
    const session = makeSession("sess-declare", "w1");
    const { ctx, surfaces, start, startSession } = streamHarness(session);
    surfaces.publisher.publish(surfaceOf(), undefined);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    const opening = mux.handleWebSocket("w1", session.id, ws as unknown as WebSocket);
    await until(() => startSession.mock.calls.length === 1);

    // Still opening: what this socket draws is known before the replay below.
    ws.receive({
      type: "client_capabilities",
      capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY],
      requestId: "caps-1",
    });
    await flush();
    start.resolve(session);
    await opening;

    expect(ws.sentOfType("extension_ui_surface")).toHaveLength(1);
    // A client that draws composites is never handed the projection it would then clear.
    expect(ws.sentOfType("extension_ui_notification")).toEqual([]);
    expect(ws.sentOfType("command_result")).toEqual([
      {
        type: "command_result",
        command: "client_capabilities",
        requestId: "caps-1",
        success: true,
        sessionId: session.id,
      },
    ]);
    ws.close();
  });

  it("delivers a surface published during bootstrap once", async () => {
    const session = makeSession("sess-bootstrap", "w1");
    const { ctx, surfaces, start, startSession } = streamHarness(session);

    const mux = new BoundSessionStreamMux(ctx);
    const ws = new FakeWebSocket();
    const opening = mux.handleWebSocket("w1", session.id, ws as unknown as WebSocket);
    await until(() => startSession.mock.calls.length === 1);
    ws.receive({
      type: "client_capabilities",
      capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY],
    });
    await flush();

    // Published while the socket bootstraps: it arrives on the live queue, not again on replay.
    surfaces.publisher.publish(surfaceOf(), async () => ({ patch: {} }));
    await flush();
    start.resolve(session);
    await opening;

    expect(ws.sentOfType("extension_ui_surface")).toHaveLength(1);
    expect(ws.sentOfType("extension_ui_notification")).toEqual([]);
    ws.close();
  });

  it("sends each frame only to the shape it was built for, and forgets a closed socket", async () => {
    const session = makeSession("sess-shapes", "w1");
    const { ctx, surfaces, start } = streamHarness(session);
    const mux = new BoundSessionStreamMux(ctx);

    const v1 = new FakeWebSocket();
    const composites = new FakeWebSocket();
    const opening = [
      mux.handleWebSocket("w1", session.id, v1 as unknown as WebSocket),
      mux.handleWebSocket("w1", session.id, composites as unknown as WebSocket),
    ];
    start.resolve(session);
    await Promise.all(opening);

    const compositesId = mux.connectionIdFor(composites as unknown as WebSocket);
    expect(compositesId).toBeDefined();
    composites.receive({
      type: "client_capabilities",
      capabilities: [EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY],
    });
    await flush();

    surfaces.publisher.publish(surfaceOf(), async () => ({ patch: {} }));
    await flush();

    expect(composites.sentOfType("extension_ui_surface")).toHaveLength(1);
    expect(composites.sentOfType("extension_ui_notification")).toEqual([]);
    expect(v1.sentOfType("extension_ui_surface")).toEqual([]);
    expect(v1.sentOfType("extension_ui_notification")).toEqual([
      expect.objectContaining({ widgetKey: "surface:deploy" }),
    ]);

    // A socket that goes away leaves no declaration behind for the next one.
    composites.close();
    await flush();
    expect(surfaces.audience(compositesId ?? "")).toBe("v1-projection");
    v1.close();
  });

  it("sends an elapsed node only to a socket that declared it, and static text to the other", async () => {
    const session = makeSession("sess-elapsed", "w1");
    const { ctx, surfaces, start } = streamHarness(session);
    const mux = new BoundSessionStreamMux(ctx);

    const current = new FakeWebSocket();
    const older = new FakeWebSocket();
    const opening = [
      mux.handleWebSocket("w1", session.id, current as unknown as WebSocket),
      mux.handleWebSocket("w1", session.id, older as unknown as WebSocket),
    ];
    start.resolve(session);
    await Promise.all(opening);
    current.receive({
      type: "client_capabilities",
      capabilities: [
        EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
        EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
        EXTENSION_NATIVE_UI_ELAPSED_CAPABILITY,
      ],
    });
    // A build that draws trees but predates the elapsed node.
    older.receive({
      type: "client_capabilities",
      capabilities: [
        EXTENSION_NATIVE_UI_COMPOSITES_CAPABILITY,
        EXTENSION_NATIVE_UI_BLOCKS_CAPABILITY,
      ],
    });
    await flush();

    const since = Date.now() - 65_000;
    const value = JSON.parse(JSON.stringify(fixtures["blocks-elapsed.json"]));
    value.pill.content.children[2].since = since;
    value.sections[0].body.children[1].since = since;
    const read = readExtensionUISurface(value);
    if ("problem" in read) throw new Error(read.problem);
    surfaces.publisher.publish(read.surface, undefined);
    await flush();

    const [live] = current.sentOfType("extension_ui_surface");
    expect(live?.surface.pill?.content.children[2]).toMatchObject({ type: "elapsed", since });
    const [fixed] = older.sentOfType("extension_ui_surface");
    // The span as it stood when sent, in the node's own format and look.
    expect(fixed?.surface.pill?.content.children[2]).toEqual({
      type: "text",
      text: "1:05",
      style: "mono",
      tone: "warning",
    });
    const body = fixed?.surface.sections[0];
    if (body?.composite !== "blocks") throw new Error("expected a blocks section");
    expect(body.body.children[1]).toEqual({ type: "text", id: "job-elapsed", text: "1m" });
    expect(JSON.stringify(older.sent)).not.toContain('"elapsed"');
    current.close();
    older.close();
  });
});
