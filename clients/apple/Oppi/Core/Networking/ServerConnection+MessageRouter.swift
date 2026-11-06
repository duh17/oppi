import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

// MARK: - Message Router

extension ServerConnection {

    /// Handle active-session UI concerns for the focused session.
    ///
    /// Processes connection-level effects (silence watchdog, extension dialogs,
    /// message queue, connected/state handling) that only apply to the session
    /// currently focused by the user.
    ///
    /// Timeline mutations (coalescer/reducer) are handled by the per-session
    /// ChatSessionManager.routeToTimeline() instead.
    func handleActiveSessionUI(
        _ message: ServerMessage,
        sessionId: String,
        storeResult: StoreUpdateResult = .notHandled
    ) {
        guard isFocusedSession(sessionId) else { return }

        switch message {
        case .connected(let session):
            handleConnected(session)

        case .state(let session):
            handleState(session, previousWorkspaceId: storeResult.previousWorkspaceId)
            applyCleanupEffects(for: message, sessionId: sessionId, isFocusedSession: true)

        case .sessionSummary(let summary):
            handleState(summary.session, previousWorkspaceId: storeResult.previousWorkspaceId)
            applyCleanupEffects(for: message, sessionId: sessionId, isFocusedSession: true)

        case .queueState, .queueItemStarted:
            applyQueueEffects(ServerMessageEffects.queueEffects(for: message), sessionId: sessionId)

        case .extensionUIRequest, .extensionUINotification:
            applyUIEffects(ServerMessageEffects.uiEffects(for: message, isFocusedSession: true), sessionId: sessionId)

        case .extensionUISurface, .extensionUIPatch:
            applyComposableSurface(message, sessionId: sessionId)

        case .turnAck(let command, let clientTurnId, let stage, let requestId, _):
            _ = commands.resolveTurnAck(command: command, clientTurnId: clientTurnId, stage: stage, requestId: requestId, requiredStage: MessageSender.turnSendRequiredStage)

        case .gitStatus(let workspaceId, let worktreeId, let status):
            gitStatusStore.handleGitStatusPush(workspaceId: workspaceId, worktreeId: worktreeId, status: status)
            fileIndexStore.invalidate()
            if let serverId = currentServerId {
                Task { await FileBrowserCache.shared.invalidateDirectoryListings(for: workspaceId, serverId: serverId) }
            }

        case .agentStart:
            silenceWatchdog.start()

        case .agentEnd:
            // Keep monitoring through possible retries until settled.
            break

        case .agentSettled:
            silenceWatchdog.stop()

        case .textDelta, .thinkingDelta, .toolStart, .toolOutput, .toolEnd, .customCard, .conversationStream:
            silenceWatchdog.recordEvent()

        case .error:
            break

        case .extensionUISettled(let id, _):
            extensionSurfaces.settle(requestId: id, sessionId: sessionId)
            applyCleanupEffects(for: message, sessionId: sessionId, isFocusedSession: true)

        case .sessionEnded, .sessionDeleted, .stopConfirmed:
            applyCleanupEffects(for: message, sessionId: sessionId, isFocusedSession: true)

        default:
            break
        }
    }

    /// Handle connection-level UI concerns for non-focused sessions.
    ///
    /// Keeps ask state coherent for sessions that still receive messages via
    /// notification-level subscription or a non-active per-session continuation.
    func handleInactiveSessionUI(
        _ message: ServerMessage,
        sessionId: String
    ) {
        switch message {
        case .extensionUIRequest, .extensionUINotification:
            applyUIEffects(ServerMessageEffects.uiEffects(for: message, isFocusedSession: false), sessionId: sessionId)

        case .extensionUISurface, .extensionUIPatch:
            applyComposableSurface(message, sessionId: sessionId)

        case .extensionUISettled(let id, _):
            extensionSurfaces.settle(requestId: id, sessionId: sessionId)
            applyCleanupEffects(for: message, sessionId: sessionId, isFocusedSession: false)

        case .state, .sessionSummary, .sessionEnded, .stopConfirmed, .sessionDeleted:
            applyCleanupEffects(for: message, sessionId: sessionId, isFocusedSession: false)

        default:
            break
        }
    }

