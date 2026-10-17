// ─── Push ───

/** Session events that push (protocol/push/spec.md §5). Pairing events: `PushSubject`. */
export type SessionPushEvent = "blocked" | "done";

/** `off`: no pushes (default). `relay`: end-to-end-encrypted pushes through a push relay. */
export type PushMode = "off" | "relay";

export interface PushConfig {
  mode: PushMode;
  /** `[primary, standby]` relay origins. Required in relay mode. */
  relays?: string[];
}

/** Body of `PUT /me/push-registration` (spec §5). */
export interface PushRegistrationRequest {
  keyId: string;
  /** Base64url of the raw X25519 public key (32 bytes). */
  publicKey: string;
  /** Relay send permission minted by the phone for this server. */
  sendToken: string;
  /** Relay origin the send token was minted at; must be this server's primary. */
  relay: string;
  issuedAt: number;
  /** Base64url P-256 `r || s` by the device's enrolled key. */
  signature: string;
}

/**
 * One paired device's push registration. Owned by that device: revoking it removes the
 * registration, and a relay `410` from the primary prunes it.
 */
export interface PushRegistration {
  /** `DeviceRecord.id` of the registering device. */
  deviceId: string;
  keyId: string;
  /** Base64url of the raw X25519 public key. */
  publicKey: string;
  sendToken: string;
  registeredAt: number;
}
