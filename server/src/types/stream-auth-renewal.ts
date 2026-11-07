// Live stream access renewal (capabilities.streamAuthRenewal).
//
// A control exchange on every live device stream (`/app/events/stream`, the focused session
// streams, `/dictation/stream`), outside each stream's own message set. Sent only by clients
// that read the capability, so older builds never see a result frame.

/**
 * Client → server: replace this socket's access token before the server closes it with
 * `4001 auth_expired`. The token is checked exactly as at connect, and must belong to the
 * same device.
 */
export interface StreamAuthRenewMessage {
  type: "auth_renew";
  token: string;
}

/**
 * Why a renewal was refused. The token's own reasons come from access-token validation;
 * `wrong_device` is a valid token of another device. Two refusals no newer token fixes:
 * `not_renewable`, a socket without an expiring device token, and `past_deadline`, a socket
 * already past its deadline (held open only to finish a dictation take or a Live Voice call).
 */
export type StreamAuthRenewRejection =
  | "unknown_token"
  | "expired"
  | "revoked"
  | "evicted"
  | "wrong_device"
  | "not_renewable"
  | "past_deadline";

/**
 * Server → client, answering `auth_renew`. `expiresAt` is the token expiry the socket now
 * runs to (epoch ms; it closes `CLOCK_SKEW_MS` after it). A refusal changes nothing.
 */
export type StreamAuthRenewResultMessage =
  | { type: "auth_renew_result"; ok: true; expiresAt: number }
  | { type: "auth_renew_result"; ok: false; reason: StreamAuthRenewRejection };
