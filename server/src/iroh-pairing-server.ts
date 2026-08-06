import { mkdir, readFile, rename, rm, writeFile, chmod } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import type { Socket } from "node:net";

import {
  Endpoint,
  EndpointTicket,
  RelayMap,
  RelayMode,
  type Incoming,
  type RelayConfig,
  type RelayMode as IrohRelayMode,
} from "@number0/iroh";

import { decodeIrohFrame, encodeIrohFrame } from "./iroh-frame-codec.js";
import {
  IROH_PAIR_ALPN_TEXT,
  clearIrohInviteState,
  irohDataDir,
  writeIrohInviteState,
} from "./iroh-invite-state.js";
import { handleIrohPairingRequest } from "./iroh-pairing.js";
import type { IrohLoopbackContext } from "./iroh-http-loopback.js";
import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";
import type { Storage } from "./storage.js";
import type { IrohRelayConfig } from "./types.js";

export { IROH_PAIR_ALPN_TEXT } from "./iroh-invite-state.js";
export const IROH_HTTP_ALPN_TEXT = "oppi/http/1";

const IROH_PAIR_ALPN = Array.from(Buffer.from(IROH_PAIR_ALPN_TEXT, "utf8"));
const IROH_HTTP_ALPN = Array.from(Buffer.from(IROH_HTTP_ALPN_TEXT, "utf8"));
const MAX_PAIRING_FRAME_HEADER_BYTES = 16 * 1024;
const MAX_PAIRING_FRAME_BYTES = 4 + MAX_PAIRING_FRAME_HEADER_BYTES;
const MAX_TUNNEL_PREFACE_BYTES = 4 * 1024;
const MAX_TUNNEL_BEARER_BYTES = 512;
const TUNNEL_READ_CHUNK_BYTES = 64 * 1024;
const DEFAULT_ONLINE_TIMEOUT_MS = 15_000;
const DEFAULT_PREFACE_TIMEOUT_MS = 10_000;
const DEFAULT_LOOPBACK_CONNECT_TIMEOUT_MS = 3_000;
const DEFAULT_HANDSHAKE_TIMEOUT_MS = 10_000;
const DEFAULT_PAIRING_STREAM_TIMEOUT_MS = 10_000;
const DEFAULT_PAIRING_FRAME_TIMEOUT_MS = 10_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS = 5_000;
const PUMP_CANCEL_TIMEOUT_MS = 1_000;
const MAX_CONNECTIONS = 64;
const MAX_STREAMS_PER_CONNECTION = 16;
const MAX_ACTIVE_TUNNELS = 128;
const QUIC_APPLICATION_ERROR = 1n;

const log = createLogger({ base: { component: "iroh_transport" } });

type IrohSecretState = {
  endpointId?: string;
  secretKey?: number[];
};

type IrohRecvStream = {
  read(sizeLimit: number): Promise<number[]>;
  readExact(size: number): Promise<number[]>;
  readToEnd(maxBytes: number): Promise<number[]>;
  stop(errorCode: bigint): Promise<void>;
};

type IrohSendStream = {
  writeAll(bytes: number[]): Promise<void>;
  finish(): Promise<void>;
  reset(errorCode: bigint): Promise<void>;
};

type IrohBiStream = {
  recv: IrohRecvStream;
  send: IrohSendStream;
};

type IrohConnection = {
  acceptBi(): Promise<IrohBiStream>;
  remoteId(): { toString(): string };
  closed?(): Promise<string>;
  close(errorCode: bigint, reason: number[]): void;
  setMaxConcurrentBiStreams?(count: bigint): void;
};

type IrohEndpoint = {
  id(): { toString(): string };
  addr(): { relayUrl?: () => string | null };
  secretKey(): { toBytes(): number[] };
  online(): Promise<void>;
  acceptNext(): Promise<Incoming | null>;
  close(): Promise<void>;
  isClosed(): boolean;
};

type IrohRelayMap = {
  insert(config: RelayConfig): void;
};

