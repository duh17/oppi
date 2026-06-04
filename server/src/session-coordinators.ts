import { homedir } from "node:os";
import { join } from "node:path";

import { applyHostEnv } from "./host-env.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { SessionBackendEvent } from "./pi-events.js";
import type { ServerMetricCollector } from "./server-metric-collector.js";
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
import { SessionStopCoordinator } from "./session-stop.js";
import { SessionTurnCoordinator, type TurnSessionState } from "./session-turns.js";
import { SessionUICoordinator } from "./session-ui.js";
import type { Storage } from "./storage.js";
import { resolveSdkSessionCwd } from "./sdk-backend.js";
import { resolveUploadStoreConfig } from "./uploads/local-upload-store.js";
import type { ServerConfig, ServerMessage, Session } from "./types.js";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { WorkspaceRuntime } from "./workspace-runtime.js";
import type {
  ListChildSessions,
  SendSessionMessage,
  SpawnChildSession,
  SpawnDetachedSession,
  SubscribeToSession,
} from "./session-spawn-types.js";

export type { SessionCatchUpResponse };

function trustedSessionAttachmentSourceRoots(): string[] {
  return [join(homedir(), "Library/Application Support/Yuwp/Audio/pi-voice")];
}

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
  uiCoordinator: SessionUICoordinator;
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
  getContextWindowResolver: () => ((modelId: string) => number) | null;
  getSkillPathResolver: () => ((skillNames: string[]) => Promise<string[]>) | null;
  getAndClearPendingExtensionFactories: (sessionId: string) => ExtensionFactory[];
  emitSessionEvent: (payload: SessionBroadcastEvent) => void;
  onPiEvent: (key: string, event: SessionBackendEvent) => void;
  onSessionEnd: (key: string, reason: string) => void;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
  sendCommand: (key: string, command: Record<string, unknown>) => void;
  sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>;
  broadcast: (key: string, message: ServerMessage) => void;
  stopSession: (sessionId: string) => Promise<void>;
  resumeSession: (sessionId: string) => Promise<Session>;
  // spawn_agent support
  spawnChildSession: SpawnChildSession;
  spawnDetachedSession: SpawnDetachedSession;
  listChildSessions: ListChildSessions;
  subscribeToSession: SubscribeToSession;
  getAvailableModelIds: () => string[];
  /** Send a message to a session. Dispatches as prompt, steer, or follow-up based on state. */
  sendMessage: SendSessionMessage;
  /** Called when a session's firstMessage is first captured. */
  onFirstMessage?: (session: Session) => void;
  /** Operational metrics collector for session lifecycle timing. */
  metrics?: ServerMetricCollector;
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
    // Lazy — uiCoordinator created later in this function
    respondToUIRequest: (key, response): boolean => uiCoordinator.respondToUIRequest(key, response),
    metrics: deps.metrics,
  });

  const stopCoordinator = new SessionStopCoordinator(
    {
      getActiveSession: (key) => deps.active.get(key),
      persistSessionNow: (key, session) => broadcaster.persistSessionNow(key, session),
      broadcast: (key, message) => broadcaster.broadcast(key, message),
      handleSessionEnd: (key, reason) => deps.onSessionEnd(key, reason),
    },
    deps.stopAbortTimeoutMs,
    deps.stopAbortRetryTimeoutMs,
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
    getAndClearPendingExtensionFactories: (sessionId) =>
      deps.getAndClearPendingExtensionFactories(sessionId),
    onPiEvent: (key, event) => deps.onPiEvent(key, event),
    onSessionEnd: (key, reason) => deps.onSessionEnd(key, reason),
    registerActiveSession: (key, active) => deps.active.set(key, active),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
    bootstrapSessionState: (key) => deps.bootstrapSessionState(key),
    spawnChildSession: (parentSessionId, params) => deps.spawnChildSession(parentSessionId, params),
    spawnDetachedSession: (originSessionId, params) =>
      deps.spawnDetachedSession(originSessionId, params),
    listChildSessions: (parentSessionId) => deps.listChildSessions(parentSessionId),
    subscribeToSession: (sessionId, callback) => deps.subscribeToSession(sessionId, callback),
    getAvailableModelIds: () => deps.getAvailableModelIds(),
    stopSession: (sessionId) => deps.stopSession(sessionId),
    resumeSession: (sessionId) => deps.resumeSession(sessionId),
    sendMessage: (sessionId, message, behavior) => deps.sendMessage(sessionId, message, behavior),
    metrics: deps.metrics,
  });

  const activationCoordinator = new SessionActivationCoordinator({
    runtimeManager: deps.runtimeManager,
    getActiveSession: (key) => deps.active.get(key) as SessionActivationActiveSession | undefined,
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
    startSessionInner: (key, sessionId, workspace) =>
      startCoordinator.startSessionInner(key, sessionId, workspace),
  });

  const lifecycleCoordinator = new SessionLifecycleCoordinator({
    getActiveSession: (key) => deps.active.get(key) as SessionLifecycleSessionState | undefined,
    removeActiveSession: (key) => deps.active.delete(key),
    clearPendingStop: (active) => stopCoordinator.clearPendingStop(active),
    broadcast: (key, message) => deps.broadcast(key, message),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    releaseSession: (identity) => deps.runtimeManager.releaseSession(identity),
    stopSession: (sessionId) => deps.stopSession(sessionId),
    getSessionIdleTimeoutMs: () => deps.runtimeManager.getLimits().sessionIdleTimeoutMs,
    getChildAutoStopWhenDone: () => deps.runtimeManager.getLimits().subagents.autoStopWhenDone,
    getChildStartupGraceMs: () => deps.runtimeManager.getLimits().subagents.startupGraceMs,
    getChildIdleTimeoutMs: () => deps.runtimeManager.getLimits().subagents.childIdleTimeoutMs,
    hasActiveChildren: (sessionId) => {
      for (const active of deps.active.values()) {
        if (active.session.parentSessionId === sessionId) {
          return true;
        }
      }
      return false;
    },
    metrics: deps.metrics,
  });

  const turnCoordinator = new SessionTurnCoordinator({
    broadcast: (key, message) => broadcaster.broadcast(key, message),
  });

  const resolveWorkspaceRoot = (session: Session): string | null => {
    if (!session.workspaceId) {
      return null;
    }
    const workspace = deps.storage.getWorkspace(session.workspaceId);
    if (!workspace?.hostMount) {
      return null;
    }
    return resolveSdkSessionCwd(workspace);
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
    getActiveSession: (key) => deps.active.get(key) as SessionInputSessionState | undefined,
    beginTurnIntent: (key, active, command, payload, clientTurnId, requestId) =>
      turnCoordinator.beginTurnIntent(
        key,
        active as TurnSessionState,
        command,
        payload,
        clientTurnId,
        requestId,
      ),
    isDuplicateTurnIntent: (active, command, clientTurnId, payload) =>
      turnCoordinator.isDuplicateTurnIntent(
        active as TurnSessionState,
        command,
        clientTurnId,
        payload,
      ),
    markTurnDispatched: (key, active, command, turn, requestId) =>
      turnCoordinator.markTurnDispatched(key, active as TurnSessionState, command, turn, requestId),
    sendCommand: (key, command) => deps.sendCommand(key, command),
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
    maxTurnAttachmentBytes,
    uploadStoreConfig,
    onFirstMessage: deps.onFirstMessage,
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
    dataDir: deps.storage.getDataDir(),
    trustedAttachmentSourceRoots: trustedSessionAttachmentSourceRoots(),
  });

  const stopFlowCoordinator = new SessionStopFlowCoordinator(
    {
      runtimeManager: deps.runtimeManager,
      getActiveSession: (key) => deps.active.get(key) as SessionStopFlowSessionState | undefined,
      stopCoordinator,
      broadcast: (key, message) => deps.broadcast(key, message),
      sendCommand: (key, command) => deps.sendCommand(key, command),
      clearQueueOnAbort: (key) => queueCoordinator.clearQueueOnAbort(key),
    },
    deps.stopSessionGraceMs,
  );

  const uiCoordinator = new SessionUICoordinator({
    getActiveSession: (key) => deps.active.get(key),
    eventProcessor,
  });

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
    uiCoordinator,
  };
}
