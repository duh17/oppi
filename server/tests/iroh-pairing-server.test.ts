import { existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Incoming } from "@number0/iroh";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { startIrohHttpLoopback, type RunningIrohHttpLoopback } from "../src/iroh-http-loopback.js";
import { readIrohInviteState } from "../src/iroh-invite-state.js";
import {
  decodeIrohPairingFrame,
  decodeIrohTunnelPreface,
  encodeIrohPairingFrame,
  encodeIrohTunnelPreface,
  IROH_HTTP_ALPN_TEXT,
  IROH_PAIR_ALPN_TEXT,
  pumpIrohTunnel,
  startIrohPairingServer,
} from "../src/iroh-pairing-server.js";
import { Storage } from "../src/storage.js";

const PAIR_ALPN_BYTES = Array.from(Buffer.from(IROH_PAIR_ALPN_TEXT, "utf8"));
const HTTP_ALPN_BYTES = Array.from(Buffer.from(IROH_HTTP_ALPN_TEXT, "utf8"));

let dataDir: string;
let storage: Storage;
let loopbacks: RunningIrohHttpLoopback[];

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-iroh-server-"));
  storage = new Storage(dataDir);
  loopbacks = [];
});

afterEach(async () => {
  await Promise.all(loopbacks.map((loopback) => loopback.close()));
  rmSync(dataDir, { recursive: true, force: true });
});

type FakeEndpointOptions = { secretKey?: number[]; alpns?: number[][] };
type FakeStream = ReturnType<typeof makeStream>;

function nodeIdForSecret(secretKey: number[]): string {
  return `node-${Buffer.from(secretKey).toString("hex").slice(0, 16)}`;
}

function makeStream(input: Uint8Array) {
  let offset = 0;
  const writes: number[][] = [];
  return {
    writes,
    recv: {
      readExact: vi.fn(async (size: number) => {
        const result = Array.from(input.subarray(offset, offset + size));
        offset += result.length;
        return result;
      }),
      read: vi.fn(async (limit: number) => {
        const result = Array.from(input.subarray(offset, offset + limit));
        offset += result.length;
        return result;
      }),
      readToEnd: vi.fn(async (limit: number) => {
        const remaining = input.subarray(offset);
        if (remaining.length > limit) throw new Error("size limit exceeded");
        offset = input.length;
        return Array.from(remaining);
      }),
      stop: vi.fn(async () => {}),
    },
    send: {
      writeAll: vi.fn(async (bytes: number[]) => writes.push(bytes)),
      finish: vi.fn(async () => {}),
      reset: vi.fn(async () => {}),
    },
  };
}

function makeIncoming(options: { alpn?: number[]; remoteId?: string; streams: FakeStream[] }) {
  const close = vi.fn();
  let streamIndex = 0;
  const connection = {
    remoteId: () => ({ toString: () => options.remoteId ?? "client-node-1" }),
    acceptBi: vi.fn(async () => {
      const stream = options.streams[streamIndex++];
      if (!stream) throw new Error("connection closed");
      return stream;
    }),
    close,
    setMaxConcurrentBiStreams: vi.fn(),
  };
  const incoming = {
    accept: vi.fn(async () => ({
      alpn: vi.fn(async () => options.alpn ?? PAIR_ALPN_BYTES),
      connect: vi.fn(async () => connection),
    })),
    refuse: vi.fn(async () => {}),
  } as unknown as Incoming;
  return { incoming, connection, close };
}