type IrohRuntime = {
  Endpoint: {
    bind(
      options?: { secretKey?: number[]; alpns?: number[][] } | null,
      relayMode?: IrohRelayMode | null,
    ): Promise<IrohEndpoint>;
  };
  EndpointTicket: {
    fromAddr(addr: unknown): { toString(): string };
  };
  RelayMap: {
    empty(): IrohRelayMap;
  };
  RelayMode: {
    custom(map: IrohRelayMap): IrohRelayMode;
  };
};

class TunnelLimiter {
  private active = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(private readonly limit: number) {}

  async acquire(): Promise<() => void> {
    if (this.active >= this.limit) {
      await new Promise<void>((resolve) => this.waiters.push(resolve));
    }
    this.active += 1;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.active -= 1;
      this.waiters.shift()?.();
    };
  }
}

export interface IrohTunnelTarget {
  open(context: IrohLoopbackContext): Promise<Socket>;
}

export interface IrohPairingServerOptions {
  runtime?: IrohRuntime;
  onlineTimeoutMs?: number;
  handshakeTimeoutMs?: number;
  pairingStreamTimeoutMs?: number;
  pairingFrameTimeoutMs?: number;
  tunnelPrefaceTimeoutMs?: number;
  loopbackConnectTimeoutMs?: number;
  shutdownTimeoutMs?: number;
  maxConnections?: number;
  readinessId?: string;
  onFailure?: (error: Error) => void;
  tunnelTarget?: IrohTunnelTarget;
}

export interface RunningIrohPairingServer {
  nodeId: string;
  ticket: string;
  alpns: string[];
  close(): Promise<void>;
}

export type IrohTunnelPreface = {
  v: 1;
  kind: "httpTunnel";
  authorization: string;
};

function customRelayMode(
  runtime: IrohRuntime,
  relays: readonly IrohRelayConfig[],
): IrohRelayMode | undefined {
  if (relays.length === 0) return undefined;
  const relayMap = runtime.RelayMap.empty();
  for (const relay of relays) {
    relayMap.insert({
      url: relay.url,
      ...(relay.quicPort === undefined ? {} : { quicPort: relay.quicPort }),
    });
  }
  return runtime.RelayMode.custom(relayMap);
}

function ticketHomeRelay(addr: { relayUrl?: () => string | null }): string | undefined {
  const relayUrl = addr.relayUrl?.();
  return relayUrl ?? undefined;
}

function canonicalRelayOrigin(relayUrl: string | undefined): string | undefined {
  if (!relayUrl) return undefined;
  try {
    return new URL(relayUrl).origin;
  } catch {
    return undefined;
  }
}

function relayHostForDiagnostic(relayUrl: string | undefined): string {
  if (!relayUrl) return "unknown";
  try {
    return new URL(relayUrl).hostname || "unknown";
  } catch {
    return "unknown";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function encodeIrohPairingFrame(value: unknown): Uint8Array {
  if (!isRecord(value)) {
    throw new Error("Iroh pairing frame JSON header must be a JSON object");
  }
  return encodeIrohFrame(value);
}

export function decodeIrohPairingFrame(bytes: Uint8Array): Record<string, unknown> {
  try {
    return decodeIrohFrame(bytes, {
      maxHeaderBytes: MAX_PAIRING_FRAME_HEADER_BYTES,
      maxBodyBytes: 0,
    }).header;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(message.replace(/^Iroh frame/, "Iroh pairing frame"), { cause: error });
  }
}

export function encodeIrohTunnelPreface(authorization: string): Uint8Array {
  return encodeIrohFrame({ v: 1, kind: "httpTunnel", authorization });
}

export function decodeIrohTunnelPreface(bytes: Uint8Array): IrohTunnelPreface {
  const header = decodeIrohFrame(bytes, {
    maxHeaderBytes: MAX_TUNNEL_PREFACE_BYTES,
    maxBodyBytes: 0,
  }).header;
  if (header.v !== 1 || header.kind !== "httpTunnel" || typeof header.authorization !== "string") {
    throw new Error("Iroh tunnel preface has an invalid shape");
  }
  if (Buffer.byteLength(header.authorization, "utf8") > MAX_TUNNEL_BEARER_BYTES) {
    throw new Error("Iroh tunnel bearer exceeds its size limit");
  }
  return { v: 1, kind: "httpTunnel", authorization: header.authorization };
}

function secretPath(dataDir: string): string {
  return join(irohDataDir(dataDir), "server-secret.json");
}

async function ensurePrivateIrohDir(dataDir: string): Promise<string> {
  const dir = irohDataDir(dataDir);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(dir, 0o700).catch(() => {});
  return dir;
}

function isSecretBytes(value: unknown): value is number[] {
  return (
    Array.isArray(value) &&
    value.length === 32 &&
    value.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255)
  );
}

async function loadSecretBytes(dataDir: string): Promise<number[] | undefined> {
  const path = secretPath(dataDir);
  try {
    await chmod(path, 0o600).catch(() => {});
    const parsed = JSON.parse(await readFile(path, "utf8")) as IrohSecretState;
    return isSecretBytes(parsed.secretKey) ? parsed.secretKey : undefined;
  } catch {
    return undefined;
  }
}

async function writePrivateJsonFile(path: string, value: unknown): Promise<void> {
  const tempPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
    await chmod(tempPath, 0o600).catch(() => {});
    await rename(tempPath, path);
    await chmod(path, 0o600).catch(() => {});
  } catch (error) {
    await rm(tempPath, { force: true }).catch(() => {});
    throw error;
  }
}

