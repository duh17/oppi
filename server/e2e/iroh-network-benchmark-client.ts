import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { lookup } from "node:dns/promises";
import { readFileSync, writeFileSync } from "node:fs";
import { request as httpRequest, Agent as HttpAgent } from "node:http";
import { connect as netConnect } from "node:net";
import { performance } from "node:perf_hooks";

import {
  Endpoint,
  EndpointAddr,
  EndpointId,
  EndpointTicket,
  type BiStream,
  type Connection,
  type RecvStream,
} from "@number0/iroh";
import WebSocket from "ws";

import { decodeIrohFrame, encodeIrohFrame } from "../dist/src/iroh-frame-codec.js";
import { encodeIrohTunnelPreface } from "../dist/src/iroh-pairing-server.js";
import {
  COLD_SAMPLES,
  IrohPathRecorder,
  RECONNECT_SAMPLES,
  TRANSFER_SAMPLES,
  TRANSFER_SIZES,
  WARM_REST_SAMPLES,
  WEBSOCKET_SAMPLES,
  summarizePathResult,
  validatePathResult,
  waitForSelectedPath,
  type ExpectedIrohPath,
  type PathBenchmarkResult,
  type TimedSample,
  type TransferSample,
} from "./iroh-network-benchmark-common.js";

type Invite = {
  lane: "direct" | "relay";
  pairingToken: string;
  expectedHttpPort: number;
  workspaceDir: string;
  iroh: { nodeId: string; ticket: string; alpns: string[] };
};

type RawHttpResponse = {
  status: number;
  headers: Record<string, string>;
  body: Buffer<ArrayBufferLike>;
};

type RequestOptions = {
  headers?: Record<string, string>;
  body?: Buffer;
};

type BenchmarkFixture = {
  workspaceId: string;
  sessionId: string;
};

const lane = process.env.BENCH_CLIENT_LANE;
if (lane !== "direct" && lane !== "relay") {
  throw new Error("BENCH_CLIENT_LANE must be direct or relay");
}
const exchangePath = process.env.BENCH_EXCHANGE_PATH ?? "/exchange/invite.json";
const outputPath = process.env.BENCH_OUTPUT_PATH ?? "/output/result.json";
const invite = JSON.parse(readFileSync(exchangePath, "utf8")) as Invite;
if (invite.lane !== lane) throw new Error(`Benchmark invite lane mismatch: ${invite.lane}`);

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`Benchmark assertion failed: ${message}`);
}

function round(value: number, digits = 6): number {
  const scale = 10 ** digits;
  return Math.round(value * scale) / scale;
}

function decodeChunked(body: Buffer): Buffer {
  const chunks: Buffer[] = [];
  let offset = 0;
  while (offset < body.length) {
    const lineEnd = body.indexOf("\r\n", offset, "utf8");
    if (lineEnd < 0) throw new Error("Malformed chunked HTTP response");
    const size = Number.parseInt(body.subarray(offset, lineEnd).toString("ascii"), 16);
    if (!Number.isFinite(size)) throw new Error("Malformed HTTP chunk size");
    offset = lineEnd + 2;
    if (size === 0) break;
    chunks.push(body.subarray(offset, offset + size));
    offset += size + 2;
  }
  return Buffer.concat(chunks);
}

function parseHttpResponse(bytes: Uint8Array): RawHttpResponse {
  const response = Buffer.from(bytes);
  const headerEnd = response.indexOf("\r\n\r\n");
  if (headerEnd < 0) throw new Error("HTTP response headers are incomplete");
  const lines = response.subarray(0, headerEnd).toString("latin1").split("\r\n");
  const status = Number(lines[0]?.split(" ")[1]);
  const headers: Record<string, string> = {};
  for (const line of lines.slice(1)) {
    const colon = line.indexOf(":");
    if (colon > 0) headers[line.slice(0, colon).toLowerCase()] = line.slice(colon + 1).trim();
  }
  let body: Buffer<ArrayBufferLike> = response.subarray(headerEnd + 4);
  if (headers["transfer-encoding"]?.toLowerCase() === "chunked") body = decodeChunked(body);
  return { status, headers, body };
}

function responseJson(response: RawHttpResponse): Record<string, unknown> {
  return JSON.parse(response.body.toString("utf8")) as Record<string, unknown>;
}

