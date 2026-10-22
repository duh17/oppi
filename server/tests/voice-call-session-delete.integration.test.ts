/**
 * Deleting a session through the real server ends its Live Voice call and removes the
 * session's call records from voice-calls.json, leaving other sessions' calls alone.
 */
import { generateKeyPairSync } from "node:crypto";
import { createServer, type Server as HttpServer } from "node:http";
import type { AddressInfo } from "node:net";
import { request as httpsRequest } from "node:https";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket, type RawData } from "ws";

import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { voiceCallStorePath } from "../src/voice-call-store.js";
import type { DevicePublicKey } from "../src/types.js";

function makeDeviceKey(): DevicePublicKey {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

function enroll(storage: Storage): { id: string; token: string } {
  const pairingToken = storage.issuePairingToken(60_000);
  const result = storage.enrollViaPairing(pairingToken, {
    publicKey: makeDeviceKey(),
    name: "Expiry rotation test device",
  });
  if (!result) throw new Error("enrollment failed");
  return { id: result.deviceId, token: result.accessToken };
}

class WsProbe {
  readonly opened: Promise<void>;
  readonly closed: Promise<{ code: number; reason: string }>;
  private frames: Record<string, unknown>[] = [];

  constructor(readonly ws: WebSocket) {
    this.opened = new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        ws.terminate();
        reject(new Error("timed out waiting for WebSocket open"));
      }, 15_000);
      ws.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      ws.once("unexpected-response", (_req, res) => {
        clearTimeout(timer);
        reject(new Error(`WS upgrade failed with HTTP ${res.statusCode ?? "unknown"}`));
      });
      ws.once("error", (error: Error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
    this.closed = new Promise<{ code: number; reason: string }>((resolve) => {
      ws.once("close", (code, reasonBuf) => {
        const reason =
          typeof reasonBuf === "string"
            ? reasonBuf
            : Buffer.isBuffer(reasonBuf)
              ? reasonBuf.toString("utf8")
              : "";
        resolve({ code, reason });
      });
    });
    ws.on("message", (data) => {
      this.frames.push(JSON.parse(rawDataToString(data)) as Record<string, unknown>);
    });
  }

  async waitForFrame(
    type: string,
    fields: Record<string, unknown> = {},
    timeoutMs = 10_000,
  ): Promise<Record<string, unknown>> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const frame = this.frames.find(
        (candidate) =>
          candidate["type"] === type &&
          Object.entries(fields).every(([key, value]) => candidate[key] === value),
      );
      if (frame) return frame;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error(`timed out waiting for frame ${type}`);
  }
}

function rawDataToString(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  return Buffer.from(data).toString("utf8");
}

let dataDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let probes: WsProbe[] = [];
const sttServers: HttpServer[] = [];

beforeEach(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-voice-delete-"));
  storage = new Storage(dataDir);
  storage.updateConfig({ port: 0, host: "127.0.0.1", tls: { mode: "self-signed" } });
  storage.ensurePaired();
  server = new Server(storage);
  await server.start();
  baseUrl = `https://127.0.0.1:${server.port}`;
}, 30_000);

afterEach(async () => {
  for (const probe of probes) probe.ws.terminate();
  probes = [];
  for (const stt of sttServers.splice(0)) stt.close();
  await server.stop().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}, 45_000);

async function connectStream(
  token: string,
  path = "/app/events/stream",
  readyFrame = "app_events_connected",
): Promise<WsProbe> {
  const wsUrl = `${baseUrl.replace(/^https:/, "wss:")}${path}`;
  const probe = new WsProbe(
    new WebSocket(wsUrl, {
      headers: { Authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
    }),
  );
  probes.push(probe);
  await probe.opened;
  await probe.waitForFrame(readyFrame);
  return probe;
}

/** Streaming STT that accepts a session and hears nothing, enough for a Live Voice call to run. */
async function silentStreamingStt(): Promise<string> {
  const stt = createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(req.method === "POST" ? { session_id: "stt-1" } : { text: "" }));
    });
  });
  sttServers.push(stt);
  await new Promise<void>((resolve) => stt.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(stt.address() as AddressInfo).port}`;
}

function networkRequest(
  method: "POST" | "DELETE",
  path: string,
  token: string,
  body?: unknown,
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const req = httpsRequest(
      `${baseUrl}${path}`,
      {
        method,
        rejectUnauthorized: false,
        headers: {
          Authorization: `Bearer ${token}`,
          ...(payload
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
            : {}),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk: Buffer) => (data += chunk.toString("utf8")));
        res.on("end", () => {
          let parsed: unknown = data;
          try {
            parsed = JSON.parse(data);
          } catch {
            // Keep the raw body for non-JSON responses.
          }
          resolve({ status: res.statusCode ?? 0, body: parsed });
        });
      },
    );
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

function storedCalls(): Array<{ callId: string; controlSessionId: string; lifecycle: string }> {
  const path = voiceCallStorePath(dataDir);
  if (!existsSync(path)) return [];
  return (
    JSON.parse(readFileSync(path, "utf8")) as {
      calls: Array<{ callId: string; controlSessionId: string; lifecycle: string }>;
    }
  ).calls;
}

describe("deleting a session that has a Live Voice call", { timeout: 60_000 }, () => {
  it("ends the call, releases its media, and removes only that session's records", async () => {
    storage.updateConfig({
      asr: { sttEndpoint: await silentStreamingStt(), liveVoiceBackend: "yuwp" },
    });
    const device = enroll(storage);
    const workspace = storage.createWorkspace({ name: "Voice", hostMount: dataDir });
    const sessionIds: string[] = [];
    for (let i = 0; i < 2; i += 1) {
      const created = await networkRequest(
        "POST",
        `/workspaces/${workspace.id}/sessions`,
        device.token,
        {},
      );
      sessionIds.push((created.body as { session: { id: string } }).session.id);
    }
    const [deletedId, keptId] = sessionIds as [string, string];

    const calls: Record<string, WsProbe> = {};
    for (const sessionId of sessionIds) {
      const call = await connectStream(
        device.token,
        `/workspaces/${workspace.id}/sessions/${sessionId}/stream`,
        "connected",
      );
      call.ws.send(
        JSON.stringify({
          type: "voice_call_start",
          clientCallId: `c-${sessionId}`,
          requestId: "s",
        }),
      );
      await call.waitForFrame("command_result", { requestId: "s", success: true });
      calls[sessionId] = call;
    }
    expect(
      storedCalls()
        .map((call) => call.controlSessionId)
        .sort(),
    ).toEqual([...sessionIds].sort());

    const deleted = await networkRequest(
      "DELETE",
      `/workspaces/${workspace.id}/sessions/${deletedId}`,
      device.token,
    );
    expect(deleted.status).toBe(200);

    // The caller on the deleted session is told the call ended; the other call is untouched.
    expect(
      await (calls[deletedId] as WsProbe).waitForFrame("voice_call_state", { lifecycle: "ended" }),
    ).toBeDefined();
    expect(storedCalls().map((call) => call.controlSessionId)).toEqual([keptId]);
    expect(storedCalls()[0]?.lifecycle).toBe("active");
  });
});