async function saveSecretBytes(dataDir: string, endpoint: IrohEndpoint): Promise<void> {
  const dir = await ensurePrivateIrohDir(dataDir);
  await writePrivateJsonFile(join(dir, "server-secret.json"), {
    endpointId: endpoint.id().toString(),
    secretKey: endpoint.secretKey().toBytes(),
  } satisfies IrohSecretState);
}

async function withTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
  message: string,
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), timeoutMs);
        timer.unref?.();
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function waitForOnline(endpoint: IrohEndpoint, timeoutMs: number): Promise<void> {
  await withTimeout(
    endpoint.online(),
    timeoutMs,
    `Iroh endpoint did not become online within ${timeoutMs}ms`,
  );
}

async function closeAfterPeerDrains(conn: IrohConnection, reason: string): Promise<void> {
  if (conn.closed) {
    await withTimeout(conn.closed(), 2_000, "Iroh peer drain timed out").catch(() => {});
  }
  conn.close(0n, Array.from(Buffer.from(reason, "utf8")));
}

async function handleIncomingPairing(
  storage: Storage,
  conn: IrohConnection,
  options: IrohPairingServerOptions,
): Promise<void> {
  try {
    const pairingStreamTimeoutMs =
      options.pairingStreamTimeoutMs ?? DEFAULT_PAIRING_STREAM_TIMEOUT_MS;
    const stream = await withTimeout(
      conn.acceptBi(),
      pairingStreamTimeoutMs,
      `Iroh pairing stream timed out after ${pairingStreamTimeoutMs}ms`,
    );
    let request: unknown = {};
    try {
      const pairingFrameTimeoutMs =
        options.pairingFrameTimeoutMs ?? DEFAULT_PAIRING_FRAME_TIMEOUT_MS;
      request = decodeIrohPairingFrame(
        Buffer.from(
          await withTimeout(
            stream.recv.readToEnd(MAX_PAIRING_FRAME_BYTES),
            pairingFrameTimeoutMs,
            `Iroh pairing frame timed out after ${pairingFrameTimeoutMs}ms`,
          ),
        ),
      );
    } catch (error) {
      log.warn("iroh_pairing.invalid_frame", { error: safeErrorMessage(error) });
    }

    const response = handleIrohPairingRequest(storage, request, {
      transport: "iroh",
      clientNodeId: conn.remoteId().toString(),
    });
    const responsePayload = response.ok
      ? {
          v: 1,
          kind: "pairResponse",
          ok: true,
          deviceToken: response.deviceToken,
          credentialTransports: response.credentialTransports,
        }
      : { v: 1, kind: "pairResponse", ok: false, status: response.status, error: response.error };

    await stream.send.writeAll(Array.from(encodeIrohPairingFrame(responsePayload)));
    await stream.send.finish();
  } finally {
    await closeAfterPeerDrains(conn, "pairing complete");
  }
}

