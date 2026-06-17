import { EventEmitter } from "node:events";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { ServerMetricCollector } from "../src/server-metric-collector.js";

const { http2ConnectMock } = vi.hoisted(() => ({
  http2ConnectMock: vi.fn(),
}));

vi.mock("node:http2", () => ({
  connect: http2ConnectMock,
}));

import {
  APNsClient,
  NoopAPNsClient,
  createPushClient,
  redactTokenForLog,
  type APNsConfig,
} from "../src/push.js";

type RequestHeaders = Record<string, string | number>;

type ResponseMode =
  | {
      kind: "response";
      status: number;
      body?: string;
    }
  | {
      kind: "request-error";
      error: Error;
    };

class MockAPNsRequest extends EventEmitter {
  body = "";
  readonly setEncoding = vi.fn((_encoding: BufferEncoding) => {});
  readonly end = vi.fn((chunk?: string | Uint8Array) => {
    if (chunk !== undefined) {
      this.body += chunk.toString();
    }

    queueMicrotask(() => {
      if (this.mode.kind === "request-error") {
        this.emit("error", this.mode.error);
        return;
      }

      this.emit("response", { ":status": this.mode.status });
      if (this.mode.body) {
        this.emit("data", this.mode.body);
      }
      this.emit("end");
    });
  });

  constructor(private readonly mode: ResponseMode) {
    super();
  }
}

class MockAPNsConnection extends EventEmitter {
  closed = false;
  destroyed = false;
  readonly requests: Array<{ headers: RequestHeaders; request: MockAPNsRequest }> = [];
  readonly close = vi.fn(() => {
    this.closed = true;
    this.emit("close");
  });
  readonly request = vi.fn((headers: RequestHeaders) => {
    const mode = this.responseModes.shift() ?? { kind: "response", status: 200 };
    const request = new MockAPNsRequest(mode);
    this.requests.push({ headers, request });
    return request;
  });

  constructor(
    readonly url: string,
    private readonly responseModes: ResponseMode[],
  ) {
    super();
  }
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
  vi.restoreAllMocks();
  http2ConnectMock.mockReset();
});

function createTestConfig(overrides: Partial<APNsConfig> = {}): APNsConfig {
  const dir = mkdtempSync(join(tmpdir(), "oppi-push-test-"));
  tempDirs.push(dir);

  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const keyPath = join(dir, "AuthKey_TESTKEY.p8");
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }));

  return {
    keyPath,
    keyId: "TESTKEY",
    teamId: "TEAMID1234",
    bundleId: "works.earendil.oppi",
    ...overrides,
  };
}

function mockHttp2(responseModes: ResponseMode[]): MockAPNsConnection[] {
  const connections: MockAPNsConnection[] = [];
  http2ConnectMock.mockImplementation((url: string) => {
    const connection = new MockAPNsConnection(url, [...responseModes]);
    connections.push(connection);
    queueMicrotask(() => connection.emit("connect"));
    return connection;
  });
  return connections;
}

function mockHttp2ConnectionError(error: Error): MockAPNsConnection[] {
  const connections: MockAPNsConnection[] = [];
  http2ConnectMock.mockImplementation((url: string) => {
    const connection = new MockAPNsConnection(url, []);
    connections.push(connection);
    queueMicrotask(() => connection.emit("error", error));
    return connection;
  });
  return connections;
}

function makeMetrics(): { metrics: ServerMetricCollector; record: ReturnType<typeof vi.fn> } {
  const record = vi.fn();
  return {
    metrics: { record } as unknown as ServerMetricCollector,
    record,
  };
}

