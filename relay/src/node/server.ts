/** Node adapter: the relay core behind `node:http`. Local development, forks, and capture. */

import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import type { ApnsSender } from "../core/apns.js";
import { createRelayHandler, type RelayConfig, type RelayLog } from "../core/relay.js";
import type { RelayStore } from "../core/store.js";

const MAX_REQUEST_BYTES = 16 * 1024;

export interface NodeRelayOptions {
  store: RelayStore;
  apns: ApnsSender;
  config: RelayConfig;
  log?: RelayLog;
  now?: () => number;
  host?: string;
  port?: number;
  /** Behind a reverse proxy: take the client address from the first `X-Forwarded-For` entry. */
  trustForwardedFor?: boolean;
}

export interface NodeRelay {
  server: Server;
  url: string;
  close(): Promise<void>;
}

async function toRequest(req: IncomingMessage, origin: string): Promise<Request> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    // The core enforces the 8 KiB body cap; this only stops unbounded reads.
    if (size > MAX_REQUEST_BYTES) break;
    chunks.push(chunk as Buffer);
  }
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (typeof value === "string") headers.set(name, value);
    else if (Array.isArray(value)) headers.set(name, value.join(", "));
  }
  const method = req.method ?? "GET";
  return new Request(new URL(req.url ?? "/", origin), {
    method,
    headers,
    ...(method === "GET" || method === "HEAD" ? {} : { body: Buffer.concat(chunks) }),
  });
}

async function writeResponse(res: ServerResponse, response: Response): Promise<void> {
  res.statusCode = response.status;
  response.headers.forEach((value, name) => res.setHeader(name, value));
  res.end(Buffer.from(await response.arrayBuffer()));
}

export async function startNodeRelay(options: NodeRelayOptions): Promise<NodeRelay> {
  const handle = createRelayHandler({
    store: options.store,
    apns: options.apns,
    config: options.config,
    ...(options.log ? { log: options.log } : {}),
    ...(options.now ? { now: options.now } : {}),
  });
  const host = options.host ?? "127.0.0.1";
  const server = createServer((req, res) => {
    void (async () => {
      try {
        const request = await toRequest(req, `http://${host}`);
        const forwarded = options.trustForwardedFor
          ? request.headers.get("x-forwarded-for")?.split(",")[0]?.trim()
          : undefined;
        // The address feeds in-memory rate limits only; it is never stored or logged.
        await writeResponse(
          res,
          await handle(request, forwarded || (req.socket.remoteAddress ?? null)),
        );
      } catch {
        res.statusCode = 400;
        res.end();
      }
    })();
  });
  await new Promise<void>((resolve) => server.listen(options.port ?? 0, host, resolve));
  const { port } = server.address() as AddressInfo;
  return {
    server,
    url: `http://${host.includes(":") ? `[${host}]` : host}:${port}`,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}
