// ─── Server Config ───

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

/** `dt_` compatibility window state. */
export type AuthMigrationMode = "compat" | "finalized";

/** Canonical P-256 device public key (JWK, RFC 7517 §6). */
export interface DevicePublicKey {
  kty: "EC";
  crv: "P-256";
  x: string;
  y: string;
}

/** Per-device identity stored server-side. Only the public key, never a private key. */
export interface DeviceRecord {
  id: string;
  name: string;
  /** Absent for a legacy `dt_` record that has not yet migrated to key proof. */
  publicKey?: DevicePublicKey;
  scope: DeviceScope;
  createdAt: number;
  lastUsedAt?: number;
  revokedAt?: number;
  /** SHA-256 of the legacy `dt_` token pending revocation after migration commit. */
  legacyTokenHash?: string;
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

  /** Transport security (HTTPS/WSS). */
  tls?: TlsConfig;

  // Owner/admin bearer token
  token?: string;

  // One-time pairing token bootstrap state
  pairingToken?: string;
  pairingTokenExpiresAt?: number;
  // Device auth state (issued during pairing)
  authDeviceTokens?: string[];

  // Device-key auth state (new model). Additive and backward compatible.
  authMigrationMode?: AuthMigrationMode;
  authDevices?: DeviceRecord[];
  authAccessTokens?: AccessTokenRecord[];
  // Push notification state (written by iOS client registration)
  pushDeviceTokens?: string[];
  liveActivityToken?: string;

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
    sttEndpoint?: string;
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
