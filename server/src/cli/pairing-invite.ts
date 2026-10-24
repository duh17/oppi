import type { ServerConfig } from "../types.js";

/**
 * Whether an unexpired pairing invite is outstanding. Invites have one slot, so anything
 * that would mint another must leave a pending one alone. This is the rule for consuming
 * an invite: one stored before expiries were recorded never expires on its own.
 */
export function hasPendingPairingInvite(
  config: Pick<ServerConfig, "pairingToken" | "pairingTokenExpiresAt">,
  now: number = Date.now(),
): boolean {
  return (
    config.pairingToken !== undefined &&
    (config.pairingTokenExpiresAt === undefined || config.pairingTokenExpiresAt > now)
  );
}
