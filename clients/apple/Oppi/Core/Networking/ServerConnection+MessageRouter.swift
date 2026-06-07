import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")
private let terminalOnlyExtensionStatusKeys: Set<String> = ["oppi-mirror"]

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

        case .sessionEnded, .sessionDeleted, .stopConfirmed, .extensionUISettled:
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

        case .state, .sessionSummary, .sessionEnded, .stopConfirmed, .sessionDeleted, .extensionUISettled:
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
                workingIndicator: notification.workingIndicator,
                workingVisible: notification.workingVisible,
                hiddenThinkingLabel: notification.hiddenThinkingLabel,
                toolsExpanded: notification.toolsExpanded,
                nativeSurface: notification.nativeSurface,
                sessionId: sessionId,
                isActiveSession: effects.isFocusedSession
            )
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
        let effects = ServerMessageEffects.cleanupEffects(
            for: message,
            routedSessionId: sessionId,
            isFocusedSession: isFocusedSession
        )
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
        for sessionId in effects.clearMessageQueueSessionIds {
            messageQueueStore.clear(sessionId: sessionId)
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
        workingIndicator: ExtensionUIWorkingIndicator?,
        workingVisible: Bool?,
        hiddenThinkingLabel: String?,
        toolsExpanded: Bool?,
        nativeSurface: ExtensionUINativeSurface?,
        sessionId: String,
        isActiveSession: Bool
    ) {
        switch method {
        case "notify":
            if isActiveSession {
                extensionToast = message
            }

        case "setWorkingMessage":
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            var working = surface.working ?? ExtensionWorkingState()
            let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            working.message = (normalized?.isEmpty == false) ? normalized : nil
            surface.working = working.isDefault ? nil : working
            storeExtensionSurface(surface, for: sessionId)

        case "setWorkingVisible":
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            var working = surface.working ?? ExtensionWorkingState()
            working.visible = workingVisible ?? true
            surface.working = working.isDefault ? nil : working
            storeExtensionSurface(surface, for: sessionId)

        case "setWorkingIndicator":
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            var working = surface.working ?? ExtensionWorkingState()
            working.indicator = workingIndicator
            surface.working = working.isDefault ? nil : working
            storeExtensionSurface(surface, for: sessionId)

        case "setHiddenThinkingLabel":
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            let normalized = hiddenThinkingLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            surface.hiddenThinkingLabel = (normalized?.isEmpty == false) ? normalized : nil
            storeExtensionSurface(surface, for: sessionId)

        case "setToolsExpanded":
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            surface.toolsExpanded = toolsExpanded ?? false
            storeExtensionSurface(surface, for: sessionId)

        case "setStatus":
            guard let statusKey else { return }
            var surface = extensionSurfaceBySession[sessionId] ?? ExtensionSurfaceState()
            if terminalOnlyExtensionStatusKeys.contains(statusKey) {
                surface.statuses.removeValue(forKey: statusKey)
                storeExtensionSurface(surface, for: sessionId)
                return
            }
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
            let nativeSurfaceId = nativeSurface?.id ?? "widget:\(widgetKey)"
            if let nativeSurface, nativeSurface.hasVisibleContent {
                surface.widgets.removeValue(forKey: widgetKey)
                surface.nativeSurfaces[nativeSurface.id] = ExtensionNativeSurfaceState(
                    surface: nativeSurface,
                    placement: widgetPlacement
                )
            } else if let widgetLines {
                surface.nativeSurfaces.removeValue(forKey: nativeSurfaceId)
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
                surface.nativeSurfaces.removeValue(forKey: nativeSurfaceId)
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
        if surface.hasRetainedContent {
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
        syncLiveActivityState()
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
        guard isFocusedSession(session.id) else { return }

        syncThinkingLevel(from: session)
        if previousWorkspaceId != session.workspaceId {
            scheduleSlashCommandsRefresh(for: session, force: true)
        }
    }

    func emitSessionUsageMetricsIfNeeded(_ session: Session) {
        let snapshot = sessionUsageMetricSnapshot(from: session)
        let now = Date()
        guard shouldEmitSessionUsageMetrics(for: session, snapshot: snapshot, now: now) else { return }
        sessionUsageMetricSnapshots[session.id] = snapshot
        sessionUsageMetricLastEmittedAt[session.id] = now

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

    func shouldEmitSessionUsageMetrics(
        for session: Session,
        snapshot: SessionUsageMetricSnapshot,
        now: Date = Date()
    ) -> Bool {
        guard snapshot.hasUsageSignal else { return false }
        guard sessionUsageMetricSnapshots[session.id] != snapshot else { return false }

        if session.status == .stopped || session.status == .error {
            return true
        }

        guard session.status.isTerminal else { return false }
        guard let lastEmittedAt = sessionUsageMetricLastEmittedAt[session.id] else { return true }
        return now.timeIntervalSince(lastEmittedAt) >= Self.sessionUsageMetricMinimumInterval
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

        if command == "get_queue" || command == "set_queue" {
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
             .sessionEnded:
            return true
        case .error(_, let message):
            return !message.hasPrefix("Retrying (")
        case .textDelta,
             .thinkingDelta,
             .messageEnd,
             .toolUpdate,
             .toolOutput,
             .compactionStart,
             .compactionEnd,
             .retryStart,
             .retryEnd,
             .commandResult:
            return false
        }
    }

    func syncLiveActivityState() {
        guard ReleaseFeatures.liveActivitiesEnabled else {
            return
        }

        LiveActivityManager.shared.sync(
            connectionId: liveActivityConnectionId,
            sessions: sessionStore.sessions
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

}