async function readTunnelPreface(
  stream: IrohBiStream,
  timeoutMs: number,
): Promise<IrohTunnelPreface> {
  const lengthBytes = Buffer.from(
    await withTimeout(
      stream.recv.readExact(4),
      timeoutMs,
      `Iroh tunnel preface length timed out after ${timeoutMs}ms`,
    ),
  );
  if (lengthBytes.length !== 4) throw new Error("Iroh tunnel preface length is truncated");
  const length = lengthBytes.readUInt32BE(0);
  if (length === 0 || length > MAX_TUNNEL_PREFACE_BYTES) {
    throw new Error(`Iroh tunnel preface exceeds ${MAX_TUNNEL_PREFACE_BYTES} bytes`);
  }
  const header = Buffer.from(
    await withTimeout(
      stream.recv.readExact(length),
      timeoutMs,
      `Iroh tunnel preface body timed out after ${timeoutMs}ms`,
    ),
  );
  return decodeIrohTunnelPreface(Buffer.concat([lengthBytes, header]));
}

function bearerFromAuthorization(value: string): string | undefined {
  if (!value.startsWith("Bearer ")) return undefined;
  const token = value.slice(7);
  return token.length > 0 ? token : undefined;
}

async function writeTunnelHttpError(
  stream: IrohBiStream,
  status: 400 | 401 | 403 | 503,
  code?:
    | "missing_bearer"
    | "unknown_token"
    | "forbidden_transport"
    | "binding_missing"
    | "binding_mismatch",
): Promise<void> {
  const reason =
    status === 400
      ? "Bad Request"
      : status === 401
        ? "Unauthorized"
        : status === 403
          ? "Forbidden"
          : "Service Unavailable";
  const body = Buffer.from(
    JSON.stringify({
      error: reason.toLowerCase().replaceAll(" ", "_"),
      ...(code ? { code } : {}),
    }),
  );
  const response = Buffer.from(
    `HTTP/1.1 ${status} ${reason}\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n`,
    "utf8",
  );
  await stream.send.writeAll(Array.from(Buffer.concat([response, body])));
  await stream.send.finish();
  await stream.recv.stop(QUIC_APPLICATION_ERROR).catch(() => {});
}

type PumpResult = { lane: "request" | "response"; error?: unknown };

export async function pumpIrohTunnel(stream: IrohBiStream, socket: Socket): Promise<void> {
  let requestBytes = 0;
  let responseBytes = 0;

  const requestPump = (async (): Promise<void> => {
    while (!socket.destroyed) {
      const bytes = await stream.recv.read(TUNNEL_READ_CHUNK_BYTES);
      if (bytes.length === 0) {
        // HTTP framing already marks complete requests. Do not propagate QUIC
        // request EOF as a TCP FIN: Node may tear down the accepted socket
        // before a delayed/chunked response writes its final bytes.
        return;
      }
      requestBytes += bytes.length;
      if (!socket.write(Buffer.from(bytes))) await once(socket, "drain");
    }
  })();

  const responsePump = (async (): Promise<void> => {
    for await (const chunk of socket) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      responseBytes += bytes.length;
      await stream.send.writeAll(Array.from(bytes));
    }
    await stream.send.finish();
  })();

  const settle = (lane: PumpResult["lane"], promise: Promise<void>): Promise<PumpResult> =>
    promise.then(
      () => ({ lane }),
      (error: unknown) => ({ lane, error }),
    );
  const first = await Promise.race([
    settle("request", requestPump),
    settle("response", responsePump),
  ]);

  let failure = first.error;
  if (first.lane === "request" && !first.error) {
    // Request EOF is not tunnel completion. Wait for the full delayed response.
    const response = await settle("response", responsePump);
    failure = response.error;
  } else if (first.lane === "request") {
    socket.destroy();
    await stream.send.reset(QUIC_APPLICATION_ERROR).catch(() => {});
    await withTimeout(
      settle("response", responsePump),
      PUMP_CANCEL_TIMEOUT_MS,
      "Iroh response pump cancellation timed out",
    ).catch((): PumpResult => ({ lane: "response" }));
  } else {
    // Response close/reset is terminal even if the peer kept its request half
    // open. Stop the blocked receive so this tunnel releases its slot.
    await stream.recv.stop(QUIC_APPLICATION_ERROR).catch(() => {});
    socket.destroy();
    await withTimeout(
      settle("request", requestPump),
      PUMP_CANCEL_TIMEOUT_MS,
      "Iroh request pump cancellation timed out",
    ).catch((): PumpResult => ({ lane: "request" }));
  }

  socket.destroy();
  log.debug("iroh_tunnel.pump_completed", { requestBytes, responseBytes });
  if (failure) {
    await stream.recv.stop(QUIC_APPLICATION_ERROR).catch(() => {});
    await stream.send.reset(QUIC_APPLICATION_ERROR).catch(() => {});
    throw failure;
  }
}