    func applyUIEffects(_ effects: ServerMessageUIEffects, sessionId: String) {
        if let request = effects.extensionRequest {
            if let ask = request.askRequest {
                storeAskRequest(ask, for: sessionId, isFocusedSession: effects.isFocusedSession)
            } else {
                storeExtensionDialog(
                    request,
                    for: sessionId,
                    isFocusedSession: effects.isFocusedSession
                )
            }
        }

        if let notification = effects.extensionNotification {
            applyExtensionUINotification(
                notification,
                sessionId: sessionId,
                isActiveSession: effects.isFocusedSession
            )
        }
    }

    /// A composable surface's frame belongs to the session it names: a surface published by a
    /// tool call outlives the turn, and a background session keeps the one its strip would show.
    func applyComposableSurface(_ message: ServerMessage, sessionId: String) {
        switch message {
        case .extensionUISurface(let surface, let routedSessionId):
            extensionSurfaces.apply(surface, sessionId: routedSessionId ?? sessionId)
        case .extensionUIPatch(let patch):
            extensionSurfaces.apply(patch, sessionId: patch.sessionId ?? sessionId)
        default:
            break
        }
    }

    func applyQueueEffects(_ effects: ServerMessageQueueEffects, sessionId: String) {
        if let queue = effects.applyQueueState {
            messageQueueStore.apply(queue, for: sessionId)
        }
        if let started = effects.queueItemStarted {
            messageQueueStore.applyQueueItemStarted(
                for: sessionId,
                kind: started.kind,
                item: started.item,
                queueVersion: started.queueVersion
            )
        }
    }

    func applyCleanupEffects(
        for message: ServerMessage,
        sessionId: String,
        isFocusedSession: Bool
    ) {
        applyCleanupEffects(
            ServerMessageEffects.cleanupEffects(
                for: message,
                routedSessionId: sessionId,
                isFocusedSession: isFocusedSession
            )
        )
    }

    func applyCleanupEffects(_ effects: ServerMessageCleanupEffects) {
        if effects.stopSilenceWatchdog {
            silenceWatchdog.stop()
        }
        for sessionId in effects.clearAskSessionIds {
            clearAskState(for: sessionId)
        }
        for requestId in effects.clearAskRequestIds {
            clearAskRequest(id: requestId)
        }
        for sessionId in effects.clearExtensionDialogSessionIds {
            clearExtensionDialog(for: sessionId)
        }
        for requestId in effects.clearExtensionDialogRequestIds {
            clearExtensionDialog(id: requestId)
        }
        for sessionId in effects.clearExtensionSurfaceSessionIds {
            clearExtensionSurface(for: sessionId)
        }
        for sessionId in effects.clearExtensionNotifyChipSessionIds {
            extensionNotifyChipStore.dismiss(sessionId: sessionId)
        }
        for sessionId in effects.clearMessageQueueSessionIds {
            messageQueueStore.clear(sessionId: sessionId)
        }
    }

    // MARK: - Extension Surface

    /// Session-stream frames own editor text and persistent surfaces; the server
    /// replays the surfaces on subscribe. Notify chips come only from app events.
    func applyExtensionUINotification(
        _ notification: ExtensionUINotification,
        sessionId: String,
        isActiveSession: Bool
    ) {
        switch notification.method {
        case "set_editor_text":
            guard isActiveSession, let text = notification.text else { return }
            chatState.stageExtensionEditorText(text: text, sessionId: sessionId)

        case "setStatus",
             "setWidget",
             "setTitle",
             "setWorkingMessage",
             "setWorkingVisible",
             "setWorkingIndicator",
             "setHiddenThinkingLabel",
             "setToolsExpanded":
            extensionSurfaces.apply(notification, sessionId: sessionId)

        default:
            return
        }
    }

