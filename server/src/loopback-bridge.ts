import { createServer, connect, type Server as NetServer } from "node:net";
import { URL } from "node:url";

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);
const BRIDGE_BIND_HOST = "0.0.0.0";
const BRIDGE_TARGET_HOST = "127.0.0.1";

interface BridgeEntry {
  targetPort: number;
  bridgePort: number;
  server: NetServer;
}

function parseLoopbackPort(rawBaseUrl: string): number | null {
  let url: URL;

  try {
    url = new URL(rawBaseUrl);
  } catch {
    return null;
  }

  if (url.protocol !== "http:") {
    return null;
  }

  if (!LOOPBACK_HOSTS.has(url.hostname.toLowerCase())) {
    return null;
  }

  if (url.port.length === 0) {
    return 80;
  }

  const parsed = Number.parseInt(url.port, 10);
  if (!Number.isInteger(parsed) || parsed <= 0 || parsed > 65_535) {
    return null;
  }

  return parsed;
}

function closeServer(server: NetServer): Promise<void> {
  return new Promise((resolve) => {
    server.close(() => resolve());
  });
}

export class LoopbackBridgeManager {
  private bridges = new Map<number, BridgeEntry>();
  private inflight = new Map<number, Promise<BridgeEntry>>();

  async ensureForBaseUrls(baseUrls: string[]): Promise<void> {
    const targetPorts = new Set<number>();

    for (const baseUrl of baseUrls) {
      const targetPort = parseLoopbackPort(baseUrl);
      if (targetPort !== null) {
        targetPorts.add(targetPort);
      }
    }

    for (const targetPort of targetPorts) {
      await this.ensureBridge(targetPort);
    }
  }

  rewriteForHostGateway(baseUrl: string, hostGateway: string): string {
    const targetPort = parseLoopbackPort(baseUrl);
    if (targetPort === null) {
      return baseUrl;
    }

    let rewritten: URL;

    try {
      rewritten = new URL(baseUrl);
    } catch {
      return baseUrl;
    }

    rewritten.hostname = hostGateway;
    rewritten.port = String(this.bridgePortForTarget(targetPort) ?? targetPort);
    return rewritten.toString();
  }

  bridgePortForTarget(targetPort: number): number | undefined {
    return this.bridges.get(targetPort)?.bridgePort;
  }

  async shutdown(): Promise<void> {
    const entries = Array.from(this.bridges.values());
    this.bridges.clear();

    this.inflight.clear();

    await Promise.all(entries.map((entry) => closeServer(entry.server)));
  }

  private async ensureBridge(targetPort: number): Promise<BridgeEntry> {
    const existing = this.bridges.get(targetPort);
    if (existing) {
      return existing;
    }

    const inProgress = this.inflight.get(targetPort);
    if (inProgress) {
      return inProgress;
    }

    const startPromise = this.startBridge(targetPort)
      .then((entry) => {
        this.bridges.set(targetPort, entry);
        this.inflight.delete(targetPort);
        return entry;
      })
      .catch((err) => {
        this.inflight.delete(targetPort);
        throw err;
      });

    this.inflight.set(targetPort, startPromise);
    return startPromise;
  }

  private startBridge(targetPort: number): Promise<BridgeEntry> {
    return new Promise((resolve, reject) => {
      const server = createServer((clientSocket) => {
        const upstream = connect({ host: BRIDGE_TARGET_HOST, port: targetPort });

        const closeBoth = (): void => {
          if (!clientSocket.destroyed) {
            clientSocket.destroy();
          }

          if (!upstream.destroyed) {
            upstream.destroy();
          }
        };

        clientSocket.on("error", closeBoth);
        upstream.on("error", closeBoth);

        clientSocket.pipe(upstream);
        upstream.pipe(clientSocket);
      });

      const onError = (err: Error): void => {
        server.removeListener("listening", onListening);
        reject(err);
      };

      const onListening = (): void => {
        server.removeListener("error", onError);

        const address = server.address();
        if (!address || typeof address === "string") {
          reject(new Error(`bridge address unavailable for target port ${targetPort}`));
          return;
        }

        resolve({ targetPort, bridgePort: address.port, server });
      };

      server.once("error", onError);
      server.once("listening", onListening);
      server.listen(0, BRIDGE_BIND_HOST);
    });
  }
}
