import type { Storage } from "./storage.js";
import type { AuthTransport } from "./types.js";

export type IrohPairingStorage = Pick<Storage, "consumePairingToken">;

export type IrohPairingRequest = {
  pairingToken?: unknown;
  clientNodeId?: unknown;
};

export type IrohPairingResponse =
  | { ok: true; deviceToken: string; credentialTransports: AuthTransport[] }
  | { ok: false; status: 400 | 401; error: string };

export function handleIrohPairingRequest(
  storage: IrohPairingStorage,
  request: unknown,
  options: { transport: AuthTransport; clientNodeId?: string },
): IrohPairingResponse {
  const pairingTokenValue =
    request && typeof request === "object" && !Array.isArray(request)
      ? (request as IrohPairingRequest).pairingToken
      : undefined;
  const pairingToken = typeof pairingTokenValue === "string" ? pairingTokenValue.trim() : "";

  if (!pairingToken) {
    return { ok: false, status: 400, error: "pairingToken required" };
  }

  const requestedClientNodeId =
    request && typeof request === "object" && !Array.isArray(request)
      ? (request as IrohPairingRequest).clientNodeId
      : undefined;
  const clientNodeIdValue = options.clientNodeId ?? requestedClientNodeId;
  const clientNodeId =
    typeof clientNodeIdValue === "string" && clientNodeIdValue.trim().length > 0
      ? clientNodeIdValue.trim()
      : undefined;

  const credential = storage.consumePairingToken(pairingToken, {
    transport: options.transport,
    irohClientNodeId: clientNodeId,
  });
  if (!credential) {
    return { ok: false, status: 401, error: "Invalid or expired pairing token" };
  }

  return { ok: true, ...credential };
}
