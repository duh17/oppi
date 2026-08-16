// ─── Pairing / Invite ───

export type InviteScheme = "http" | "https";

export interface InviteData {
  host: string;
  port: number;
  scheme?: InviteScheme;
  token: string;
  pairingToken?: string;
  name: string;
  tlsCertFingerprint?: string;
}

export interface InvitePayloadV3 extends InviteData {
  v: 3;
  fingerprint?: string;
}

export interface SignedInviteEnvelopeV3 {
  v: 3;
  signedPayload: string;
  publicKey: string;
  signature: string;
}
