import { generateId } from "./id.js";
import {
  isRequiredModelUnavailableError,
  isRequiredModelUnavailableMessage,
} from "./model-resolution.js";
import { resolveInitialChatModel } from "./session-model-selection.js";
import type { Storage } from "./storage.js";
import type { ThinkingLevel } from "./thinking-levels.js";
import type { ChatAttachmentRef, IconChoice, Session, Workspace } from "./types.js";

export type { ThinkingLevel } from "./thinking-levels.js";

export interface AgentDefinition {
  name: string;
  icon?: IconChoice;
  description?: string;
  instructions?: {
    mode: "append" | "replace";
    text: string;
  };
  resources?: {
    agentsFiles?: Array<{ path: string; content: string }>;
    noContextFiles?: boolean;
    /** Omitted inherits Pi discovery; an array is the Agent's exact Skill selection. */
    skillPaths?: string[];
    /** Omitted inherits Pi discovery; an array is the Agent's exact Extension selection. */
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
  agentId?: string;
  agentVersion?: number;
  parentSessionId?: string;
  allowNestedDelegation?: boolean;
  target: AgentLaunchTarget;
  prompt?: string;
  attachments?: ChatAttachmentRef[];
  idempotencyKey?: string;
  leaseOwner?: string;
  source?: NonNullable<Session["launch"]>["source"];
  schedule?: NonNullable<Session["launch"]>["schedule"];
  modelPolicy?: NonNullable<Session["launch"]>["modelPolicy"];
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
    | "claimSessionLaunchRecovery"
    | "createSession"
    | "findSessionByLaunchIdempotencyKey"
    | "getSession"
    | "listSessions"
    | "saveSession"
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

/** Return the launch error that creation routes must surface instead of reporting success. */
export function requiredModelLaunchFailureMessage(session: Session): string | undefined {
  const launch = session.launch;
  if (
    launch?.modelPolicy !== "required" ||
    launch.status !== "failed" ||
    launch.promptDispatch !== "not_sent" ||
    !isRequiredModelUnavailableMessage(launch.promptError)
  ) {
    return undefined;
  }
  return launch.promptError;
}

export class DelegationPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DelegationPolicyError";
  }
}

export class AgentLaunchService {
  private readonly nowMs: () => number;
  private readonly leaseTtlMs: number;

  constructor(private readonly deps: AgentLaunchServiceDeps) {
    this.nowMs = deps.nowMs ?? Date.now;
    this.leaseTtlMs = deps.leaseTtlMs ?? DEFAULT_LEASE_TTL_MS;
  }

