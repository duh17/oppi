import type { IncomingMessage, ServerResponse } from "node:http";

import type { Storage } from "../storage.js";
import type { SessionManager } from "../sessions.js";
import type { GateServer } from "../gate.js";
import type { SkillRegistry, UserSkillStore } from "../skills.js";
import type { UserStreamMux } from "../stream.js";
import type { Session, Workspace } from "../types.js";
import type { ModelInfo } from "../model-catalog.js";

/** Services needed by route handlers — injected by Server. */
export interface RouteContext {
  storage: Storage;
  sessions: SessionManager;
  gate: GateServer;
  skillRegistry: SkillRegistry;
  userSkillStore: UserSkillStore;
  streamMux: UserStreamMux;
  ensureSessionContextWindow: (session: Session) => Session;
  resolveWorkspaceForSession: (session: Session) => Workspace | undefined;
  isValidMemoryNamespace: (ns: string) => boolean;
  refreshModelCatalog: () => Promise<void>;
  getModelCatalog: () => ModelInfo[];
  serverStartedAt: number;
  serverVersion: string;
  piVersion: string;
}

export interface RouteHelpers {
  parseBody<T>(req: IncomingMessage): Promise<T>;
  json(res: ServerResponse, data: Record<string, unknown>, status?: number): void;
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
