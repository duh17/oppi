/**
 * Marks HTTP requests that arrived over the owner-only local Unix socket so
 * route code can distinguish local-admin trust from network trust without
 * importing the server composition root.
 */

import type { IncomingMessage } from "node:http";

const LOCAL_REQUEST_KEY = Symbol.for("oppi.localRequest");
/** Constant base so request-target parsing never consults the Host header. */
const REQUEST_TARGET_BASE = "http://127.0.0.1";

type LocalRequest = IncomingMessage & { [LOCAL_REQUEST_KEY]?: boolean };
type TlsRequest = IncomingMessage & { socket: IncomingMessage["socket"] & { encrypted?: boolean } };

export function markLocalRequest(req: IncomingMessage): void {
  (req as LocalRequest)[LOCAL_REQUEST_KEY] = true;
}

export function isLocalRequest(req: IncomingMessage): boolean {
  return (req as LocalRequest)[LOCAL_REQUEST_KEY] === true;
}

export function isSecureNetworkRequest(req: IncomingMessage): boolean {
  return !isLocalRequest(req) && (req as TlsRequest).socket.encrypted === true;
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
