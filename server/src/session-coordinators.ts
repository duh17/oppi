import { trustedSessionAttachmentSourceRoots } from "./chat-attachments.js";
import { isDeclaredControlSession } from "./control-session.js";
import { applyHostEnv } from "./host-env.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { SessionBackendEvent } from "./pi-events.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
import type { ResourceUsageService } from "./resource-usage-service.js";
import {
  SessionActivationCoordinator,
  type SessionActivationActiveSession,
} from "./session-activation.js";
import {
  SessionAgentEventCoordinator,
  type SessionAgentEventState,
} from "./session-agent-events.js";
import {
  SessionBroadcaster,
  type SessionBroadcastEvent,
  type SessionCatchUpResponse,
} from "./session-broadcast.js";
import { SessionCommandCoordinator, type CommandSessionState } from "./session-commands.js";
import { SessionEventProcessor } from "./session-events.js";
import { SessionInputCoordinator, type SessionInputSessionState } from "./session-input.js";
import {
  SessionLifecycleCoordinator,
  type SessionLifecycleSessionState,
} from "./session-lifecycle.js";
import { SessionMessageQueueCoordinator, type SessionMessageQueueState } from "./session-queue.js";
import { SessionStartCoordinator, type SessionStartActiveSession } from "./session-start.js";
import { SessionStateCoordinator } from "./session-state.js";
import {
  SessionStopFlowCoordinator,
  type SessionStopFlowSessionState,
} from "./session-stop-flow.js";
import { SessionStopCoordinator, type SessionStopTimers } from "./session-stop.js";
import { SessionTurnCoordinator } from "./session-turns.js";
import type { Storage } from "./storage.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import { resolveUploadStoreConfig } from "./uploads/local-upload-store.js";
import type { ServerConfig, ServerMessage, Session } from "./types.js";
import type { WorkspaceRuntime } from "./workspace-runtime.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";

export type { SessionCatchUpResponse };

export interface SessionCoordinatorBundle {
  broadcaster: SessionBroadcaster;
  eventProcessor: SessionEventProcessor;
  stopCoordinator: SessionStopCoordinator;
  stateCoordinator: SessionStateCoordinator;
  commandCoordinator: SessionCommandCoordinator;
  startCoordinator: SessionStartCoordinator;
  activationCoordinator: SessionActivationCoordinator;
  lifecycleCoordinator: SessionLifecycleCoordinator;
  inputCoordinator: SessionInputCoordinator;
  turnCoordinator: SessionTurnCoordinator;
  queueCoordinator: SessionMessageQueueCoordinator;
  agentEventCoordinator: SessionAgentEventCoordinator;
  stopFlowCoordinator: SessionStopFlowCoordinator;
}

export interface SessionCoordinatorBundleDeps {
  storage: Storage;
  config: ServerConfig;
  runtimeManager: WorkspaceRuntime;
  active: Map<string, SessionStartActiveSession>;
  mobileRenderers: MobileRendererRegistry;
  /** Lazy accessor for server operational metric collector. */
  getMetrics?: () => ServerMetricCollector | null;
  eventRingCapacity: number;
  stopAbortTimeoutMs: number;
  stopAbortRetryTimeoutMs: number;
  stopSessionGraceMs: number;
  stopSessionBoundMs: number;
  stopTimers?: SessionStopTimers;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
  getSkillPathResolver: () => ((skillNames: string[]) => Promise<string[]>) | null;
  emitSessionEvent: (payload: SessionBroadcastEvent) => void;
  onPiEvent: (key: string, event: SessionBackendEvent) => void;
  onSessionEnd: (key: string, reason: string, stopConfirmationReason?: string) => Promise<void>;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
  sendCommand: (
    key: string,
    command: Record<string, unknown>,
    permit?: SessionRuntimeTransactionPermit,
    onPreflightAccepted?: () => void,
  ) => void | Promise<void>;
  sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>;
  broadcast: (key: string, message: ServerMessage) => void;
  stopSession: (sessionId: string) => Promise<void>;
  /** Called when a session's firstMessage is first captured. */
  onFirstMessage?: (session: Session) => void;
  /** Operational metrics collector for session lifecycle timing. */
  metrics?: ServerMetricCollector;
  resourceUsage?: ResourceUsageService;
}