function makeRuntime(options: { online?: () => Promise<void>; incoming?: Incoming } = {}) {
  let nextGeneratedByte = 7;
  let closed = false;
  const endpoints: Array<{ close: ReturnType<typeof vi.fn> }> = [];
  const incomingQueue: Incoming[] = options.incoming ? [options.incoming] : [];
  const acceptWaiters: Array<{
    resolve: (incoming: Incoming | null) => void;
    reject: (error: Error) => void;
  }> = [];
  const bind = vi.fn(async (endpointOptions?: FakeEndpointOptions | null) => {
    const secretKey = endpointOptions?.secretKey ?? Array(32).fill(nextGeneratedByte++);
    const nodeId = nodeIdForSecret(secretKey);
    const close = vi.fn(async () => {
      closed = true;
      for (const waiter of acceptWaiters.splice(0)) waiter.resolve(null);
    });
    endpoints.push({ close });
    return {
      online: vi.fn(options.online ?? (async () => {})),
      close,
      isClosed: () => closed,
      acceptNext: vi.fn(async () => {
        const queued = incomingQueue.shift();
        if (queued) return queued;
        if (closed) return null;
        return await new Promise<Incoming | null>((resolve, reject) =>
          acceptWaiters.push({ resolve, reject }),
        );
      }),
      id: () => ({ toString: () => nodeId }),
      addr: () => ({ nodeId }),
      secretKey: () => ({ toBytes: () => [...secretKey] }),
    };
  });
  return {
    endpoints,
    pushIncoming(incoming: Incoming) {
      const waiter = acceptWaiters.shift();
      if (waiter) waiter.resolve(incoming);
      else incomingQueue.push(incoming);
    },
    failAccept(error: Error) {
      const waiter = acceptWaiters.shift();
      if (!waiter) throw new Error("accept loop is not waiting");
      waiter.reject(error);
    },
    runtime: {
      Endpoint: { bind },
      EndpointTicket: {
        fromAddr: vi.fn((addr: { nodeId: string }) => ({
          toString: () => `endpoint-ticket-for-${addr.nodeId}`,
        })),
      },
    },
  };
}

function nullTunnelTarget() {
  return {
    open: vi.fn(async () => {
      throw new Error("not used");
    }),
  };
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  expect(predicate()).toBe(true);
}

async function makeLoopback(): Promise<RunningIrohHttpLoopback> {
  let running: RunningIrohHttpLoopback;
  running = await startIrohHttpLoopback({
    handleRequest(req, res) {
      const context = running.contextFor(req);
      res.writeHead(context ? 200 : 401, {
        "content-type": "application/json",
        connection: "close",
      });
      res.end(JSON.stringify({ path: req.url, clientNodeId: context?.clientNodeId }));
    },
    handleUpgrade(_req, socket) {
      socket.destroy();
    },
  });
  loopbacks.push(running);
  return running;
}

function rawHttpRequest(path: string, connection = "close"): Buffer {
  return Buffer.from(
    `GET ${path} HTTP/1.1\r\nHost: iroh.internal\r\nConnection: ${connection}\r\n\r\n`,
  );
}

function makeOpenRequestStream(input: Uint8Array, recvFailure?: Error) {
  let offset = 0;
  let releaseBlockedRead: ((value: number[]) => void) | undefined;
  const writes: number[][] = [];
  const recv = {
    read: vi.fn(async (limit: number) => {
      if (offset < input.length) {
        const result = Array.from(input.subarray(offset, offset + limit));
        offset += result.length;
        return result;
      }
      if (recvFailure) throw recvFailure;
      return await new Promise<number[]>((resolve) => {
        releaseBlockedRead = resolve;
      });
    }),
    readExact: vi.fn(async () => [] as number[]),
    readToEnd: vi.fn(async () => [] as number[]),
    stop: vi.fn(async () => releaseBlockedRead?.([])),
  };
  const send = {
    writeAll: vi.fn(async (bytes: number[]) => writes.push(bytes)),
    finish: vi.fn(async () => {}),
    reset: vi.fn(async () => {}),
  };
  return { recv, send, writes };
}

async function makeCustomLoopback(
  handleRequest: Parameters<typeof startIrohHttpLoopback>[0]["handleRequest"],
): Promise<RunningIrohHttpLoopback> {
  let running: RunningIrohHttpLoopback;
  running = await startIrohHttpLoopback({
    handleRequest,
    handleUpgrade(_req, socket) {
      socket.destroy();
    },
  });
  loopbacks.push(running);
  return running;
}

