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
    func handleActiveSessionUI(_ message: ServerMessage, sessionId: String) {
        guard sessionId == activeSessionId else { return }

        switch message {
        case .connected(let session):
            handleConnected(session)

        case .state(let session):
            let prevWsId = sessionStore.sessions.first(where: { $0.id == session.id })?.workspaceId
            handleState(session, previousWorkspaceId: prevWsId)

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
            extensionTimeoutTask?.cancel()
            activeExtensionDialog = request
            scheduleExtensionTimeout(request)

        case .extensionUINotification(_, let message, _, _, _):
            extensionToast = message

        case .turnAck(let command, let clientTurnId, let stage, let requestId, _):
            _ = commands.resolveTurnAck(command: command, clientTurnId: clientTurnId, stage: stage, requestId: requestId, requiredStage: MessageSender.turnSendRequiredStage)

        case .gitStatus(let workspaceId, let status):
            gitStatusStore.handleGitStatusPush(workspaceId: workspaceId, status: status)
            fileIndexStore.invalidate()

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
            messageQueueStore.clear(sessionId: sessionId)

        case .sessionDeleted(let deletedId):
            messageQueueStore.clear(sessionId: deletedId)

        case .stopConfirmed:
            silenceWatchdog.stop()

        default:
            break
        }
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
    /// **Important:** `previousWorkspaceId` must be captured BEFORE
    /// `applySharedStoreUpdate` upserts the session into the store.
    /// The caller passes it in to ensure correct ordering.
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
        guard let object = data?.objectValue,
              let versionNumber = object["version"]?.numberValue,
              let version = Int(exactly: versionNumber) else {
            return nil
        }

        let steering = decodeQueueItems(object["steering"]?.arrayValue)
        let followUp = decodeQueueItems(object["followUp"]?.arrayValue)
        return MessageQueueState(version: version, steering: steering, followUp: followUp)
    }

    private func decodeQueueItems(_ values: [JSONValue]?) -> [MessageQueueItem] {
        guard let values else { return [] }

        return values.compactMap { value in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let message = object["message"]?.stringValue,
                  let createdAtNumber = object["createdAt"]?.numberValue,
                  let createdAt = Int(exactly: createdAtNumber) else {
                return nil
            }

            let images = decodeQueueImages(object["images"]?.arrayValue)
            return MessageQueueItem(id: id, message: message, images: images, createdAt: createdAt)
        }
    }

    private func decodeQueueImages(_ values: [JSONValue]?) -> [ImageAttachment]? {
        guard let values else { return nil }

        let images: [ImageAttachment] = values.compactMap { value in
            guard let object = value.objectValue,
                  let data = object["data"]?.stringValue,
                  let mimeType = object["mimeType"]?.stringValue else {
                return nil
            }
            return ImageAttachment(data: data, mimeType: mimeType)
        }

        return images.isEmpty ? nil : images
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
        // Resolve prompt/steer/follow-up acceptance acks first.
        // These are local send-path control messages, not timeline events.
        if let requestId,
           command == "prompt" || command == "steer" || command == "follow_up",
           commands.resolveTurnCommandResult(command: command, requestId: requestId, success: success, error: error) {
            return true
        }

        if command == "get_queue" || command == "set_queue" {
            if success, let queue = decodeQueueStateFromCommandData(data) {
                messageQueueStore.apply(queue, for: sessionId)
            }
            if let requestId {
                _ = commands.resolveCommandResult(
                    command: command, requestId: requestId,
                    success: success, data: data, error: error
                )
            }
            return true
        }

        if command == "subscribe" || command == "unsubscribe" {
            if let requestId {
                _ = commands.resolveCommandResult(
                    command: command, requestId: requestId,
                    success: success, data: data, error: error
                )
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

        if let requestId,
           commands.resolveCommandResult(
            command: command,
            requestId: requestId,
            success: success,
            data: data,
            error: error
           ) {
            return true
        }

        syncThinkingLevelFromCommand(command: command, success: success, data: data)

        // Not consumed — caller should forward to per-session coalescer.
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
        guard let timeout = request.timeout, timeout > 0 else { return }
        extensionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self, self.activeExtensionDialog?.id == request.id else { return }
            self.activeExtensionDialog = nil
            self.extensionToast = "Extension request timed out"
        }
    }

}
