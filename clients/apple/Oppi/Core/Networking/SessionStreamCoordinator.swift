import Foundation
import OSLog

private let streamCoordinatorLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "SessionStreamCoordinator"
)

@MainActor
final class SessionStreamCoordinator {
    typealias StreamState = SessionStreamState
    typealias QueueSyncPhase = SessionStreamQueueSyncPhase
    typealias CatchUpDecision = SessionStreamCatchUpTracker.CatchUpDecision

    private enum StateKind: String {
        case idle
        case connectingTransport
        case queueSync
        case streaming
        case resubscribing
    }

    private enum Event: String {
        case beginSession
        case transportReady
        case queueSyncStarted
        case queueSyncFinished
        case streamConnected
        case disconnected
    }

    private static let transitionTable: [StateKind: Set<Event>] = [
        .idle: [.beginSession, .disconnected],
        .connectingTransport: [.transportReady, .streamConnected, .disconnected],
        .queueSync: [.queueSyncStarted, .queueSyncFinished, .disconnected],
        .streaming: [.beginSession, .streamConnected, .disconnected],
        .resubscribing: [.queueSyncFinished, .streamConnected, .disconnected],
    ]

    private(set) var state: StreamState = .idle
    private var catchUpTracker = SessionStreamCatchUpTracker()
    private var activeWorkspaceId: String?
    private var nextContinuationGeneration: UInt64 = 0
    private var continuationGenerationBySession: [String: UInt64] = [:]

    func hasFullSubscription(sessionId: String) -> Bool {
        switch state {
        case .queueSync(let activeSessionId, _), .streaming(let activeSessionId), .resubscribing(let activeSessionId):
            return activeSessionId == sessionId
        case .idle, .connectingTransport:
            return false
        }
    }

    // MARK: - Session lifecycle

    func streamSession(
        connection: ServerConnection,
        sessionId: String,
        workspaceId: String
    ) async -> AsyncStream<SessionStreamEvent>? {
        await streamSession(
            connection: connection,
            sessionId: sessionId,
            routeScope: .workspace(workspaceId)
        )
    }

    func streamSession(
        connection: ServerConnection,
        sessionId: String,
        routeScope: SessionRouteScope
    ) async -> AsyncStream<SessionStreamEvent>? {
        guard connection.wsClient != nil else { return nil }
        guard connection.focusedSessionStreamEndpointKind == "split_session" else {
            streamCoordinatorLogger.error("Split session stream unavailable for \(sessionId, privacy: .public)")
            return nil
        }

        activeWorkspaceId = routeScope.workspaceId
        transition(to: .connectingTransport(sessionId: sessionId), event: .beginSession)
        let streamStart = ContinuousClock.now

        connection.focusSession(sessionId)
        // Keep an explicit level from the session/list snapshot while the bound
        // stream is opening. The medium value remains the fallback for sessions
        // without a server-reported thinking level, but must not clobber max.
        if let storedLevel = connection.sessionStore.sessions
            .first(where: { $0.id == sessionId })?
            .thinkingLevel,
           let level = ThinkingLevel(rawValue: storedLevel) {
            connection.chatState.thinkingLevel = level
        } else {
            connection.chatState.thinkingLevel = .medium
        }

        nextContinuationGeneration &+= 1
        let continuationGeneration = nextContinuationGeneration
        continuationGenerationBySession[sessionId] = continuationGeneration

        let perSessionStream = AsyncStream<SessionStreamEvent> { continuation in
            connection.attachSessionEventContinuation(sessionId, continuation)

            continuation.onTermination = { [weak self, weak connection] _ in
                Task { @MainActor in
                    guard let self,
                          self.continuationGenerationBySession[sessionId] == continuationGeneration else {
                        return
                    }
                    self.continuationGenerationBySession.removeValue(forKey: sessionId)
                    connection?.sessionEventContinuations.removeValue(forKey: sessionId)
                }
            }
        }

        let wsStatus = connection.wsClient?.status
        let transport = connection.transportPath.rawValue
        connection.connectStream()

        let streamOpenStart = ContinuousClock.now
        let statusBeforeWait = statusTag(connection.wsClient?.status)
        let waitOutcome: String
        if connection.wsClient?.status == .connected {
            waitOutcome = "already_connected"
        } else if await connection.waitForConnectedStream(timeout: .seconds(10)) {
            waitOutcome = "connected"
        } else {
            waitOutcome = "timeout"
        }

        if connection.focusedSessionStreamEndpointIsUnsupported() {
            connection.disableSplitStreamsForUnsupportedEndpoint()
            return nil
        }

        let streamOpenMs = Int((ContinuousClock.now - streamOpenStart) / .milliseconds(1))
        recordMetric(
            .wsWaitForConnectedMs,
            value: streamOpenMs,
            sessionId: sessionId,
            tags: [
                "transport": transport,
                "status_before": statusBeforeWait,
                "outcome": waitOutcome,
            ]
        )

        guard waitOutcome != "timeout", !Task.isCancelled else {
            streamCoordinatorLogger.warning(
                "streamSession(\(sessionId, privacy: .public)): transport not connected; deferring queue sync until stream_connected"
            )
            return perSessionStream
        }

        transition(to: .queueSync(sessionId: sessionId, phase: .initial), event: .transportReady)

        scheduleQueueSync(connection: connection, sessionId: sessionId, transport: transport)

        let totalMs = Int((ContinuousClock.now - streamStart) / .milliseconds(1))
        let endpointHostKind = connection.streamEndpointHostKindForMetrics()
        streamCoordinatorLogger.info(
            "streamSession(\(sessionId, privacy: .public)): wsStatus=\(String(describing: wsStatus), privacy: .public) streamOpen=\(streamOpenMs)ms total=\(totalMs)ms transport=\(transport, privacy: .public) hostKind=\(endpointHostKind, privacy: .public)"
        )

        ClientLog.info("StreamSession", "\(sessionId.prefix(8))", metadata: [
            "wsStatus": String(describing: wsStatus),
            "streamOpenMs": String(streamOpenMs),
            "queueSyncMs": "0",
            "queueSyncStatus": "async",
            "totalMs": String(totalMs),
            "transport": transport,
            "streamEndpoint": connection.focusedSessionStreamEndpointKind,
            "endpointHostKind": endpointHostKind,
            "connectMs": String(streamOpenMs),
        ])

        return perSessionStream
    }