describe("Iroh pairing and tunnel framing", () => {
  it("round-trips pairing frames and the bounded authenticated tunnel preface", () => {
    const pairing = encodeIrohPairingFrame({ pairingToken: "pt_valid" });
    expect(decodeIrohPairingFrame(pairing)).toEqual({ pairingToken: "pt_valid" });

    const tunnel = encodeIrohTunnelPreface("Bearer dt_valid");
    expect(decodeIrohTunnelPreface(tunnel)).toEqual({
      v: 1,
      kind: "httpTunnel",
      authorization: "Bearer dt_valid",
    });

    const oversized = Buffer.alloc(4);
    oversized.writeUInt32BE(4 * 1024 + 1, 0);
    expect(() => decodeIrohTunnelPreface(oversized)).toThrow("exceeds 4096 bytes");
    expect(() => decodeIrohTunnelPreface(encodeIrohPairingFrame({ v: 1 }))).toThrow(
      "invalid shape",
    );
  });
});

describe("Iroh tunnel lifecycle", () => {
  it("terminates when the response closes while the QUIC send half remains open", async () => {
    const loopback = await makeCustomLoopback((_req, res) => {
      res.writeHead(200, { connection: "close", "content-length": "2" });
      res.end("ok");
    });
    const stream = makeOpenRequestStream(rawHttpRequest("/open-send-half"));
    const socket = await loopback.open({ clientNodeId: "client", bearerToken: "token" });

    await expect(pumpIrohTunnel(stream, socket)).resolves.toBeUndefined();

    expect(stream.recv.stop).toHaveBeenCalledOnce();
    expect(Buffer.concat(stream.writes.map(Buffer.from)).toString("utf8")).toContain(
      "HTTP/1.1 200 OK",
    );
  });

  it("preserves keep-alive requests and delayed chunked responses after request half-close", async () => {
    let requestCount = 0;
    const loopback = await makeCustomLoopback((req, res) => {
      requestCount += 1;
      if (req.url === "/delayed") {
        res.writeHead(200, { connection: "close", "transfer-encoding": "chunked" });
        setTimeout(() => {
          res.write("delayed-");
          setTimeout(() => res.end("response"), 10);
        }, 10);
        return;
      }
      res.writeHead(200, {
        connection: requestCount === 1 ? "keep-alive" : "close",
        "content-length": "2",
      });
      res.end("ok");
    });

    const keepAliveInput = Buffer.concat([
      rawHttpRequest("/first", "keep-alive"),
      rawHttpRequest("/second", "close"),
    ]);
    const keepAliveStream = makeStream(keepAliveInput);
    await pumpIrohTunnel(
      keepAliveStream,
      await loopback.open({ clientNodeId: "client", bearerToken: "token" }),
    );
    const keepAliveResponse = Buffer.concat(keepAliveStream.writes.map(Buffer.from)).toString(
      "utf8",
    );
    expect(keepAliveResponse.match(/HTTP\/1\.1 200 OK/g)).toHaveLength(2);

    const delayedStream = makeStream(rawHttpRequest("/delayed"));
    await pumpIrohTunnel(
      delayedStream,
      await loopback.open({ clientNodeId: "client", bearerToken: "token" }),
    );
    const delayedResponse = Buffer.concat(delayedStream.writes.map(Buffer.from)).toString("utf8");
    expect(delayedResponse).toContain("delayed-");
    expect(delayedResponse).toContain("response");
    expect(delayedResponse).toContain("transfer-encoding: chunked");
  });

  it("cancels the counterpart when either QUIC half resets", async () => {
    const loopback = await makeCustomLoopback((_req, res) => {
      setTimeout(() => res.end("late"), 50);
    });
    const recvReset = makeOpenRequestStream(
      rawHttpRequest("/recv-reset"),
      new Error("receive reset"),
    );
    await expect(
      pumpIrohTunnel(
        recvReset,
        await loopback.open({ clientNodeId: "client", bearerToken: "token" }),
      ),
    ).rejects.toThrow("receive reset");
    expect(recvReset.send.reset).toHaveBeenCalled();

    const sendReset = makeOpenRequestStream(rawHttpRequest("/send-reset"));
    sendReset.send.writeAll.mockRejectedValueOnce(new Error("send reset"));
    await expect(
      pumpIrohTunnel(
        sendReset,
        await loopback.open({ clientNodeId: "client", bearerToken: "token" }),
      ),
    ).rejects.toThrow("send reset");
    expect(sendReset.recv.stop).toHaveBeenCalled();
  });
});

