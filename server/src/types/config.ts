// ─── Server Config ───

export type PolicyDecision = "allow" | "auto" | "ask" | "block";

export interface PolicyMatch {
  tool?: string;
  executable?: string;
  commandMatches?: string;
  pathMatches?: string;
  pathWithin?: string;
  domain?: string;
}

export interface PolicyPermission {
  id: string;
  decision: PolicyDecision;

  label?: string;
  reason?: string;
  match: PolicyMatch;
}

/**
 * Named heuristics — complex detection logic that can't be expressed as globs.
 * Each key maps to the action taken when the heuristic triggers.
 * Set to `false` to disable a heuristic entirely.
 */
export interface PolicyHeuristics {
  /** Detect `| sh`, `| bash` — arbitrary code execution via pipe. Default: "ask" */
  pipeToShell?: PolicyDecision | false;
  /** Detect curl -d, wget --post-data, etc. — outbound data transfer. Default: "ask" */
  dataEgress?: PolicyDecision | false;
  /** Detect $API_KEY, $SECRET in curl URLs — credential leakage. Default: "ask" */
  secretEnvInUrl?: PolicyDecision | false;
  /** Detect reads of ~/.ssh/, ~/.aws/, .env, etc. via cat/head/read. Default: "block" */
  secretFileAccess?: PolicyDecision | false;
}

export interface PolicyConfig {
  schemaVersion: 1;
  mode?: string;
  description?: string;
  fallback: PolicyDecision;
  guardrails: PolicyPermission[];
  permissions: PolicyPermission[];
  /** Named heuristics for complex pattern detection. Omit to use defaults. */
  heuristics?: PolicyHeuristics;
}

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

export interface ServerConfig {
  configVersion?: number;
  port: number;
  host: string;
  dataDir: string;
  sessionIdleTimeoutMs: number;
  workspaceIdleTimeoutMs: number;
  maxSessionsPerWorkspace: number;
  maxSessionsGlobal: number;
  /** Permission approval timeout in milliseconds. Set to 0 to disable expiry. */
  approvalTimeoutMs?: number;
  /** Set to false to disable the permission gate. All tool calls run without approval. */
  permissionGate?: boolean;

  /** PATH entries used for runtime tool execution. */
  runtimePathEntries?: string[];
  /** Additional runtime environment variables. */
  runtimeEnv?: Record<string, string>;

  /** Transport security (HTTPS/WSS). */
  tls?: TlsConfig;

  /** Declarative global policy config (guardrails + permissions). */
  policy?: PolicyConfig;

  // Owner/admin bearer token
  token?: string;

  // One-time pairing token bootstrap state
  pairingToken?: string;
  pairingTokenExpiresAt?: number;

  // Device auth state (issued during pairing)
  authDeviceTokens?: string[];

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
   * Auto permission review configuration. Policy decisions of "auto" call a
   * model that can only allow or ask the human.
   */
  autoPermission?: {
    model?: string; // "provider/model-id"
    prompt?: string;
    timeoutMs?: number;
    maxTokens?: number;
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
    subagents?: SubagentConfig;
  };
}

export interface SubagentModelProfileConfig {
  /** Human-readable summary of what this profile is for. */
  description?: string;
  /** Model to use when this profile is selected and spawn_agent omits model. */
  model?: string;
  /** Thinking level to use when this profile is selected and spawn_agent omits thinking. */
  thinking?: string;
  /** Extra instructions injected ahead of the child prompt for this profile. */
  guidelines?: string[];
  /** Exact pi tool names to activate for child sessions using this profile. Omitted means inherit the default active tool set. */
  activeTools?: string[];
}

export interface SubagentModelPolicyConfig {
  /** Approved full model IDs for subagents. Empty/omitted means any available model. */
  approvedModels?: string[];
  /** Default model when spawn_agent omits model. */
  defaultModel?: string;
  /** Default thinking level when spawn_agent omits thinking. */
  defaultThinking?: string;
  /** Named presets such as discovery/research/coding/review. Overrides built-in subagent profiles by name. */
  profiles?: Record<string, SubagentModelProfileConfig>;
}

export interface SubagentConfig {
  /** How many levels deep agents can spawn other agents.
   *  1 = parent→child only (no grandchildren). 2 = allows grandchildren.
   *  Default: 1 */
  maxDepth: number;
  /** Whether children automatically stop after completing their work.
   *  When true, a child that finishes and goes idle is stopped immediately.
   *  When false, children stay alive until childIdleTimeoutMs expires.
   *  Default: false */
  autoStopWhenDone: boolean;
  /** How long (ms) a child session stays alive after completing its work
   *  when autoStopWhenDone is false. Matches typical prompt-cache TTL so
   *  follow-up messages can reuse the cached context.
   *  Default: 300000 (5 min) */
  childIdleTimeoutMs: number;
  /** How long (ms) to wait for a child to start producing output before
   *  giving up. Covers VM boot time, model loading, and first LLM call.
   *  Default: 60000 (60s) */
  startupGraceMs: number;
  /** Default timeout (ms) for spawn_agent(wait=true) when the caller
   *  doesn't specify timeout_seconds.
   *  Default: 1800000 (30 min) */
  defaultWaitTimeoutMs: number;
  /** Optional model governance for subagents: approved model IDs,
   *  default model/thinking, and named usage profiles. */
  modelPolicy?: SubagentModelPolicyConfig;
}
