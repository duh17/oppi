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

export type InviteTransportPreference = "irohOnly" | "irohPreferred" | "httpOnly";

export type IrohInviteAddressMode = "node-id" | "ticket";

export interface IrohInviteTransport {
  version: 2;
  nodeId: string;
  alpns: string[];
  addressMode: IrohInviteAddressMode;
  ticket?: string;
  /** Optional live custom relay URLs. Missing or empty retains public defaults. */
  relayUrls?: string[];
}

/** Protected local state written only by the running endpoint. */
export interface IrohInviteState extends IrohInviteTransport {
  relayMode?: "default" | "custom";
  ticketHomeRelay?: string;
  readinessId: string;
  processId: number;
}

export interface HttpInviteTransport {
  host: string;
  port: number;
  scheme: InviteScheme;
  tlsCertFingerprint?: string;
}

export interface InviteTransports {
  iroh?: IrohInviteTransport;
  http?: HttpInviteTransport;
}

export interface InvitePayloadV4 {
  v: 4;
  name: string;
  pairingToken: string;
  fingerprint: string;
  preference: InviteTransportPreference;
  transports: InviteTransports;
}

export interface SignedInviteEnvelopeV4 {
  v: 4;
  alg: "ed25519";
  signedPayload: string;
  publicKey: string;
  signature: string;
}