  async launch(request: AgentLaunchRequest): Promise<AgentLaunchResult> {
    const delegation = this.resolveDelegation(request);
    const idempotencyKey = normalizedText(request.idempotencyKey);
    const leaseOwner = normalizedText(request.leaseOwner) ?? DEFAULT_LEASE_OWNER;
    const now = this.nowMs();

    if (idempotencyKey) {
      const existing = this.findSessionByIdempotencyKey(idempotencyKey);
      if (existing) {
        this.assertIdempotentDelegationMatches(existing, delegation);
        const existingResult = this.resultForExistingLaunch(existing, now);
        if (
          existingResult.kind === "existing" &&
          this.shouldRecoverExistingLaunch(existing, request, now)
        ) {
          return this.recoverExistingLaunch(existing, request, leaseOwner, now);
        }
        return existingResult;
      }
    }

    const session = this.buildSession(request, delegation, idempotencyKey, leaseOwner, now);
    try {
      this.deps.storage.saveSession(session);
    } catch (error) {
      const existing = idempotencyKey
        ? this.findSessionByIdempotencyKey(idempotencyKey)
        : undefined;
      if (existing) {
        this.assertIdempotentDelegationMatches(existing, delegation);
        return this.resultForExistingLaunch(existing, now);
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
        isRequiredModelUnavailableError(error),
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
    delegation: {
      parentSessionId?: string;
      allowsNestedDelegation?: boolean;
    },
    idempotencyKey: string | undefined,
    leaseOwner: string,
    now: number,
  ): Session {
    const defaults = request.agent.sessionDefaults ?? {};
    // A launch-level model is an explicit caller or saved-Agent choice. Workspace/Pi defaults
    // remain fallback-capable only when no launch model was selected.
    const modelPolicy =
      request.modelPolicy ?? (normalizedText(defaults.model) ? "required" : undefined);
    const modelSelection = resolveInitialChatModel({
      requestModel: defaults.model,
      workspace: request.target.workspace,
    });
    const sessionName = normalizedText(request.sessionName);
    const agentIcon = request.agentId ? request.agent.icon : undefined;
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
    session.launch = {
      source: request.source ?? "workspace-wrapper",
      ...(request.agentId ? { agentId: request.agentId } : {}),
      ...(request.agentVersion !== undefined ? { agentVersion: request.agentVersion } : {}),
      ...(agentIcon ? { agentIcon } : {}),
      parentSessionId: delegation.parentSessionId,
      allowsNestedDelegation: delegation.allowsNestedDelegation,
      idempotencyKey,
      schedule: request.schedule,
      target: {
        workspaceId: request.target.workspace.id,
        ...(request.target.worktreeId ? { worktreeId: request.target.worktreeId } : {}),
        runtime: request.target.workspace.runtime === "sandbox" ? "sandbox" : "host",
      },
      model: modelSelection.model,
      modelPolicy,
      thinkingLevel: defaults.thinkingLevel,
      tools: {
        ...(defaults.tools ? { allowed: defaults.tools } : {}),
        ...(defaults.excludeTools ? { excluded: defaults.excludeTools } : {}),
        ...(defaults.noTools ? { noTools: defaults.noTools } : {}),
      },
      status: "launching",
      requestedAt: now,
      ...(idempotencyKey
        ? {
            lease: {
              owner: leaseOwner,
              acquiredAt: now,
              expiresAt: now + this.leaseTtlMs,
            },
          }
        : {}),
    };

    return session;
  }

  private resolveDelegation(request: AgentLaunchRequest): {
    parentSessionId?: string;
    allowsNestedDelegation?: boolean;
  } {
    const parentSessionId = normalizedText(request.parentSessionId);
    if (!parentSessionId) {
      if (request.allowNestedDelegation) {
        throw new DelegationPolicyError(
          "Nested delegation can only be authorized by a managed caller session",
        );
      }
      return {};
    }

    const parent = this.deps.storage.getSession(parentSessionId);
    if (!parent) {
      throw new DelegationPolicyError("Caller session not found");
    }

    const inheritedGrant = this.effectiveNestedGrant(parent);
    if (parent.launch?.parentSessionId && !inheritedGrant) {
      throw new DelegationPolicyError(
        "Nested delegation is not authorized for this caller session",
      );
    }

    // The nested-delegation grant propagates down the subtree: children of an
    // authorized session inherit the grant, so an explicitly requested
    // grandchild session can be created without re-authorizing each level.
    return {
      parentSessionId,
      ...(inheritedGrant || request.allowNestedDelegation ? { allowsNestedDelegation: true } : {}),
    };
  }

  /**
   * True when this session may spawn children with full nested delegation.
   * The stored grant propagates down the subtree; walking the ancestry also
   * honors sessions created before propagation existed, whose ancestors hold
   * the stored grant.
   */
  private effectiveNestedGrant(session: Session): boolean {
    let current: Session | undefined = session;
    const seen = new Set<string>();
    while (current && !seen.has(current.id)) {
      seen.add(current.id);
      if (current.launch?.allowsNestedDelegation) return true;
      if (!current.launch?.parentSessionId) return false;
      current = this.deps.storage.getSession(current.launch.parentSessionId);
    }
    return false;
  }

  private assertIdempotentDelegationMatches(
    existing: Session,
    delegation: {
      parentSessionId?: string;
      allowsNestedDelegation?: boolean;
    },
  ): void {
    const existingParentSessionId = normalizedText(existing.launch?.parentSessionId);
    const existingAllowsNestedDelegation = existing.launch?.allowsNestedDelegation === true;
    const requestedGrant = delegation.allowsNestedDelegation === true;
    // Compare effective grants: an old-format session may lack the stored
    // inherited flag, but its ancestry (or an explicit stored grant) still
    // authorizes nesting. A retry that would add a grant where the existing
    // session's lineage grants none is a different delegation lineage.
    const existingEffectiveGrant =
      existingAllowsNestedDelegation ||
      (existingParentSessionId ? this.effectiveNestedGrant(existing) : false);
    const grantMismatch = existingEffectiveGrant !== requestedGrant;
    if (existingParentSessionId !== delegation.parentSessionId || grantMismatch) {
      throw new DelegationPolicyError(
        "Idempotency key is already associated with a different delegation lineage",
      );
    }
  }

  private markLaunchComplete(
    session: Session,
    promptDispatch: PromptDispatchStatus,
    promptError?: string,
    requiredModelUnavailable = false,
  ): void {
    if (session.launch) {
      const { promptError: _previousPromptError, ...launch } = session.launch;
      if (promptError && requiredModelUnavailable) session.status = "error";
      session.launch = {
        ...launch,
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

  private resultForExistingLaunch(existing: Session, now: number): AgentLaunchResult {
    const lease = existing.launch?.lease;
    if (existing.launch?.status === "launching" && lease && lease.expiresAt > now) {
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

  private shouldRecoverExistingLaunch(
    existing: Session,
    request: AgentLaunchRequest,
    now: number,
  ): boolean {
    const launch = existing.launch;
    if (!launch) return false;
    if (launch.promptDispatch === "delivered") return false;
    if (!this.launchTargetMatchesRequest(existing, request)) return false;
    if (requiredModelLaunchFailureMessage(existing)) return false;
    if (launch.status === "failed") return true;
    if (launch.status !== "launching") return false;
    const lease = launch.lease;
    return !lease || lease.expiresAt <= now;
  }

  private launchTargetMatchesRequest(existing: Session, request: AgentLaunchRequest): boolean {
    const target = existing.launch?.target;
    const expectedWorkspaceId = target?.workspaceId ?? existing.workspaceId;
    if (expectedWorkspaceId && expectedWorkspaceId !== request.target.workspace.id) {
      return false;
    }

    const expectedWorktreeId = target?.worktreeId ?? existing.worktreeId;
    if (expectedWorktreeId !== undefined && expectedWorktreeId !== request.target.worktreeId) {
      return false;
    }

    const requestedRuntime = request.target.workspace.runtime === "sandbox" ? "sandbox" : "host";
    if (target?.runtime && target.runtime !== requestedRuntime) {
      return false;
    }

    return true;
  }

  private async recoverExistingLaunch(
    existing: Session,
    request: AgentLaunchRequest,
    leaseOwner: string,
    now: number,
  ): Promise<AgentLaunchResult> {
    if (!existing.launch) {
      return this.resultForExistingLaunch(existing, now);
    }

    const recovered = this.deps.storage.claimSessionLaunchRecovery(
      existing,
      leaseOwner,
      now,
      this.leaseTtlMs,
    );
    if (!recovered) {
      return {
        kind: "launch_in_progress",
        retryable: true,
        session: this.hydratedSnapshot(existing),
        retryAfterMs: Math.max(
          0,
          existing.launch.lease ? existing.launch.lease.expiresAt - now : 0,
        ),
      };
    }

    const prompt = request.prompt?.trim();
    if (!prompt) {
      this.markLaunchComplete(recovered, "not_sent");
      const session = this.hydratedSnapshot(recovered);
      return { kind: "existing", session, createdSession: session, promptDispatch: "not_sent" };
    }

    try {
      await this.deps.sessions.startSession(recovered.id, request.target.workspace);
      await this.deps.sessions.sendPrompt(recovered.id, prompt, {
        ...(request.attachments ? { attachments: request.attachments } : {}),
      });
      recovered.firstMessage = prompt.slice(0, 200);
      this.markLaunchComplete(recovered, "delivered");
      const session = this.hydratedSnapshot(recovered);
      return { kind: "existing", session, createdSession: session, promptDispatch: "delivered" };
    } catch (error: unknown) {
      this.markLaunchComplete(
        recovered,
        "not_sent",
        error instanceof Error ? error.message : String(error),
        isRequiredModelUnavailableError(error),
      );
      const session = this.hydratedSnapshot(recovered);
      return { kind: "existing", session, createdSession: session, promptDispatch: "not_sent" };
    }
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
