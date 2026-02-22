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
            coalescer.receive(.agentStart(sessionId: sessionId))
            silenceWatchdog.start()

        case .agentEnd:
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }), current.status == .busy {
                current.status = .ready
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
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
            if var current = sessionStore.sessions.first(where: { $0.id == sessionId }) {
                current.status = .stopped
                current.lastActivity = Date()
                sessionStore.upsert(current)
            }
            coalescer.receive(.sessionEnded(sessionId: sessionId, reason: reason))

        case .error(let msg, _, let fatal):
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
        syncThinkingLevel(from: session)
        scheduleSlashCommandsRefresh(for: session, force: true)
        syncLiveActivityPermissions()
        prefetchModelsIfNeeded()
    }

    func handleState(_ session: Session) {
        let previousWorkspaceId = sessionStore.sessions.first(where: { $0.id == session.id })?.workspaceId
        sessionStore.upsert(session)
        syncThinkingLevel(from: session)
        if previousWorkspaceId != session.workspaceId {
            scheduleSlashCommandsRefresh(for: session, force: true)
        }
        syncLiveActivityPermissions()
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
        guard ReleaseFeatures.liveActivitiesEnabled else {
            return
        }

        LiveActivityManager.shared.syncPermissions(
            permissionStore.pending,
            sessions: sessionStore.sessions,
            activeSessionId: sessionStore.activeSessionId
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
