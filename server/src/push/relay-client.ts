/**
 * Client for relay API v1 server calls (protocol/push/spec.md §3.2, §5).
 *
 * Sends go to the primary; network errors, timeouts, and 5xx move to the standby. Only a
 * `410` from the primary prunes: a standby may not share the primary's permissions.
 */

import { PUSH_ENVELOPE_BYTES, type SealedPushEnvelope } from "./envelope.js";

const ENVELOPE_BASE64URL_LENGTH = Math.ceil((PUSH_ENVELOPE_BYTES * 4) / 3);
const DEFAULT_TIMEOUT_MS = 10_000;

export type RelaySendResult =
  | { status: "delivered" }
  /** The relay holds no such permission or registration. `prune`: the primary said so. */
  | { status: "gone"; prune: boolean }
  /** A deterministic refusal (bad request, quota): no failover. */
  | { status: "rejected"; httpStatus: number; error?: string }
  /** No relay accepted the push (network, timeout, 5xx). */
  | { status: "unavailable" };

export interface RelayPushRequest {
  envelope: SealedPushEnvelope;
  collapseId?: string;
  ttl?: number;
}

export interface RelayClientOptions {
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export class RelayClient {
  private readonly fetchImpl: typeof fetch;
  private readonly timeoutMs: number;

  constructor(
    private readonly origins: readonly string[],
    options: RelayClientOptions = {},
  ) {
    if (origins.length === 0) throw new Error("relay client needs at least one origin");
    this.fetchImpl = options.fetch ?? fetch;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  async push(sendToken: string, request: RelayPushRequest): Promise<RelaySendResult> {
    // Defense in depth: the type already guarantees a sealed envelope.
    if (request.envelope.length !== ENVELOPE_BASE64URL_LENGTH) {
      throw new Error("refusing to send a push that is not a sealed v1 envelope");
    }
    const body = JSON.stringify({
      envelope: request.envelope,
      ...(request.collapseId ? { collapseId: request.collapseId } : {}),
      ...(request.ttl !== undefined ? { ttl: request.ttl } : {}),
    });

    for (const [index, origin] of this.origins.entries()) {
      const response = await this.request(origin, "/v1/push", "POST", sendToken, body);
      if (!response || response.status >= 500) continue;
      if (response.status === 200) return { status: "delivered" };
      if (response.status === 410) return { status: "gone", prune: index === 0 };
      return { status: "rejected", httpStatus: response.status, error: await errorCode(response) };
    }
    return { status: "unavailable" };
  }

  /** Best effort: release a permission this server no longer uses. */
  async deletePermission(sendToken: string): Promise<boolean> {
    for (const origin of this.origins) {
      const response = await this.request(origin, "/v1/permission", "DELETE", sendToken);
      if (response && response.status < 500) return response.status === 204;
    }
    return false;
  }

  private async request(
    origin: string,
    path: string,
    method: "POST" | "DELETE",
    sendToken: string,
    body?: string,
  ): Promise<Response | null> {
    try {
      return await this.fetchImpl(`${origin}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${sendToken}`,
          ...(body ? { "content-type": "application/json" } : {}),
        },
        body,
        redirect: "error",
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch {
      return null;
    }
  }
}

async function errorCode(response: Response): Promise<string | undefined> {
  try {
    const parsed = (await response.json()) as { error?: unknown };
    return typeof parsed.error === "string" ? parsed.error.slice(0, 64) : undefined;
  } catch {
    return undefined;
  }
}
