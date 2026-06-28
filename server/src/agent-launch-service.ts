import { generateId } from "./id.js";
import { resolveInitialChatModel } from "./session-model-selection.js";
import type { Storage } from "./storage.js";
import type { ChatAttachmentRef, Session, Workspace } from "./types.js";

export type ThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

export interface AgentDefinition {
  name: string;
  description?: string;
  instructions?: {
    mode: "append" | "replace";
    text: string;
  };
  resources?: {
    agentsFiles?: Array<{ path: string; content: string }>;
    noContextFiles?: boolean;
    skillIds?: string[];
    promptTemplateIds?: string[];
    extensionIds?: string[];
  };
  sessionDefaults?: {
    model?: string;
    thinkingLevel?: ThinkingLevel;
    tools?: string[];
    excludeTools?: string[];
    noTools?: "all" | "builtin";
  };
}

export interface AgentLaunchTarget {
  workspace: Workspace;
  worktreeId?: string;
}

export interface AgentLaunchRequest {
  agent: AgentDefinition;
  target: AgentLaunchTarget;
  prompt?: string;
  attachments?: ChatAttachmentRef[];
  idempotencyKey?: string;
  leaseOwner?: string;
  source?: NonNullable<Session["launch"]>["source"];
  schedule?: NonNullable<Session["launch"]>["schedule"];
  sessionName?: string;
  ephemeral?: boolean;
}

export type PromptDispatchStatus = "delivered" | "not_sent";

export type AgentLaunchResult =
  | {
      kind: "created" | "existing";
      session: Session;
      createdSession: Session;
      summarySession?: Session;
      promptDispatch: PromptDispatchStatus;
    }
  | {
      kind: "launch_in_progress";
      retryable: true;
      session: Session;
      retryAfterMs: number;
    };

export interface AgentLaunchServiceDeps {
  storage: Pick<
    Storage,
    "createSession" | "findSessionByLaunchIdempotencyKey" | "listSessions" | "saveSession"
  >;
  sessions: {
    startSession(sessionId: string, workspace?: Workspace): Promise<Session>;
    sendPrompt(
      sessionId: string,
      message: string,
      opts?: { attachments?: ChatAttachmentRef[] },
    ): Promise<void>;
  };
  ensureSessionContextWindow: (session: Session) => Session;
  nowMs?: () => number;
  leaseTtlMs?: number;
}

const DEFAULT_LEASE_TTL_MS = 2 * 60_000;
const DEFAULT_LEASE_OWNER = "workspace-session-create";

export class AgentLaunchService {
  private readonly nowMs: () => number;
  private readonly leaseTtlMs: number;

  constructor(private readonly deps: AgentLaunchServiceDeps) {
    this.nowMs = deps.nowMs ?? Date.now;
    this.leaseTtlMs = deps.leaseTtlMs ?? DEFAULT_LEASE_TTL_MS;
  }

  async launch(request: AgentLaunchRequest): Promise<AgentLaunchResult> {
    const idempotencyKey = normalizedText(request.idempotencyKey);
    const leaseOwner = normalizedText(request.leaseOwner) ?? DEFAULT_LEASE_OWNER;
    const now = this.nowMs();

    if (idempotencyKey) {
      const existing = this.findSessionByIdempotencyKey(idempotencyKey);
      if (existing) {
        return this.resultForExistingLaunch(existing, leaseOwner, now);
      }
    }

    const session = this.buildSession(request, idempotencyKey, leaseOwner, now);
    try {
      this.deps.storage.saveSession(session);
    } catch (error) {
      const existing = idempotencyKey
        ? this.findSessionByIdempotencyKey(idempotencyKey)
        : undefined;
      if (existing) {
        return this.resultForExistingLaunch(existing, leaseOwner, now);
      }
      throw error;
    }
    const createdSession = this.hydratedSnapshot(session);

    const prompt = request.prompt?.trim();
    if (!prompt) {
      this.markLaunchComplete(session, "not_sent");
      return {
        kind: "created",
        session: this.hydratedSnapshot(session),
        createdSession,
        promptDispatch: "not_sent",
      };
    }

    try {
      await this.deps.sessions.startSession(session.id, request.target.workspace);
      await this.deps.sessions.sendPrompt(session.id, prompt, {
        ...(request.attachments ? { attachments: request.attachments } : {}),
      });
      session.firstMessage = prompt.slice(0, 200);
      this.markLaunchComplete(session, "delivered");
      const summarySession = this.hydratedSnapshot(session);
      return {
        kind: "created",
        session: summarySession,
        createdSession,
        summarySession,
        promptDispatch: "delivered",
      };
    } catch (error: unknown) {
      this.markLaunchComplete(
        session,
        "not_sent",
        error instanceof Error ? error.message : String(error),
      );
      return {
        kind: "created",
        session: this.hydratedSnapshot(session),
        createdSession,
        promptDispatch: "not_sent",
      };
    }
  }

