import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Connection")

// MARK: - Message Router

extension ServerConnection {

    /// Route a ServerMessage to the appropriate store or pipeline.
    /// Ignores messages for non-active sessions (stale stream race).
    func handleServerMessage(_ message: ServerMessage, sessionId: String) {
        guard sessionId == activeSessionId else {
            return
        }

        if handleStopLifecycleMessage(message, sessionId: sessionId) {
            return
        }

        switch message {
        // Stream lifecycle (handled at WebSocket level, not per-session)
        case .streamConnected:
            break

        // Direct state updates (not timeline events)
        case .connected(let session):
            handleConnected(session)

        case .state(let session):
            handleState(session)

        case .queueState(let queue):
            messageQueueStore.apply(queue, for: sessionId)

        case .queueItemStarted(let kind, let item, let queueVersion):
            messageQueueStore.applyQueueItemStarted(
                for: sessionId,
                kind: kind,
                item: item,
                queueVersion: queueVersion
            )
            reducer.appendUserMessage(item.message, images: item.images ?? [])

        case .extensionUIRequest(let request):
            extensionTimeoutTask?.cancel()
            activeExtensionDialog = request
            scheduleExtensionTimeout(request)

        case .extensionUINotification(_, let message, _, _, _):
            extensionToast = message

        case .turnAck(let command, let clientTurnId, let stage, let requestId, _):
            _ = commands.resolveTurnAck(command: command, clientTurnId: clientTurnId, stage: stage, requestId: requestId, requiredStage: Self.turnSendRequiredStage)

        case .gitStatus(let workspaceId, let status):
            gitStatusStore.handleGitStatusPush(workspaceId: workspaceId, status: status)

        case .unknown, .stopRequested, .stopConfirmed, .stopFailed:
            break  // Already logged in WebSocketClient / handled earlier

        // Permission events → store + overlay (NOT inline timeline)
        case .permissionRequest(let perm):
            permissionStore.add(perm)
            // Feed coalescer for Live Activity badge count, but NOT the reducer timeline.
            coalescer.receive(.permissionRequest(perm))
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.notifyIfNeeded(
                    perm,
                    activeSessionId: sessionStore.activeSessionId
                )
            }
            syncLiveActivityPermissions()

        case .permissionExpired(let id, _):
            if let request = permissionStore.take(id: id) {
                reducer.resolvePermission(
                    id: id, outcome: .expired,
                    tool: request.tool, summary: request.displaySummary
                )
            }
            coalescer.receive(.permissionExpired(id: id))
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()

        case .permissionCancelled(let id):
            if let request = permissionStore.take(id: id) {
                reducer.resolvePermission(
                    id: id, outcome: .cancelled,
                    tool: request.tool, summary: request.displaySummary
                )
            }
            if ReleaseFeatures.pushNotificationsEnabled {
                PermissionNotificationService.shared.cancelNotification(permissionId: id)
            }
            syncLiveActivityPermissions()

        // Agent events → pipeline
        case .agentStart:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }), current.status != .stopping {
                current.status = .busy
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            screenAwakeController.setSessionActivity(true, sessionId: sessionId)
            coalescer.receive(.agentStart(sessionId: sessionId))
            silenceWatchdog.start()

        case .agentEnd:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }), current.status == .busy {
                current.status = .ready
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            coalescer.receive(.agentEnd(sessionId: sessionId))
            silenceWatchdog.stop()

        case .messageEnd(let role, let content):
            if role == "assistant" {
                coalescer.receive(.messageEnd(sessionId: sessionId, content: content))
            }

        case .textDelta(let delta):
            silenceWatchdog.recordEvent()
            coalescer.receive(.textDelta(sessionId: sessionId, delta: delta))

        case .thinkingDelta(let delta):
            silenceWatchdog.recordEvent()
            coalescer.receive(.thinkingDelta(sessionId: sessionId, delta: delta))

        case .toolStart(let tool, let args, let toolCallId, let callSegments):
            silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.start(sessionId: sessionId, tool: tool, args: args, toolCallId: toolCallId, callSegments: callSegments))

        case .toolOutput(let output, let isError, let toolCallId):
            silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.output(sessionId: sessionId, output: output, isError: isError, toolCallId: toolCallId))

        case .toolEnd(_, let toolCallId, let details, let isError, let resultSegments):
            silenceWatchdog.recordEvent()
            coalescer.receive(toolCallCorrelator.end(sessionId: sessionId, toolCallId: toolCallId, details: details, isError: isError, resultSegments: resultSegments))

        case .sessionEnded(let reason):
            silenceWatchdog.stop()
            messageQueueStore.clear(sessionId: sessionId)
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))

        case .sessionDeleted(let deletedId):
            messageQueueStore.clear(sessionId: deletedId)
            sessionStore.remove(id: deletedId)
            notificationSessionIds.remove(deletedId)
            sessionUsageMetricSnapshots.removeValue(forKey: deletedId)
            syncLiveActivityPermissions()

        case .error(let msg, let code, let fatal):
            if code == Self.missingFullSubscriptionErrorCode
                // Backward compatibility for older servers that don't emit code yet.
                || (code == nil && msg.contains("is not subscribed at level=full")) {
                triggerFullSubscriptionRecovery(sessionId: sessionId, serverError: msg)
                break
            }

            coalescer.receive(.error(sessionId: sessionId, message: msg))
            // Fatal setup errors (e.g. session limit reached) — stop auto-reconnect.
            // The server closed the WS after this; retrying would just loop.
            fatalSetupError = fatalSetupError || fatal

        // Compaction events → pipeline
        case .compactionStart(let reason):
            coalescer.receive(.compactionStart(sessionId: sessionId, reason: reason))

        case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore):
            coalescer.receive(
                .compactionEnd(
                    sessionId: sessionId,
                    aborted: aborted,
                    willRetry: willRetry,
                    summary: summary,
                    tokensBefore: tokensBefore
                )
            )

        // Retry events → pipeline
        case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage):
            coalescer.receive(.retryStart(sessionId: sessionId, attempt: attempt, maxAttempts: maxAttempts, delayMs: delayMs, errorMessage: errorMessage))

        case .retryEnd(let success, let attempt, let finalError):
            coalescer.receive(.retryEnd(sessionId: sessionId, success: success, attempt: attempt, finalError: finalError))

        // Command results → pipeline (for model changes, stats, etc.)
        case .commandResult(let command, let requestId, let success, let data, let error):
            handleCommandResult(
                command: command,
                requestId: requestId,
                success: success,
                data: data,
                error: error,
                sessionId: sessionId
            )
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

    func handleState(_ session: Session) {
        let previous = sessionStore.sessions.first(where: { $0.id == session.id })
        let previousWorkspaceId = previous?.workspaceId
        let previousStatus = previous?.status

        sessionStore.upsert(session)
        emitSessionUsageMetricsIfNeeded(session)
        syncThinkingLevel(from: session)
        if previousWorkspaceId != session.workspaceId {
            scheduleSlashCommandsRefresh(for: session, force: true)
        }

        // Recovery hardening: if server state says the session is no longer
        // running but we never observed agentEnd/messageEnd (reconnect gap,
        // stop lifecycle path), finalize in-flight timeline artifacts.
        if let previousStatus,
           previousStatus == .busy || previousStatus == .stopping,
           session.status == .ready || session.status == .stopped || session.status == .error {
            screenAwakeController.setSessionActivity(false, sessionId: session.id)
            coalescer.receive(.agentEnd(sessionId: session.id))
            silenceWatchdog.stop()
        }

        syncLiveActivityPermissions()
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
            (.sessionTotalTokens, Double(snapshot.totalTokens)),
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

    func handleStopLifecycleMessage(_ message: ServerMessage, sessionId: String) -> Bool {
        switch message {
        case .stopRequested(_, let reason):
            updateStopStatus(sessionId, status: .stopping)
            reducer.appendSystemEvent(reason ?? "Stopping…")
            return true
        case .stopConfirmed(_, let reason):
            updateStopStatus(sessionId, status: .ready, onlyFrom: .stopping)
            // Match TUI behavior: stop-confirmed without agentEnd should still
            // close any in-flight thinking/tool state.
            screenAwakeController.setSessionActivity(false, sessionId: sessionId)
            coalescer.receive(.agentEnd(sessionId: sessionId))
            silenceWatchdog.stop()
            reducer.appendSystemEvent(reason ?? "Stop confirmed")
            return true
        case .stopFailed(_, let reason):
            updateStopStatus(sessionId, status: .busy, onlyFrom: .stopping)
            reducer.process(.error(sessionId: sessionId, message: "Stop failed: \(reason)"))
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

    func handleCommandResult(
        command: String,
        requestId: String?,
        success: Bool,
        data: JSONValue?,
        error: String?,
        sessionId: String
    ) {
        // Resolve prompt/steer/follow-up acceptance acks first.
        // These are local send-path control messages, not timeline events.
        if let requestId,
           command == "prompt" || command == "steer" || command == "follow_up",
           commands.resolveTurnCommandResult(command: command, requestId: requestId, success: success, error: error) {
            return
        }

        if command == "get_queue" || command == "set_queue" {
            if success, let queue = decodeQueueStateFromCommandData(data) {
                messageQueueStore.apply(queue, for: sessionId)
            }
            // Resolve the pending command waiter (set_queue isn't eagerly
            // resolved, so the waiter may still be waiting).
            if let requestId {
                _ = commands.resolveCommandResult(
                    command: command, requestId: requestId,
                    success: success, data: data, error: error
                )
            }
            // Queue sync is internal plumbing — never surface in the timeline.
            // Failures are already handled by the stream_not_subscribed_full
            // recovery path (triggerFullSubscriptionRecovery).
            return
        }

        if command == "get_commands" {
            handleSlashCommandsResult(
                requestId: requestId,
                success: success,
                data: data,
                error: error,
                sessionId: sessionId
            )
            return
        }

        if let requestId,
           commands.resolveCommandResult(
            command: command,
            requestId: requestId,
            success: success,
            data: data,
            error: error
           ) {
            return
        }

        syncThinkingLevelFromCommand(command: command, success: success, data: data)

        coalescer.receive(
            .commandResult(
                sessionId: sessionId,
                command: command,
                requestId: requestId,
                success: success,
                data: data,
                error: error
            )
        )
    }

    func syncThinkingLevelFromCommand(command: String, success: Bool, data: JSONValue?) {
        guard success, command == "cycle_thinking_level" || command == "set_thinking_level" else {
            return
        }

        if let levelStr = data?.objectValue?["level"]?.stringValue,
           let level = ThinkingLevel(rawValue: levelStr) {
            thinkingLevel = level
        } else if command == "cycle_thinking_level" {
            // Server didn't return data — cycle locally
            thinkingLevel = thinkingLevel.next
        }
    }

    // MARK: - Live Activity Sync

    func syncLiveActivityPermissions() {
        syncNotificationSubscriptions()

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
        guard !modelsCacheReady else { return }
        modelPrefetchTask?.cancel()
        modelPrefetchTask = Task { @MainActor [weak self] in
            guard let self, let api = self.apiClient else { return }
            do {
                let models = try await api.listModels()
                self.cachedModels = models
                self.modelsCacheReady = true
            } catch {
                logger.warning("Model prefetch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Force refresh the model cache (e.g. pull-to-refresh in picker).
    func refreshModelCache() async {
        guard let api = apiClient else { return }
        do {
            cachedModels = try await api.listModels()
            modelsCacheReady = true
        } catch {
            logger.warning("Model cache refresh failed: \(error.localizedDescription)")
        }
    }

    // periphery:ignore - API surface for model cache management
    /// Invalidate the model cache so next connect re-fetches.
    func invalidateModelCache() {
        modelsCacheReady = false
        cachedModels = []
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
