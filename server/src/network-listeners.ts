/**
 * The network listeners of one server. They share one port, one transport (HTTP or HTTPS
 * with the same certificate), and the same request and upgrade handlers.
 *
 * - `host` set in config: one listener at exactly that address, as configured. `0.0.0.0`
 *   reaches every interface, the local network included.
 * - `host` unset (the default): `127.0.0.1` and `::1` for clients on this Mac, plus this
 *   machine's Tailscale addresses for phones and iPads. Nothing listens on the local
 *   network. A Tailscale address that is missing at startup (a LaunchAgent can start before
 *   Tailscale connects) is looked up again every 30 seconds until one is bound.
 */
import type { IncomingMessage, Server as HttpServer } from "node:http";
import type { Server as HttpsServer } from "node:https";
import { networkInterfaces } from "node:os";
import type { Duplex } from "node:stream";

import { createLogger } from "./logger.js";
import type { ServerConfig } from "./types.js";

export type TransportServer = HttpServer | HttpsServer;

const LOOPBACK_ADDRESSES = ["127.0.0.1", "::1"] as const;
const TAILSCALE_RETRY_MS = 30_000;

const log = createLogger({ base: { component: "server" } });

/** How messages name the listener address: the configured host, or the default pair. */
export function listenerHostLabel(config: Pick<ServerConfig, "host">): string {
  return config.host ?? "loopback and Tailscale addresses";
}

/**
 * Whether an interface of this machine has the address now. Asked before binding because
 * the bind error cannot tell: Bun reports every failed listen as EADDRINUSE.
 */
function addressIsLocal(address: string): boolean {
  return Object.values(networkInterfaces()).some((entries) =>
    entries?.some((entry) => entry.address.split("%")[0] === address),
  );
}

function closeServer(server: TransportServer): Promise<void> {
  if (!server.listening) return Promise.resolve();
  server.closeIdleConnections?.();
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

export class NetworkListeners {
  private readonly servers = new Map<string, TransportServer>();
  private retryTimer?: NodeJS.Timeout;
  private closed = false;

  constructor(
    private readonly options: {
      scheme: "http" | "https";
      createServer: () => TransportServer;
      onUpgrade: (req: IncomingMessage, socket: Duplex, head: Buffer) => void;
      /** This machine's Tailscale IPs; empty when Tailscale is missing or stopped. */
      tailscaleAddresses: () => Promise<string[]>;
    },
  ) {}

  async listen(host: string | undefined, port: number): Promise<void> {
    if (host !== undefined) {
      await this.bind(host, port);
      return;
    }
    await this.bind(LOOPBACK_ADDRESSES[0], port);
    // Port 0 picks a free port once; every other address shares it.
    const sharedPort = this.port ?? port;
    await this.bindIfAvailable(LOOPBACK_ADDRESSES[1], sharedPort);
    await this.bindTailscale(sharedPort);
  }

  get port(): number | undefined {
    for (const server of this.servers.values()) {
      const address = server.address();
      if (address && typeof address === "object") return address.port;
    }
    return undefined;
  }

  get listening(): boolean {
    for (const server of this.servers.values()) {
      if (server.listening) return true;
    }
    return false;
  }

  /** Addresses with a listener, in bind order. */
  get addresses(): string[] {
    return [...this.servers.keys()];
  }

  async close(): Promise<void> {
    this.closed = true;
    clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
    const results = await Promise.allSettled([...this.servers.values()].map(closeServer));
    const failure = results.find(
      (result): result is PromiseRejectedResult => result.status === "rejected",
    );
    if (failure) throw failure.reason;
  }

  private async bind(address: string, port: number): Promise<void> {
    const server = this.options.createServer();
    server.on("upgrade", this.options.onUpgrade);
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error): void => reject(error);
      server.once("error", onError);
      server.listen(port, address, () => {
        server.off("error", onError);
        resolve();
      });
    });
    if (this.closed) {
      // stop() ran while this bind was in flight (a Tailscale retry).
      await closeServer(server);
      return;
    }
    this.servers.set(address, server);
    log.info("server.listening", {
      scheme: this.options.scheme,
      host: address,
      port: this.port ?? port,
    });
  }

  /** False when the address is not on this machine; a failed bind of a local address throws. */
  private async bindIfAvailable(address: string, port: number): Promise<boolean> {
    if (!addressIsLocal(address)) {
      log.info("server.listen_address_absent", { host: address, port });
      return false;
    }
    await this.bind(address, port);
    return true;
  }

  private async bindTailscale(port: number): Promise<void> {
    let bound = false;
    for (const address of await this.options.tailscaleAddresses()) {
      if (this.closed) return;
      if (this.servers.has(address) || (await this.bindIfAvailable(address, port))) bound = true;
    }
    if (!bound) this.scheduleTailscaleRetry(port);
  }

  private scheduleTailscaleRetry(port: number): void {
    if (this.closed) return;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      this.bindTailscale(port).catch((error: unknown) => {
        // A conflict on a Tailscale address must not end the lookups for good.
        log.error("server.tailscale_listener.failed", {
          error: error instanceof Error ? error.message : String(error),
        });
        this.scheduleTailscaleRetry(port);
      });
    }, TAILSCALE_RETRY_MS);
    this.retryTimer.unref();
  }
}