export function createSessionCoordinatorBundle(
  deps: SessionCoordinatorBundleDeps,
): SessionCoordinatorBundle {
  const broadcaster = new SessionBroadcaster({
    getActiveSession: (key) => deps.active.get(key),
    emitSessionEvent: (payload) => deps.emitSessionEvent(payload),
    saveSession: (session) => deps.storage.saveSession(session),
    metrics: deps.metrics,
  });

  const eventProcessor = new SessionEventProcessor({
    storage: deps.storage,
    mobileRenderers: deps.mobileRenderers,
    broadcast: (key, message) => broadcaster.broadcast(key, message),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    markSessionDirty: (key) => deps.markSessionDirty(key),
    metrics: deps.metrics,
  });

  const stopCoordinator = new SessionStopCoordinator(
    {
      getActiveSession: (key) => deps.active.get(key),
      persistSessionNow: (key, session) => broadcaster.persistSessionNow(key, session),
      broadcast: (key, message) => broadcaster.broadcast(key, message),
      handleSessionEnd: (key, reason, stopConfirmationReason) =>
        deps.onSessionEnd(key, reason, stopConfirmationReason),
    },
    deps.stopAbortTimeoutMs,
    deps.stopAbortRetryTimeoutMs,
    deps.stopTimers,
  );

  const stateCoordinator = new SessionStateCoordinator({
    storage: deps.storage,
    getContextWindowResolver: () => deps.getContextWindowResolver(),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
  });

  const commandCoordinator = new SessionCommandCoordinator({
    getActiveSession: (key) => deps.active.get(key) as CommandSessionState | undefined,
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    broadcast: (key, message) => deps.broadcast(key, message),
    applyPiStateSnapshot: (session, state) => stateCoordinator.applyPiStateSnapshot(session, state),
    getContextWindowResolver: () => deps.getContextWindowResolver(),
    reloadRuntimeConfig: () => {
      applyHostEnv(deps.storage.getConfig());
    },
  });

  const startCoordinator = new SessionStartCoordinator({
    storage: deps.storage,
    runtimeManager: deps.runtimeManager,
    config: deps.config,
    eventRingCapacity: deps.eventRingCapacity,
    getSkillPathResolver: () => deps.getSkillPathResolver(),
    onPiEvent: (key, event) => deps.onPiEvent(key, event),
    onSessionEnd: (key, reason) => deps.onSessionEnd(key, reason),
    registerActiveSession: (key, active) => deps.active.set(key, active),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
    bootstrapSessionState: (key) => deps.bootstrapSessionState(key),
    metrics: deps.metrics,
    resourceUsage: deps.resourceUsage,
  });

  const activationCoordinator = new SessionActivationCoordinator({
    runtimeManager: deps.runtimeManager,
    getActiveSession: (key) => deps.active.get(key) as SessionActivationActiveSession | undefined,
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
    startSessionInner: (key, sessionId, workspace) =>
      startCoordinator.startSessionInner(key, sessionId, workspace),
  });

  const resourceUsageLifecycle: { release?: (session: Session) => void } = {};
  const lifecycleCoordinator = new SessionLifecycleCoordinator({
    getActiveSession: (key) => deps.active.get(key) as SessionLifecycleSessionState | undefined,
    removeActiveSession: (key) => deps.active.delete(key),
    releaseResourceUsageSession: (session) => resourceUsageLifecycle.release?.(session),
    clearPendingStop: (active) => stopCoordinator.clearPendingStop(active),
    broadcast: (key, message) => deps.broadcast(key, message),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    releaseSession: (identity) => deps.runtimeManager.releaseSession(identity),
    stopSession: (sessionId) => deps.stopSession(sessionId),
    getSessionIdleTimeoutMs: () => deps.runtimeManager.getLimits().sessionIdleTimeoutMs,
    metrics: deps.metrics,
  });

  const turnCoordinator = new SessionTurnCoordinator({
    broadcast: (key, message) => broadcaster.broadcast(key, message),
  });

  const resolveWorkspaceRoot = (session: Session): string | null => {
    if (!session.workspaceId) {
      return isDeclaredControlSession(session)
        ? resolveSdkSessionCwd(undefined, session, { dataDir: deps.storage.getDataDir() })
        : null;
    }
    const workspace = deps.storage.getWorkspace(session.workspaceId);
    if (!workspace?.hostMount) {
      return null;
    }
    return resolveSdkSessionCwd(workspace, session, { dataDir: deps.storage.getDataDir() });
  };

  const uploadStoreConfig = resolveUploadStoreConfig(deps.config);
  const maxTurnAttachmentBytes = deps.config.uploadStore?.maxTurnBytes ?? 100 * 1024 * 1024;

  const queueCoordinator = new SessionMessageQueueCoordinator({
    getActiveSession: (key) => deps.active.get(key) as SessionMessageQueueState | undefined,
    broadcast: (key, message) => deps.broadcast(key, message),
    resolveWorkspaceRoot,
    maxTurnAttachmentBytes,
    uploadStoreConfig,
  });

  const inputCoordinator = new SessionInputCoordinator({
    config: deps.config,
    getActiveSession: (key) => deps.active.get(key) as SessionInputSessionState | undefined,
    turnCoordinator,
    sendCommand: (key, command, permit, onPreflightAccepted) =>
      deps.sendCommand(key, command, permit, onPreflightAccepted),
    uploadStoreConfig,
    enqueueQueuedMessage: (key, kind, message, attachments, idHint, sdkMessage, sdkImages) =>
      queueCoordinator.enqueueQueuedMessage(
        key,
        kind,
        message,
        attachments,
        idHint,
        sdkMessage,
        sdkImages,
      ),
    resolveWorkspaceRoot,
    onFirstMessage: deps.onFirstMessage,
    assertModelTurnAdmissionAllowed: (key) => queueCoordinator.assertModelTurnAdmissionAllowed(key),
    resourceUsage: deps.resourceUsage,
  });

  const agentEventCoordinator = new SessionAgentEventCoordinator({
    getActiveSession: (key) => deps.active.get(key) as SessionAgentEventState | undefined,
    eventProcessor,
    stopCoordinator,
    turnCoordinator,
    broadcast: (key, message) => deps.broadcast(key, message),
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
    markQueuedMessageStarted: (key, message) =>
      queueCoordinator.markQueuedMessageStarted(key, message),
    schedulePostCompactionQueueFlush: (key) =>
      queueCoordinator.schedulePostCompactionQueueFlush(key),
    resumeQueuedCompactions: (key) => commandCoordinator.resumeQueuedCompactions(key),
    dataDir: deps.storage.getDataDir(),
    trustedAttachmentSourceRoots: trustedSessionAttachmentSourceRoots(),
    resourceUsage: deps.resourceUsage,
  });
  resourceUsageLifecycle.release = (session) =>
    agentEventCoordinator.releaseResourceUsageSession(session);

  const stopFlowCoordinator = new SessionStopFlowCoordinator(
    {
      runtimeManager: deps.runtimeManager,
      getActiveSession: (key) => deps.active.get(key) as SessionStopFlowSessionState | undefined,
      stopCoordinator,
      broadcast: (key, message) => deps.broadcast(key, message),
      clearQueueOnAbort: (key, permit) => queueCoordinator.clearQueueOnAbort(key, permit),
      acceptQueueClearOnAbort: (clear) => queueCoordinator.acceptQueueClearOnAbort(clear),
      restoreQueueAfterAbortFailure: (clear, permit) =>
        queueCoordinator.restoreQueueAfterAbortFailure(clear, permit),
    },
    deps.stopSessionGraceMs,
    deps.stopSessionBoundMs,
  );

  return {
    broadcaster,
    eventProcessor,
    stopCoordinator,
    stateCoordinator,
    commandCoordinator,
    startCoordinator,
    activationCoordinator,
    lifecycleCoordinator,
    inputCoordinator,
    turnCoordinator,
    queueCoordinator,
    agentEventCoordinator,
    stopFlowCoordinator,
  };
}