  private buildSession(
    request: AgentLaunchRequest,
    idempotencyKey: string | undefined,
    leaseOwner: string,
    now: number,
  ): Session {
    const defaults = request.agent.sessionDefaults ?? {};
    const modelSelection = resolveInitialChatModel({
      requestModel: defaults.model,
      workspace: request.target.workspace,
    });
    const sessionName = normalizedText(request.sessionName);
    const session: Session = idempotencyKey
      ? {
          id: generateId(8),
          name: sessionName,
          status: "ready",
          createdAt: now,
          lastActivity: now,
          ...(modelSelection.model ? { model: modelSelection.model } : {}),
          messageCount: 0,
          tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          cost: 0,
          runtime: "oppi",
        }
      : this.deps.storage.createSession(sessionName, modelSelection.model);

    session.workspaceId = request.target.workspace.id;
    session.workspaceName = request.target.workspace.name;

    if (request.target.worktreeId) {
      session.worktreeId = request.target.worktreeId;
    }
    if (request.ephemeral === true) {
      session.ephemeral = true;
    }
    if (defaults.thinkingLevel) {
      session.thinkingLevel = defaults.thinkingLevel;
    }
    if (idempotencyKey) {
      session.launch = {
        source: request.source ?? "workspace-wrapper",
        idempotencyKey,
        schedule: request.schedule,
        target: {
          workspaceId: request.target.workspace.id,
          ...(request.target.worktreeId ? { worktreeId: request.target.worktreeId } : {}),
          runtime: request.target.workspace.runtime === "sandbox" ? "sandbox" : "host",
        },
        model: modelSelection.model,
        thinkingLevel: defaults.thinkingLevel,
        tools: {
          ...(defaults.tools ? { allowed: defaults.tools } : {}),
          ...(defaults.excludeTools ? { excluded: defaults.excludeTools } : {}),
          ...(defaults.noTools ? { noTools: defaults.noTools } : {}),
        },
        status: "launching",
        requestedAt: now,
        lease: {
          owner: leaseOwner,
          acquiredAt: now,
          expiresAt: now + this.leaseTtlMs,
        },
      };
    }

    return session;
  }

  private markLaunchComplete(
    session: Session,
    promptDispatch: PromptDispatchStatus,
    promptError?: string,
  ): void {
    if (session.launch) {
      session.launch = {
        ...session.launch,
        status: promptDispatch === "delivered" || !promptError ? "accepted" : "failed",
        completedAt: this.nowMs(),
        promptDispatch,
        ...(promptError ? { promptError } : {}),
        lease: undefined,
      };
      this.deps.storage.saveSession(session);
      return;
    }
    if (promptDispatch === "delivered") {
      this.deps.storage.saveSession(session);
    }
  }

  private resultForExistingLaunch(
    existing: Session,
    leaseOwner: string,
    now: number,
  ): AgentLaunchResult {
    const lease = existing.launch?.lease;
    if (
      existing.launch?.status === "launching" &&
      lease &&
      lease.owner !== leaseOwner &&
      lease.expiresAt > now
    ) {
      return {
        kind: "launch_in_progress",
        retryable: true,
        session: this.hydratedSnapshot(existing),
        retryAfterMs: Math.max(0, lease.expiresAt - now),
      };
    }

    return {
      kind: "existing",
      session: this.hydratedSnapshot(existing),
      createdSession: this.hydratedSnapshot(existing),
      promptDispatch:
        existing.launch?.promptDispatch ?? (existing.firstMessage ? "delivered" : "not_sent"),
    };
  }

  private findSessionByIdempotencyKey(idempotencyKey: string): Session | undefined {
    const direct = this.deps.storage.findSessionByLaunchIdempotencyKey?.(idempotencyKey);
    if (direct) return direct;
    return this.deps.storage
      .listSessions()
      .find((session) => session.launch?.idempotencyKey === idempotencyKey);
  }

  private hydratedSnapshot(session: Session): Session {
    return { ...this.deps.ensureSessionContextWindow(session) };
  }
}

function normalizedText(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}
