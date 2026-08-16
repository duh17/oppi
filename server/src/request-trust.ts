/**
 * Marks HTTP requests that arrived over the owner-only local Unix socket so
 * route code can distinguish local-admin trust from network trust without
 * importing the server composition root.
 */

import type { IncomingMessage } from "node:http";

const LOCAL_REQUEST_KEY = Symbol.for("oppi.localRequest");

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