    func handleStreamReconnected(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }
        connection.cancelDeferredQueueSync()

        guard connection.focusedSessionStreamEndpointKind == "split_session",
              let focusedSessionId = connection.focusedSessionId else { return }

        transition(to: .resubscribing(sessionId: focusedSessionId), event: .streamConnected)
        scheduleQueueSync(
            connection: connection,
            sessionId: focusedSessionId,
            transport: connection.transportPath.rawValue
        )
    }

    func noteStreamDisconnected() {
        transition(to: .idle, event: .disconnected)
    }

    // MARK: - Catch-up state

    func seedLastSeenSeq(sessionId: String, value: Int) {
        catchUpTracker.seedLastSeenSeq(sessionId: sessionId, value: value)
    }

    func lastSeenSeq(sessionId: String) -> Int {
        catchUpTracker.lastSeenSeq(sessionId: sessionId)
    }

    func consumeLiveSeq(sessionId: String, seq: Int) -> Bool {
        catchUpTracker.consumeLiveSeq(sessionId: sessionId, seq: seq)
    }

    func catchUpDecision(sessionId: String, currentSeq: Int) -> CatchUpDecision {
        catchUpTracker.catchUpDecision(sessionId: sessionId, currentSeq: currentSeq)
    }

    func applyCatchUpProgress(sessionId: String, seq: Int) {
        catchUpTracker.applyCatchUpProgress(sessionId: sessionId, seq: seq)
    }

    // MARK: - Queue sync

    private func scheduleQueueSync(
        connection: ServerConnection,
        sessionId: String,
        transport: String
    ) {
        connection.cancelDeferredQueueSync()

        connection.deferredQueueSyncTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard !Task.isCancelled,
                  connection.isFocusedSession(sessionId) else {
                return
            }

            self.transition(to: .queueSync(sessionId: sessionId, phase: .initial), event: .queueSyncStarted)

            let initialSucceeded = await self.performQueueSyncAttempt(
                connection: connection,
                sessionId: sessionId,
                transport: transport,
                timeout: ServerConnection.initialQueueSyncTimeout,
                phase: .initial
            )

            guard !initialSucceeded else {
                self.transition(to: .streaming(sessionId: sessionId), event: .queueSyncFinished)
                return
            }

            try? await Task.sleep(for: ServerConnection.deferredQueueSyncDelay)
            guard !Task.isCancelled,
                  connection.isFocusedSession(sessionId) else {
                return
            }

            self.transition(to: .queueSync(sessionId: sessionId, phase: .retry), event: .queueSyncStarted)
            _ = await self.performQueueSyncAttempt(
                connection: connection,
                sessionId: sessionId,
                transport: transport,
                timeout: ServerConnection.deferredQueueSyncTimeout,
                phase: .retry
            )
            self.transition(to: .streaming(sessionId: sessionId), event: .queueSyncFinished)
        }
    }

    private func performQueueSyncAttempt(
        connection: ServerConnection,
        sessionId: String,
        transport: String,
        timeout: Duration,
        phase: QueueSyncPhase
    ) async -> Bool {
        let queueSyncStart = ContinuousClock.now
        var queueSyncStatus = "ok"
        var queueSyncErrorKind: String?

        do {
            try await connection.requestMessageQueue(timeout: timeout)
        } catch {
            queueSyncStatus = "error"
            queueSyncErrorKind = connection.telemetryErrorKind(from: error)
            let phaseLabel = phase == .initial ? "Initial" : "Deferred"
            streamCoordinatorLogger.debug(
                "\(phaseLabel, privacy: .public) queue refresh failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        let queueSyncMs = Int((ContinuousClock.now - queueSyncStart) / .milliseconds(1))
        let metricStatus = queueSyncStatus
        let metricErrorKind = queueSyncErrorKind
        let metricPhase = phase.rawValue
        let metricTransport = transport
        let metricSessionId = sessionId

        Task.detached(priority: .utility) {
            var tags: [String: String] = [
                "transport": metricTransport,
                "status": metricStatus,
                "phase": metricPhase,
            ]
            if let metricErrorKind {
                tags["error_kind"] = metricErrorKind
            }
            await ChatMetricsService.shared.record(
                metric: .queueSyncMs,
                value: Double(queueSyncMs),
                unit: .ms,
                sessionId: metricSessionId,
                tags: tags
            )
        }

        return metricStatus == "ok"
    }

    private func recordMetric(
        _ metric: ChatMetricName,
        value: Int,
        unit: ChatMetricUnit = .ms,
        sessionId: String?,
        tags: [String: String]
    ) {
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: metric,
                value: Double(value),
                unit: unit,
                sessionId: sessionId,
                tags: tags
            )
        }
    }

    private func statusTag(_ status: WebSocketClient.Status?) -> String {
        switch status {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        case .reconnecting: "reconnecting"
        case nil: "none"
        }
    }

    // MARK: - State machine

    private func transition(to newState: StreamState, event: Event) {
        let currentKind = kind(of: state)
        if !Self.transitionTable[currentKind, default: []].contains(event) {
            streamCoordinatorLogger.warning(
                "Unexpected stream transition \(currentKind.rawValue, privacy: .public) --\(event.rawValue, privacy: .public)--> \(self.kind(of: newState).rawValue, privacy: .public)"
            )
        }
        state = newState
        persistCrashContext(for: newState)
    }

    private func persistCrashContext(for state: StreamState) {
        switch state {
        case .idle:
            MetricKitCrashContextStore.record(
                sessionId: nil,
                workspaceId: activeWorkspaceId,
                streamState: StateKind.idle.rawValue
            )
        case .connectingTransport(let sessionId):
            MetricKitCrashContextStore.record(
                sessionId: sessionId,
                workspaceId: activeWorkspaceId,
                streamState: StateKind.connectingTransport.rawValue
            )
        case .queueSync(let sessionId, let phase):
            MetricKitCrashContextStore.record(
                sessionId: sessionId,
                workspaceId: activeWorkspaceId,
                streamState: "\(StateKind.queueSync.rawValue).\(phase.rawValue)"
            )
        case .streaming(let sessionId):
            MetricKitCrashContextStore.record(
                sessionId: sessionId,
                workspaceId: activeWorkspaceId,
                streamState: StateKind.streaming.rawValue
            )
        case .resubscribing(let sessionId):
            MetricKitCrashContextStore.record(
                sessionId: sessionId,
                workspaceId: activeWorkspaceId,
                streamState: StateKind.resubscribing.rawValue
            )
        }
    }

    private func kind(of state: StreamState) -> StateKind {
        switch state {
        case .idle: .idle
        case .connectingTransport: .connectingTransport
        case .queueSync: .queueSync
        case .streaming: .streaming
        case .resubscribing: .resubscribing
        }
    }
}
