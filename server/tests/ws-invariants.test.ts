import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type RawData, WebSocket } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { ClientMessage, ServerMessage } from "../src/types.js";
import {
  collectMessages,
  connectStream as connectHarnessStream,
  sendClientMessage,
  waitForMessage,
} from "./harness/ws-harness.js";
import { generateLifecycleProgram } from "./harness/property-generators.js";

let dataDir: string;
let storage: Storage;
let server: Server;
let baseWsUrl: string;
let token: string;

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-ws-invariants-"));
  storage = new Storage(dataDir);

  const randomPort = 35_000 + Math.floor(Math.random() * 10_000);
  storage.updateConfig({
    host: "127.0.0.1",
    port: randomPort,
  });

  token = storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseWsUrl = `ws://127.0.0.1:${server.port}`;
}, 15_000);

afterAll(async () => {
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 10_000);

function connectStream(): WebSocket {
  return connectHarnessStream(baseWsUrl, token);
}

function send(ws: WebSocket, message: ClientMessage): void {
  sendClientMessage(ws, message);
}

async function createWorkspaceAndSession(): Promise<{ workspaceId: string; sessionId: string }> {
  const baseUrl = `http://127.0.0.1:${server.port}`;
  const headers = {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
  };

  const workspaceResponse = await fetch(`${baseUrl}/workspaces`, {
    method: "POST",
    headers,
    body: JSON.stringify({ name: `inv-${Date.now()}`, skills: [] }),
  });
  const { workspace } = (await workspaceResponse.json()) as { workspace: { id: string } };

  const sessionResponse = await fetch(`${baseUrl}/workspaces/${workspace.id}/sessions`, {
    method: "POST",
    headers,
    body: JSON.stringify({ model: "anthropic/claude-sonnet-4-20250514" }),
  });
  const { session } = (await sessionResponse.json()) as { session: { id: string } };

  return { workspaceId: workspace.id, sessionId: session.id };
}

function parseServerMessage(data: RawData): ServerMessage {
  if (typeof data === "string") {
    return JSON.parse(data) as ServerMessage;
  }
  if (Buffer.isBuffer(data)) {
    return JSON.parse(data.toString("utf8")) as ServerMessage;
  }
  if (Array.isArray(data)) {
    return JSON.parse(Buffer.concat(data).toString("utf8")) as ServerMessage;
  }
  return JSON.parse(Buffer.from(data).toString("utf8")) as ServerMessage;
}

async function waitForNextSessionMessage(
  ws: WebSocket,
  sessionId: string,
  timeoutMs = 1_500,
): Promise<ServerMessage> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.off("message", onMessage);
      ws.off("error", onError);
      reject(new Error(`Timed out waiting for session ${sessionId} message`));
    }, timeoutMs);

    const onMessage = (raw: RawData): void => {
      const message = parseServerMessage(raw);
      if (message.sessionId !== sessionId) {
        return;
      }

      clearTimeout(timer);
      ws.off("message", onMessage);
      ws.off("error", onError);
      resolve(message);
    };

    const onError = (error: Error): void => {
      clearTimeout(timer);
      ws.off("message", onMessage);
      reject(error);
    };

    ws.on("message", onMessage);
    ws.once("error", onError);
  });
}

