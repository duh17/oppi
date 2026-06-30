import { AgentLaunchService } from "./agent-launch-service.js";
import type {
  AgentScheduleDispatchHooks,
  ExistingSessionDispatchInput,
  NewSessionDispatchInput,
} from "./agent-schedules.js";
import type { AppEventEmitter } from "./app-event-stream.js";
import type { Storage } from "./storage.js";
import type { ChatAttachmentRef, Session, Workspace } from "./types.js";

export interface AgentScheduleDispatchDeps {
  storage: Pick<
    Storage,
    | "claimSessionLaunchRecovery"
    | "createSession"
    | "findSessionByLaunchIdempotencyKey"
    | "getAgentScheduleStore"
    | "getSession"
    | "getWorkspace"
    | "listSessions"
    | "saveSession"
  >;
  sessions: {
    startSession(sessionId: string, workspace?: Workspace): Promise<Session>;
    sendPrompt(
      sessionId: string,
      message: string,
      opts?: {
        attachments?: ChatAttachmentRef[];
        streamingBehavior?: "steer" | "followUp";
        requestId?: string;
      },
    ): Promise<void>;
  };
  ensureSessionContextWindow: (session: Session) => Session;
  appEvents?: Pick<AppEventEmitter, "emitSessionCreated" | "emitSessionSummary">;
}

export function createAgentScheduleDispatchHooks(
  deps: AgentScheduleDispatchDeps,
  leaseOwner: string,
): AgentScheduleDispatchHooks {
  return {
    launchNewSession: (input) => launchNewSession(deps, leaseOwner, input),
    sendExistingSessionInput: (input) => sendExistingSessionInput(deps, input),
  };
}

async function launchNewSession(
  deps: AgentScheduleDispatchDeps,
  leaseOwner: string,
  input: NewSessionDispatchInput,
): Promise<unknown> {
  const workspace = deps.storage.getWorkspace(input.action.workspaceId);
  if (!workspace) throw new Error("Workspace not found");

  const launchService = new AgentLaunchService({
    storage: deps.storage,
    sessions: deps.sessions,
    ensureSessionContextWindow: deps.ensureSessionContextWindow,
  });
  const result = await launchService.launch({
    agent: {
      name: input.action.name?.trim() || `Schedule ${input.schedule.id}`,
      sessionDefaults: {
        ...(input.action.model ? { model: input.action.model } : {}),
      },
    },
    target: {
      workspace,
      ...(input.action.worktreeId ? { worktreeId: input.action.worktreeId } : {}),
    },
    prompt: input.action.prompt,
    idempotencyKey: input.run.idempotencyKey,
    leaseOwner,
    source: "schedule",
    schedule: {
      scheduleId: input.schedule.id,
      runId: input.run.id,
      slotKey: input.run.slotKey,
    },
    sessionName: input.action.name,
  });
  if (result.kind === "launch_in_progress") {
    throw new Error("launch_in_progress");
  }
  if (input.action.prompt.trim().length > 0 && result.promptDispatch !== "delivered") {
    throw new Error("prompt_not_sent");
  }
  deps.appEvents?.emitSessionCreated(result.createdSession);
  if (result.summarySession) deps.appEvents?.emitSessionSummary(result.summarySession);
  return {
    sessionId: result.session.id,
    promptDispatch: result.promptDispatch,
    existing: result.kind === "existing",
  };
}

async function sendExistingSessionInput(
  deps: AgentScheduleDispatchDeps,
  input: ExistingSessionDispatchInput,
): Promise<unknown> {
  const session = deps.storage.getSession(input.action.sessionId);
  if (!session) throw new Error("Session not found");
  if (session.workspaceId !== input.action.workspaceId) {
    throw new Error("Session does not belong to schedule workspace");
  }
  await deps.sessions.sendPrompt(input.action.sessionId, input.action.prompt, {
    requestId: input.run.idempotencyKey,
    ...(input.action.streamingBehavior
      ? { streamingBehavior: input.action.streamingBehavior }
      : {}),
  });
  return { sessionId: input.action.sessionId, promptDispatch: "delivered" };
}
