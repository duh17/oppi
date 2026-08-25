import { writeFileSync } from "node:fs";
import { Agent as HttpsAgent, request as httpsRequest } from "node:https";
import { performance } from "node:perf_hooks";
import { connect as tlsConnect } from "node:tls";

import WebSocket from "ws";

import {
  COLD_SAMPLES,
  RECONNECT_SAMPLES,
  TRANSFER_SAMPLES,
  TRANSFER_SIZES,
  WARM_REST_SAMPLES,
  WEBSOCKET_SAMPLES,
  summarize,
  type NumericSummary,
  type TimedSample,
  type TransferSample,
} from "./network-benchmark-common.js";

type HttpResponse = {
  status: number;
  headers: Record<string, string>;
  body: Buffer<ArrayBufferLike>;
  socketKey: string;
};

type RequestOptions = {
  headers?: Record<string, string>;
  body?: Buffer;
};

type Fixture = {
  workspaceId: string;
  sessionId: string;
};

type TailscaleBenchmarkResult = {
  name: "tailscaleDirect";
  transport: "https-over-tailscale";
  region: string;
  serverVersion: string;
  topology: {
    description: string;
    directPathRequired: true;
    certificateValidation: "disabled-for-ephemeral-self-signed-benchmark";
  };
  raw: {
    coldConnection: TimedSample[];
    warmRest: TimedSample[];
    websocketRtt: TimedSample[];
    reconnect: TimedSample[];
    transfers: TransferSample[];
  };
  summaries: {
    coldConnectionMs: NumericSummary;
    warmRestMs: NumericSummary;
    websocketRttMs: NumericSummary;
    reconnectMs: NumericSummary;
    transfers: Record<string, NumericSummary>;
  };
};

const host = process.env.TAILSCALE_BENCH_TARGET;
const token = process.env.TAILSCALE_BENCH_TOKEN;
const port = Number(process.env.TAILSCALE_BENCH_PORT);
const workspaceDir = process.env.TAILSCALE_BENCH_WORKSPACE_DIR;
const serverVersion = process.env.TAILSCALE_BENCH_SERVER_VERSION ?? "unknown";
const region = process.env.TAILSCALE_BENCH_REGION ?? "region-withheld";
const outputPath = process.env.TAILSCALE_BENCH_OUTPUT ?? "/tmp/tailscale-benchmark.json";

if (!host || !token || !workspaceDir || !Number.isInteger(port) || port <= 0) {
  throw new Error("Missing Tailscale benchmark client environment");
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`Tailscale benchmark assertion failed: ${message}`);
}

function round(value: number, digits = 6): number {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

async function request(
  agent: HttpsAgent,
  method: string,
  path: string,
  options: RequestOptions = {},
): Promise<HttpResponse> {
  return await new Promise((resolve, reject) => {
    const body = options.body ?? Buffer.alloc(0);
    let socketKey = "";
    const req = httpsRequest(
      {
        host,
        port,
        method,
        path,
        agent,
        rejectUnauthorized: false,
        servername: "oppi-benchmark.invalid",
        headers: {
          authorization: `Bearer ${token}`,
          ...(body.length > 0 ? { "content-length": String(body.length) } : {}),
          ...options.headers,
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.once("end", () => {
          const headers: Record<string, string> = {};
          for (const [key, value] of Object.entries(res.headers)) {
            if (typeof value === "string") headers[key] = value;
            else if (Array.isArray(value)) headers[key] = value.join(", ");
          }
          resolve({
            status: res.statusCode ?? 0,
            headers,
            body: Buffer.concat(chunks),
            socketKey,
          });
        });
      },
    );
    req.once("socket", (socket) => {
      socketKey = `${socket.localAddress ?? "unknown"}:${socket.localPort ?? 0}`;
    });
    req.once("error", reject);
    req.end(body);
  });
}

function responseJson(response: HttpResponse): Record<string, unknown> {
  return JSON.parse(response.body.toString("utf8")) as Record<string, unknown>;
}

async function createFixture(agent: HttpsAgent): Promise<Fixture> {
  const workspaceResponse = await request(agent, "POST", "/workspaces", {
    headers: { "content-type": "application/json" },
    body: Buffer.from(
      JSON.stringify({
        name: "public-network-benchmark",
        hostMount: workspaceDir,
        runtime: "host",
        systemPromptMode: "append",
      }),
    ),
  });
  assert(workspaceResponse.status === 201, "workspace creation succeeds");
  const workspace = responseJson(workspaceResponse).workspace as Record<string, unknown>;
  const workspaceId = String(workspace.id);

  const sessionResponse = await request(
    agent,
    "POST",
    `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
    {
      headers: { "content-type": "application/json" },
      body: Buffer.from(JSON.stringify({ model: "stub/deterministic" })),
    },
  );
  assert(sessionResponse.status === 201, "session creation succeeds");
  const session = responseJson(sessionResponse).session as Record<string, unknown>;
  return { workspaceId, sessionId: String(session.id) };
}

class BenchmarkWebSocket {
  private readonly messages: Record<string, unknown>[] = [];
  private readonly waiters: Array<() => void> = [];

  private constructor(private readonly ws: WebSocket) {
    ws.on("message", (data, isBinary) => {
      if (isBinary) return;
      this.messages.push(JSON.parse(data.toString()) as Record<string, unknown>);
      for (const waiter of this.waiters.splice(0)) waiter();
    });
  }

  static async open(path: string): Promise<BenchmarkWebSocket> {
    const ws = new WebSocket(`wss://${host}:${port}${path}`, {
      headers: { authorization: `Bearer ${token}` },
      rejectUnauthorized: false,
      servername: "oppi-benchmark.invalid",
      perMessageDeflate: false,
    });
    const client = new BenchmarkWebSocket(ws);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", resolve);
      ws.once("error", reject);
    });
    return client;
  }

  async sendJson(value: Record<string, unknown>): Promise<void> {
    await new Promise<void>((resolve, reject) =>
      this.ws.send(JSON.stringify(value), (error) => (error ? reject(error) : resolve())),
    );
  }

  async waitForType(type: string, timeoutMs = 30_000): Promise<Record<string, unknown>> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.messages.findIndex((message) => message.type === type);
      if (index >= 0) return this.messages.splice(index, 1)[0];
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 25).unref?.();
      });
    }
    throw new Error(`Timed out waiting for WebSocket message type ${type}`);
  }

  async close(): Promise<void> {
    if (this.ws.readyState === WebSocket.CLOSED) return;
    await new Promise<void>((resolve) => {
      this.ws.once("close", () => resolve());
      this.ws.close(1000);
      setTimeout(() => {
        this.ws.terminate();
        resolve();
      }, 1_000).unref?.();
    });
  }
}