describe("websocket invariants", () => {
  it("keeps command_result correlation and success invariants across seeded lifecycle programs", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const seeds = [11, 23, 47];

    for (const seed of seeds) {
      const ws = connectStream();
      try {
        const first = await waitForMessage(ws);
        expect(first.type).toBe("stream_connected");

        const program = generateLifecycleProgram({
          seed,
          sessionId,
          steps: 10,
        });

        for (const command of program) {
          send(ws, command);
        }

        const messages = await collectMessages(ws, 1_800);
        const commandResults = messages.filter((message) => message.type === "command_result");

        expect(commandResults).toHaveLength(program.length);

        for (const command of program) {
          const matches = commandResults.filter((result) => result.requestId === command.requestId);
          expect(matches).toHaveLength(1);
          expect(matches[0]?.command).toBe(command.type);
          expect(matches[0]?.success).toBe(true);
        }
      } finally {
        ws.close();
      }
    }
  }, 20_000);

  it("preserves subscribe bootstrap ordering for full subscriptions", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      const first = await waitForMessage(ws);
      expect(first.type).toBe("stream_connected");

      send(ws, {
        type: "subscribe",
        sessionId,
        level: "full",
        requestId: "ordered-subscribe",
      });

      const messages = await collectMessages(ws, 1_500);
      const connectedIndex = messages.findIndex((message) => message.type === "connected");
      const stateIndex = messages.findIndex((message) => message.type === "state");
      const commandResultIndex = messages.findIndex(
        (message) =>
          message.type === "command_result" &&
          message.command === "subscribe" &&
          message.requestId === "ordered-subscribe",
      );

      expect(connectedIndex).toBeGreaterThanOrEqual(0);
      expect(stateIndex).toBeGreaterThanOrEqual(0);
      expect(commandResultIndex).toBeGreaterThanOrEqual(0);
      expect(connectedIndex).toBeLessThan(stateIndex);
      expect(stateIndex).toBeLessThan(commandResultIndex);
    } finally {
      ws.close();
    }
  });

  it("keeps unsubscribe idempotent and enforces final full-subscribe lifecycle", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      await waitForMessage(ws);

      const commands: ClientMessage[] = [
        { type: "unsubscribe", sessionId, requestId: "u-1" },
        { type: "subscribe", sessionId, level: "full", requestId: "s-1" },
        { type: "unsubscribe", sessionId, requestId: "u-2" },
        { type: "unsubscribe", sessionId, requestId: "u-3" },
      ];

      for (const command of commands) {
        send(ws, command);
      }

      const messages = await collectMessages(ws, 1_500);
      const results = messages.filter(
        (message): message is Extract<ServerMessage, { type: "command_result" }> =>
          message.type === "command_result",
      );

      expect(results).toHaveLength(commands.length);
      expect(
        results
          .filter((result) => result.command === "unsubscribe")
          .every((result) => result.success),
      ).toBe(true);

      send(ws, {
        type: "get_state",
        sessionId,
        requestId: "state-after-unsub",
      });

      const denied = await waitForNextSessionMessage(ws, sessionId);
      expect(denied.type).toBe("error");
      if (denied.type === "error") {
        expect(denied.error).toContain("not subscribed at level=full");
      }
    } finally {
      ws.close();
    }
  });

  it("correlates mixed subscribe command_result outcomes by requestId", async () => {
    const { sessionId } = await createWorkspaceAndSession();
    const ws = connectStream();

    try {
      await waitForMessage(ws);

      const commands: ClientMessage[] = [
        {
          type: "subscribe",
          sessionId,
          level: "full",
          requestId: "sub-ok",
        },
        {
          type: "subscribe",
          sessionId: "MISSING_SESSION",
          level: "full",
          requestId: "sub-missing",
        },
        {
          type: "subscribe",
          sessionId,
          level: "full",
          sinceSeq: -1,
          requestId: "sub-bad-since",
        },
      ];

      for (const command of commands) {
        send(ws, command);
      }

      const messages = await collectMessages(ws, 1_800);
      const results = messages.filter(
        (message): message is Extract<ServerMessage, { type: "command_result" }> =>
          message.type === "command_result",
      );

      const byRequestId = new Map(results.map((result) => [result.requestId, result]));

      expect(byRequestId.get("sub-ok")?.success).toBe(true);
      expect(byRequestId.get("sub-ok")?.command).toBe("subscribe");

      expect(byRequestId.get("sub-missing")?.success).toBe(false);
      expect(byRequestId.get("sub-missing")?.error).toContain("Session not found");

      expect(byRequestId.get("sub-bad-since")?.success).toBe(false);
      expect(byRequestId.get("sub-bad-since")?.error).toContain("sinceSeq must be a non-negative integer");
    } finally {
      ws.close();
    }
  });
});