function rawRequestHead(
  token: string,
  method: string,
  path: string,
  options: RequestOptions = {},
): Buffer {
  const body = options.body ?? Buffer.alloc(0);
  const headers = {
    host: "oppi.benchmark",
    authorization: `Bearer ${token}`,
    connection: "close",
    ...(body.length > 0 ? { "content-length": String(body.length) } : {}),
    ...options.headers,
  };
  return Buffer.from(
    `${method} ${path} HTTP/1.1\r\n${Object.entries(headers)
      .map(([key, value]) => `${key}: ${value}`)
      .join("\r\n")}\r\n\r\n`,
    "utf8",
  );
}

async function irohRequest(
  connection: Connection,
  token: string,
  method: string,
  path: string,
  options: RequestOptions = {},
): Promise<RawHttpResponse> {
  const stream = await connection.openBi();
  const body = options.body ?? Buffer.alloc(0);
  await stream.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
  await stream.send.writeAll(Array.from(rawRequestHead(token, method, path, options)));
  for (let offset = 0; offset < body.length; offset += 256 * 1024) {
    await stream.send.writeAll(Array.from(body.subarray(offset, offset + 256 * 1024)));
  }
  await stream.send.finish();
  const response = await stream.recv.readToEnd(4 * 1024 * 1024);
  return parseHttpResponse(Uint8Array.from(response));
}

async function directRequest(
  host: string,
  port: number,
  token: string,
  method: string,
  path: string,
  options: RequestOptions & { agent?: HttpAgent } = {},
): Promise<RawHttpResponse & { socketKey: string }> {
  return await new Promise((resolve, reject) => {
    const body = options.body ?? Buffer.alloc(0);
    let socketKey = "";
    const request = httpRequest(
      {
        host,
        port,
        method,
        path,
        agent: options.agent,
        headers: {
          authorization: `Bearer ${token}`,
          ...(body.length > 0 ? { "content-length": String(body.length) } : {}),
          ...options.headers,
        },
      },
      (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.once("end", () => {
          const headers: Record<string, string> = {};
          for (const [key, value] of Object.entries(response.headers)) {
            if (typeof value === "string") headers[key] = value;
            else if (Array.isArray(value)) headers[key] = value.join(", ");
          }
          resolve({
            status: response.statusCode ?? 0,
            headers,
            body: Buffer.concat(chunks),
            socketKey,
          });
        });
      },
    );
    request.once("socket", (socket) => {
      socketKey = `${socket.localAddress ?? "unknown"}:${socket.localPort ?? 0}`;
    });
    request.once("error", reject);
    request.end(body);
  });
}