async function openReadyWebSocket(path: string): Promise<BenchmarkWebSocket> {
  const ws = await BenchmarkWebSocket.open(path);
  await ws.waitForType("stream_connected");
  await ws.waitForType("connected", 60_000);
  await ws.waitForType("state", 60_000);
  return ws;
}

async function coldConnectionSample(sample: number): Promise<TimedSample> {
  const startedAt = performance.now();
  const socket = tlsConnect({
    host,
    port,
    rejectUnauthorized: false,
    servername: "oppi-benchmark.invalid",
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("secureConnect", resolve);
    socket.once("error", reject);
  });
  const durationMs = performance.now() - startedAt;

  socket.write(
    `GET /me HTTP/1.1\r\nHost: oppi-benchmark.invalid\r\nAuthorization: Bearer ${token}\r\nConnection: close\r\n\r\n`,
  );
  const response = await new Promise<Buffer>((resolve, reject) => {
    const chunks: Buffer[] = [];
    socket.on("data", (chunk: Buffer) => chunks.push(chunk));
    socket.once("end", () => resolve(Buffer.concat(chunks)));
    socket.once("error", reject);
  });
  assert(
    response.subarray(0, 32).toString("latin1").includes(" 200 "),
    `cold sample ${sample} carries authenticated traffic`,
  );
  socket.destroy();
  return { sample, durationMs: round(durationMs) };
}

async function download(
  agent: HttpsAgent,
  path: string,
): Promise<{ status: number; bytes: number }> {
  return await new Promise((resolve, reject) => {
    const req = httpsRequest(
      {
        host,
        port,
        path,
        method: "GET",
        agent,
        rejectUnauthorized: false,
        servername: "oppi-benchmark.invalid",
        headers: { authorization: `Bearer ${token}` },
      },
      (res) => {
        let bytes = 0;
        res.on("data", (chunk: Buffer) => {
          bytes += chunk.length;
        });
        res.once("end", () => resolve({ status: res.statusCode ?? 0, bytes }));
      },
    );
    req.once("error", reject);
    req.end();
  });
}

function summarizeTransfers(samples: TransferSample[]): Record<string, NumericSummary> {
  const summaries: Record<string, NumericSummary> = {};
  for (const direction of ["upload", "download"] as const) {
    for (const sizeBytes of TRANSFER_SIZES) {
      const matching = samples.filter(
        (sample) => sample.direction === direction && sample.sizeBytes === sizeBytes,
      );
      assert(matching.length === TRANSFER_SAMPLES, `${direction} ${sizeBytes} sample count`);
      summaries[`${direction}-${sizeBytes}`] = summarize(
        matching.map((sample) => sample.throughputMbps),
      );
    }
  }
  return summaries;
}

