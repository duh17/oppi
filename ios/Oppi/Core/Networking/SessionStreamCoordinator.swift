import Foundation
import OSLog

private let streamCoordinatorLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "SessionStreamCoordinator"
)

@MainActor
final class SessionStreamCoordinator {
    enum StreamState: Equatable {
        case idle
        case connectingTransport(sessionId: String)
        case awaitingSubscribeAck(sessionId: String)
        case queueSync(sessionId: String, phase: QueueSyncPhase)
        case streaming(sessionId: String)
        case resubscribing(sessionId: String)
    }

    enum QueueSyncPhase: String, Equatable {
        case initial
        case retry
    }

    enum CatchUpDecision: Equatable {
        case noGap
        case fetchSince(Int)
        case seqRegression(resetTo: Int)
    }

    private enum StateKind: String {
        case idle
        case connectingTransport
        case awaitingSubscribeAck
        case queueSync
        case streaming
        case resubscribing
    }

    private enum Event: String {
        case beginSession
        case transportReady
        case subscribeAck
        case queueSyncStarted
        case queueSyncFinished
        case streamConnected
        case disconnected
    }

    private static let transitionTable: [StateKind: Set<Event>] = [
        .idle: [.beginSession, .disconnected],
        .connectingTransport: [.transportReady, .disconnected],
        .awaitingSubscribeAck: [.subscribeAck, .disconnected],
        .queueSync: [.queueSyncStarted, .queueSyncFinished, .disconnected],
        .streaming: [.beginSession, .streamConnected, .disconnected],
        .resubscribing: [.queueSyncFinished, .streamConnected, .disconnected],
    ]

    // nonisolated(unsafe): immutable Set, safe to read from any context.
    nonisolated(unsafe) private static let eagerResolveCommands: Set<String> = ["subscribe", "unsubscribe", "get_queue"]
    /// Maximum notification-level sessions to subscribe after reconnect.
    private static let maxNotificationSubscriptions = 20

    private(set) var state: StreamState = .idle
    private var lastSeenSeqBySession: [String: Int] = [:]
    // MARK: - Command correlation

    nonisolated func shouldResolveEagerly(command: String) -> Bool {
        Self.eagerResolveCommands.contains(command)
    }

    // MARK: - Session lifecycle