    /// App-event notifications are notify chips for any session. The server
    /// keeps surface and editor methods on the session stream, so an older
    /// server's copies here are ignored rather than applied twice.
    func applyAppEventExtensionNotification(_ notification: ExtensionUINotification, sessionId: String) {
        switch notification.method {
        case "set_editor_text",
             "setStatus",
             "setWidget",
             "setTitle",
             "setWorkingMessage",
             "setWorkingVisible",
             "setWorkingIndicator",
             "setHiddenThinkingLabel",
             "setToolsExpanded":
            return

        case "notify":
            applyNotifyChip(
                message: notification.message,
                notifyType: notification.notifyType,
                displayName: notification.extensionDisplayName,
                sessionId: sessionId
            )

        default:
            applyNotifyChip(
                message: notification.message ?? notification.notifyType,
                notifyType: notification.notifyType,
                displayName: notification.extensionDisplayName,
                sessionId: sessionId
            )
        }
    }

    private func applyNotifyChip(
        message: String?,
        notifyType: String?,
        displayName: String?,
        sessionId: String
    ) {
        extensionNotifyChipStore.apply(
            message: message,
            notifyType: notifyType,
            displayName: displayName,
            sessionId: sessionId
        )
    }

    func clearExtensionSurface(for sessionId: String) {
        extensionSurfaces.clear(sessionId: sessionId)
        clearExtensionDialog(for: sessionId)
    }

    // MARK: - Connected / State

    func handleConnected(_ session: Session) {
        // Display versions are scoped to the backend instance. A fresh
        // stream bootstrap may follow a server/backend restart at version 1.
        messageQueueStore.clear(sessionId: session.id)
        sessionStore.upsert(session)
        sessionUsageMetrics.reportIfNeeded(session)
        syncThinkingLevel(from: session)
        scheduleSlashCommandsRefresh(for: session, force: true)
        syncLiveActivityState()
        prefetchModelsIfNeeded()
    }

    /// Handle active-session UI state updates from `.state` messages.
    ///
    /// `previousWorkspaceId` must come from pre-update session context captured
    /// before `applySharedStoreUpdate` upserts the session into the store.
    func handleState(_ session: Session, previousWorkspaceId: String? = nil) {
        // Active-session-only: thinking level, slash commands.
        guard isFocusedSession(session.id) else { return }

        syncThinkingLevel(from: session)
        if previousWorkspaceId != session.workspaceId {
            scheduleSlashCommandsRefresh(for: session, force: true)
        }
    }

    // MARK: - Stop Lifecycle