async function main(): Promise<void> {
  const coldConnection: TimedSample[] = [];
  for (let sample = 1; sample <= COLD_SAMPLES; sample += 1) {
    coldConnection.push(await coldConnectionSample(sample));
  }

  const agent = new HttpsAgent({
    keepAlive: true,
    maxSockets: 1,
    maxFreeSockets: 1,
    rejectUnauthorized: false,
  });
  const fixture = await createFixture(agent);

  const seed = await request(agent, "GET", "/me");
  assert(seed.status === 200, "warm seed succeeds");
  const warmSocketKey = seed.socketKey;
  const warmRest: TimedSample[] = [];
  for (let sample = 1; sample <= WARM_REST_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    const response = await request(agent, "GET", "/me");
    const durationMs = performance.now() - startedAt;
    assert(response.status === 200, `warm /me sample ${sample} succeeds`);
    assert(response.socketKey === warmSocketKey, `warm /me sample ${sample} reuses TLS socket`);
    warmRest.push({ sample, durationMs: round(durationMs) });
  }

  const wsPath = `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/stream`;
  const ws = await openReadyWebSocket(wsPath);
  const websocketRtt: TimedSample[] = [];
  for (let sample = 1; sample <= WEBSOCKET_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    await ws.sendJson({
      type: "get_state",
      sessionId: fixture.sessionId,
      requestId: `tailscale-${sample}`,
    });
    await ws.waitForType("state");
    websocketRtt.push({ sample, durationMs: round(performance.now() - startedAt) });
  }
  await ws.close();

  const reconnect: TimedSample[] = [];
  for (let sample = 1; sample <= RECONNECT_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    const candidate = await BenchmarkWebSocket.open(wsPath);
    await candidate.waitForType("stream_connected");
    await candidate.waitForType("connected", 60_000);
    reconnect.push({ sample, durationMs: round(performance.now() - startedAt) });
    await candidate.close();
  }

  const transfers: TransferSample[] = [];
  for (const sizeBytes of TRANSFER_SIZES) {
    const payload = Buffer.alloc(sizeBytes, 0xa5);
    for (let sample = 1; sample <= TRANSFER_SAMPLES; sample += 1) {
      const create = await request(
        agent,
        "POST",
        `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/attachments`,
        {
          headers: { "content-type": "application/json" },
          body: Buffer.from(
            JSON.stringify({
              name: `tailscale-${sizeBytes}-${sample}.bin`,
              mimeType: "application/octet-stream",
              sizeBytes,
              purpose: "chat_attachment",
            }),
          ),
        },
      );
      assert(create.status === 201, `upload record ${sizeBytes}/${sample} succeeds`);
      const uploadId = String(responseJson(create).uploadId);
      const startedAt = performance.now();
      const uploaded = await request(
        agent,
        "PUT",
        `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/attachments/${uploadId}/content`,
        { headers: { "content-type": "application/octet-stream" }, body: payload },
      );
      const durationMs = performance.now() - startedAt;
      assert(uploaded.status === 200, `upload ${sizeBytes}/${sample} succeeds`);
      transfers.push({
        sample,
        direction: "upload",
        sizeBytes,
        durationMs: round(durationMs),
        throughputMbps: round((sizeBytes * 8) / durationMs / 1000),
      });
    }

    const sizeMiB = sizeBytes / 1024 / 1024;
    for (let sample = 1; sample <= TRANSFER_SAMPLES; sample += 1) {
      const startedAt = performance.now();
      const result = await download(
        agent,
        `/workspaces/${fixture.workspaceId}/raw/benchmark-${sizeMiB}m.mp4`,
      );
      const durationMs = performance.now() - startedAt;
      assert(result.status === 200, `download ${sizeBytes}/${sample} succeeds`);
      assert(result.bytes === sizeBytes, `download ${sizeBytes}/${sample} preserves byte count`);
      transfers.push({
        sample,
        direction: "download",
        sizeBytes,
        durationMs: round(durationMs),
        throughputMbps: round((sizeBytes * 8) / durationMs / 1000),
      });
    }
  }
  agent.destroy();

  assert(coldConnection.length === COLD_SAMPLES, "cold sample count");
  assert(warmRest.length === WARM_REST_SAMPLES, "warm REST sample count");
  assert(websocketRtt.length === WEBSOCKET_SAMPLES, "WebSocket sample count");
  assert(reconnect.length === RECONNECT_SAMPLES, "reconnect sample count");
  assert(
    transfers.length === TRANSFER_SIZES.length * 2 * TRANSFER_SAMPLES,
    "transfer sample count",
  );

  const result: TailscaleBenchmarkResult = {
    name: "tailscaleDirect",
    transport: "https-over-tailscale",
    region,
    serverVersion,
    topology: {
      description:
        "Dedicated Oppi server on a separate macOS peer over a verified direct Tailscale path",
      directPathRequired: true,
      certificateValidation: "disabled-for-ephemeral-self-signed-benchmark",
    },
    raw: { coldConnection, warmRest, websocketRtt, reconnect, transfers },
    summaries: {
      coldConnectionMs: summarize(coldConnection.map((sample) => sample.durationMs)),
      warmRestMs: summarize(warmRest.map((sample) => sample.durationMs)),
      websocketRttMs: summarize(websocketRtt.map((sample) => sample.durationMs)),
      reconnectMs: summarize(reconnect.map((sample) => sample.durationMs)),
      transfers: summarizeTransfers(transfers),
    },
  };
  writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
  process.stdout.write(`${JSON.stringify({ event: "tailscale_benchmark.client_complete" })}\n`);
}

await main();