async function handleTunnelStream(
  storage: Storage,
  target: IrohTunnelTarget,
  stream: IrohBiStream,
  clientNodeId: string,
  options: IrohPairingServerOptions,
): Promise<void> {
  let preface: IrohTunnelPreface;
  try {
    preface = await readTunnelPreface(
      stream,
      options.tunnelPrefaceTimeoutMs ?? DEFAULT_PREFACE_TIMEOUT_MS,
    );
  } catch (error) {
    log.warn("iroh_tunnel.preface_rejected", {
      clientNodeId,
      error: safeErrorMessage(error),
    });
    await writeTunnelHttpError(stream, 400).catch(() => {});
    return;
  }

  const bearerToken = bearerFromAuthorization(preface.authorization);
  if (!bearerToken) {
    log.warn("iroh_tunnel.auth_rejected", { clientNodeId, code: "missing_bearer" });
    await writeTunnelHttpError(stream, 401, "missing_bearer").catch(() => {});
    return;
  }
  const auth = storage.validateIrohDeviceToken(bearerToken, clientNodeId);
  if (!auth.ok) {
    log.warn("iroh_tunnel.auth_rejected", { clientNodeId, code: auth.code });
    await writeTunnelHttpError(stream, auth.code === "unknown_token" ? 401 : 403, auth.code).catch(
      () => {},
    );
    return;
  }

  log.debug("iroh_tunnel.authenticated", { clientNodeId });
  let socket: Socket;
  const openSocket = target.open({ clientNodeId, bearerToken });
  try {
    socket = await withTimeout(
      openSocket,
      options.loopbackConnectTimeoutMs ?? DEFAULT_LOOPBACK_CONNECT_TIMEOUT_MS,
      "Iroh tunnel loopback connection timed out",
    );
  } catch (error) {
    void openSocket.then((lateSocket) => lateSocket.destroy()).catch(() => {});
    log.error("iroh_tunnel.loopback_failed", {
      clientNodeId,
      error: safeErrorMessage(error),
    });
    await writeTunnelHttpError(stream, 503).catch(() => {});
    return;
  }

  try {
    await pumpIrohTunnel(stream, socket);
  } catch (error) {
    log.warn("iroh_tunnel.pump_failed", {
      clientNodeId,
      error: safeErrorMessage(error),
    });
  }
}

async function handleTunnelConnection(
  storage: Storage,
  target: IrohTunnelTarget,
  conn: IrohConnection,
  options: IrohPairingServerOptions,
  limiter: TunnelLimiter,
): Promise<void> {
  conn.setMaxConcurrentBiStreams?.(BigInt(MAX_STREAMS_PER_CONNECTION));
  const clientNodeId = conn.remoteId().toString();
  const active = new Set<Promise<void>>();
  try {
    while (true) {
      if (active.size >= MAX_STREAMS_PER_CONNECTION) {
        await Promise.race(active);
        continue;
      }
      const stream = await conn.acceptBi();
      const release = await limiter.acquire();
      const task = handleTunnelStream(storage, target, stream, clientNodeId, options).finally(
        () => {
          release();
          active.delete(task);
        },
      );
      active.add(task);
    }
  } catch (error) {
    conn.close(0n, Array.from(Buffer.from("tunnel connection complete", "utf8")));
    if (active.size > 0) {
      const shutdownTimeoutMs = options.shutdownTimeoutMs ?? DEFAULT_SHUTDOWN_TIMEOUT_MS;
      await withTimeout(
        Promise.allSettled(active),
        shutdownTimeoutMs,
        "Iroh active tunnel shutdown timed out",
      ).catch(() => {});
    }
    const message = safeErrorMessage(error);
    if (!message.toLowerCase().includes("closed")) {
      log.debug("iroh_tunnel.connection_ended", { clientNodeId, error: message });
    }
  } finally {
    conn.close(0n, Array.from(Buffer.from("tunnel connection complete", "utf8")));
  }
}

