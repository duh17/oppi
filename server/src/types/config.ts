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

export type AuthTransport = "http" | "iroh";
export type IrohInviteMode = "irohOnly" | "irohPreferred" | "httpOnly";

export interface IrohDeviceTokenBinding {
  token: string;
  clientNodeId: string;
  allowedTransports: AuthTransport[];
  createdAt: number;
  lastSeenAt?: number;
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

  /** Effective invite policy persisted by the running server for separate CLI invocations. */
  irohInviteMode?: IrohInviteMode;
  /** Correlates invite readiness with the current server start. */
  irohInviteReadinessId?: string;

  // Owner/admin bearer token
  token?: string;

  // One-time pairing token bootstrap state
  pairingToken?: string;
  pairingTokenExpiresAt?: number;
  pairingTokenAllowedTransports?: AuthTransport[];

  // Device auth state (issued during pairing)
  authDeviceTokens?: string[];
  irohDeviceTokenBindings?: IrohDeviceTokenBinding[];

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