    func updateStopStatus(
        _ sessionId: String,
        status: SessionStatus,
        onlyFrom: SessionStatus? = nil
    ) {
        guard var current = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return }
        if let onlyFrom, current.status != onlyFrom { return }
        current.status = status
        if status == .ready || status == .stopped || status == .error {
            current.currentTurnStartedAt = nil
        }
        current.lastActivity = Date()
        sessionStore.upsert(current)
    }

    // MARK: - Command Result Routing

    /// Handle command result: resolve waiters, sync UI state, and return
    /// whether the event should be forwarded to the per-session timeline.
    ///
    /// Returns `true` if the command was consumed internally (not a timeline event).
    func handleCommandResult(
        command: String,
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) -> Bool {
        // Prompt/steer/follow-up acceptance acks are local send-path control
        // messages, not timeline events. Their waiters resolve at the stream
        // boundary before this semantic handler runs.
        if command == "prompt" || command == "steer" || command == "follow_up" {
            return true
        }

        if command == "get_queue" || command == "remove_queued_message" {
            let effects = ServerMessageEffects.queueEffectsForCommandResult(
                command: command,
                success: success,
                data: data
            )
            if success, !effects.isEmpty {
                applyQueueEffects(effects, sessionId: sessionId)
            } else if success, data != nil {
                logger.warning("Failed to decode queue command_result for \(command, privacy: .public)")
            }
            return true
        }

        if command == "get_commands" {
            handleSlashCommandsResult(
                requestId: requestId,
                success: success,
                data: data,
                error: error,
                sessionId: sessionId
            )
            return true
        }

        syncThinkingLevelFromCommand(command: command, success: success, data: data)

        // Boundary-correlated command results are control-plane responses. They
        // have already resolved their waiter; keep them out of the timeline.
        if requestId != nil {
            return true
        }

        // Uncorrelated command results may still be useful as timeline/debug
        // events, so let the caller forward them to the per-session coalescer.
        return false
    }

    func syncThinkingLevelFromCommand(command: String, success: Bool, data: JSONValue?) {
        guard success, command == "cycle_thinking_level" || command == "set_thinking_level" else {
            return
        }

        if let levelStr = data?.objectValue?["level"]?.stringValue,
           let level = ThinkingLevel(rawValue: levelStr) {
            chatState.thinkingLevel = level
        } else if command == "cycle_thinking_level" {
            // Server didn't return data — cycle locally
            chatState.thinkingLevel = chatState.thinkingLevel.next
        }
    }

    // MARK: - Live Activity Sync

    func syncLiveActivityState() {
        guard let currentServerId else { return }
        LiveActivityManager.shared.sync(connectionId: currentServerId, sessions: sessionStore.sessions)
    }

    // MARK: - Model Cache

    func prefetchModelsIfNeeded() {
        guard !chatState.modelsCacheReady else { return }
        chatState.modelPrefetchTask?.cancel()
        chatState.modelPrefetchTask = Task { @MainActor [weak self] in
            guard let self, let api = self.apiClient else { return }
            do {
                let models = try await api.listModels()
                self.chatState.cachedModels = models
                self.chatState.modelsCacheReady = true
            } catch {
                logger.warning("Model prefetch failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Surface capabilities

extension ServerConnection {
    /// Declare what this build draws on the session socket that just opened.
    ///
    /// This is the earliest moment the socket can carry a frame. `server/src/stream.ts` holds a
    /// `client_capabilities` that arrives before the subscribe replay and applies it first, so a
    /// bootstrap that outlasts a round trip replays the session's surfaces already in the shape
    /// this screen draws. A declaration that lands after the replay still takes: the server sends
    /// the clears for the projections it already sent, so the end state matches either order.
    /// Every socket open declares again — first connect, reconnect, and a switch to another
    /// focused session — because the server keeps one declaration per socket. Fire-and-forget:
    /// the frames are the answer, and the subscribe never waits on one.
    ///
    /// Only a server advertising the same capability is told. A build predating the v2 stack does
    /// not know this command and answers it with an error frame on the session stream.
    ///
    /// Every capability this build can draw is declared, but only the ones the server lists: a
    /// server that does not name `blocks` would answer a surface in that shape with the v1
    /// projection anyway, and naming it would only invite a frame this build reads as unreadable.
    func declareStreamSurfaceCapabilities() {
        guard let sessionId = focusedStreamBinder.boundSessionId,
              let advertised = serverCapabilities?.extensionNativeUI?.capabilities,
              advertised.contains(ClientCapability.extensionNativeUIComposites) else { return }
        let capabilities = Self.surfaceCapabilities(advertisedBy: advertised)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sender.dispatchSend(
                    .clientCapabilities(capabilities: capabilities),
                    sessionIdOverride: sessionId
                )
            } catch {
                var metadata = ClientLog.networkErrorMetadata(error)
                metadata["sessionId"] = String(sessionId.prefix(8))
                ClientLog.warning("Stream", "Surface capability declaration failed", metadata: metadata)
            }
        }
    }

    /// What this build draws, in the order the server wants it named: the closed composites on
    /// every v2 socket, the block trees beside them when the server lists that capability too, and
    /// each node kind added since blocks that the server lists.
    static func surfaceCapabilities(advertisedBy advertised: [String]) -> [String] {
        var capabilities = [ClientCapability.extensionNativeUIComposites]
        guard advertised.contains(ClientCapability.extensionNativeUIBlocks) else { return capabilities }
        capabilities.append(ClientCapability.extensionNativeUIBlocks)
        if advertised.contains(ClientCapability.extensionNativeUIElapsed) {
            capabilities.append(ClientCapability.extensionNativeUIElapsed)
        }
        return capabilities
    }
}