async function handleIncoming(
  storage: Storage,
  options: IrohPairingServerOptions,
  incoming: Incoming,
  limiter: TunnelLimiter,
  activeConnections: Set<IrohConnection>,
): Promise<void> {
  const handshakeTimeoutMs = options.handshakeTimeoutMs ?? DEFAULT_HANDSHAKE_TIMEOUT_MS;
  let conn: IrohConnection | undefined;
  try {
    const accepting = await withTimeout(
      incoming.accept(),
      handshakeTimeoutMs,
      `Iroh incoming accept timed out after ${handshakeTimeoutMs}ms`,
    );
    const acceptedAlpn = Buffer.from(
      await withTimeout(
        accepting.alpn(),
        handshakeTimeoutMs,
        `Iroh ALPN negotiation timed out after ${handshakeTimeoutMs}ms`,
      ),
    ).toString("utf8");
    conn = (await withTimeout(
      accepting.connect(),
      handshakeTimeoutMs,
      `Iroh connection completion timed out after ${handshakeTimeoutMs}ms`,
    )) as unknown as IrohConnection;
    activeConnections.add(conn);

    if (acceptedAlpn === IROH_PAIR_ALPN_TEXT) {
      await handleIncomingPairing(storage, conn, options);
      return;
    }
    if (acceptedAlpn === IROH_HTTP_ALPN_TEXT && options.tunnelTarget) {
      await handleTunnelConnection(storage, options.tunnelTarget, conn, options, limiter);
      return;
    }
    conn.close(QUIC_APPLICATION_ERROR, Array.from(Buffer.from("unsupported alpn", "utf8")));
    throw new Error(`Unexpected Iroh ALPN: ${acceptedAlpn}`);
  } catch (error) {
    if (!conn) await incoming.refuse().catch(() => {});
    throw error;
  } finally {
    if (conn) activeConnections.delete(conn);
  }
}

