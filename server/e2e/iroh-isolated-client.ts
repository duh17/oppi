import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";

import { Endpoint, EndpointTicket, type BiStream, type Connection } from "@number0/iroh";

import { decodeIrohFrame, encodeIrohFrame } from "../dist/src/iroh-frame-codec.js";
import { encodeIrohTunnelPreface } from "../dist/src/iroh-pairing-server.js";

type Invite = {
  pairingToken: string;
  expectedHttpPort: number;
  workspaceDir: string;
  iroh: { nodeId: string; ticket: string; alpns: string[] };
};

type HttpResponse = {
  status: number;
  headers: Record<string, string>;
  body: Buffer;
};

let assertions = 0;
function assert(condition: unknown, message: string): asserts condition {
  assertions += 1;
  if (!condition) throw new Error(`Assertion failed: ${message}`);
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

function parseHttpResponse(bytes: Uint8Array): HttpResponse {
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
  let body = response.subarray(headerEnd + 4);
  if (headers["transfer-encoding"]?.toLowerCase() === "chunked") body = decodeChunked(body);
  return { status, headers, body };
}

function json(response: HttpResponse): Record<string, unknown> {
  return JSON.parse(response.body.toString("utf8")) as Record<string, unknown>;
}

async function pair(endpoint: Endpoint, invite: Invite): Promise<string> {
  const addr = EndpointTicket.fromString(invite.iroh.ticket).endpointAddr();
  assert(addr.id().toString() === invite.iroh.nodeId, "ticket node ID matches invite");
  const connection = await endpoint.connect(addr, Array.from(Buffer.from("oppi/pair/1")));
  assert(connection.remoteId().toString() === invite.iroh.nodeId, "pairing peer ID matches invite");
  const stream = await connection.openBi();
  await stream.send.writeAll(
    Array.from(
      encodeIrohFrame({
        v: 1,
        kind: "pairRequest",
        pairingToken: invite.pairingToken,
        deviceName: "isolated-iroh-client",
      }),
    ),
  );
  await stream.send.finish();
  const frame = decodeIrohFrame(Uint8Array.from(await stream.recv.readToEnd(64 * 1024)), {
    maxHeaderBytes: 16 * 1024,
    maxBodyBytes: 0,
  });
  connection.close(0n, []);
  assert(frame.header.ok === true, "pairing succeeds over scoped ALPN");
  assert(typeof frame.header.deviceToken === "string", "pairing returns a device token");
  return frame.header.deviceToken;
}

async function httpRequest(
  connection: Connection,
  token: string,
  method: string,
  path: string,
  options: { headers?: Record<string, string>; body?: Buffer } = {},
): Promise<HttpResponse> {
  const stream = await connection.openBi();
  const body = options.body ?? Buffer.alloc(0);
  const headers = {
    host: "oppi.iroh",
    authorization: `Bearer ${token}`,
    connection: "close",
    ...(body.length > 0 ? { "content-length": String(body.length) } : {}),
    ...options.headers,
  };
  const requestHead = Buffer.from(
    `${method} ${path} HTTP/1.1\r\n${Object.entries(headers)
      .map(([key, value]) => `${key}: ${value}`)
      .join("\r\n")}\r\n\r\n`,
    "utf8",
  );
  await stream.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
  try {
    await stream.send.writeAll(Array.from(Buffer.concat([requestHead, body])));
    await stream.send.finish();
  } catch {
    // Auth rejection may STOP_SENDING after the preface while its deterministic
    // HTTP error is already available on the receive half.
  }
  return parseHttpResponse(Uint8Array.from(await stream.recv.readToEnd(64 * 1024 * 1024)));
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

class TunnelWebSocket {
  private buffered = Buffer.alloc(0);
  private messages: Array<{ opcode: number; payload: Buffer }> = [];
  private waiters: Array<() => void> = [];
  private sendQueue: Promise<void> = Promise.resolve();
  private reader: Promise<void>;

  private constructor(private readonly stream: BiStream) {
    this.reader = this.readLoop();
  }

  static async open(connection: Connection, token: string, path: string): Promise<TunnelWebSocket> {
    const stream = await connection.openBi();
    const key = randomBytes(16).toString("base64");
    const request = Buffer.from(
      `GET ${path} HTTP/1.1\r\nHost: oppi.iroh\r\nAuthorization: Bearer ${token}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
    );
    await stream.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
    await stream.send.writeAll(Array.from(request));
    const ws = new TunnelWebSocket(stream);
    const handshake = await ws.waitForRawHeaders();
    assert(handshake.startsWith("HTTP/1.1 101"), `WebSocket upgrade succeeds for ${path}`);
    return ws;
  }

  private async waitForRawHeaders(): Promise<string> {
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      const end = this.buffered.indexOf("\r\n\r\n");
      if (end >= 0) {
        const headers = this.buffered.subarray(0, end + 4).toString("latin1");
        this.buffered = this.buffered.subarray(end + 4);
        this.parseFrames();
        return headers;
      }
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 50).unref?.();
      });
    }
    throw new Error("WebSocket handshake timeout");
  }

  private async readLoop(): Promise<void> {
    while (true) {
      const bytes = await this.stream.recv.read(64 * 1024);
      if (bytes.length === 0) break;
      this.buffered = Buffer.concat([this.buffered, Buffer.from(bytes)]);
      this.parseFrames();
      for (const waiter of this.waiters.splice(0)) waiter();
    }
    for (const waiter of this.waiters.splice(0)) waiter();
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
        this.writeFrame(0x0a, payload);
      } else {
        this.messages.push({ opcode, payload });
      }
    }
  }

  private writeFrame(opcode: number, payload: Buffer): void {
    this.sendQueue = this.sendQueue.then(() =>
      this.stream.send.writeAll(Array.from(maskedFrame(opcode, payload))),
    );
  }

  sendJson(value: Record<string, unknown>): void {
    this.writeFrame(0x1, Buffer.from(JSON.stringify(value)));
  }

  sendBinary(value: Buffer): void {
    this.writeFrame(0x2, value);
  }

  async waitForType(type: string, timeoutMs = 20_000): Promise<Record<string, unknown>> {
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
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 50).unref?.();
      });
    }
    throw new Error(`Timed out waiting for WebSocket message type ${type}`);
  }

  async close(): Promise<void> {
    this.writeFrame(0x8, Buffer.from([0x03, 0xe8]));
    await this.sendQueue;
    await this.stream.send.finish().catch(() => {});
    await Promise.race([
      this.reader.catch(() => {}),
      new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);
  }
}

async function main(): Promise<void> {
  const invite = JSON.parse(readFileSync("/exchange/invite.json", "utf8")) as Invite;
  assert(invite.iroh.alpns.includes("oppi/pair/1"), "invite advertises pairing ALPN");
  assert(invite.iroh.alpns.includes("oppi/http/1"), "invite advertises transparent HTTP ALPN");

  let directHttpReachable = false;
  try {
    await fetch(`http://iroh-server:${invite.expectedHttpPort}/health`, {
      signal: AbortSignal.timeout(1_500),
    });
    directHttpReachable = true;
  } catch {
    directHttpReachable = false;
  }
  assert(!directHttpReachable, "client cannot reach the Oppi HTTP listener directly");

  const endpoint = await Endpoint.bind();
  try {
    const token = await pair(endpoint, invite);
    assert(token.startsWith("dt_"), "Iroh pairing returns device credential");

    const addr = EndpointTicket.fromString(invite.iroh.ticket).endpointAddr();
    const connection = await endpoint.connect(addr, Array.from(Buffer.from("oppi/http/1")));
    assert(
      connection.remoteId().toString() === invite.iroh.nodeId,
      "HTTP tunnel peer ID matches invite",
    );

    const rejected = await httpRequest(connection, "dt_invalid", "GET", "/me");
    assert(rejected.status === 401, "invalid tunnel bearer returns a deterministic HTTP error");
    const missingRawBearer = await httpRequest(connection, token, "GET", "/health", {
      headers: { authorization: "" },
    });
    assert(missingRawBearer.status === 401, "missing raw HTTP bearer is rejected inside tunnel");
    const wrongRawBearer = await httpRequest(connection, token, "GET", "/health", {
      headers: { authorization: "Bearer dt_wrong" },
    });
    assert(wrongRawBearer.status === 401, "wrong raw HTTP bearer is rejected inside tunnel");

    const openSendHalf = await connection.openBi();
    await openSendHalf.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
    await openSendHalf.send.writeAll(
      Array.from(
        Buffer.from(
          `GET /health HTTP/1.1\r\nHost: oppi.iroh\r\nAuthorization: Bearer ${token}\r\nConnection: close\r\n\r\n`,
        ),
      ),
    );
    const openSendResponseBytes = await Promise.race([
      openSendHalf.recv.readToEnd(64 * 1024),
      new Promise<never>((_, rejectTimeout) => {
        const timer = setTimeout(
          () => rejectTimeout(new Error("open send-half response timed out")),
          10_000,
        );
        timer.unref?.();
      }),
    ]);
    assert(
      parseHttpResponse(Uint8Array.from(openSendResponseBytes)).status === 200,
      "response completion cancels an open request send-half",
    );
    await openSendHalf.send.reset(1n).catch(() => {});

    const cancelled = await connection.openBi();
    await cancelled.send.writeAll(Array.from(encodeIrohTunnelPreface(`Bearer ${token}`)));
    await cancelled.send.writeAll(
      Array.from(Buffer.from("GET /me HTTP/1.1\r\nHost: oppi.iroh\r\nConnection: close\r\n\r\n")),
    );
    await cancelled.send.finish();
    await cancelled.recv.stop(1n);

    const me = await httpRequest(connection, token, "GET", "/me");
    assert(me.status === 200, "a cancelled stream does not poison the reused Iroh connection");

    const workspaceCreate = await httpRequest(connection, token, "POST", "/workspaces", {
      headers: { "content-type": "application/json" },
      body: Buffer.from(
        JSON.stringify({
          name: "isolated-iroh-workspace",
          hostMount: invite.workspaceDir,
          runtime: "host",
          systemPromptMode: "append",
          defaultModel: "stub/deterministic",
        }),
      ),
    });
    assert(workspaceCreate.status === 201, "REST workspace mutation succeeds");
    const workspace = json(workspaceCreate).workspace as Record<string, unknown>;
    const workspaceId = String(workspace.id);
    assert(workspaceId.length > 0, "workspace mutation returns ID");

    const file = await httpRequest(
      connection,
      token,
      "GET",
      `/workspaces/${encodeURIComponent(workspaceId)}/raw/fixture.txt`,
    );
    assert(file.status === 200, "full file download succeeds");
    assert(file.body.toString("utf8").startsWith("0123456789"), "full file body is preserved");
    const range = await httpRequest(
      connection,
      token,
      "GET",
      `/workspaces/${encodeURIComponent(workspaceId)}/raw/fixture.txt`,
      { headers: { range: "bytes=10-19" } },
    );
    assert(range.status === 206, "byte range request succeeds");
    assert(range.body.toString("utf8") === "abcdefghij", "byte range body is exact");
    assert(range.headers["content-range"] === "bytes 10-19/37", "content range is preserved");

    const appEvents = await TunnelWebSocket.open(connection, token, "/app/events/stream");
    const appConnected = await appEvents.waitForType("app_events_connected");
    assert(
      appConnected.snapshotRequired === true,
      "app-event stream uses existing snapshot contract",
    );

    const sessionCreate = await httpRequest(
      connection,
      token,
      "POST",
      `/workspaces/${encodeURIComponent(workspaceId)}/sessions`,
      {
        headers: { "content-type": "application/json" },
        body: Buffer.from(JSON.stringify({ model: "stub/deterministic" })),
      },
    );
    assert(sessionCreate.status === 201, "REST session mutation succeeds");
    const session = json(sessionCreate).session as Record<string, unknown>;
    const sessionId = String(session.id);
    const createdEvent = await appEvents.waitForType("session_created");
    assert(createdEvent.sessionId === sessionId, "REST mutation reaches existing app-event stream");

    const uploadCreate = await httpRequest(
      connection,
      token,
      "POST",
      `/workspaces/${workspaceId}/sessions/${sessionId}/attachments`,
      {
        headers: { "content-type": "application/json" },
        body: Buffer.from(
          JSON.stringify({
            name: "payload.bin",
            mimeType: "application/octet-stream",
            sizeBytes: 8,
            purpose: "chat_attachment",
          }),
        ),
      },
    );
    assert(uploadCreate.status === 201, "upload record creation succeeds");
    const uploadId = String(json(uploadCreate).uploadId);
    const upload = await httpRequest(
      connection,
      token,
      "PUT",
      `/workspaces/${workspaceId}/sessions/${sessionId}/attachments/${uploadId}/content`,
      {
        headers: { "content-type": "application/octet-stream" },
        body: Buffer.from([0, 1, 2, 3, 252, 253, 254, 255]),
      },
    );
    assert(upload.status === 200, "binary upload body reaches existing upload route");

    const focused = await TunnelWebSocket.open(
      connection,
      token,
      `/workspaces/${workspaceId}/sessions/${sessionId}/stream`,
    );
    await focused.waitForType("stream_connected");
    const focusedConnected = await focused.waitForType("connected", 30_000);
    assert(focusedConnected.sessionId === sessionId, "focused stream opens through existing mux");
    focused.sendJson({ type: "get_state", sessionId, requestId: "iroh-state" });
    const state = await focused.waitForType("state");
    assert(state.sessionId === sessionId, "focused stream remains bidirectional");

    const catchUp = await httpRequest(
      connection,
      token,
      "GET",
      `/workspaces/${workspaceId}/sessions/${sessionId}/events?since=0`,
    );
    assert(catchUp.status === 200, "focused reconnect catch-up stays on the existing REST route");
    assert(json(catchUp).catchUpComplete === true, "catch-up response reports completion");

    await focused.close();
    const focusedReconnect = await TunnelWebSocket.open(
      connection,
      token,
      `/workspaces/${workspaceId}/sessions/${sessionId}/stream`,
    );
    await focusedReconnect.waitForType("stream_connected");
    const reconnected = await focusedReconnect.waitForType("connected", 30_000);
    assert(reconnected.sessionId === sessionId, "focused WebSocket reconnect succeeds");

    await appEvents.close();
    const appEventsReconnect = await TunnelWebSocket.open(connection, token, "/app/events/stream");
    const appReconnected = await appEventsReconnect.waitForType("app_events_connected");
    assert(appReconnected.snapshotRequired === true, "app-event WebSocket reconnect succeeds");

    const dictation = await TunnelWebSocket.open(connection, token, "/dictation/stream");
    dictation.sendJson({ type: "dictation_start" });
    await dictation.waitForType("dictation_ready");
    dictation.sendBinary(Buffer.from([0, 0, 1, 0, 255, 127, 0, 128]));
    dictation.sendJson({ type: "dictation_stop" });
    const final = await dictation.waitForType("dictation_final");
    assert(final.text === "stub transcript", "dictation control and binary audio use existing mux");

    await dictation.close();
    await focusedReconnect.close();
    await appEventsReconnect.close();
    connection.close(0n, []);
  } finally {
    await endpoint.close();
  }
  assert(assertions >= 25, "isolated E2E executed its full assertion matrix");
  console.log(JSON.stringify({ event: "iroh_isolated.passed", assertions }));
}

await main();