describe("push", () => {
  it("redacts device tokens by length only", () => {
    expect(redactTokenForLog("abcdef012345")).toBe("<redacted:12 chars>");
  });

  it("creates a no-op client when APNs config is absent", async () => {
    const client = createPushClient();

    expect(client).toBeInstanceOf(NoopAPNsClient);
    await expect(
      client.sendSessionEventPush("device-token", {
        sessionId: "session-1",
        event: "ended",
        reason: "done",
      }),
    ).resolves.toBe(false);
    await expect(client.sendLiveActivityUpdate("live-token", { status: "running" })).resolves.toBe(
      false,
    );
    await expect(client.endLiveActivity("live-token", { status: "done" })).resolves.toBe(false);
    expect(() => client.shutdown()).not.toThrow();
  });

  it("falls back to a no-op client when the APNs key cannot be loaded", () => {
    const client = createPushClient({
      keyPath: join(tmpdir(), "missing-apns-key.p8"),
      keyId: "TESTKEY",
      teamId: "TEAMID1234",
      bundleId: "works.earendil.oppi",
    });

    expect(client).toBeInstanceOf(NoopAPNsClient);
  });

  it("sends session-ended alerts with sandbox APNs headers and success metrics", async () => {
    const connections = mockHttp2([{ kind: "response", status: 200 }]);
    const { metrics, record } = makeMetrics();
    const client = new APNsClient(createTestConfig(), metrics);

    const result = await client.sendSessionEventPush("device-token-123", {
      sessionId: "session-1",
      sessionName: "Coverage run",
      event: "ended",
      reason: "Tests finished",
    });

    expect(result).toBe(true);
    expect(connections).toHaveLength(1);
    expect(connections[0].url).toBe("https://api.sandbox.push.apple.com");

    const sent = connections[0].requests[0];
    expect(sent.headers).toMatchObject({
      ":method": "POST",
      ":path": "/3/device/device-token-123",
      "apns-topic": "works.earendil.oppi",
      "apns-push-type": "alert",
      "apns-priority": 5,
    });
    expect(sent.headers.authorization).toMatch(/^bearer [^.]+\.[^.]+\.[^.]+$/);
    expect(JSON.parse(sent.request.body)).toEqual({
      aps: {
        alert: {
          title: "Session Ended",
          subtitle: "Coverage run",
          body: "Tests finished",
        },
        category: "SESSION_DONE",
        "interruption-level": "passive",
      },
      sessionId: "session-1",
      event: "ended",
    });
    expect(record).toHaveBeenCalledWith("server.push_send_ms", expect.any(Number), {
      push_type: "alert",
    });
    expect(record).toHaveBeenCalledWith("server.push_result", 1, {
      push_type: "alert",
      success: "true",
    });
  });

  it("sends session-error alerts with production host and active priority", async () => {
    const connections = mockHttp2([{ kind: "response", status: 200 }]);
    const client = new APNsClient(createTestConfig({ environment: "production" }));

    const result = await client.sendSessionEventPush("device-token-456", {
      sessionId: "session-2",
      event: "error",
      reason: "Agent stopped",
    });

    expect(result).toBe(true);
    expect(connections[0].url).toBe("https://api.push.apple.com");

    const sent = connections[0].requests[0];
    expect(sent.headers["apns-priority"]).toBe(10);
    expect(JSON.parse(sent.request.body)).toEqual({
      aps: {
        alert: {
          title: "Session Error",
          subtitle: "session-2",
          body: "Agent stopped",
        },
        category: "SESSION_ERROR",
        "interruption-level": "active",
        sound: "default",
      },
      sessionId: "session-2",
      event: "error",
    });
  });

  it("sends Live Activity updates with a liveactivity topic and stale date", async () => {
    const staleDate = 1_700_000_123_456;
    const connections = mockHttp2([{ kind: "response", status: 200 }]);
    const client = new APNsClient(createTestConfig());

    const result = await client.sendLiveActivityUpdate(
      "live-token-1",
      { status: "running", progress: 0.5 },
      staleDate,
      10,
    );

    expect(result).toBe(true);
    const sent = connections[0].requests[0];
    expect(sent.headers).toMatchObject({
      ":path": "/3/device/live-token-1",
      "apns-topic": "works.earendil.oppi.push-type.liveactivity",
      "apns-push-type": "liveactivity",
      "apns-priority": 10,
    });
    expect(JSON.parse(sent.request.body)).toMatchObject({
      aps: {
        event: "update",
        "content-state": { status: "running", progress: 0.5 },
        "stale-date": Math.floor(staleDate / 1000),
      },
    });
  });

  it("ends Live Activities with default dismissal and closes the APNs connection", async () => {
    const connections = mockHttp2([{ kind: "response", status: 200 }]);
    const client = new APNsClient(createTestConfig());

    const beforeDismissal = Math.floor(Date.now() / 1000) + 300;
    const result = await client.endLiveActivity("live-token-2", { status: "done" });
    const afterDismissal = Math.floor(Date.now() / 1000) + 300;

    expect(result).toBe(true);
    const sent = connections[0].requests[0];
    expect(sent.headers["apns-priority"]).toBe(10);
    const body = JSON.parse(sent.request.body);
    expect(body).toMatchObject({
      aps: {
        event: "end",
        "content-state": { status: "done" },
      },
    });
    expect(body.aps["dismissal-date"]).toBeGreaterThanOrEqual(beforeDismissal);
    expect(body.aps["dismissal-date"]).toBeLessThanOrEqual(afterDismissal);

    client.shutdown();
    expect(connections[0].close).toHaveBeenCalledTimes(1);
  });

  it("returns false and records failure metrics when APNs rejects a token", async () => {
    const connections = mockHttp2([
      { kind: "response", status: 410, body: JSON.stringify({ reason: "Unregistered" }) },
    ]);
    const { metrics, record } = makeMetrics();
    const client = new APNsClient(createTestConfig(), metrics);

    const result = await client.sendSessionEventPush("sensitive-device-token", {
      sessionId: "session-3",
      event: "ended",
      reason: "done",
    });

    expect(result).toBe(false);
    expect(connections[0].requests).toHaveLength(1);
    expect(record).toHaveBeenCalledWith("server.push_result", 1, {
      push_type: "alert",
      success: "false",
    });
  });

  it("returns false and records failure metrics when an APNs request errors", async () => {
    mockHttp2([{ kind: "request-error", error: new Error("stream reset") }]);
    const { metrics, record } = makeMetrics();
    const client = new APNsClient(createTestConfig(), metrics);

    const result = await client.sendSessionEventPush("device-token", {
      sessionId: "session-4",
      event: "ended",
      reason: "done",
    });

    expect(result).toBe(false);
    expect(record).toHaveBeenCalledWith("server.push_result", 1, {
      push_type: "alert",
      success: "false",
    });
  });

  it("reuses an open APNs connection and cached JWT between pushes", async () => {
    const connections = mockHttp2([
      { kind: "response", status: 200 },
      { kind: "response", status: 200 },
    ]);
    const client = new APNsClient(createTestConfig());

    await expect(
      client.sendSessionEventPush("device-token-1", {
        sessionId: "session-5",
        event: "ended",
        reason: "done",
      }),
    ).resolves.toBe(true);
    await expect(client.sendLiveActivityUpdate("live-token-3", { status: "running" })).resolves.toBe(
      true,
    );

    expect(http2ConnectMock).toHaveBeenCalledTimes(1);
    expect(connections[0].requests).toHaveLength(2);
    expect(connections[0].requests[1].headers.authorization).toBe(
      connections[0].requests[0].headers.authorization,
    );
  });

  it("rejects when the APNs connection fails before sending", async () => {
    const connections = mockHttp2ConnectionError(new Error("tls failed"));
    const client = new APNsClient(createTestConfig());

    await expect(
      client.sendSessionEventPush("device-token", {
        sessionId: "session-6",
        event: "ended",
        reason: "done",
      }),
    ).rejects.toThrow("tls failed");
    expect(connections[0].requests).toHaveLength(0);
  });
});
