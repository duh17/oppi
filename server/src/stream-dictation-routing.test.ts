/**
 * Regression tests for dictation routing through UserStreamMux.
 *
 * After consolidating dictation onto the /stream WebSocket, these tests
 * verify that binary frames, dictation control messages, and disconnect
 * events are correctly routed from the /stream WS to the DictationManager.
 *
 * Uses a real WebSocket server + client (not mocked transport) with a
 * mock DictationManager to isolate the routing layer.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { WebSocketServer, WebSocket } from "ws";
import { createServer, type Server as HttpServer } from "node:http";
import { UserStreamMux, type StreamContext } from "./stream.js";
import type { DictationManager, DictationSendFn } from "./dictation-manager.js";
import type { DictationClientMessage } from "./dictation-types.js";
import type { ClientMessage, ServerMessage } from "./types.js";

// ─── Mock DictationManager ───

interface MockDictation {
  handleControlMessage: ReturnType<typeof vi.fn>;
  handleAudioData: ReturnType<typeof vi.fn>;
  handleDisconnect: ReturnType<typeof vi.fn>;
}

function createMockDictationManager(): MockDictation {
  return {
    handleControlMessage: vi.fn(),
    handleAudioData: vi.fn(),
    handleDisconnect: vi.fn(),
  };
}

// ─── Mock StreamContext ───

function createMockStreamContext(dictationManager?: MockDictation): StreamContext {
  return {
    storage: {
      getOwnerName: () => "test-owner",
      getSession: () => undefined,
    } as unknown as StreamContext["storage"],
    sessions: {
      startSession: vi.fn(),
      subscribe: vi.fn(() => () => {}),
      getCurrentSeq: vi.fn(() => 0),
      getActiveSession: vi.fn(() => undefined),
      getPendingAskMessage: vi.fn(() => undefined),
      getPendingUIRequestMessages: vi.fn(() => []),
      getCatchUp: vi.fn(() => undefined),
    } as unknown as StreamContext["sessions"],
    gate: {
      getPendingForUser: vi.fn(() => []),
      resolveDecision: vi.fn(),
    } as unknown as StreamContext["gate"],
    ensureSessionContextWindow: (session) => session,
    resolveWorkspaceForSession: () => undefined,
    handleClientMessage: vi.fn(),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
    dictationManager: dictationManager as unknown as DictationManager,
  };
}

// ─── Test Harness ───

interface TestHarness {
  mux: UserStreamMux;
  mock: MockDictation;
  httpServer: HttpServer;
  wss: WebSocketServer;
  port: number;
  /** Connect a WS client and wait for the stream_connected message. */
  connect(): Promise<{ ws: WebSocket; messages: ServerMessage[] }>;
  cleanup(): Promise<void>;
}

async function setupHarness(opts?: { noDictation?: boolean }): Promise<TestHarness> {
  const mock = createMockDictationManager();
  const ctx = createMockStreamContext(opts?.noDictation ? undefined : mock);
  const mux = new UserStreamMux(ctx);

  const httpServer = createServer();
  const wss = new WebSocketServer({ server: httpServer });

  wss.on("connection", (ws) => {
    void mux.handleWebSocket(ws);
  });

  const port = await new Promise<number>((resolve) => {
    httpServer.listen(0, "127.0.0.1", () => {
      const addr = httpServer.address();
      resolve(typeof addr === "object" && addr ? addr.port : 0);
    });
  });

  const connect = async (): Promise<{ ws: WebSocket; messages: ServerMessage[] }> => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const messages: ServerMessage[] = [];

    ws.on("message", (data) => {
      if (Buffer.isBuffer(data) || (Array.isArray(data) && data.length > 0)) {
        try {
          messages.push(JSON.parse(data.toString("utf8")) as ServerMessage);
        } catch {
          // binary frame — skip
        }
      } else if (typeof data === "string") {
        messages.push(JSON.parse(data) as ServerMessage);
      }
    });

    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("WS connect timeout")), 3000);
      ws.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      ws.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });

    // Wait for stream_connected
    await waitForCondition(() => messages.some((m) => m.type === "stream_connected"), 2000);
    return { ws, messages };
  };

  const cleanup = async (): Promise<void> => {
    for (const client of wss.clients) {
      client.terminate();
    }
    wss.close();
    await new Promise<void>((resolve) => httpServer.close(() => resolve()));
  };

  return { mux, mock, httpServer, wss, port, connect, cleanup };
}

