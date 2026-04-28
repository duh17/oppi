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
        guard sessionId == activeSessionId else { return }

        switch message {
        case .connected(let session):
            handleConnected(session)

        case .state(let session):
            handleState(session, previousWorkspaceId: storeResult.previousWorkspaceId)
            if session.status.isTerminal {
                silenceWatchdog.stop()
                clearAskState(for: sessionId)
                clearExtensionDialog(for: sessionId)
            }

        case .queueState(let queue):
            messageQueueStore.apply(queue, for: sessionId)

        case .queueItemStarted(let kind, let item, let queueVersion):
            messageQueueStore.applyQueueItemStarted(
                for: sessionId,
                kind: kind,
                item: item,
                queueVersion: queueVersion
            )

        case .extensionUIRequest(let request):
            if let ask = askRequest(from: request) {
                presentAskRequest(ask, for: sessionId)
            } else {
                presentExtensionDialog(request, for: sessionId)
            }

        case .extensionUINotification(let notification):
            applyExtensionUINotification(
                method: notification.method,
                message: notification.message,
                notifyType: notification.notifyType,
                statusKey: notification.statusKey,
                statusText: notification.statusText,
                title: notification.title,
                text: notification.text,
                widgetKey: notification.widgetKey,
                widgetLines: notification.widgetLines,
                widgetPlacement: notification.widgetPlacement,
                sessionId: sessionId,
                isActiveSession: true
            )

        case .turnAck(let command, let clientTurnId, let stage, let requestId, _):
            _ = commands.resolveTurnAck(command: command, clientTurnId: clientTurnId, stage: stage, requestId: requestId, requiredStage: MessageSender.turnSendRequiredStage)

        case .gitStatus(let workspaceId, let status):
            gitStatusStore.handleGitStatusPush(workspaceId: workspaceId, status: status)
            fileIndexStore.invalidate()
            Task { await FileBrowserCache.shared.invalidateDirectoryListings(for: workspaceId) }

        case .agentStart:
            silenceWatchdog.start()

        case .agentEnd:
            silenceWatchdog.stop()

        case .textDelta, .thinkingDelta, .toolStart, .toolOutput, .toolEnd:
            silenceWatchdog.recordEvent()

        case .error(_, _, _):
            break

        case .sessionEnded:
            silenceWatchdog.stop()
            clearAskState(for: sessionId)
            messageQueueStore.clear(sessionId: sessionId)
            clearExtensionSurface(for: sessionId)

        case .sessionDeleted(let deletedId):
            messageQueueStore.clear(sessionId: deletedId)
            clearExtensionSurface(for: deletedId)

        case .stopConfirmed:
            silenceWatchdog.stop()
            clearAskState(for: sessionId)

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
        case .extensionUIRequest(let request):
            if let ask = askRequest(from: request) {
                stashPendingAskRequest(ask, for: sessionId)
            } else {
                stashPendingExtensionDialog(request, for: sessionId)
            }

        case .extensionUINotification(let notification):
            applyExtensionUINotification(
                method: notification.method,
                message: notification.message,
                notifyType: notification.notifyType,
                statusKey: notification.statusKey,
                statusText: notification.statusText,
                title: notification.title,
                text: notification.text,
                widgetKey: notification.widgetKey,
                widgetLines: notification.widgetLines,
                widgetPlacement: notification.widgetPlacement,
                sessionId: sessionId,
                isActiveSession: false
            )

        case .state(let session):
            if session.status.isTerminal {
                clearAskState(for: sessionId)
                clearExtensionDialog(for: sessionId)
            }

        case .sessionEnded:
            clearAskState(for: sessionId)
            clearExtensionSurface(for: sessionId)

        case .stopConfirmed:
            clearAskState(for: sessionId)

        case .sessionDeleted(let deletedId):
            clearAskState(for: deletedId)
            clearExtensionSurface(for: deletedId)

        default:
            break
        }
    }

    // MARK: - Extension Surface

    func applyExtensionUINotification(
        method: String,
        message: String?,
        notifyType: String?,
        statusKey: String?,
        statusText: String?,
        title: String?,
        text: String?,
        widgetKey: String?,
        widgetLines: [String]?,
        widgetPlacement: String?,
        sessionId: String,
        isActiveSession: Bool
    ) {
        switch method {
        case "notify":
            if isActiveSession {
                extensionToast = message
            }

        case "setStatus":
            guard let statusKey else { return }
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            let normalized = statusText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                surface.statuses[statusKey] = normalized
            } else {
                surface.statuses.removeValue(forKey: statusKey)
            }
            storeExtensionSurface(surface, for: sessionId)

        case "setWidget":
            guard let widgetKey else { return }
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            if let widgetLines {
                let normalizedLines = widgetLines
                    .map { $0.trimmingCharacters(in: .newlines) }
                    .filter { !$0.isEmpty }
                if normalizedLines.isEmpty {
                    surface.widgets.removeValue(forKey: widgetKey)
                } else {
                    surface.widgets[widgetKey] = ExtensionWidgetState(
                        key: widgetKey,
                        lines: normalizedLines,
                        placement: widgetPlacement
                    )
                }
            } else {
                surface.widgets.removeValue(forKey: widgetKey)
            }
            storeExtensionSurface(surface, for: sessionId)

        case "setTitle":
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            surface.title = (normalized?.isEmpty == false) ? normalized : nil
            storeExtensionSurface(surface, for: sessionId)

        case "set_editor_text":
            guard isActiveSession,
                  let text else { return }
            chatState.stageExtensionEditorText(text: text, sessionId: sessionId)

        default:
            if isActiveSession {
                extensionToast = message ?? notifyType
            }
        }
    }

    func storeExtensionSurface(_ surface: ExtensionSurfaceState, for sessionId: String) {
        if surface.hasVisibleContent {
            extensionSurfaceBySession[sessionId] = surface
        } else {
            extensionSurfaceBySession.removeValue(forKey: sessionId)
        }
    }

    func clearExtensionSurface(for sessionId: String) {
        extensionSurfaceBySession.removeValue(forKey: sessionId)
        clearExtensionDialog(for: sessionId)
    }

    // MARK: - Connected / State

    func handleConnected(_ session: Session) {
        sessionStore.upsert(session)
        emitSessionUsageMetricsIfNeeded(session)
        syncThinkingLevel(from: session)
        scheduleSlashCommandsRefresh(for: session, force: true)
        syncLiveActivityPermissions()
        prefetchModelsIfNeeded()
    }

    /// Handle active-session UI state updates from `.state` messages.
    ///
    /// `previousWorkspaceId` must come from pre-update session context captured
    /// before `applySharedStoreUpdate` upserts the session into the store.
    func handleState(_ session: Session, previousWorkspaceId: String? = nil) {
        // Active-session-only: thinking level, slash commands.
        // Skip for child sessions whose state arrives via the parent's broadcast key —
        // they should not overwrite the active session's UI state.
        guard session.id == activeSessionId else { return }

        syncThinkingLevel(from: session)
        if previousWorkspaceId != session.workspaceId {
            scheduleSlashCommandsRefresh(for: session, force: true)
        }
    }

    func emitSessionUsageMetricsIfNeeded(_ session: Session) {
        let snapshot = sessionUsageMetricSnapshot(from: session)
        if sessionUsageMetricSnapshots[session.id] == snapshot {
            return
        }
        sessionUsageMetricSnapshots[session.id] = snapshot

        let sessionId = session.id
        let workspaceId = session.workspaceId
        let tags: [String: String] = [
            "provider": snapshot.provider,
            "model": snapshot.model,
        ]

        let samples: [(ChatMetricName, Double)] = [
            (.sessionMessageCount, Double(snapshot.messageCount)),
            (.sessionInputTokens, Double(snapshot.inputTokens)),
            (.sessionOutputTokens, Double(snapshot.outputTokens)),
            (.sessionMutatingToolCalls, Double(snapshot.mutatingToolCalls)),
            (.sessionFilesChanged, Double(snapshot.filesChanged)),
            (.sessionAddedLines, Double(snapshot.addedLines)),
            (.sessionRemovedLines, Double(snapshot.removedLines)),
            (.sessionContextTokens, Double(snapshot.contextTokens)),
            (.sessionContextWindow, Double(snapshot.contextWindow)),
        ]

        Task.detached(priority: .utility) {
            for (metric, value) in samples {
                await ChatMetricsService.shared.record(
                    metric: metric,
                    value: value,
                    unit: .count,
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    tags: tags
                )
            }
        }
    }

    func sessionUsageMetricSnapshot(from session: Session) -> SessionUsageMetricSnapshot {
        let (provider, model) = parseModelTags(session.model)
        let inputTokens = max(0, session.tokens.input)
        let outputTokens = max(0, session.tokens.output)
        let mutatingToolCalls = max(0, session.changeStats?.mutatingToolCalls ?? 0)
        let filesChanged = max(0, session.changeStats?.filesChanged ?? 0)
        let addedLines = max(0, session.changeStats?.addedLines ?? 0)
        let removedLines = max(0, session.changeStats?.removedLines ?? 0)
        let contextTokens = max(0, session.contextTokens ?? 0)
        let contextWindow = max(0, session.contextWindow ?? 0)

        return SessionUsageMetricSnapshot(
            provider: provider,
            model: model,
            messageCount: max(0, session.messageCount),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens + outputTokens,
            mutatingToolCalls: mutatingToolCalls,
            filesChanged: filesChanged,
            addedLines: addedLines,
            removedLines: removedLines,
            contextTokens: contextTokens,
            contextWindow: contextWindow
        )
    }

    func parseModelTags(_ rawModel: String?) -> (provider: String, model: String) {
        guard let rawModel,
              !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("unknown", "unknown")
        }

        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let provider = String(parts[0]).isEmpty ? "unknown" : String(parts[0])
            let model = String(parts[1]).isEmpty ? "unknown" : String(parts[1])
            return (provider, model)
        }

        return ("unknown", trimmed)
    }

    func decodeQueueStateFromCommandData(_ data: JSONValue?) -> MessageQueueState? {
        guard let data else { return nil }

        do {
            let encoded = try JSONEncoder().encode(data)
            return try JSONDecoder().decode(MessageQueueState.self, from: encoded)
        } catch {
            logger.warning("Failed to decode queue command_result: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Stop Lifecycle

    /// Returns true if the message is a stop lifecycle event.
    /// Timeline effects (system events, coalescer agentEnd) are now handled
    /// by ChatSessionManager.routeToTimeline(). This only checks the type.
    func isStopLifecycleMessage(_ message: ServerMessage) -> Bool {
        switch message {
        case .stopRequested, .stopConfirmed, .stopFailed:
            return true
        default:
            return false
        }
    }

    func updateStopStatus(
        _ sessionId: String,
        status: SessionStatus,
        onlyFrom: SessionStatus? = nil
    ) {
        guard var current = sessionStore.sessions.first(where: { $0.id == sessionId }) else { return }
        if let onlyFrom, current.status != onlyFrom { return }
        current.status = status
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

        if command == "get_queue" || command == "set_queue" {
            if success, let queue = decodeQueueStateFromCommandData(data) {
                messageQueueStore.apply(queue, for: sessionId)
            }
            return true
        }

        if command == "subscribe" || command == "unsubscribe" {
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

    func handleLiveActivityFlush(_ events: [AgentEvent]) {
        guard ReleaseFeatures.liveActivitiesEnabled else {
            return
        }

        let relevantEvents = liveActivityRelevantEvents(from: events)
        guard !relevantEvents.isEmpty else {
            return
        }

        for event in relevantEvents {
            LiveActivityManager.shared.recordEvent(
                connectionId: liveActivityConnectionId,
                event: event
            )
        }

        syncLiveActivityState()
    }

    func liveActivityRelevantEvents(from events: [AgentEvent]) -> [AgentEvent] {
        events.filter(isLiveActivityRelevant)
    }

    func isLiveActivityRelevant(_ event: AgentEvent) -> Bool {
        switch event {
        case .agentStart,
             .agentEnd,
             .toolStart,
             .toolEnd,
             .permissionRequest,
             .sessionEnded:
            return true
        case .error(_, let message):
            return !message.hasPrefix("Retrying (")
        case .textDelta,
             .thinkingDelta,
             .messageEnd,
             .toolOutput,
             .compactionStart,
             .compactionEnd,
             .retryStart,
             .retryEnd,
             .commandResult,
             .permissionExpired:
            return false
        }
    }

    func syncLiveActivityPermissions() {
        syncNotificationSubscriptions()
        syncLiveActivityState()
    }

    func syncLiveActivityState() {
        guard ReleaseFeatures.liveActivitiesEnabled else {
            return
        }

        LiveActivityManager.shared.sync(
            connectionId: liveActivityConnectionId,
            sessions: sessionStore.sessions,
            pendingPermissions: permissionStore.pending
        )
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

    /// Force refresh the model cache (e.g. pull-to-refresh in picker).
    func refreshModelCache() async {
        guard let api = apiClient else { return }
        await chatState.refreshModelCache(api: api)
    }

    // periphery:ignore - API surface for model cache management
    /// Invalidate the model cache so next connect re-fetches.
    func invalidateModelCache() {
        chatState.resetModelCache()
    }

    // MARK: - Extension Timeout

    /// Auto-dismiss extension dialog after its timeout expires.
    /// The server has already given up waiting — we just clean up the UI.
    func scheduleExtensionTimeout(_ request: ExtensionUIRequest) {
        let remainingMs: Int
        if let timeoutAt = request.timeoutAt {
            remainingMs = max(0, Int(timeoutAt.timeIntervalSinceNow * 1000))
        } else if let timeout = request.timeout, timeout > 0 {
            remainingMs = timeout
        } else {
            return
        }
        guard remainingMs > 0 else {
            activeExtensionDialog = nil
            extensionToast = "Extension request timed out"
            return
        }
        extensionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(remainingMs))
            guard !Task.isCancelled else { return }
            guard let self, self.activeExtensionDialog?.id == request.id else { return }
            self.activeExtensionDialog = nil
            self.extensionToast = "Extension request timed out"
        }
    }

}