    func streamSession(
        connection: ServerConnection,
        sessionId: String,
        workspaceId: String
    ) async -> AsyncStream<ServerMessage>? {
        guard connection.wsClient != nil else { return nil }

        transition(to: .connectingTransport(sessionId: sessionId), event: .beginSession)

        let streamStart = ContinuousClock.now

        // Cancel any pending unsubscribe for the session we're about to subscribe.
        if let pendingUnsub = connection.pendingUnsubscribeTasks.removeValue(forKey: sessionId) {
            pendingUnsub.cancel()
        }

        connection.activeSessionId = sessionId
        connection.sender.activeSessionId = sessionId
        connection.chatState.thinkingLevel = .medium
        Task {
            await SentryService.shared.setSessionContext(sessionId: sessionId, workspaceId: workspaceId)
        }

        let wsStatus = connection.wsClient?.status
        let transport = connection.transportPath.rawValue

        connection.connectStream()

        // Wait for transport to be connected before opening the per-session stream.
        let streamOpenStart = ContinuousClock.now
        if connection.wsClient?.status == .connected {
            // already connected
        } else if await connection.waitForConnectedStream(timeout: .seconds(10)) {
            // connected after wait
        } else {
            // timeout — proceed anyway, subscribe will fail and be handled
        }
        let streamOpenMs = Int((ContinuousClock.now - streamOpenStart) / .milliseconds(1))

        let perSessionStream = AsyncStream<ServerMessage> { continuation in
            connection.sessionContinuations[sessionId] = continuation

            continuation.onTermination = { [weak connection] _ in
                Task { @MainActor in
                    connection?.sessionContinuations.removeValue(forKey: sessionId)
                }
            }
        }

        transition(to: .awaitingSubscribeAck(sessionId: sessionId), event: .transportReady)

        let subscribeStart = ContinuousClock.now
        var subscribeStatus = "ok"
        var subscribeErrorKind: String?

        do {
            _ = try await connection.sendCommandAwaitingResult(
                command: "subscribe",
                timeout: .seconds(10)
            ) { requestId in
                .subscribe(sessionId: sessionId, level: .full, requestId: requestId)
            }
            transition(to: .queueSync(sessionId: sessionId, phase: .initial), event: .subscribeAck)
        } catch {
            subscribeStatus = "error"
            subscribeErrorKind = connection.telemetryErrorKind(from: error)
            streamCoordinatorLogger.error(
                "Subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        let subscribeAckMs = Int((ContinuousClock.now - subscribeStart) / .milliseconds(1))

        Task.detached(priority: .utility) {
            var tags: [String: String] = [
                "transport": transport,
                "status": subscribeStatus,
            ]
            if let subscribeErrorKind {
                tags["error_kind"] = subscribeErrorKind
            }
            await ChatMetricsService.shared.record(
                metric: .subscribeAckMs,
                value: Double(subscribeAckMs),
                unit: .ms,
                sessionId: sessionId,
                tags: tags
            )
        }

        scheduleQueueSync(connection: connection, sessionId: sessionId, transport: transport)

        let totalMs = Int((ContinuousClock.now - streamStart) / .milliseconds(1))
        let endpointHost = connection.streamEndpointHostForMetrics()

        streamCoordinatorLogger.info(
            "streamSession(\(sessionId, privacy: .public)): wsStatus=\(String(describing: wsStatus), privacy: .public) streamOpen=\(streamOpenMs)ms subscribeAck=\(subscribeAckMs)ms total=\(totalMs)ms transport=\(transport, privacy: .public) host=\(endpointHost, privacy: .public)"
        )

        ClientLog.info("StreamSession", "\(sessionId.prefix(8))", metadata: [
            "wsStatus": String(describing: wsStatus),
            "streamOpenMs": String(streamOpenMs),
            "subscribeAckMs": String(subscribeAckMs),
            "queueSyncMs": "0",
            "queueSyncStatus": "async",
            "totalMs": String(totalMs),
            "transport": transport,
            "endpointHost": endpointHost,
            "connectMs": String(streamOpenMs),
            "subscribeMs": String(subscribeAckMs),
        ])

        await syncNotificationSubscriptions(connection: connection)

        return perSessionStream
    }

    func handleStreamReconnected(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }

        // Cancel any in-flight queue sync from the previous WS connection.
        connection.cancelDeferredQueueSync()

        if let activeSessionId = connection.activeSessionId {
            transition(to: .resubscribing(sessionId: activeSessionId), event: .streamConnected)
        }

        await resubscribeTrackedSessions(connection: connection)
    }

    func syncNotificationSubscriptions(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }

        if let activeSessionId = connection.activeSessionId {
            connection.notificationSessionIds.remove(activeSessionId)
            connection.pendingNotificationSubscriptionIds.remove(activeSessionId)
        }

        let desired = desiredNotificationSessionIds(connection: connection)
        let tracked = connection.notificationSessionIds
        let pending = connection.pendingNotificationSubscriptionIds

        let toRemove = tracked.subtracting(desired)
        let toAdd = desired.subtracting(tracked).subtracting(pending)

        for sessionId in toRemove {
            connection.notificationSessionIds.remove(sessionId)
            connection.pendingNotificationSubscriptionIds.remove(sessionId)
            try? await connection.wsClient?.send(
                .unsubscribe(sessionId: sessionId, requestId: UUID().uuidString)
            )
        }

        for sessionId in toAdd {
            if let pendingUnsub = connection.pendingUnsubscribeTasks.removeValue(forKey: sessionId) {
                pendingUnsub.cancel()
            }

            connection.pendingNotificationSubscriptionIds.insert(sessionId)

            do {
                _ = try await connection.sendCommandAwaitingResult(
                    command: "subscribe",
                    timeout: .seconds(6)
                ) { requestId in
                    .subscribe(sessionId: sessionId, level: .notifications, requestId: requestId)
                }

                let stillDesired = desiredNotificationSessionIds(connection: connection).contains(sessionId)
                if stillDesired {
                    connection.notificationSessionIds.insert(sessionId)
                } else {
                    try? await connection.wsClient?.send(
                        .unsubscribe(sessionId: sessionId, requestId: UUID().uuidString)
                    )
                    connection.notificationSessionIds.remove(sessionId)
                }
            } catch {
                streamCoordinatorLogger.warning(
                    "Notification subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            connection.pendingNotificationSubscriptionIds.remove(sessionId)
        }
    }

    func noteStreamDisconnected() {
        transition(to: .idle, event: .disconnected)
    }

    // MARK: - Catch-up state

    func seedLastSeenSeq(sessionId: String, value: Int) {
        lastSeenSeqBySession[sessionId] = value
    }

    func lastSeenSeq(sessionId: String) -> Int {
        lastSeenSeqBySession[sessionId] ?? 0
    }

    func consumeLiveSeq(sessionId: String, seq: Int) -> Bool {
        let current = lastSeenSeqBySession[sessionId] ?? 0
        guard seq > current else { return false }
        lastSeenSeqBySession[sessionId] = seq
        return true
    }

    func catchUpDecision(sessionId: String, currentSeq: Int) -> CatchUpDecision {
        let lastSeen = lastSeenSeqBySession[sessionId] ?? 0

        if currentSeq < lastSeen {
            lastSeenSeqBySession[sessionId] = currentSeq
            return .seqRegression(resetTo: currentSeq)
        }

        if currentSeq == lastSeen {
            return .noGap
        }

        return .fetchSince(lastSeen)
    }

    func applyCatchUpProgress(sessionId: String, seq: Int) {
        let current = lastSeenSeqBySession[sessionId] ?? 0
        if seq > current {
            lastSeenSeqBySession[sessionId] = seq
        }
    }

    // MARK: - Internals

    private func scheduleQueueSync(
        connection: ServerConnection,
        sessionId: String,
        transport: String
    ) {
        connection.cancelDeferredQueueSync()

        connection.deferredQueueSyncTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard !Task.isCancelled,
                  connection.activeSessionId == sessionId else {
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
                  connection.activeSessionId == sessionId else {
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

    private func resubscribeTrackedSessions(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }

        var activeResubscribed = false
        if let activeSessionId = connection.activeSessionId {
            let ok = await resubscribeWithRetry(
                connection: connection,
                sessionId: activeSessionId,
                level: .full,
                maxAttempts: ServerConnection.resubscribeMaxAttempts
            )
            if ok {
                activeResubscribed = true
            } else {
                streamCoordinatorLogger.error(
                    "Resubscription failed for active session \(activeSessionId, privacy: .public)"
                )
                ClientLog.error(
                    "WebSocket",
                    "Resubscription failed for active session",
                    metadata: ["sessionId": activeSessionId]
                )
                ClientLog.error("StreamCoordinator", "Connection recovered but session sync failed", metadata: ["sessionId": activeSessionId])
            }
        }

        let notificationSessionIds = connection.notificationSessionIds
        let activeSessionId = connection.activeSessionId

        let sortedNotifications = Array(notificationSessionIds.filter { $0 != activeSessionId })
        let batch = sortedNotifications.prefix(Self.maxNotificationSubscriptions)

        if sortedNotifications.count > Self.maxNotificationSubscriptions {
            streamCoordinatorLogger.info(
                "Reconnect: resubscribing \(batch.count)/\(sortedNotifications.count) notification sessions (capped)"
            )
        }

        for sessionId in batch {
            _ = await resubscribeWithRetry(
                connection: connection,
                sessionId: sessionId,
                level: .notifications,
                maxAttempts: 1
            )
        }

        if let activeSessionId {
            transition(to: .streaming(sessionId: activeSessionId), event: .queueSyncFinished)

            if activeResubscribed {
                let transport = connection.transportPath.rawValue
                scheduleQueueSync(
                    connection: connection,
                    sessionId: activeSessionId,
                    transport: transport
                )
            }
        }
    }

    private func resubscribeWithRetry(
        connection: ServerConnection,
        sessionId: String,
        level: StreamSubscriptionLevel,
        maxAttempts: Int
    ) async -> Bool {
        for attempt in 1...maxAttempts {
            guard connection.wsClient != nil else { return false }

            do {
                _ = try await connection.sendCommandAwaitingResult(
                    command: "subscribe",
                    timeout: ServerConnection.resubscribeAckTimeout
                ) { requestId in
                    .subscribe(sessionId: sessionId, level: level, requestId: requestId)
                }
                return true
            } catch {
                let delayMs = Int(500 * attempt)
                streamCoordinatorLogger.warning(
                    "Resubscribe attempt \(attempt)/\(maxAttempts) failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        }

        return false
    }

    private func desiredNotificationSessionIds(connection: ServerConnection) -> Set<String> {
        let active = connection.activeSessionId
        let candidates = connection.sessionStore.sessions
            .filter { $0.status != .stopped && $0.id != active }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(Self.maxNotificationSubscriptions)
            .map(\.id)
        return Set(candidates)
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
    }

    private func kind(of state: StreamState) -> StateKind {
        switch state {
        case .idle: .idle
        case .connectingTransport: .connectingTransport
        case .awaitingSubscribeAck: .awaitingSubscribeAck
        case .queueSync: .queueSync
        case .streaming: .streaming
        case .resubscribing: .resubscribing
        }
    }
}
