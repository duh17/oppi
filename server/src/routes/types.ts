import type { IncomingMessage, ServerResponse } from "node:http";

import type { Storage } from "../storage.js";
import type { SessionManager } from "../sessions.js";
import type { SkillRegistry } from "../skills.js";
import type { Session, Workspace } from "../types.js";
import type { ModelInfo } from "../model-catalog.js";
import type { SearchIndex } from "../search-index.js";
import type { ProviderAuthManager } from "../provider-auth/provider-auth-manager.js";
import type { CodexUsageStatus } from "../codex-usage.js";
import type { AppEventEmitter } from "../app-event-stream.js";
import type { SessionRuntimes } from "../runtime-router.js";

/** Services needed by route handlers — injected by Server. */
export interface RouteContext {
  storage: Storage;
  sessions: SessionManager;
  sessionRuntimes: SessionRuntimes;
  skillRegistry: SkillRegistry;
  providerAuth: ProviderAuthManager;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  refreshModelCatalog: () => Promise<void>;
  getModelCatalog: () => ModelInfo[];
  getCodexUsageStatus?: () => Promise<CodexUsageStatus>;
  searchIndex?: SearchIndex;
  appEvents?: AppEventEmitter;
  serverStartedAt: number;
  serverVersion: string;
  piVersion: string;
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
}

export type RouteDispatcher = (request: RouteDispatchRequest) => Promise<boolean>;
