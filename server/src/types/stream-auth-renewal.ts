// Live stream access renewal (capabilities.streamAuthRenewal).
//
// A control exchange on every live device stream (`/app/events/stream`, the focused session
// streams, `/dictation/stream`, `/godot/{id}/link`), outside each stream's own message set. Sent only by clients
// that read the capability, so older builds never see a result frame.

/**
 * Client → server: replace this socket's access token before the server closes it with
 * `4001 auth_expired`. The socket is admitted exactly as at connect (the `auth.module` gate
 * with its upgrade request, then the token), and the token must belong to the same device.
 */
export interface StreamAuthRenewMessage {
  type: "auth_renew";
  token: string;
}

/**
 * Why a renewal was refused. The token's own reasons come from access-token validation;
 * `wrong_device` is a valid token of another device, and `rate_limited` a socket that asked
 * too often this minute. Refusals no newer token fixes: `not_renewable`, a socket without an
 * expiring device token; `past_deadline`, a socket already past its deadline (held open only
 * to finish a dictation take or a Live Voice call); and `gate_denied`, the `auth.module` gate
 * no longer admitting the request the socket opened with.
 */
export type StreamAuthRenewRejection =
  | "unknown_token"
  | "expired"
  | "revoked"
  | "evicted"
  | "wrong_device"
  | "not_renewable"
  | "past_deadline"
  | "gate_denied"
  | "rate_limited";

/**
 * Server → client, answering `auth_renew`. `expiresAt` is the token expiry the socket now
 * runs to (epoch ms; it closes `CLOCK_SKEW_MS` after it). A refusal changes nothing.
 */
export type StreamAuthRenewResultMessage =
  | { type: "auth_renew_result"; ok: true; expiresAt: number }
  | { type: "auth_renew_result"; ok: false; reason: StreamAuthRenewRejection };