async function createFixture(
  request: (method: string, path: string, options?: RequestOptions) => Promise<RawHttpResponse>,
  label: string,
): Promise<BenchmarkFixture> {
  const workspaceResponse = await request("POST", "/workspaces", {
    headers: { "content-type": "application/json" },
    body: Buffer.from(
      JSON.stringify({
        name: `iroh-benchmark-${label}`,
        hostMount: invite.workspaceDir,
        runtime: "host",
        systemPromptMode: "append",
        defaultModel: "stub/deterministic",
      }),
    ),
  });
  assert(workspaceResponse.status === 201, `${label} workspace creation returned 201`);
  const workspace = responseJson(workspaceResponse).workspace as Record<string, unknown>;
  const workspaceId = String(workspace.id);
  assert(workspaceId.length > 0, `${label} workspace has an ID`);

  const sessionResponse = await request(
    "POST",
    `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
    {
      headers: { "content-type": "application/json" },
      body: Buffer.from(JSON.stringify({ model: "stub/deterministic" })),
    },
  );
  assert(sessionResponse.status === 201, `${label} session creation returned 201`);
  const session = responseJson(sessionResponse).session as Record<string, unknown>;
  const sessionId = String(session.id);
  assert(sessionId.length > 0, `${label} session has an ID`);
  return { workspaceId, sessionId };
}

function maskedFrame(opcode: number, payload: Buffer): Buffer {
  const mask = randomBytes(4);
  const lengthBytes =
    payload.length < 126
      ? Buffer.from([0x80 | payload.length])
      : payload.length <= 0xffff
        ? Buffer.from([0xfe, payload.length >> 8, payload.length & 0xff])
        : (() => {
            const bytes = Buffer.alloc(9);
            bytes[0] = 0xff;
            bytes.writeBigUInt64BE(BigInt(payload.length), 1);
            return bytes;
          })();
  const masked = Buffer.alloc(payload.length);
  for (let index = 0; index < payload.length; index += 1) {
    masked[index] = payload[index] ^ mask[index % 4];
  }
  return Buffer.concat([Buffer.from([0x80 | opcode]), lengthBytes, mask, masked]);
}

interface BenchmarkWebSocket {
  sendJson(value: Record<string, unknown>): Promise<void>;
  waitForType(type: string, timeoutMs?: number): Promise<Record<string, unknown>>;
  close(): Promise<void>;
}

class IrohWebSocket implements BenchmarkWebSocket {
  private buffered = Buffer.alloc(0);
  private readonly messages: Array<{ opcode: number; payload: Buffer }> = [];
  private readonly waiters: Array<() => void> = [];
  private sendQueue: Promise<void> = Promise.resolve();
  private readonly reader: Promise<void>;

  private constructor(private readonly stream: BiStream) {
    this.reader = this.readLoop();
  }

  static async open(connection: Connection, token: string, path: string): Promise<IrohWebSocket> {
    const stream = await connection.openBi();
    const key = randomBytes(16).toString("base64");
    const request = Buffer.from(
      `GET ${path} HTTP/1.1\r\nHost: oppi.benchmark\r\nAuthorization: Bearer ${token}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
    );
    await stream.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
    await stream.send.writeAll(Array.from(request));
    const ws = new IrohWebSocket(stream);
    const handshake = await ws.waitForRawHeaders();
    assert(handshake.startsWith("HTTP/1.1 101"), `Iroh WebSocket upgrade succeeds for ${path}`);
    return ws;
  }

  private async waitForRawHeaders(): Promise<string> {
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const end = this.buffered.indexOf("\r\n\r\n");
      if (end >= 0) {
        const headers = this.buffered.subarray(0, end + 4).toString("latin1");
        this.buffered = this.buffered.subarray(end + 4);
        this.parseFrames();
        return headers;
      }
      await this.wait();
    }
    throw new Error("Iroh WebSocket handshake timed out");
  }

  private async readLoop(): Promise<void> {
    while (true) {
      const bytes = await this.stream.recv.read(64 * 1024);
      if (bytes.length === 0) break;
      this.buffered = Buffer.concat([this.buffered, Buffer.from(bytes)]);
      this.parseFrames();
      this.wake();
    }
    this.wake();
  }

  private parseFrames(): void {
    while (
      this.buffered.length >= 2 &&
      !this.buffered.subarray(0, 5).toString().startsWith("HTTP/")
    ) {
      const opcode = this.buffered[0] & 0x0f;
      let length = this.buffered[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffered.length < 4) return;
        length = this.buffered.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffered.length < 10) return;
        const wide = this.buffered.readBigUInt64BE(2);
        if (wide > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("WebSocket frame too large");
        length = Number(wide);
        offset = 10;
      }
      if (this.buffered.length < offset + length) return;
      const payload = this.buffered.subarray(offset, offset + length);
      this.buffered = this.buffered.subarray(offset + length);
      if (opcode === 0x9) {
        void this.queueFrame(0x0a, payload);
      } else {
        this.messages.push({ opcode, payload });
      }
    }
  }

  private async wait(): Promise<void> {
    await new Promise<void>((resolve) => {
      this.waiters.push(resolve);
      setTimeout(resolve, 25).unref?.();
    });
  }

  private wake(): void {
    for (const waiter of this.waiters.splice(0)) waiter();
  }

  private queueFrame(opcode: number, payload: Buffer): Promise<void> {
    this.sendQueue = this.sendQueue.then(() =>
      this.stream.send.writeAll(Array.from(maskedFrame(opcode, payload))),
    );
    return this.sendQueue;
  }

  async sendJson(value: Record<string, unknown>): Promise<void> {
    await this.queueFrame(0x1, Buffer.from(JSON.stringify(value)));
  }

  async waitForType(type: string, timeoutMs = 30_000): Promise<Record<string, unknown>> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      for (let index = 0; index < this.messages.length; index += 1) {
        const message = this.messages[index];
        if (message.opcode !== 0x1) continue;
        const parsed = JSON.parse(message.payload.toString("utf8")) as Record<string, unknown>;
        if (parsed.type === type) {
          this.messages.splice(index, 1);
          return parsed;
        }
      }
      await this.wait();
    }
    throw new Error(`Timed out waiting for Iroh WebSocket message type ${type}`);
  }

  async close(): Promise<void> {
    await this.queueFrame(0x8, Buffer.from([0x03, 0xe8]));
    await this.stream.send.finish().catch(() => {});
    await Promise.race([
      this.reader.catch(() => {}),
      new Promise((resolve) => setTimeout(resolve, 1_000)),
    ]);
  }
}

