import type { Storage } from "./storage.js";
import type { AuthTransport } from "./types.js";

export type IrohPairingStorage = Pick<Storage, "consumePairingToken">;

export type IrohPairingRequest = {
  pairingToken?: unknown;
};

export type IrohPairingResponse =
  | { ok: true; deviceToken: string }
  | { ok: false; status: 400 | 401; error: string };

export function handleIrohPairingRequest(
  storage: IrohPairingStorage,
  request: unknown,
  options?: { clientNodeId?: string; allowedTransports?: AuthTransport[] },
): IrohPairingResponse {
  const pairingTokenValue =
    request && typeof request === "object" && !Array.isArray(request)
      ? (request as IrohPairingRequest).pairingToken
      : undefined;
  const pairingToken = typeof pairingTokenValue === "string" ? pairingTokenValue.trim() : "";

  if (!pairingToken) {
    return { ok: false, status: 400, error: "pairingToken required" };
  }

  const deviceToken = storage.consumePairingToken(pairingToken, {
    irohClientNodeId: options?.clientNodeId,
    allowedTransports: options?.allowedTransports,
  });
  if (!deviceToken) {
    return { ok: false, status: 401, error: "Invalid or expired pairing token" };
  }

  return { ok: true, deviceToken };
}
