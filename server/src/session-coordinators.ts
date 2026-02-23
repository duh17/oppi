import type { GateServer } from "./gate.js";
import type { MobileRendererRegistry } from "./mobile-renderer.js";
import type { PiEvent } from "./pi-events.js";
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
import type { ServerConfig, ServerMessage, Session } from "./types.js";
import type { WorkspaceRuntime } from "./workspace-runtime.js";

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
  agentEventCoordinator: SessionAgentEventCoordinator;
  stopFlowCoordinator: SessionStopFlowCoordinator;
  uiCoordinator: SessionUICoordinator;
}

export interface SessionCoordinatorBundleDeps {
  storage: Storage;
  config: ServerConfig;
  gate: GateServer;
  runtimeManager: WorkspaceRuntime;
  active: Map<string, SessionStartActiveSession>;
  mobileRenderers: MobileRendererRegistry;
  eventRingCapacity: number;
  stopAbortTimeoutMs: number;
  stopAbortRetryTimeoutMs: number;
  stopSessionGraceMs: number;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
  getSkillPathResolver: () => ((skillNames: string[]) => string[]) | null;
  emitSessionEvent: (payload: SessionBroadcastEvent) => void;
  onPiEvent: (key: string, event: PiEvent) => void;
  onSessionEnd: (key: string, reason: string) => void;
  persistSessionNow: (key: string, session: Session) => void;
  markSessionDirty: (key: string) => void;
  resetIdleTimer: (key: string) => void;
  bootstrapSessionState: (key: string) => Promise<void>;
  sendCommand: (key: string, command: Record<string, unknown>) => void;
  sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>;
  broadcast: (key: string, message: ServerMessage) => void;
  stopSession: (sessionId: string) => Promise<void>;
}

export function createSessionCoordinatorBundle(
  deps: SessionCoordinatorBundleDeps,
): SessionCoordinatorBundle {
  const broadcaster = new SessionBroadcaster({
    getActiveSession: (key) => deps.active.get(key),
    emitSessionEvent: (payload) => deps.emitSessionEvent(payload),
    saveSession: (session) => deps.storage.saveSession(session),
  });

  const eventProcessor = new SessionEventProcessor({
    storage: deps.storage,
    mobileRenderers: deps.mobileRenderers,
    broadcast: (key, message) => broadcaster.broadcast(key, message),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    markSessionDirty: (key) => deps.markSessionDirty(key),
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
    sendCommandAsync: (key, command) => deps.sendCommandAsync(key, command),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    broadcast: (key, message) => deps.broadcast(key, message),
  });

  const commandCoordinator = new SessionCommandCoordinator({
    getActiveSession: (key) => deps.active.get(key) as CommandSessionState | undefined,
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    broadcast: (key, message) => deps.broadcast(key, message),
    applyPiStateSnapshot: (session, state) => stateCoordinator.applyPiStateSnapshot(session, state),
    applyRememberedThinkingLevel: (key, active) =>
      stateCoordinator.applyRememberedThinkingLevel(key, active),
    persistThinkingPreference: (session) => stateCoordinator.persistThinkingPreference(session),
    persistWorkspaceLastUsedModel: (session) =>
      stateCoordinator.persistWorkspaceLastUsedModel(session),
    getContextWindowResolver: () => deps.getContextWindowResolver(),
  });

  const startCoordinator = new SessionStartCoordinator({
    storage: deps.storage,
    runtimeManager: deps.runtimeManager,
    config: deps.config,
    gate: deps.gate,
    eventRingCapacity: deps.eventRingCapacity,
    getSkillPathResolver: () => deps.getSkillPathResolver(),
    onPiEvent: (key, event) => deps.onPiEvent(key, event),
    onSessionEnd: (key, reason) => deps.onSessionEnd(key, reason),
    registerActiveSession: (key, active) => deps.active.set(key, active),
    persistSessionNow: (key, session) => deps.persistSessionNow(key, session),
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
    bootstrapSessionState: (key) => deps.bootstrapSessionState(key),
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
    destroySessionGuard: (sessionId) => deps.gate.destroySessionGuard(sessionId),
    releaseSession: (identity) => deps.runtimeManager.releaseSession(identity),
    stopSession: (sessionId) => deps.stopSession(sessionId),
    getSessionIdleTimeoutMs: () => deps.runtimeManager.getLimits().sessionIdleTimeoutMs,
  });

  const turnCoordinator = new SessionTurnCoordinator({
    broadcast: (key, message) => broadcaster.broadcast(key, message),
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
    markTurnDispatched: (key, active, command, turn, requestId) =>
      turnCoordinator.markTurnDispatched(key, active as TurnSessionState, command, turn, requestId),
    sendCommand: (key, command) => deps.sendCommand(key, command),
  });

  const agentEventCoordinator = new SessionAgentEventCoordinator({
    getActiveSession: (key) => deps.active.get(key) as SessionAgentEventState | undefined,
    eventProcessor,
    stopCoordinator,
    turnCoordinator,
    broadcast: (key, message) => deps.broadcast(key, message),
    resetIdleTimer: (key) => deps.resetIdleTimer(key),
  });

  const stopFlowCoordinator = new SessionStopFlowCoordinator(
    {
      runtimeManager: deps.runtimeManager,
      getActiveSession: (key) => deps.active.get(key) as SessionStopFlowSessionState | undefined,
      stopCoordinator,
      broadcast: (key, message) => deps.broadcast(key, message),
      sendCommand: (key, command) => deps.sendCommand(key, command),
    },
    deps.stopSessionGraceMs,
  );

  const uiCoordinator = new SessionUICoordinator({
    getActiveSession: (key) => deps.active.get(key),
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
    agentEventCoordinator,
    stopFlowCoordinator,
    uiCoordinator,
  };
}
