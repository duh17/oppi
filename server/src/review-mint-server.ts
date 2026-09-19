/**
 * Loopback HTTP sidecar for App Review: a stable secret path 302s to a minted
 * signed invite. It must not be published through the public reverse proxy.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { InviteMintCoordinator, redactMintPath, type MintedInvite } from "./review-mint.js";

export type ReviewMintServerOptions = {
  secret: string;
  listenHost?: string;
  listenPort?: number;
  /** Explicit opt-in for a non-loopback mint bind. */
  allowNonLoopback?: boolean;
  mint: () => Promise<MintedInvite> | MintedInvite;
  /** Invalidate the live pairing token without minting a replacement. */
  invalidate?: () => Promise<void> | void;
  log?: (message: string) => void;
};

function isLoopbackMintHost(host: string): boolean {
  const trimmed = host.trim().toLowerCase();
  const unwrapped =
    trimmed.startsWith("[") && trimmed.endsWith("]") ? trimmed.slice(1, -1) : trimmed;
  return unwrapped === "127.0.0.1" || unwrapped === "localhost" || unwrapped === "::1";
}

export function createReviewMintServer(options: ReviewMintServerOptions): {
  server: ReturnType<typeof createServer>;
  revokeOutstanding: () => Promise<void>;
  listen: () => Promise<{ host: string; port: number }>;
  close: () => Promise<void>;
} {
  const secret = options.secret;
  if (!secret || secret.length < 16) {
    throw new Error("review mint secret must be at least 16 characters");
  }
  const listenHost = options.listenHost ?? "127.0.0.1";
  if (!isLoopbackMintHost(listenHost) && options.allowNonLoopback !== true) {
    throw new Error(
      `review mint refuses non-loopback bind ${listenHost}; set allowNonLoopback or REVIEW_MINT_ALLOW_NON_LOOPBACK=1`,
    );
  }
  const coordinator = new InviteMintCoordinator(options.mint, options.invalidate);
  const log = options.log ?? (() => {});

  const server = createServer((req, res) => {
    void handle(req, res);
  });

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    const expected = `/r/${secret}`;
    const method = (req.method || "GET").toUpperCase();
    const safePath = redactMintPath(url.pathname, secret);

    if (url.pathname === `${expected}/revoke-link` && method === "POST") {
      await coordinator.revokeOutstanding();
      log(`mint link_revoked path=${safePath}`);
      res.writeHead(204, { "Cache-Control": "no-store" });
      res.end();
      return;
    }

    if (url.pathname !== expected) {
      log(`mint miss path=${safePath}`);
      res.writeHead(404, { "Cache-Control": "no-store" });
      res.end();
      return;
    }

    const result = await coordinator.connect({
      method,
      userAgent: headerValue(req.headers["user-agent"]),
      retry: url.searchParams.get("retry") === "1",
    });

    res.setHeader("Cache-Control", "no-store");
    if (result.status === "preview" || result.status === "method_not_allowed") {
      log(`mint skipped reason=${result.status} path=${safePath}`);
      res.writeHead(result.status === "method_not_allowed" ? 405 : 200, {
        "Content-Type": "text/html; charset=utf-8",
      });
      res.end("<!doctype html><title>Oppi Review</title><p>Open this link in Oppi.</p>");
      return;
    }
    if (result.status !== "minted" && result.status !== "reused") {
      res.writeHead(404);
      res.end();
      return;
    }

    log(`mint ${result.status} path=${safePath}`);
    res.writeHead(302, { Location: result.invite.inviteURL });
    res.end();
  }

  async function revokeOutstanding(): Promise<void> {
    await coordinator.revokeOutstanding();
  }

  return {
    server,
    revokeOutstanding,
    listen(): Promise<{ host: string; port: number }> {
      return new Promise((resolve, reject) => {
        server.listen(options.listenPort ?? 0, listenHost, () => {
          const address = server.address();
          if (!address || typeof address === "string") {
            reject(new Error("review mint server failed to bind"));
            return;
          }
          resolve({ host: listenHost, port: address.port });
        });
        server.on("error", reject);
      });
    },
    close(): Promise<void> {
      return new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    },
  };
}

function headerValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}