/** Wait for a condition to be true, polling every 10ms. */
async function waitForCondition(
  fn: () => boolean,
  timeoutMs = 2000,
  intervalMs = 10,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!fn()) {
    if (Date.now() > deadline) throw new Error("waitForCondition timeout");
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

/** Send a client message as a JSON text frame. */
function sendClient(ws: WebSocket, msg: ClientMessage): void {
  ws.send(JSON.stringify(msg));
}

// ─── Tests ───

describe("stream dictation routing", () => {
  let harness: TestHarness;

  afterEach(async () => {
    if (harness) await harness.cleanup();
  });

  describe("control message routing", () => {
    beforeEach(async () => {
      harness = await setupHarness();
    });

    it("routes dictation_start to handleControlMessage", async () => {
      const { ws } = await harness.connect();
      sendClient(ws, { type: "dictation_start" } as ClientMessage);

      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 1);

      const call = harness.mock.handleControlMessage.mock.calls[0];
      expect(call[0]).toEqual({ type: "dictation_start" });
      expect(typeof call[1]).toBe("function"); // send callback
      ws.close();
    });

    it("routes dictation_stop to handleControlMessage", async () => {
      const { ws } = await harness.connect();
      sendClient(ws, { type: "dictation_stop" } as ClientMessage);

      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 1);

      expect(harness.mock.handleControlMessage.mock.calls[0][0]).toEqual({
        type: "dictation_stop",
      });
      ws.close();
    });

    it("routes dictation_cancel to handleControlMessage", async () => {
      const { ws } = await harness.connect();
      sendClient(ws, { type: "dictation_cancel" } as ClientMessage);

      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 1);

      expect(harness.mock.handleControlMessage.mock.calls[0][0]).toEqual({
        type: "dictation_cancel",
      });
      ws.close();
    });
  });

  describe("binary frame routing", () => {
    beforeEach(async () => {
      harness = await setupHarness();
    });

    it("routes binary frames to handleAudioData", async () => {
      const { ws } = await harness.connect();
      const audioData = Buffer.from([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]);

      ws.send(audioData);

      await waitForCondition(() => harness.mock.handleAudioData.mock.calls.length >= 1);

      const buf = harness.mock.handleAudioData.mock.calls[0][0] as Buffer;
      expect(Buffer.isBuffer(buf)).toBe(true);
      expect(buf.length).toBe(6);
      expect(buf[0]).toBe(0xde);
      expect(buf[3]).toBe(0xef);
      ws.close();
    });

    it("routes multiple binary frames sequentially", async () => {
      const { ws } = await harness.connect();

      ws.send(Buffer.from([0x01, 0x02]));
      ws.send(Buffer.from([0x03, 0x04]));
      ws.send(Buffer.from([0x05, 0x06]));

      await waitForCondition(() => harness.mock.handleAudioData.mock.calls.length >= 3);

      expect(harness.mock.handleAudioData).toHaveBeenCalledTimes(3);
      ws.close();
    });
  });

  describe("without dictation manager", () => {
    beforeEach(async () => {
      harness = await setupHarness({ noDictation: true });
    });

    it("silently ignores binary frames when no DictationManager", async () => {
      const { ws } = await harness.connect();

      ws.send(Buffer.from([0xde, 0xad]));
      // Give time for processing
      await new Promise((r) => setTimeout(r, 200));

      // Connection should still be open
      expect(ws.readyState).toBe(WebSocket.OPEN);
      // No calls to the mock (it's not wired in this harness)
      ws.close();
    });

    it("silently ignores dictation control messages when no DictationManager", async () => {
      const { ws, messages } = await harness.connect();

      sendClient(ws, { type: "dictation_start" } as ClientMessage);
      await new Promise((r) => setTimeout(r, 200));

      // Connection stays open, no error sent
      expect(ws.readyState).toBe(WebSocket.OPEN);
      const errors = messages.filter((m) => m.type === "error");
      expect(errors).toHaveLength(0);
      ws.close();
    });
  });

  describe("disconnect cleanup", () => {
    beforeEach(async () => {
      harness = await setupHarness();
    });

    it("calls handleDisconnect when WS closes", async () => {
      const { ws } = await harness.connect();

      ws.close();
      await waitForCondition(() => harness.mock.handleDisconnect.mock.calls.length >= 1);

      expect(harness.mock.handleDisconnect).toHaveBeenCalledTimes(1);
    });

    it("calls handleDisconnect on abrupt termination", async () => {
      const { ws } = await harness.connect();

      ws.terminate();
      await waitForCondition(() => harness.mock.handleDisconnect.mock.calls.length >= 1);

      expect(harness.mock.handleDisconnect).toHaveBeenCalledTimes(1);
    });
  });

  describe("dictation response delivery", () => {
    beforeEach(async () => {
      harness = await setupHarness();
    });

    it("delivers dictation_ready response to the WS client", async () => {
      // When the mock's handleControlMessage is called, invoke the send
      // callback with a dictation_ready response.
      harness.mock.handleControlMessage.mockImplementation(
        (_msg: DictationClientMessage, send: DictationSendFn) => {
          send({
            type: "dictation_ready",
            sttProvider: "test-provider",
            sttModel: "test-model",
          });
        },
      );

      const { ws, messages } = await harness.connect();
      sendClient(ws, { type: "dictation_start" } as ClientMessage);

      await waitForCondition(() => messages.some((m) => m.type === "dictation_ready"), 2000);

      const ready = messages.find((m) => m.type === "dictation_ready") as ServerMessage & {
        sttProvider?: string;
      };
      expect(ready).toBeDefined();
      expect(ready.sttProvider).toBe("test-provider");
      ws.close();
    });

    it("delivers dictation_result updates to the WS client", async () => {
      let capturedSend: DictationSendFn | null = null;
      harness.mock.handleControlMessage.mockImplementation(
        (_msg: DictationClientMessage, send: DictationSendFn) => {
          capturedSend = send;
        },
      );

      const { ws, messages } = await harness.connect();
      sendClient(ws, { type: "dictation_start" } as ClientMessage);

      await waitForCondition(() => capturedSend !== null);

      // Simulate streaming results
      capturedSend!({ type: "dictation_result", text: "hello" });
      capturedSend!({ type: "dictation_result", text: "hello world" });

      await waitForCondition(
        () => messages.filter((m) => m.type === "dictation_result").length >= 2,
      );

      const results = messages.filter((m) => m.type === "dictation_result") as Array<
        ServerMessage & { text: string }
      >;
      expect(results).toHaveLength(2);
      expect(results[0].text).toBe("hello");
      expect(results[1].text).toBe("hello world");
      ws.close();
    });

    it("delivers dictation_error to the WS client", async () => {
      harness.mock.handleControlMessage.mockImplementation(
        (_msg: DictationClientMessage, send: DictationSendFn) => {
          send({ type: "dictation_error", error: "STT failed", fatal: true });
        },
      );

      const { ws, messages } = await harness.connect();
      sendClient(ws, { type: "dictation_start" } as ClientMessage);

      await waitForCondition(() => messages.some((m) => m.type === "dictation_error"));

      const err = messages.find((m) => m.type === "dictation_error") as ServerMessage & {
        error: string;
        fatal: boolean;
      };
      expect(err.error).toBe("STT failed");
      expect(err.fatal).toBe(true);
      ws.close();
    });
  });

  describe("non-interference with session messages", () => {
    beforeEach(async () => {
      harness = await setupHarness();
    });

    it("session subscribe still works with dictation manager present", async () => {
      const { ws, messages } = await harness.connect();

      // Send a subscribe — should route to session handler, not dictation
      sendClient(ws, {
        type: "subscribe",
        sessionId: "nonexistent-session",
        requestId: "req-1",
      } as ClientMessage);

      await waitForCondition(() =>
        messages.some(
          (m) => m.type === "command_result" && "command" in m && m.command === "subscribe",
        ),
      );

      // Should get a command_result (even if error, it means routing worked)
      const result = messages.find(
        (m) => m.type === "command_result" && "command" in m && m.command === "subscribe",
      );
      expect(result).toBeDefined();

      // dictation manager should NOT have been called
      expect(harness.mock.handleControlMessage).not.toHaveBeenCalled();
      ws.close();
    });

    it("error messages still route through normal path", async () => {
      const { ws, messages } = await harness.connect();

      // Send a prompt without subscribing — should get an error, not routed to dictation
      sendClient(ws, {
        type: "prompt",
        sessionId: "some-session",
        message: "hello",
      } as ClientMessage);

      await waitForCondition(() => messages.some((m) => m.type === "error"));

      expect(harness.mock.handleControlMessage).not.toHaveBeenCalled();
      ws.close();
    });
  });

  describe("multiple dictation cycles", () => {
    beforeEach(async () => {
      harness = await setupHarness();
    });

    it("routes multiple start/stop cycles on the same connection", async () => {
      const { ws } = await harness.connect();

      // First cycle
      sendClient(ws, { type: "dictation_start" } as ClientMessage);
      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 1);

      ws.send(Buffer.from([0x01, 0x02]));
      await waitForCondition(() => harness.mock.handleAudioData.mock.calls.length >= 1);

      sendClient(ws, { type: "dictation_stop" } as ClientMessage);
      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 2);

      // Second cycle
      sendClient(ws, { type: "dictation_start" } as ClientMessage);
      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 3);

      ws.send(Buffer.from([0x03, 0x04]));
      await waitForCondition(() => harness.mock.handleAudioData.mock.calls.length >= 2);

      sendClient(ws, { type: "dictation_stop" } as ClientMessage);
      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 4);

      // Verify all calls arrived
      expect(harness.mock.handleControlMessage).toHaveBeenCalledTimes(4);
      expect(harness.mock.handleAudioData).toHaveBeenCalledTimes(2);

      const calls = harness.mock.handleControlMessage.mock.calls;
      expect(calls[0][0].type).toBe("dictation_start");
      expect(calls[1][0].type).toBe("dictation_stop");
      expect(calls[2][0].type).toBe("dictation_start");
      expect(calls[3][0].type).toBe("dictation_stop");

      ws.close();
    });

    it("interleaves dictation and session messages correctly", async () => {
      const { ws, messages } = await harness.connect();

      // Dictation start
      sendClient(ws, { type: "dictation_start" } as ClientMessage);
      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 1);

      // Session subscribe (should NOT go to dictation)
      sendClient(ws, {
        type: "subscribe",
        sessionId: "test-session",
        requestId: "req-1",
      } as ClientMessage);
      await waitForCondition(() => messages.some((m) => m.type === "command_result"));

      // More audio
      ws.send(Buffer.from([0xaa, 0xbb]));
      await waitForCondition(() => harness.mock.handleAudioData.mock.calls.length >= 1);

      // Dictation stop
      sendClient(ws, { type: "dictation_stop" } as ClientMessage);
      await waitForCondition(() => harness.mock.handleControlMessage.mock.calls.length >= 2);

      // Dictation got exactly start + stop, nothing else
      expect(harness.mock.handleControlMessage).toHaveBeenCalledTimes(2);
      expect(harness.mock.handleControlMessage.mock.calls[0][0].type).toBe("dictation_start");
      expect(harness.mock.handleControlMessage.mock.calls[1][0].type).toBe("dictation_stop");

      ws.close();
    });
  });
});