describe("Iroh endpoint runtime", () => {
  it("reuses a stable endpoint and advertises scoped pairing plus HTTP tunnel ALPNs", async () => {
    const firstRuntime = makeRuntime();
    const first = await startIrohPairingServer(storage, {
      runtime: firstRuntime.runtime,
      onlineTimeoutMs: 50,
      tunnelTarget: nullTunnelTarget(),
    });
    const firstState = readIrohInviteState(dataDir);
    await first.close();

    expect(firstRuntime.runtime.Endpoint.bind).toHaveBeenCalledWith({
      alpns: [PAIR_ALPN_BYTES, HTTP_ALPN_BYTES],
    });
    expect(first.alpns).toEqual([IROH_PAIR_ALPN_TEXT, IROH_HTTP_ALPN_TEXT]);
    expect(firstState).toMatchObject({
      version: 2,
      nodeId: first.nodeId,
      alpns: [IROH_PAIR_ALPN_TEXT, IROH_HTTP_ALPN_TEXT],
      addressMode: "ticket",
    });
    expect(statSync(join(dataDir, "iroh", "server-secret.json")).mode & 0o777).toBe(0o600);
    expect(readIrohInviteState(dataDir)).toBeUndefined();

    const secondRuntime = makeRuntime();
    const second = await startIrohPairingServer(storage, {
      runtime: secondRuntime.runtime,
      onlineTimeoutMs: 50,
      tunnelTarget: nullTunnelTarget(),
    });
    await second.close();
    expect(secondRuntime.runtime.Endpoint.bind).toHaveBeenCalledWith({
      secretKey: Array(32).fill(7),
      alpns: [PAIR_ALPN_BYTES, HTTP_ALPN_BYTES],
    });
    expect(second.nodeId).toBe(first.nodeId);
  });

  it("pairs on the dedicated ALPN and binds the token to the remote node ID", async () => {
    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });
    const stream = makeStream(encodeIrohPairingFrame({ pairingToken }));
    const connection = makeIncoming({ streams: [stream], remoteId: "paired-node" });
    const fake = makeRuntime({ incoming: connection.incoming });
    const server = await startIrohPairingServer(storage, {
      runtime: fake.runtime,
      onlineTimeoutMs: 50,
      tunnelTarget: nullTunnelTarget(),
    });
    await waitFor(() => stream.writes.length > 0);
    await server.close();

    const response = decodeIrohPairingFrame(Uint8Array.from(stream.writes[0] ?? []));
    expect(response).toMatchObject({ ok: true, deviceToken: expect.stringMatching(/^dt_/) });
    expect(storage.getConfig().irohDeviceTokenBindings?.[0]).toMatchObject({
      token: response.deviceToken,
      clientNodeId: "paired-node",
      allowedTransports: ["iroh"],
    });
  });

  it("authenticates one preface and pumps raw HTTP through the existing loopback stack", async () => {
    const pairingToken = storage.issuePairingToken(60_000);
    const token = storage.consumePairingToken(pairingToken, {
      irohClientNodeId: "client-node-1",
      allowedTransports: ["iroh"],
    });
    if (!token) throw new Error("failed to issue token");

    const input = Buffer.concat([
      Buffer.from(encodeIrohTunnelPreface(`Bearer ${token}`)),
      rawHttpRequest("/through-existing-stack"),
    ]);
    const stream = makeStream(input);
    const connection = makeIncoming({
      alpn: HTTP_ALPN_BYTES,
      streams: [stream],
      remoteId: "client-node-1",
    });
    const fake = makeRuntime({ incoming: connection.incoming });
    const loopback = await makeLoopback();
    const server = await startIrohPairingServer(storage, {
      runtime: fake.runtime,
      onlineTimeoutMs: 50,
      tunnelTarget: loopback,
    });
    await waitFor(() => stream.send.finish.mock.calls.length > 0);
    await server.close();

    const response = Buffer.concat(stream.writes.map((bytes) => Buffer.from(bytes))).toString(
      "utf8",
    );
    expect(response).toContain("HTTP/1.1 200 OK");
    expect(response).toContain('"path":"/through-existing-stack"');
    expect(response).toContain('"clientNodeId":"client-node-1"');
    expect(connection.connection.setMaxConcurrentBiStreams).toHaveBeenCalledWith(16n);
  });

  it("rejects a valid bearer presented by the wrong Iroh node before opening loopback", async () => {
    const pairingToken = storage.issuePairingToken(60_000);
    const token = storage.consumePairingToken(pairingToken, {
      irohClientNodeId: "bound-node",
      allowedTransports: ["iroh"],
    });
    if (!token) throw new Error("failed to issue token");
    const stream = makeStream(encodeIrohTunnelPreface(`Bearer ${token}`));
    const connection = makeIncoming({
      alpn: HTTP_ALPN_BYTES,
      streams: [stream],
      remoteId: "attacker-node",
    });
    const fake = makeRuntime({ incoming: connection.incoming });
    const target = nullTunnelTarget();
    const server = await startIrohPairingServer(storage, {
      runtime: fake.runtime,
      onlineTimeoutMs: 50,
      tunnelTarget: target,
    });
    await waitFor(() => stream.send.finish.mock.calls.length > 0);
    await server.close();

    expect(target.open).not.toHaveBeenCalled();
    expect(Buffer.concat(stream.writes.map(Buffer.from)).toString("utf8")).toContain(
      "HTTP/1.1 403 Forbidden",
    );
  });

  it("bounds handshake, ALPN/connect, pairing stream, and pairing frame stalls", async () => {
    const fake = makeRuntime();
    const server = await startIrohPairingServer(storage, {
      runtime: fake.runtime,
      onlineTimeoutMs: 50,
      handshakeTimeoutMs: 5,
      pairingStreamTimeoutMs: 5,
      pairingFrameTimeoutMs: 5,
      maxConnections: 1,
      tunnelTarget: nullTunnelTarget(),
    });

    const stalledAccept = {
      accept: vi.fn(() => new Promise(() => {})),
      refuse: vi.fn(async () => {}),
    } as unknown as Incoming;
    fake.pushIncoming(stalledAccept);
    await waitFor(() => (stalledAccept.refuse as ReturnType<typeof vi.fn>).mock.calls.length > 0);

    const stalledAlpn = {
      accept: vi.fn(async () => ({
        alpn: vi.fn(() => new Promise(() => {})),
        connect: vi.fn(async () => {
          throw new Error("connect should not run");
        }),
      })),
      refuse: vi.fn(async () => {}),
    } as unknown as Incoming;
    fake.pushIncoming(stalledAlpn);
    await waitFor(() => (stalledAlpn.refuse as ReturnType<typeof vi.fn>).mock.calls.length > 0);

    const stalledConnect = {
      accept: vi.fn(async () => ({
        alpn: vi.fn(async () => PAIR_ALPN_BYTES),
        connect: vi.fn(() => new Promise(() => {})),
      })),
      refuse: vi.fn(async () => {}),
    } as unknown as Incoming;
    fake.pushIncoming(stalledConnect);
    await waitFor(() => (stalledConnect.refuse as ReturnType<typeof vi.fn>).mock.calls.length > 0);

    const noStream = makeIncoming({ streams: [] });
    noStream.connection.acceptBi.mockImplementation(() => new Promise(() => {}));
    fake.pushIncoming(noStream.incoming);
    await waitFor(() => noStream.close.mock.calls.length > 0);

    const incompleteFrame = makeStream(new Uint8Array());
    incompleteFrame.recv.readToEnd.mockImplementation(() => new Promise(() => {}));
    const stalledFrame = makeIncoming({ streams: [incompleteFrame] });
    fake.pushIncoming(stalledFrame.incoming);
    await waitFor(() => stalledFrame.close.mock.calls.length > 0);

    const pairingToken = storage.issuePairingToken(60_000, { allowedTransports: ["iroh"] });
    const legitimateStream = makeStream(encodeIrohPairingFrame({ pairingToken }));
    const legitimate = makeIncoming({ streams: [legitimateStream], remoteId: "legitimate-node" });
    fake.pushIncoming(legitimate.incoming);
    await waitFor(() => legitimateStream.writes.length > 0);
    expect(decodeIrohPairingFrame(Uint8Array.from(legitimateStream.writes[0] ?? []))).toMatchObject(
      {
        ok: true,
      },
    );

    await server.close();
  });

  it("clears readiness, closes the endpoint, and reports terminal accept-loop failure", async () => {
    const fake = makeRuntime();
    const failures: Error[] = [];
    const server = await startIrohPairingServer(storage, {
      runtime: fake.runtime,
      onlineTimeoutMs: 50,
      tunnelTarget: nullTunnelTarget(),
      onFailure: (error) => failures.push(error),
    });
    expect(readIrohInviteState(dataDir)).toBeDefined();

    fake.failAccept(new Error("accept failed after readiness"));
    await waitFor(() => failures.length > 0);

    expect(failures[0]?.message).toBe("accept failed after readiness");
    expect(readIrohInviteState(dataDir)).toBeUndefined();
    expect(fake.endpoints[0]?.close).toHaveBeenCalledOnce();
    await server.close();
  });

  it("bounds shutdown while an accepted pairing peer remains stalled", async () => {
    const incoming = makeIncoming({ streams: [] });
    incoming.connection.acceptBi.mockImplementation(() => new Promise(() => {}));
    const fake = makeRuntime({ incoming: incoming.incoming });
    const server = await startIrohPairingServer(storage, {
      runtime: fake.runtime,
      onlineTimeoutMs: 50,
      pairingStreamTimeoutMs: 60_000,
      shutdownTimeoutMs: 20,
      tunnelTarget: nullTunnelTarget(),
    });
    await waitFor(() => incoming.connection.acceptBi.mock.calls.length > 0);

    const startedAt = Date.now();
    await server.close();
    expect(Date.now() - startedAt).toBeLessThan(200);
    expect(incoming.close).toHaveBeenCalled();
  });

  it("fails startup closed when endpoint readiness times out and clears stale invite state", async () => {
    const irohDir = join(dataDir, "iroh");
    mkdirSync(irohDir, { recursive: true, mode: 0o700 });
    const stalePath = join(irohDir, "invite.json");
    writeFileSync(stalePath, JSON.stringify({ stale: true }), { mode: 0o600 });
    const fake = makeRuntime({ online: () => new Promise<void>(() => {}) });

    await expect(
      startIrohPairingServer(storage, {
        runtime: fake.runtime,
        onlineTimeoutMs: 5,
        tunnelTarget: nullTunnelTarget(),
      }),
    ).rejects.toThrow("Iroh endpoint did not become online within 5ms");
    expect(fake.endpoints[0]?.close).toHaveBeenCalledOnce();
    expect(existsSync(stalePath)).toBe(false);
  });
});
