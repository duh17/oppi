// ─── Server Config ───

import type { PushConfig, PushRegistration } from "./push.js";

export type TlsMode = "auto" | "tailscale" | "cloudflare" | "self-signed" | "manual" | "disabled";

export interface TlsConfig {
  mode: TlsMode;
  certPath?: string;
  keyPath?: string;
  caPath?: string;
  /**
   * Explicit escape hatch for binding an HTTP server to non-loopback interfaces.
   * Defaults to false. Keep disabled unless the network path is otherwise protected.
   */
  allowInsecureNetworkHttp?: boolean;
}

export interface UploadStoreConfig {
  mode?: "local";
  path?: string;
  maxFileBytes?: number;
  maxTurnBytes?: number;
  unusedTtlMs?: number;
  retainedTtlMs?: number;
  allowedMimeTypes?: string[];
}

/** Coarse capability scope for an authenticated credential. */
export type DeviceScope = "device" | "admin" | "mirror";

/** Canonical P-256 device public key (JWK, RFC 7517 §6). */
export interface DevicePublicKey {
  kty: "EC";
  crv: "P-256";
  x: string;
  y: string;
}

/** How a device got its pairing approved: a `pt_` invite, a same-user Tailscale invite, or `auth.module`. */
export type PairingMethod = "invite" | "tailscale" | "custom";

/** Enrollment facts kept with the device record. Absent on devices paired before they existed. */
export interface DevicePairingInfo {
  method: PairingMethod;
  /** Client IP, or the Tailscale login for `tailscale`, or the custom approver's `source`. */
  source?: string;
  /** Set when an existing device approved this pairing. */
  approvedByDeviceId?: string;
}

/** Per-device identity stored server-side. Only the public key, never a private key. */
export interface DeviceRecord {
  id: string;
  name: string;
  publicKey: DevicePublicKey;
  scope: DeviceScope;
  /** Enrollment time. */
  createdAt: number;
  lastUsedAt?: number;
  revokedAt?: number;
  pairing?: DevicePairingInfo;
}

/**
 * Where the outstanding `pt_` invite came from. Stored next to `pairingToken` and cleared with it:
 * the approval policy needs the issued TTL and whether `/pair/tailscale` minted it.
 */
export interface PairingTokenOrigin {
  method: "invite" | "tailscale";
  ttlMs: number;
  /** Tailscale login for `tailscale`. */
  source?: string;
}

/** Short-lived access token stored hashed at rest. The server is the only verifier. */
export interface AccessTokenRecord {
  id: string;
  tokenHash: string;
  deviceId: string;
  scope: DeviceScope;
  createdAt: number;
  expiresAt: number;
  lastUsedAt?: number;
}

export interface ServerConfig {
  configVersion?: number;
  port: number;
  host: string;
  dataDir: string;
  sessionIdleTimeoutMs: number;
  workspaceIdleTimeoutMs: number;
  maxSessionsPerWorkspace: number;
  maxSessionsGlobal: number;

  /** PATH entries used for runtime tool execution. */
  runtimePathEntries?: string[];
  /** Additional runtime environment variables. */
  runtimeEnv?: Record<string, string>;

  /** Prompt hint that points Oppi-owned sessions at packaged Oppi docs. */
  oppiDocsPrompt?: {
    enabled: boolean;
  };

  /** Experimental one-line Oppi CLI management hint for Oppi-owned sessions. */
  oppiCliPrompt?: {
    enabled: boolean;
  };

  /** Opt-in runtime experiments. Requires a server restart. */
  experimental?: {
    serverDurable?: boolean;
    /** Mac → Node live H.264 view lane. Default off. */
    desktopLiveView?: boolean;
  };

  /** Provider quota display options. */
  providerQuotas?: {
    /**
     * Show the legacy `openai-codex` connection's plan-wide usage on the official `openai`
     * (Sign in with ChatGPT) row. The operator confirms both sign-ins are the same ChatGPT
     * account/workspace; Oppi does not verify it. Default false.
     */
    openaiUseCodexPlan?: boolean;
  };

  /** Transport security (HTTPS/WSS). */
  tls?: TlsConfig;

  /**
   * Phone-facing HTTPS origin. Independent of the listener `host`/`port`/`tls`.
   * When set, signed invites advertise this origin and omit the origin TLS leaf pin.
   */
  publicUrl?: string;

  /**
   * Immediate reverse-proxy peers as Oppi sees them on the socket.
   * Required for trusted private HTTP; `publicUrl` alone never authorizes plaintext.
   */
  proxy?: {
    trustedPeers?: string[];
  };

  // Owner/admin bearer token
  token?: string;

  // One-time pairing token bootstrap state
  pairingToken?: string;
  pairingTokenExpiresAt?: number;
  pairingTokenOrigin?: PairingTokenOrigin;

  /** Pairing and network auth policy. Requires a server restart. */
  auth?: {
    /** `false` turns off `POST /pair/tailscale` (same-user Tailscale pairing). Default true. */
    tailscalePairing?: boolean;
    /**
     * Absolute path to an owner ES module exporting `approvePairing` and/or `gate`.
     * A module that fails to load makes every network request answer 503.
     */
    module?: string;
  };
  // Device-key auth state (issued during pairing)
  authDevices?: DeviceRecord[];
  authAccessTokens?: AccessTokenRecord[];
  /** End-to-end-encrypted push through a relay. Omitted means `off`. */
  push?: PushConfig;
  // Push registrations (written by PUT /me/push-registration from paired devices)
  pushRegistrations?: PushRegistration[];

  /**
   * Auto-title configuration. When enabled, generates concise task titles
   * for sessions using a configurable model provider.
   */
  autoTitle?: {
    enabled: boolean;
    model?: string; // "provider/model-id" (e.g. "anthropic/claude-haiku-3")
  };

  /**
   * ASR / dictation pipeline configuration. Controls remote dictation routing
   * by pointing Oppi at an STT backend endpoint.
   */
  asr?: {
    /** Explicit backend. Omitted with a non-empty sttEndpoint means "http". */
    backend?: "http";
    /** STT vendor. Omitted means infer from sttEndpoint, else Yuwp/http. */
    provider?: "http" | "xai";
    sttEndpoint?: string;
    /** Model id for the HTTP/Yuwp backend. */
    sttModel?: string;
  };

  /** Image attachment preprocessing performed by clients before upload. */
  images?: {
    autoResize?: boolean;
  };

  /** Local upload store config for chat attachments. */
  uploadStore?: UploadStoreConfig;

  /**
   * Server-managed extension configuration and lightweight persisted state.
   */
  extensions?: {
    voice?: {
      defaultVoiceId?: string;
    };
  };
}
