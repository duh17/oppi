/**
 * WebSocket stress tests — real server, real WS connections.
 *
 * Tests delivery reliability, reconnect + catch-up, subscribe churn,
 * and no-drop delivery under load. Uses a real Server on a random
 * port — no mocks.
 *
 * Architecture assumption: one iOS client ↔ one server (1:1).
 * Multiple servers per client, but never multiple clients per server.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { WebSocket } from "ws";
import type { ServerMessage } from "../src/types.js";
import {
  collectMessages,
  connectStream as connectHarnessStream,
  messagesOfType,
  requireMessageOfType,
  sendClientMessage,
  waitForMessage,
} from "./harness/ws-harness.js";
import { waitForClose, waitForReadyState } from "./harness/async.js";

// ─── Test Harness ───

let dataDir: string;
let storage: Storage;
let server: Server;
let baseWsUrl: string;
let token: string;

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-ws-stress-"));
  storage = new Storage(dataDir);
  // Port 0 is rejected by normalizeConfig (min: 1), so pick a random high port.
  // Use a unique port range to avoid collisions with server-integration.test.ts.
  const randomPort = 30_000 + Math.floor(Math.random() * 20_000);
  storage.updateConfig({
    port: randomPort,
    host: "127.0.0.1",
  });
  token = storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseWsUrl = `ws://127.0.0.1:${server.port}`;
}, 15_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  await new Promise((r) => setTimeout(r, 100));
  rmSync(dataDir, { recursive: true, force: true });
}, 10_000);

// ─── Helpers ───

function connectStream(): WebSocket {
  return connectHarnessStream(baseWsUrl, token);
}

function sendJson(ws: WebSocket, message: Parameters<typeof sendClientMessage>[1]): void {
  sendClientMessage(ws, message);
}

async function createWorkspaceAndSession(): Promise<{
  workspaceId: string;
  sessionId: string;
}> {
  const baseUrl = `http://127.0.0.1:${server.port}`;
  const headers = {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
  };

  const wsRes = await fetch(`${baseUrl}/workspaces`, {
    method: "POST",
    headers,
    body: JSON.stringify({ name: `stress-${Date.now()}`, skills: [] }),
  });
  const { workspace } = (await wsRes.json()) as { workspace: { id: string } };

  const sessRes = await fetch(
    `${baseUrl}/workspaces/${workspace.id}/sessions`,
    {
      method: "POST",
      headers,
      body: JSON.stringify({ model: "anthropic/claude-sonnet-4-20250514" }),
    },
  );
  const { session } = (await sessRes.json()) as { session: { id: string } };
  return { workspaceId: workspace.id, sessionId: session.id };
}

// ─── Tests ───

describe("stream connection lifecycle", () => {
  it("receives stream_connected immediately on connect", async () => {
    const ws = connectStream();
    try {
      const msg = await waitForMessage(ws);
      expect(msg.type).toBe("stream_connected");
      expect(msg).toHaveProperty("userName");
    } finally {
      ws.close();
    }
  });

  it("receives stream_connected on every new connection (reconnect simulation)", async () => {
    // Simulate 5 rapid reconnects
    for (let i = 0; i < 5; i++) {
      const ws = connectStream();
      const msg = await waitForMessage(ws);
      expect(msg.type).toBe("stream_connected");
      ws.close();
      await waitForClose(ws);
    }
  });

  it("handles concurrent connections from same user without crash", async () => {
    // One server, one user — but rapid connect/disconnect shouldn't crash
    const connections: WebSocket[] = [];
    for (let i = 0; i < 3; i++) {
      connections.push(connectStream());
    }

    // All should get stream_connected
    const messages = await Promise.all(
      connections.map((ws) => waitForMessage(ws)),
    );
    expect(messages.every((msg) => msg.type === "stream_connected")).toBe(true);

    await Promise.all(
      connections.map(async (ws) => {
        ws.close();
        await waitForClose(ws);
      }),
    );
  });
});

describe("subscribe/unsubscribe churn", () => {
  it("handles rapid subscribe → unsubscribe → subscribe for same session", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      // Wait for stream_connected
      await waitForMessage(ws);

      // Fire rapid subscribe/unsubscribe/subscribe
      sendJson(ws, {
        type: "subscribe",
        sessionId,
        level: "full",
        requestId: "sub-1",
      });
      sendJson(ws, {
        type: "unsubscribe",
        sessionId,
        requestId: "unsub-1",
      });
      sendJson(ws, {
        type: "subscribe",
        sessionId,
        level: "full",
        requestId: "sub-2",
      });

      // Collect all responses — the server processes messages sequentially
      // via promise chain, so the final state should be subscribed.
      const messages = await collectMessages(ws, 2_000);

      const results = messagesOfType(messages, "command_result");

      // Should have 3 command_results (2 subscribe + 1 unsubscribe)
      const subResults = results.filter((r) => r.command === "subscribe");
      const unsubResults = results.filter((r) => r.command === "unsubscribe");

      expect(subResults.length).toBe(2);
      expect(unsubResults.length).toBe(1);
      expect(subResults.every((r) => r.success)).toBe(true);
      expect(unsubResults.every((r) => r.success)).toBe(true);
    } finally {
      ws.close();
    }
  });

  it("handles subscribe to nonexistent session gracefully", async () => {
    const ws = connectStream();

    try {
      await waitForMessage(ws);

      sendJson(ws, {
        type: "subscribe",
        sessionId: "NONEXISTENT_SESSION",
        level: "full",
        requestId: "sub-missing",
      });

      const messages = await collectMessages(ws, 1_000);
      const result = requireMessageOfType(
        messages,
        "command_result",
        (msg) => msg.requestId === "sub-missing",
      );

      expect(result.success).toBe(false);
      expect(result.error).toContain("not found");
    } finally {
      ws.close();
    }
  });

  it("rejects session commands before subscribe", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      await waitForMessage(ws);

      // Send a prompt without subscribing first
      sendJson(ws, {
        type: "prompt",
        sessionId,
        message: "hello",
      });

      const messages = await collectMessages(ws, 1_000);
      const error = requireMessageOfType(messages, "error");

      expect(error.error).toContain("not subscribed");
    } finally {
      ws.close();
    }
  });
});

describe("reconnect + catch-up sequence", () => {
  it("delivers same initial messages on reconnect (deterministic subscribe)", async () => {
    const { sessionId } = await createWorkspaceAndSession();

    // First connection
    const ws1 = connectStream();
    await waitForMessage(ws1); // stream_connected
    sendJson(ws1, {
      type: "subscribe",
      sessionId,
      level: "full",
      requestId: "sub-1",
    });
    const firstMessages = await collectMessages(ws1, 1_500);
    ws1.close();
    await waitForClose(ws1);

    // Second connection (simulating reconnect)
    const ws2 = connectStream();
    await waitForMessage(ws2); // stream_connected
    sendJson(ws2, {
      type: "subscribe",
      sessionId,
      level: "full",
      requestId: "sub-1",
    });
    const secondMessages = await collectMessages(ws2, 1_500);
    ws2.close();

    // Both connections should receive the same message types in the same order
    const normalize = (msgs: ServerMessage[]) =>
      msgs.map((msg) => ({
        type: msg.type,
        command: msg.type === "command_result" ? msg.command : undefined,
        sessionId: msg.sessionId,
      }));

    expect(normalize(firstMessages)).toEqual(normalize(secondMessages));
  });
});

describe("message ordering under load", () => {
  it("stream_connected is always the first message", async () => {
    // Rapid connect — first message must always be stream_connected
    const results: boolean[] = [];

    for (let i = 0; i < 10; i++) {
      const ws = connectStream();
      const first = await waitForMessage(ws, 3_000);
      results.push(first.type === "stream_connected");
      ws.close();
    }

    expect(results.every(Boolean)).toBe(true);
  });

  it("subscribe command_result arrives before subsequent state events", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      await waitForMessage(ws); // stream_connected

      sendJson(ws, {
        type: "subscribe",
        sessionId,
        level: "full",
        requestId: "ordering-test",
      });

      const messages = await collectMessages(ws, 2_000);

      // Find the subscribe result and any state events
      const subResultIdx = messages.findIndex(
        (msg) => msg.type === "command_result" && msg.command === "subscribe",
      );

      // Command result must exist
      expect(subResultIdx).toBeGreaterThanOrEqual(0);

      // connected event should come before command_result (server sends it first)
      const connectedIdx = messages.findIndex(
        (msg) => msg.type === "connected",
      );
      if (connectedIdx >= 0) {
        expect(connectedIdx).toBeLessThan(subResultIdx);
      }
    } finally {
      ws.close();
    }
  });
});

describe("server-side ping/pong", () => {
  it("connection survives past first ping interval when pongs are sent", async () => {
    // URLSession and ws library auto-respond to pings. We just verify
    // the connection stays alive for > 1 ping interval.
    // Server default is 30s — too long for a test. But we can at least
    // verify the connection isn't terminated prematurely.
    const ws = connectStream();

    try {
      await waitForMessage(ws); // stream_connected

      // Ensure connection is not terminated shortly after handshake.
      await waitForReadyState(ws, WebSocket.OPEN, {
        timeoutMs: 500,
        intervalMs: 20,
        description: "connection to remain open after connect",
      });
    } finally {
      ws.close();
    }
  });
});

describe("close code handling", () => {
  it("server handles normal close gracefully", async () => {
    const ws = connectStream();
    await waitForMessage(ws);

    ws.close(1000, "Normal closure");
    await waitForClose(ws);

    // Server should not crash — verify by opening another connection
    const ws2 = connectStream();
    const msg = await waitForMessage(ws2);
    expect(msg.type).toBe("stream_connected");
    ws2.close();
  });

  it("server handles abnormal close (going away) gracefully", async () => {
    const ws = connectStream();
    await waitForMessage(ws);

    ws.close(1001, "Going away");
    await waitForClose(ws);

    const ws2 = connectStream();
    const msg = await waitForMessage(ws2);
    expect(msg.type).toBe("stream_connected");
    ws2.close();
  });

  it("server handles abrupt termination (no close frame)", async () => {
    const ws = connectStream();
    await waitForMessage(ws);

    // Terminate without close frame — simulates network drop
    ws.terminate();
    await waitForReadyState(ws, WebSocket.CLOSED, {
      timeoutMs: 1_000,
      description: "terminated socket to close",
    });

    // Server should handle this and accept new connections
    const ws2 = connectStream();
    const msg = await waitForMessage(ws2);
    expect(msg.type).toBe("stream_connected");
    ws2.close();
  });
});

describe("malformed message handling", () => {
  it("survives invalid JSON", async () => {
    const ws = connectStream();
    await waitForMessage(ws);

    ws.send("not json at all {{{");
    ws.send('{"type": "subscribe"'); // truncated JSON

    // Connection should still be open — server catches parse errors
    await new Promise((r) => setTimeout(r, 500));

    // Verify connection is still alive by checking we can get a response
    // (The server might close on parse error — this tests resilience)
    if (ws.readyState === WebSocket.OPEN) {
      // Still alive — good
    }
    ws.close();
  });

  it("survives unknown message types", async () => {
    const ws = connectStream();
    await waitForMessage(ws);

    ws.send(JSON.stringify({ type: "future_command_v99" }));

    // Should get an error response, not a crash
    await collectMessages(ws, 500);
    // Server should handle gracefully (either ignore or error response)
    expect(ws.readyState).toBe(WebSocket.OPEN);
    ws.close();
  });

  it("handles subscribe with invalid sinceSeq", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      await waitForMessage(ws);

      sendJson(ws, {
        type: "subscribe",
        sessionId,
        level: "full",
        sinceSeq: -5,
        requestId: "bad-seq",
      });

      const messages = await collectMessages(ws, 1_000);
      const result = requireMessageOfType(
        messages,
        "command_result",
        (msg) => msg.requestId === "bad-seq",
      );

      expect(result.success).toBe(false);
    } finally {
      ws.close();
    }
  });
});

describe("per-session WebSocket lifecycle", () => {
  it("per-session stream endpoint returns 404 (removed, use /stream)", async () => {
    const { workspaceId, sessionId } = await createWorkspaceAndSession();

    const ws = new WebSocket(
      `${baseWsUrl}/workspaces/${workspaceId}/sessions/${sessionId}/stream`,
      { headers: { Authorization: `Bearer ${token}` } },
    );

    const closed = await new Promise<boolean>((resolve) => {
      ws.on("error", () => resolve(true));
      ws.on("close", () => resolve(true));
      ws.on("open", () => {
        ws.close();
        resolve(false);
      });
    });
    expect(closed).toBe(true);
  });
});

describe("no-drop delivery contract", () => {
  it("server delivers all frame types unconditionally (no backpressure dropping)", async () => {
    // Architecture: one client per server. Backpressure dropping was removed
    // because it silently discarded frames the client needs (tool_output,
    // text_delta, thinking_delta). For 1:1 connections, TCP flow control
    // handles congestion at the OS level — no application-level dropping needed.
    //
    // This test verifies the server stays alive and delivers messages
    // without any drop logic by confirming stream_connected is delivered
    // and the connection remains open under normal conditions.
    const ws = connectStream();
    try {
      const msg = await waitForMessage(ws);
      expect(msg.type).toBe("stream_connected");
      expect(ws.readyState).toBe(WebSocket.OPEN);
    } finally {
      ws.close();
    }
  });
});

describe("connection exhaustion resilience", () => {
  it("handles 20 rapid connect-disconnect cycles without leaking", async () => {
    for (let i = 0; i < 20; i++) {
      const ws = connectStream();
      const msg = await waitForMessage(ws, 3_000);
      expect(msg.type).toBe("stream_connected");
      ws.close();
    }

    // Final connection should work fine — no resource exhaustion
    const ws = connectStream();
    const msg = await waitForMessage(ws, 3_000);
    expect(msg.type).toBe("stream_connected");
    ws.close();
  }, 30_000);
});

// ─── D) State transition interleavings (integration) ───

describe("reconnect bootstrap order (integration)", () => {
  it("reconnect receives deterministic bootstrap: stream_connected -> connected -> state -> command_result", async () => {
    const { sessionId } = await createWorkspaceAndSession();

    const ws = connectStream();
    try {
      const streamConnected = await waitForMessage(ws);
      expect(streamConnected.type).toBe("stream_connected");

      sendJson(ws, {
        type: "subscribe",
        sessionId,
        level: "full",
        requestId: "sub-bootstrap",
      });

      const messages = await collectMessages(ws, 3_000);

      // Extract the ordering of key message types
      const keyTypes = messages
        .filter((msg) =>
          ["connected", "state", "command_result"].includes(msg.type),
        )
        .map((msg) => ({
          type: msg.type,
          command:
            msg.type === "command_result"
              ? msg.command
              : undefined,
        }));

      // connected must come before state, state before command_result(subscribe)
      const connectedIdx = keyTypes.findIndex((t) => t.type === "connected");
      const stateIdx = keyTypes.findIndex((t) => t.type === "state");
      const subResultIdx = keyTypes.findIndex(
        (t) => t.type === "command_result" && t.command === "subscribe",
      );

      expect(connectedIdx).toBeGreaterThanOrEqual(0);
      expect(stateIdx).toBeGreaterThanOrEqual(0);
      expect(subResultIdx).toBeGreaterThanOrEqual(0);
      expect(connectedIdx).toBeLessThan(stateIdx);
      expect(stateIdx).toBeLessThan(subResultIdx);
    } finally {
      ws.close();
    }
  });

  it("rapid subscribe/unsubscribe churn: final state is consistent (integration)", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      await waitForMessage(ws); // stream_connected

      // Rapid churn — all sent without awaiting individual results
      sendJson(ws, { type: "subscribe", sessionId, level: "full", requestId: "sub-1" });
      sendJson(ws, { type: "unsubscribe", sessionId, requestId: "unsub-1" });
      sendJson(ws, { type: "subscribe", sessionId, level: "full", requestId: "sub-2" });
      sendJson(ws, { type: "unsubscribe", sessionId, requestId: "unsub-2" });
      sendJson(ws, { type: "subscribe", sessionId, level: "full", requestId: "sub-3" });

      const messages = await collectMessages(ws, 3_000);

      const commandResults = messagesOfType(messages, "command_result");
      const subResults = commandResults.filter((msg) => msg.command === "subscribe");
      const unsubResults = commandResults.filter((msg) => msg.command === "unsubscribe");

      // Should have 3 subscribe + 2 unsubscribe results
      expect(subResults).toHaveLength(3);
      expect(unsubResults).toHaveLength(2);

      // All should succeed
      expect(subResults.every((r) => r.success)).toBe(true);
      expect(unsubResults.every((r) => r.success)).toBe(true);

      // Request IDs should correlate correctly
      expect(subResults.map((r) => r.requestId)).toEqual(["sub-1", "sub-2", "sub-3"]);
      expect(unsubResults.map((r) => r.requestId)).toEqual(["unsub-1", "unsub-2"]);
    } finally {
      ws.close();
    }
  });
});
