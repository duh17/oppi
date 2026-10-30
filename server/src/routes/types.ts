import type { IncomingMessage, ServerResponse } from "node:http";

import type { Storage } from "../storage.js";
import type { SessionManager } from "../sessions.js";
import type { SkillRegistry } from "../skills.js";
import type { Session, Workspace } from "../types.js";
import type { ModelInfo } from "../model-catalog.js";
import type { SearchIndex } from "../search-index.js";
import type { ProviderAuthManager } from "../provider-auth/provider-auth-manager.js";
import type { ProviderQuotasStatus } from "../provider-quota.js";
import type { AppEventEmitter } from "../app-event-stream.js";
import type { SessionRuntimes } from "../runtime-router.js";
import type { RequestPrincipal } from "../request-principal.js";
import type { ServerResourceService } from "../server-resource-service.js";
import type { ConfigSettingResult, RevisionedEnabled } from "../settings/config-settings.js";
import type { EnabledPatch } from "../settings/registry.js";
import type { ServerUpdateService } from "../server-update.js";
import type { McpService } from "../mcp-service.js";
import type { ServerTelemetry } from "../telemetry/server-telemetry.js";
import type { PushSender } from "../push/push-sender.js";
import type { DevicePairing } from "../device-pairing.js";
import type { ServerResourceRecord } from "../server-metrics-history.js";
import type { SttGetAuth } from "../create-stt-provider.js";
import type { VoiceBackendHealth } from "../voice-backend-health.js";

/** The resource sampler behind the Server Metrics page. */
export interface ServerMetricsControl {
  telemetryDir: string;
  intervalMs: number;
  isEnabled(): boolean;
  settings(): RevisionedEnabled;
  /** Saves `serverMetrics.enabled` (see `applySetting`) and starts or stops the sampler. */
  apply(patch: EnabledPatch, baseRevision: number | undefined): ConfigSettingResult;
  latestSample(): ServerResourceRecord | null;
}

/** Services needed by route handlers — injected by Server. */
export interface RouteContext {
  storage: Storage;
  sessions: SessionManager;
  sessionRuntimes: SessionRuntimes;
  skillRegistry: SkillRegistry;
  serverResources: ServerResourceService;
  providerAuth: ProviderAuthManager;
  mcp?: McpService;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  refreshModelCatalog: (options?: { force?: boolean }) => Promise<void>;
  getModelCatalog: () => ModelInfo[];
  getProviderQuotasStatus?: () => Promise<ProviderQuotasStatus>;
  /** Configured provider credentials (API key or refreshed OAuth token), e.g. xAI for read aloud. */
  getProviderAuth?: SttGetAuth;
  /**
   * Voice backend states behind `capabilities.dictationStream`/`speech`/`liveVoice` and
   * `voiceBackends`; also told how each read-aloud request went.
   */
  voiceBackendHealth: VoiceBackendHealth;
  searchIndex?: SearchIndex;
  appEvents?: AppEventEmitter;
  serverStartedAt: number;
  serverVersion: string;
  /** The HTTPS/WSS listener's port and whether it is bound yet (it binds after the owner socket). */
  networkListener?: () => { port: number; listening: boolean };
  piVersion: string;
  /** Installed Pi TUI/CLI version. Omit when detection is unknown/empty. */
  piCliVersion?: string;
  /** In-app npm update of this server process. */
  serverUpdate?: ServerUpdateService;
  /** Close upgraded sockets owned by a newly revoked device. */
  onDeviceRevoked?: (deviceId: string) => void;
  /**
   * Best effort, bounded: end the device's Live Activity card. Called before the revoke removes
   * the push registration, which the send needs; never throws.
   */
  endLiveActivityCard?: (deviceId: string) => Promise<void>;
  /**
   * E2E UI harness: close a session's focused sockets like a dropped connection; resolves with
   * the count once they have closed.
   */
  dropSessionStreams?: (sessionId: string) => Promise<number>;
  /**
   * End-to-end-encrypted push (protocol/push/spec.md). In relay mode `/server/info` advertises
   * the primary relay so apps register; `/me/push-registration` stores their keys.
   */
  push?: {
    sender: PushSender;
    /** Base64url raw Ed25519 identity public key; the app checks it against its pin. */
    serverPublicKey: string;
    serverFingerprint: string;
  };
  /** Pairing approvers, approval policy, pending approvals, and enrollment alerts. */
  pairing: DevicePairing;
  /** Close every network device socket when the owner token rotates. */
  onOwnerTokenRotated?: () => void;
  /** End a deleted session's Live Voice calls and forget their records. Composed in server.ts. */
  endSessionVoiceCalls?: (sessionId: string) => Promise<void>;
  /** Stop the sandbox VM for a deleted workspace. Composed in server.ts. */
  stopWorkspaceVm?: (workspaceId: string) => void | Promise<void>;
  /** Server operational metrics. Optional so route tests can omit it. */
  metrics?: ServerTelemetry;
  /** Resource sampler control. Optional so route tests can omit it. */
  serverMetrics?: ServerMetricsControl;
}

export interface RouteHelpers {
  parseBody<T>(req: IncomingMessage, options?: { maxBytes?: number }): Promise<T>;
  json(res: ServerResponse, data: unknown, status?: number): void;
  compressedJson(req: IncomingMessage, res: ServerResponse, data: unknown, status?: number): void;
  error(res: ServerResponse, status: number, message: string): void;
}

export interface RouteDispatchRequest {
  method: string;
  path: string;
  url: URL;
  req: IncomingMessage;
  res: ServerResponse;
  principal?: RequestPrincipal;
}

export type RouteDispatcher = (request: RouteDispatchRequest) => Promise<boolean>;
