/**
 * Marks HTTP requests that arrived over the owner-only local Unix socket so
 * route code can distinguish local-admin trust from network trust without
 * importing the server composition root.
 *
 * Network request provenance (TLS, trusted-proxy HTTPS assertion, Origin, and
 * rate-limit identity) also lives here so REST, pairing, and WebSocket upgrades
 * share one policy.
 */

import type { IncomingMessage } from "node:http";
import {
  ipMatchesCidrs,
  normalizeIp,
  type ParsedPublicUrl,
  type RequestTrustConfig,
} from "./proxy-config.js";

const LOCAL_REQUEST_KEY = Symbol.for("oppi.localRequest");
/** Constant base so request-target parsing never consults the Host header. */
const REQUEST_TARGET_BASE = "http://127.0.0.1";

type LocalRequest = IncomingMessage & { [LOCAL_REQUEST_KEY]?: boolean };
type TlsRequest = IncomingMessage & { socket: IncomingMessage["socket"] & { encrypted?: boolean } };

export type RequestProvenance = {
  isLocal: boolean;
  socketEncrypted: boolean;
  socketPeer: string | null;
  trustedPeer: boolean;
  httpsAsserted: boolean;
  /**
   * True when network credentials and pairing may proceed: socket TLS, or a
   * trusted peer with a single unambiguous `X-Forwarded-Proto: https`.
   * Unix-socket requests are never "secure network" requests.
   */
  isSecure: boolean;
  /** Rate-limit identity. Never taken from an untrusted forwarded address. */
  clientIdentity: string;
  publicOrigin: ParsedPublicUrl | null;
  insecureReason?: string;
};

export function markLocalRequest(req: IncomingMessage): void {
  (req as LocalRequest)[LOCAL_REQUEST_KEY] = true;
}

export function isLocalRequest(req: IncomingMessage): boolean {
  return (req as LocalRequest)[LOCAL_REQUEST_KEY] === true;
}

/**
 * Whether this network request may carry pairing or device credentials.
 *
 * `config` is required for trusted-private-HTTP. Omitting it preserves the
 * historical socket-TLS-only rule.
 */
export function isSecureNetworkRequest(
  req: IncomingMessage,
  config: RequestTrustConfig = { trustedPeers: [] },
): boolean {
  return resolveRequestProvenance(req, config).isSecure;
}

/**
 * Parse an HTTP request-target against a constant local base.
 * Host is not part of path routing; Origin comparison validates it separately.
 */
export function parseHttpRequestTarget(requestUrl: string | undefined): URL | null {
  try {
    return new URL(requestUrl || "/", REQUEST_TARGET_BASE);
  } catch {
    return null;
  }
}

export function resolveRequestProvenance(
  req: IncomingMessage,
  config: RequestTrustConfig,
): RequestProvenance {
  const isLocal = isLocalRequest(req);
  const socketEncrypted = (req as TlsRequest).socket?.encrypted === true;
  const socketPeer = normalizeIp(req.socket?.remoteAddress);
  const trustedPeer = !isLocal && ipMatchesCidrs(socketPeer, config.trustedPeers);
  const assertion = readHttpsAssertion(req);
  const httpsAsserted = assertion.ok;
  const publicOrigin = config.publicUrl ?? null;

  let isSecure = false;
  let insecureReason: string | undefined;
  if (isLocal) {
    insecureReason = "local_socket";
  } else if (socketEncrypted) {
    isSecure = true;
  } else if (!trustedPeer) {
    insecureReason = "insecure";
  } else if (!httpsAsserted) {
    insecureReason = assertion.reason;
  } else {
    isSecure = true;
  }

  return {
    isLocal,
    socketEncrypted,
    socketPeer,
    trustedPeer,
    httpsAsserted,
    isSecure,
    clientIdentity: clientIdentity(socketPeer, trustedPeer, req),
    publicOrigin,
    ...(insecureReason ? { insecureReason } : {}),
  };
}

export function isAllowedWebSocketOrigin(
  req: IncomingMessage,
  transportScheme: "http" | "https",
  config: RequestTrustConfig = { trustedPeers: [] },
): boolean {
  const originHeader = firstHeader(req.headers.origin);
  if (!originHeader) {
    return true;
  }

  let origin: URL;
  try {
    origin = new URL(originHeader);
  } catch {
    return false;
  }

  const publicUrl = config.publicUrl;
  if (publicUrl) {
    return origin.origin === publicUrl.origin;
  }

  const hostHeader = firstHeader(req.headers.host);
  if (!hostHeader) {
    return false;
  }
  return origin.protocol === `${transportScheme}:` && origin.host === hostHeader;
}

type HeaderBag = IncomingMessage["headers"];

function firstHeader(value: string | string[] | undefined): string | undefined {
  if (Array.isArray(value)) return value[0];
  return value;
}

/**
 * Documented HTTPS assertion: a single `X-Forwarded-Proto: https` value.
 *
 * Duplicate headers, comma lists, quotes, and any value other than `https`
 * fail closed. `Forwarded` / `X-Forwarded-Protocol` / `X-Forwarded-Scheme`
 * are unsupported.
 */
function readHttpsAssertion(req: IncomingMessage): { ok: true } | { ok: false; reason: string } {
  const raw = req.headers?.["x-forwarded-proto"];
  if (raw === undefined) {
    return { ok: false, reason: "missing_forwarded_proto" };
  }
  if (Array.isArray(raw)) {
    return { ok: false, reason: "duplicate_forwarded_proto" };
  }
  if (raw.includes(",")) {
    return { ok: false, reason: "duplicate_forwarded_proto" };
  }
  const value = raw.trim().toLowerCase();
  if (!value) {
    return { ok: false, reason: "missing_forwarded_proto" };
  }
  if (value !== "https") {
    return { ok: false, reason: "unsupported_forwarded_proto" };
  }
  return { ok: true };
}

function clientIdentity(
  socketPeer: string | null,
  trustedPeer: boolean,
  req: IncomingMessage,
): string {
  const peerKey = `peer:${socketPeer ?? "unknown"}`;
  if (!trustedPeer) {
    return peerKey;
  }

  const forwarded = readSingleForwardedClientIp(req.headers);
  if (!forwarded) {
    return peerKey;
  }
  return `xff:${forwarded}`;
}

/**
 * From a trusted peer, accept only a single overwritten client IP in
 * `X-Forwarded-For`. Multiple addresses, malformed IPs, and vendor headers
 * (`X-Real-IP`, `CF-Connecting-IP`) are ignored; the socket peer is the
 * fallback so one client cannot pick another client's limiter bucket.
 */
function readSingleForwardedClientIp(headers: HeaderBag | undefined): string | null {
  const raw = headers?.["x-forwarded-for"];
  if (raw === undefined) return null;
  if (Array.isArray(raw)) return null;
  if (raw.includes(",")) return null;
  return normalizeIp(raw);
}
