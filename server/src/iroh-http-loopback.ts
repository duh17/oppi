import { randomBytes } from "node:crypto";
import {
  createServer as createHttpServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import { createServer as createNetServer, createConnection, type Socket } from "node:net";
import type { Duplex } from "node:stream";

const LOOPBACK_HOST = "127.0.0.1";
const INTERNAL_PREFACE_MAX_BYTES = 1024;
const INTERNAL_PREFACE_TIMEOUT_MS = 3_000;
const INTERNAL_ACK = Buffer.from([0x06]);

export interface IrohLoopbackContext {
  clientNodeId: string;
  bearerToken: string;
}

export interface RunningIrohHttpLoopback {
  open(context: IrohLoopbackContext): Promise<Socket>;
  contextFor(req: IncomingMessage): IrohLoopbackContext | undefined;
  close(): Promise<void>;
}

export interface IrohHttpLoopbackOptions {
  handleRequest(req: IncomingMessage, res: ServerResponse): void;
  handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void;
  maxConnections?: number;
  internalPrefaceTimeoutMs?: number;
}

type InternalPreface = {
  secret: string;
  clientNodeId: string;
  bearerToken: string;
};

function encodeInternalPreface(preface: InternalPreface): Buffer {
  const body = Buffer.from(JSON.stringify(preface), "utf8");
  if (body.length > INTERNAL_PREFACE_MAX_BYTES) {
    throw new Error("Iroh internal loopback preface exceeds its size limit");
  }
  const frame = Buffer.allocUnsafe(4 + body.length);
  frame.writeUInt32BE(body.length, 0);
  body.copy(frame, 4);
  return frame;
}

function readInternalPreface(
  socket: Socket,
  timeoutMs: number,
): Promise<{ preface: InternalPreface; remainder: Buffer }> {
  return new Promise((resolve, reject) => {
    let buffered = Buffer.alloc(0);
    const timer = setTimeout(
      () => fail(new Error("Iroh internal loopback preface timed out")),
      timeoutMs,
    );
    timer.unref?.();

    const cleanup = (): void => {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", fail);
      socket.off("close", onClose);
    };
    const fail = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const onClose = (): void =>
      fail(new Error("Iroh internal loopback socket closed during preface"));
    const onData = (chunk: Buffer): void => {
      buffered = Buffer.concat([buffered, chunk]);
      if (buffered.length < 4) return;
      const length = buffered.readUInt32BE(0);
      if (length === 0 || length > INTERNAL_PREFACE_MAX_BYTES) {
        fail(new Error("Iroh internal loopback preface has an invalid size"));
        return;
      }
      if (buffered.length < 4 + length) return;

      let parsed: unknown;
      try {
        parsed = JSON.parse(buffered.subarray(4, 4 + length).toString("utf8")) as unknown;
      } catch {
        fail(new Error("Iroh internal loopback preface contains malformed JSON"));
        return;
      }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        fail(new Error("Iroh internal loopback preface must be an object"));
        return;
      }
      const record = parsed as Record<string, unknown>;
      if (
        typeof record.secret !== "string" ||
        typeof record.clientNodeId !== "string" ||
        typeof record.bearerToken !== "string"
      ) {
        fail(new Error("Iroh internal loopback preface is missing fields"));
        return;
      }
      cleanup();
      resolve({
        preface: {
          secret: record.secret,
          clientNodeId: record.clientNodeId,
          bearerToken: record.bearerToken,
        },
        remainder: buffered.subarray(4 + length),
      });
    };

    socket.on("data", onData);
    socket.once("error", fail);
    socket.once("close", onClose);
    socket.resume();
  });
}

function waitForAck(socket: Socket, timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => fail(new Error("Iroh internal loopback acknowledgement timed out")),
      timeoutMs,
    );
    timer.unref?.();
    const cleanup = (): void => {
      clearTimeout(timer);
      socket.off("data", onData);
      socket.off("error", fail);
      socket.off("close", onClose);
    };
    const fail = (error: Error): void => {
      cleanup();
      reject(error);
    };
    const onClose = (): void =>
      fail(new Error("Iroh internal loopback socket closed before acknowledgement"));
    const onData = (chunk: Buffer): void => {
      if (chunk.length !== 1 || chunk[0] !== INTERNAL_ACK[0]) {
        fail(new Error("Iroh internal loopback returned an invalid acknowledgement"));
        return;
      }
      cleanup();
      resolve();
    };
    socket.once("data", onData);
    socket.once("error", fail);
    socket.once("close", onClose);
    socket.resume();
  });
}

export async function startIrohHttpLoopback(
  options: IrohHttpLoopbackOptions,
): Promise<RunningIrohHttpLoopback> {
  const secret = randomBytes(32).toString("base64url");
  const contexts = new WeakMap<Socket, IrohLoopbackContext>();
  const sockets = new Set<Socket>();
  const timeoutMs = options.internalPrefaceTimeoutMs ?? INTERNAL_PREFACE_TIMEOUT_MS;

  const httpServer = createHttpServer((req, res) => options.handleRequest(req, res));
  httpServer.requestTimeout = 300_000;
  httpServer.headersTimeout = 15_000;
  httpServer.keepAliveTimeout = 5_000;
  httpServer.maxRequestsPerSocket = 100;
  httpServer.on("upgrade", (req, socket, head) => options.handleUpgrade(req, socket, head));

  // A QUIC sender can finish its request half before Node writes the HTTP
  // response. Keep the accepted TCP write half open until the HTTP server ends it.
  const listener = createNetServer({ allowHalfOpen: true }, (socket) => {
    sockets.add(socket);
    socket.pause();
    socket.once("close", () => sockets.delete(socket));
    void readInternalPreface(socket, timeoutMs)
      .then(({ preface, remainder }) => {
        if (preface.secret !== secret) {
          throw new Error("Iroh internal loopback authentication failed");
        }
        const context = {
          clientNodeId: preface.clientNodeId,
          bearerToken: preface.bearerToken,
        };
        contexts.set(socket, context);
        socket.write(INTERNAL_ACK);
        if (remainder.length > 0) socket.unshift(remainder);
        httpServer.emit("connection", socket);
        socket.resume();
      })
      .catch(() => socket.destroy());
  });
  listener.maxConnections = options.maxConnections ?? 128;

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => reject(error);
    listener.once("error", onError);
    listener.listen(0, LOOPBACK_HOST, () => {
      listener.off("error", onError);
      resolve();
    });
  });

  const address = listener.address();
  if (!address || typeof address === "string") {
    listener.close();
    throw new Error("Iroh internal loopback listener did not expose a TCP address");
  }

  let closed = false;
  return {
    async open(context) {
      if (closed) throw new Error("Iroh internal loopback listener is closed");
      const socket = createConnection({ host: LOOPBACK_HOST, port: address.port });
      socket.pause();
      socket.setNoDelay(true);
      socket.setKeepAlive(true, 30_000);
      try {
        await new Promise<void>((resolve, reject) => {
          socket.once("connect", resolve);
          socket.once("error", reject);
        });
        socket.write(
          encodeInternalPreface({
            secret,
            clientNodeId: context.clientNodeId,
            bearerToken: context.bearerToken,
          }),
        );
        await waitForAck(socket, timeoutMs);
        socket.pause();
        return socket;
      } catch (error) {
        socket.destroy();
        throw error;
      }
    },
    contextFor(req) {
      return contexts.get(req.socket);
    },
    async close() {
      if (closed) return;
      closed = true;
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => listener.close(() => resolve()));
      httpServer.close();
    },
  };
}