export async function startIrohPairingServer(
  storage: Storage,
  options: IrohPairingServerOptions = {},
): Promise<RunningIrohPairingServer> {
  if (!options.tunnelTarget) {
    throw new Error("Iroh HTTP tunnel target is required");
  }

  const dataDir = storage.getDataDir();
  clearIrohInviteState(dataDir);
  const runtime: IrohRuntime = options.runtime ?? { Endpoint, EndpointTicket, RelayMap, RelayMode };
  const configuredRelays = storage.getConfig().iroh?.relays ?? [];
  const relayMode = customRelayMode(runtime, configuredRelays);
  const secretKey = await loadSecretBytes(dataDir);
  const bindOptions = {
    ...(secretKey ? { secretKey } : {}),
    alpns: [IROH_PAIR_ALPN, IROH_HTTP_ALPN],
  };
  // @number0/iroh@1.0.0 accepts custom RelayMode as Endpoint.bind's second argument.
  const endpoint =
    relayMode === undefined
      ? await runtime.Endpoint.bind(bindOptions)
      : await runtime.Endpoint.bind(bindOptions, relayMode);

  try {
    await waitForOnline(endpoint, options.onlineTimeoutMs ?? DEFAULT_ONLINE_TIMEOUT_MS);
  } catch (error) {
    await endpoint.close().catch(() => {});
    clearIrohInviteState(dataDir);
    throw error;
  }

  await saveSecretBytes(dataDir, endpoint);

  let stopping = false;
  let closePromise: Promise<void> | undefined;
  const limiter = new TunnelLimiter(MAX_ACTIVE_TUNNELS);
  const connections = new Set<Promise<void>>();
  const activeConnections = new Set<IrohConnection>();
  const maxConnections = options.maxConnections ?? MAX_CONNECTIONS;
  const shutdownTimeoutMs = options.shutdownTimeoutMs ?? DEFAULT_SHUTDOWN_TIMEOUT_MS;

  const nodeId = endpoint.id().toString();
  const endpointAddr = endpoint.addr();
  const ticket = runtime.EndpointTicket.fromAddr(endpointAddr).toString();
  const homeRelay = ticketHomeRelay(endpointAddr);
  const alpns = [IROH_PAIR_ALPN_TEXT, IROH_HTTP_ALPN_TEXT];

  const homeRelayOrigin = canonicalRelayOrigin(homeRelay);
  if (
    configuredRelays.length > 0 &&
    !configuredRelays.some((relay) => canonicalRelayOrigin(relay.url) === homeRelayOrigin)
  ) {
    await endpoint.close().catch(() => {});
    clearIrohInviteState(dataDir);
    throw new Error(
      `Iroh ticket home relay host ${relayHostForDiagnostic(homeRelay)} is not in the configured custom relay set`,
    );
  }

  writeIrohInviteState(dataDir, {
    version: 2,
    nodeId,
    alpns,
    addressMode: "ticket",
    ticket,
    relayMode: configuredRelays.length > 0 ? "custom" : "default",
    ...(configuredRelays.length > 0
      ? { relayUrls: configuredRelays.map((relay) => relay.url) }
      : {}),
    ...(homeRelay ? { ticketHomeRelay: homeRelay } : {}),
    readinessId: options.readinessId ?? randomUUID(),
    processId: process.pid,
  });

  const acceptLoop = (async () => {
    while (!stopping && !endpoint.isClosed()) {
      const incoming = await endpoint.acceptNext();
      if (!incoming) {
        if (!stopping && !endpoint.isClosed()) {
          throw new Error("Iroh accept loop ended unexpectedly");
        }
        return;
      }
      if (connections.size >= maxConnections) {
        await incoming.refuse();
        log.warn("iroh_transport.connection_rejected", { reason: "connection_limit" });
        continue;
      }
      const task = handleIncoming(storage, options, incoming, limiter, activeConnections)
        .catch((error: unknown) => {
          if (!stopping) {
            log.warn("iroh_transport.connection_failed", { error: safeErrorMessage(error) });
          }
        })
        .finally(() => connections.delete(task));
      connections.add(task);
    }
  })().catch(async (error: unknown) => {
    if (stopping) return;
    const failure = error instanceof Error ? error : new Error(safeErrorMessage(error));
    clearIrohInviteState(dataDir);
    log.error("iroh_transport.accept_loop_failed", { error: failure.message });
    for (const conn of activeConnections) {
      conn.close(QUIC_APPLICATION_ERROR, Array.from(Buffer.from("accept loop failed", "utf8")));
    }
    await withTimeout(
      endpoint.close(),
      shutdownTimeoutMs,
      "Iroh failed endpoint close timed out",
    ).catch(() => {});
    options.onFailure?.(failure);
  });

  log.info("iroh_transport.started", {
    nodeId,
    maxConnections,
    maxStreamsPerConnection: MAX_STREAMS_PER_CONNECTION,
    maxActiveTunnels: MAX_ACTIVE_TUNNELS,
  });

  return {
    nodeId,
    ticket,
    alpns,
    async close() {
      if (closePromise) return closePromise;
      stopping = true;
      closePromise = (async () => {
        try {
          for (const conn of activeConnections) {
            conn.close(0n, Array.from(Buffer.from("server stopping", "utf8")));
          }
          await withTimeout(
            Promise.allSettled([endpoint.close(), acceptLoop, Promise.allSettled(connections)]),
            shutdownTimeoutMs,
            "Iroh shutdown timed out",
          ).catch(() => {});
        } finally {
          clearIrohInviteState(dataDir);
        }
        log.info("iroh_transport.stopped", { nodeId });
      })();
      return closePromise;
    },
  };
}