class DirectWebSocket implements BenchmarkWebSocket {
  private readonly messages: Record<string, unknown>[] = [];
  private readonly waiters: Array<() => void> = [];

  private constructor(private readonly ws: WebSocket) {
    ws.on("message", (data, isBinary) => {
      if (isBinary) return;
      this.messages.push(JSON.parse(data.toString()) as Record<string, unknown>);
      for (const waiter of this.waiters.splice(0)) waiter();
    });
  }

  static async open(
    host: string,
    port: number,
    token: string,
    path: string,
  ): Promise<DirectWebSocket> {
    const ws = new WebSocket(`ws://${host}:${port}${path}`, {
      headers: { authorization: `Bearer ${token}` },
      perMessageDeflate: false,
    });
    const client = new DirectWebSocket(ws);
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
    throw new Error(`Timed out waiting for direct WebSocket message type ${type}`);
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

async function openReadyWebSocket(
  open: () => Promise<BenchmarkWebSocket>,
): Promise<BenchmarkWebSocket> {
  const ws = await open();
  await ws.waitForType("stream_connected");
  await ws.waitForType("connected", 60_000);
  await ws.waitForType("state", 60_000);
  return ws;
}

async function pair(
  endpoint: Endpoint,
  target: EndpointAddr,
  expectedPath: ExpectedIrohPath,
): Promise<string> {
  const connection = await endpoint.connect(target, Array.from(Buffer.from("oppi/pair/1")));
  assert(connection.remoteId().toString() === invite.iroh.nodeId, "pairing peer ID matches invite");
  await waitForSelectedPath(connection, expectedPath);
  const stream = await connection.openBi();
  await stream.send.writeAll(
    Array.from(
      encodeIrohFrame({
        v: 1,
        kind: "pairRequest",
        pairingToken: invite.pairingToken,
        deviceName: `iroh-benchmark-${lane}`,
      }),
    ),
  );
  await stream.send.finish();
  const frame = decodeIrohFrame(Uint8Array.from(await stream.recv.readToEnd(64 * 1024)), {
    maxHeaderBytes: 16 * 1024,
    maxBodyBytes: 0,
  });
  connection.close(0n, []);
  assert(frame.header.ok === true, "pairing succeeds");
  assert(typeof frame.header.deviceToken === "string", "pairing returns a device token");
  return frame.header.deviceToken;
}

function targetAddress(expectedPath: ExpectedIrohPath): EndpointAddr {
  const ticketAddress = EndpointTicket.fromString(invite.iroh.ticket).endpointAddr();
  assert(ticketAddress.id().toString() === invite.iroh.nodeId, "ticket node ID matches invite");
  if (expectedPath === "direct") return ticketAddress;
  const relayUrl = ticketAddress.relayUrl();
  assert(typeof relayUrl === "string" && relayUrl.length > 0, "relay ticket has a relay URL");
  return new EndpointAddr(EndpointId.fromString(invite.iroh.nodeId), relayUrl, []);
}

async function applyRelayOnlyFirewall(relayUrl: string): Promise<void> {
  const relayAddresses = await lookup(new URL(relayUrl).hostname, { all: true });
  const ipv4Addresses = relayAddresses.filter((item) => item.family === 4);
  assert(ipv4Addresses.length > 0, "relay hostname resolves to IPv4 for the Docker topology");
  for (const address of ipv4Addresses) {
    execFileSync("iptables", ["-A", "OUTPUT", "-p", "udp", "-d", address.address, "-j", "ACCEPT"]);
    execFileSync("iptables", ["-A", "INPUT", "-p", "udp", "-s", address.address, "-j", "ACCEPT"]);
  }
  execFileSync("iptables", ["-A", "OUTPUT", "-p", "udp", "--dport", "53", "-j", "ACCEPT"]);
  execFileSync("iptables", ["-A", "INPUT", "-p", "udp", "--sport", "53", "-j", "ACCEPT"]);
  execFileSync("iptables", ["-A", "OUTPUT", "-p", "udp", "-j", "REJECT"]);
  execFileSync("iptables", ["-A", "INPUT", "-p", "udp", "-j", "DROP"]);
}

async function probeHttp(host: string, port: number): Promise<boolean> {
  try {
    const response = await fetch(`http://${host}:${port}/health`, {
      signal: AbortSignal.timeout(2_000),
    });
    return response.status === 200;
  } catch {
    return false;
  }
}

async function runHttpBaseline(token: string): Promise<PathBenchmarkResult> {
  const host = "iroh-benchmark-direct-server";
  const port = invite.expectedHttpPort;
  assert(await probeHttp(host, port), "HTTP baseline server is reachable on the isolated bridge");

  const coldConnection: TimedSample[] = [];
  for (let sample = 1; sample <= COLD_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    const socket = netConnect({ host, port });
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    const durationMs = performance.now() - startedAt;
    assert(!socket.remoteAddress?.startsWith("127."), "HTTP baseline is not loopback");
    socket.destroy();
    coldConnection.push({ sample, durationMs: round(durationMs) });
  }

  const agent = new HttpAgent({ keepAlive: true, maxSockets: 1, maxFreeSockets: 1 });
  const direct = async (
    method: string,
    path: string,
    options: RequestOptions = {},
  ): Promise<RawHttpResponse> =>
    directRequest(host, port, token, method, path, { ...options, agent });
  const fixture = await createFixture(direct, "http-direct");

  const seeded = await directRequest(host, port, token, "GET", "/me", { agent });
  assert(seeded.status === 200, "HTTP warm seed /me succeeds");
  const warmSocketKey = seeded.socketKey;
  assert(warmSocketKey.length > 0, "HTTP warm seed records its socket");
  const warmRest: TimedSample[] = [];
  for (let sample = 1; sample <= WARM_REST_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    const response = await directRequest(host, port, token, "GET", "/me", { agent });
    const durationMs = performance.now() - startedAt;
    assert(response.status === 200, `HTTP warm /me sample ${sample} succeeds`);
    assert(
      response.socketKey === warmSocketKey,
      `HTTP warm /me sample ${sample} reuses one TCP socket`,
    );
    warmRest.push({ sample, durationMs: round(durationMs) });
  }

  const wsPath = `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/stream`;
  const openWs = () => DirectWebSocket.open(host, port, token, wsPath);
  const ws = await openReadyWebSocket(openWs);
  const websocketRtt: TimedSample[] = [];
  for (let sample = 1; sample <= WEBSOCKET_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    await ws.sendJson({
      type: "get_state",
      sessionId: fixture.sessionId,
      requestId: `http-${sample}`,
    });
    await ws.waitForType("state");
    websocketRtt.push({ sample, durationMs: round(performance.now() - startedAt) });
  }
  await ws.close();

  const reconnect: TimedSample[] = [];
  for (let sample = 1; sample <= RECONNECT_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    const candidate = await openWs();
    await candidate.waitForType("stream_connected");
    await candidate.waitForType("connected", 60_000);
    reconnect.push({ sample, durationMs: round(performance.now() - startedAt) });
    await candidate.close();
  }

  const transfers: TransferSample[] = [];
  for (const sizeBytes of TRANSFER_SIZES) {
    const payload = Buffer.alloc(sizeBytes, 0xa5);
    for (let sample = 1; sample <= TRANSFER_SAMPLES; sample += 1) {
      const create = await direct(
        "POST",
        `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/attachments`,
        {
          headers: { "content-type": "application/json" },
          body: Buffer.from(
            JSON.stringify({
              name: `http-${sizeBytes}-${sample}.bin`,
              mimeType: "application/octet-stream",
              sizeBytes,
              purpose: "chat_attachment",
            }),
          ),
        },
      );
      assert(create.status === 201, `HTTP ${sizeBytes} upload record ${sample} succeeds`);
      const uploadId = String(responseJson(create).uploadId);
      const startedAt = performance.now();
      const uploaded = await direct(
        "PUT",
        `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/attachments/${uploadId}/content`,
        {
          headers: { "content-type": "application/octet-stream" },
          body: payload,
        },
      );
      const durationMs = performance.now() - startedAt;
      assert(uploaded.status === 200, `HTTP ${sizeBytes} upload ${sample} succeeds`);
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
      const result = await directDownload(
        host,
        port,
        token,
        `/workspaces/${fixture.workspaceId}/raw/benchmark-${sizeMiB}m.mp4`,
        agent,
      );
      const durationMs = performance.now() - startedAt;
      assert(result.status === 200, `HTTP ${sizeBytes} download ${sample} succeeds`);
      assert(
        result.bytes === sizeBytes,
        `HTTP ${sizeBytes} download ${sample} preserves byte count`,
      );
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

  const result = summarizePathResult({
    name: "httpDirect",
    transport: "http",
    topology: {
      description: "HTTP/1.1 over one project-scoped Docker bridge; no published host port",
      directHttpReachable: true,
      hostNetwork: false,
      hostDockerInternal: false,
      tailscale: false,
      hostModelService: false,
    },
    raw: { coldConnection, warmRest, websocketRtt, reconnect, transfers },
  });
  validatePathResult(result);
  return result;
}

async function directDownload(
  host: string,
  port: number,
  token: string,
  path: string,
  agent: HttpAgent,
): Promise<{ status: number; bytes: number }> {
  return await new Promise((resolve, reject) => {
    const request = httpRequest(
      { host, port, path, method: "GET", agent, headers: { authorization: `Bearer ${token}` } },
      (response) => {
        let bytes = 0;
        response.on("data", (chunk: Buffer) => {
          bytes += chunk.length;
        });
        response.once("end", () => resolve({ status: response.statusCode ?? 0, bytes }));
      },
    );
    request.once("error", reject);
    request.end();
  });
}

async function readIrohDownload(recv: RecvStream): Promise<{ status: number; bytes: number }> {
  let buffered = Buffer.alloc(0);
  let status = 0;
  let bodyBytes = 0;
  let headersParsed = false;
  let expectedLength: number | undefined;
  while (true) {
    const chunk = Buffer.from(await recv.read(256 * 1024));
    if (chunk.length === 0) break;
    if (!headersParsed) {
      buffered = Buffer.concat([buffered, chunk]);
      const headerEnd = buffered.indexOf("\r\n\r\n");
      if (headerEnd < 0) {
        if (buffered.length > 64 * 1024) throw new Error("Iroh download headers exceed 64 KiB");
        continue;
      }
      const lines = buffered.subarray(0, headerEnd).toString("latin1").split("\r\n");
      status = Number(lines[0]?.split(" ")[1]);
      for (const line of lines.slice(1)) {
        const colon = line.indexOf(":");
        if (colon > 0 && line.slice(0, colon).toLowerCase() === "content-length") {
          expectedLength = Number(line.slice(colon + 1).trim());
        }
      }
      bodyBytes += buffered.length - headerEnd - 4;
      buffered = Buffer.alloc(0);
      headersParsed = true;
    } else {
      bodyBytes += chunk.length;
    }
  }
  assert(headersParsed, "Iroh download returned complete HTTP headers");
  if (expectedLength !== undefined)
    assert(bodyBytes === expectedLength, "Iroh download matches Content-Length");
  return { status, bytes: bodyBytes };
}

async function runIrohPath(
  endpoint: Endpoint,
  target: EndpointAddr,
  token: string,
  expectedPath: ExpectedIrohPath,
  directHttpReachable: boolean,
): Promise<PathBenchmarkResult> {
  const coldConnection: TimedSample[] = [];
  for (let sample = 1; sample <= COLD_SAMPLES; sample += 1) {
    const startedAt = performance.now();
    const connection = await endpoint.connect(target, Array.from(Buffer.from("oppi/http/1")));
    await waitForSelectedPath(connection, expectedPath);
    const durationMs = performance.now() - startedAt;
    const coldRecorder = await IrohPathRecorder.start(connection, expectedPath);
    const beforeProbe = coldRecorder.begin();
    const probe = await irohRequest(connection, token, "GET", "/me");
    assert(
      probe.status === 200,
      `Iroh ${expectedPath} cold connection ${sample} carries authenticated traffic`,
    );
    coldConnection.push({
      sample,
      durationMs: round(durationMs),
      path: coldRecorder.end(beforeProbe),
    });
    coldRecorder.stop();
    connection.close(0n, []);
    await Promise.race([connection.closed(), new Promise((resolve) => setTimeout(resolve, 2_000))]);
  }

  const connection = await endpoint.connect(target, Array.from(Buffer.from("oppi/http/1")));
  assert(
    connection.remoteId().toString() === invite.iroh.nodeId,
    "HTTP tunnel peer ID matches invite",
  );
  const recorder = await IrohPathRecorder.start(connection, expectedPath);
  const request = (method: string, path: string, options: RequestOptions = {}) =>
    irohRequest(connection, token, method, path, options);
  const fixture = await createFixture(request, `iroh-${expectedPath}`);

  const seed = await request("GET", "/me");
  assert(seed.status === 200, `Iroh ${expectedPath} warm seed /me succeeds`);
  const warmRest: TimedSample[] = [];
  for (let sample = 1; sample <= WARM_REST_SAMPLES; sample += 1) {
    const before = recorder.begin();
    const startedAt = performance.now();
    const response = await request("GET", "/me");
    const durationMs = performance.now() - startedAt;
    assert(response.status === 200, `Iroh ${expectedPath} warm /me sample ${sample} succeeds`);
    warmRest.push({ sample, durationMs: round(durationMs), path: recorder.end(before) });
  }

  const wsPath = `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/stream`;
  const openWs = () => IrohWebSocket.open(connection, token, wsPath);
  const ws = await openReadyWebSocket(openWs);
  const websocketRtt: TimedSample[] = [];
  for (let sample = 1; sample <= WEBSOCKET_SAMPLES; sample += 1) {
    const before = recorder.begin();
    const startedAt = performance.now();
    await ws.sendJson({
      type: "get_state",
      sessionId: fixture.sessionId,
      requestId: `${expectedPath}-${sample}`,
    });
    await ws.waitForType("state");
    websocketRtt.push({
      sample,
      durationMs: round(performance.now() - startedAt),
      path: recorder.end(before),
    });
  }
  await ws.close();

  const reconnect: TimedSample[] = [];
  for (let sample = 1; sample <= RECONNECT_SAMPLES; sample += 1) {
    const before = recorder.begin();
    const startedAt = performance.now();
    const candidate = await openWs();
    await candidate.waitForType("stream_connected");
    await candidate.waitForType("connected", 60_000);
    reconnect.push({
      sample,
      durationMs: round(performance.now() - startedAt),
      path: recorder.end(before),
    });
    await candidate.close();
  }

  const transfers: TransferSample[] = [];
  for (const sizeBytes of TRANSFER_SIZES) {
    const payload = Buffer.alloc(sizeBytes, 0xa5);
    for (let sample = 1; sample <= TRANSFER_SAMPLES; sample += 1) {
      const create = await request(
        "POST",
        `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/attachments`,
        {
          headers: { "content-type": "application/json" },
          body: Buffer.from(
            JSON.stringify({
              name: `iroh-${expectedPath}-${sizeBytes}-${sample}.bin`,
              mimeType: "application/octet-stream",
              sizeBytes,
              purpose: "chat_attachment",
            }),
          ),
        },
      );
      assert(
        create.status === 201,
        `Iroh ${expectedPath} ${sizeBytes} upload record ${sample} succeeds`,
      );
      const uploadId = String(responseJson(create).uploadId);
      const before = recorder.begin();
      const startedAt = performance.now();
      const uploaded = await request(
        "PUT",
        `/workspaces/${fixture.workspaceId}/sessions/${fixture.sessionId}/attachments/${uploadId}/content`,
        { headers: { "content-type": "application/octet-stream" }, body: payload },
      );
      const durationMs = performance.now() - startedAt;
      assert(
        uploaded.status === 200,
        `Iroh ${expectedPath} ${sizeBytes} upload ${sample} succeeds`,
      );
      transfers.push({
        sample,
        direction: "upload",
        sizeBytes,
        durationMs: round(durationMs),
        throughputMbps: round((sizeBytes * 8) / durationMs / 1000),
        path: recorder.end(before),
      });
    }

    const sizeMiB = sizeBytes / 1024 / 1024;
    for (let sample = 1; sample <= TRANSFER_SAMPLES; sample += 1) {
      const before = recorder.begin();
      const startedAt = performance.now();
      const stream = await connection.openBi();
      await stream.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
      await stream.send.writeAll(
        Array.from(
          rawRequestHead(
            token,
            "GET",
            `/workspaces/${fixture.workspaceId}/raw/benchmark-${sizeMiB}m.mp4`,
          ),
        ),
      );
      await stream.send.finish();
      const downloaded = await readIrohDownload(stream.recv);
      const durationMs = performance.now() - startedAt;
      assert(
        downloaded.status === 200,
        `Iroh ${expectedPath} ${sizeBytes} download ${sample} succeeds`,
      );
      assert(
        downloaded.bytes === sizeBytes,
        `Iroh ${expectedPath} ${sizeBytes} download ${sample} preserves byte count`,
      );
      transfers.push({
        sample,
        direction: "download",
        sizeBytes,
        durationMs: round(durationMs),
        throughputMbps: round((sizeBytes * 8) / durationMs / 1000),
        path: recorder.end(before),
      });
    }
  }

  await recorder.stop();
  const relayCategory =
    expectedPath === "relay"
      ? transfers.find((sample) => sample.path)?.path?.after.addressCategory
      : undefined;
  connection.close(0n, []);

  const result = summarizePathResult({
    name: expectedPath === "direct" ? "irohDirect" : "irohRelay",
    transport: "iroh",
    requestedIrohPath: expectedPath,
    topology: {
      description:
        expectedPath === "direct"
          ? "Iroh endpoints share one project-scoped Docker bridge; selected PathSnapshot must be IP"
          : "Server and client use separate Docker egress networks; after relay readiness each container allowlists relay IPv4 UDP and blocks all other UDP; target address contains relay only; every selected PathSnapshot must be relay",
      directHttpReachable,
      hostNetwork: false,
      hostDockerInternal: false,
      tailscale: false,
      hostModelService: false,
      ...(relayCategory ? { relayCategory } : {}),
    },
    raw: { coldConnection, warmRest, websocketRtt, reconnect, transfers },
  });
  validatePathResult(result);
  return result;
}

async function main(): Promise<void> {
  assert(invite.iroh.alpns.includes("oppi/pair/1"), "invite advertises pairing ALPN");
  assert(invite.iroh.alpns.includes("oppi/http/1"), "invite advertises HTTP tunnel ALPN");

  const endpoint = await Endpoint.bind();
  if (lane === "relay") {
    const relayUrl = EndpointTicket.fromString(invite.iroh.ticket).endpointAddr().relayUrl();
    assert(relayUrl, "relay ticket contains a relay URL");
    await applyRelayOnlyFirewall(relayUrl);
  }
  try {
    if (lane === "direct") {
      const target = targetAddress("direct");
      const token = await pair(endpoint, target, "direct");
      const httpResult = await runHttpBaseline(token);
      const irohResult = await runIrohPath(endpoint, target, token, "direct", true);
      writeFileSync(
        outputPath,
        JSON.stringify({ httpDirect: httpResult, irohDirect: irohResult }, null, 2),
      );
    } else {
      const directHttpReachable = await probeHttp(
        "iroh-benchmark-relay-server",
        invite.expectedHttpPort,
      );
      assert(!directHttpReachable, "forced-relay client cannot reach the server HTTP listener");
      const target = targetAddress("relay");
      const token = await pair(endpoint, target, "relay");
      const relayResult = await runIrohPath(endpoint, target, token, "relay", false);
      writeFileSync(outputPath, JSON.stringify({ irohRelay: relayResult }, null, 2));
    }
  } finally {
    await endpoint.close();
  }
  process.stdout.write(`${JSON.stringify({ event: "iroh_benchmark.client_complete", lane })}\n`);
}

await main();
