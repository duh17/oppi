import Foundation
import OSLog

private let streamCoordinatorLogger = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "SessionStreamCoordinator"
)

actor SessionStreamCoordinator {
    enum StreamState: Equatable {
        case idle
        case connectingTransport(sessionId: String)
        case awaitingSubscribeAck(sessionId: String)
        case queueSync(sessionId: String, phase: QueueSyncPhase)
        case streaming(sessionId: String)
        case resubscribing(sessionId: String)
        case recoveringFullSubscription(sessionId: String)
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
        case recoveringFullSubscription
    }

    private enum Event: String {
        case beginSession
        case transportReady
        case subscribeAck
        case queueSyncStarted
        case queueSyncFinished
        case streamConnected
        case recoveryStarted
        case recoveryFinished
        case disconnected
    }

    private static let transitionTable: [StateKind: Set<Event>] = [
        .idle: [.beginSession, .disconnected],
        .connectingTransport: [.transportReady, .disconnected],
        .awaitingSubscribeAck: [.subscribeAck, .disconnected],
        .queueSync: [.queueSyncStarted, .queueSyncFinished, .disconnected],
        .streaming: [.beginSession, .streamConnected, .recoveryStarted, .disconnected],
        // streamConnected: WS can drop again mid-resubscribe; the new
        // handleStreamReconnected() will restart resubscription.
        .resubscribing: [.queueSyncFinished, .recoveryStarted, .streamConnected, .disconnected],
        .recoveringFullSubscription: [.recoveryFinished, .streamConnected, .disconnected],
    ]

    private static let eagerResolveCommands: Set<String> = ["subscribe", "unsubscribe", "get_queue"]
    private static let fullSubscriptionRecoveryCooldown: TimeInterval = 1.5

    /// Maximum notification-level sessions to subscribe after reconnect.
    /// Prevents subscribe floods when many sessions are non-stopped.
    /// The server processes subscribes sequentially — too many cause ping
    /// timeouts → reconnect → more subscribes → death spiral.
    private static let maxNotificationSubscriptions = 20

    private(set) var state: StreamState = .idle
    private var lastSeenSeqBySession: [String: Int] = [:]
    private var recoveryReservationSessionId: String?

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
        let hasClient = await MainActor.run { connection.wsClient != nil }
        guard hasClient else { return nil }

        transition(to: .connectingTransport(sessionId: sessionId), event: .beginSession)

        let streamStart = ContinuousClock.now

        let previousSessionId = await MainActor.run { connection.activeSessionId }
        if let previousSessionId, previousSessionId != sessionId {
            await MainActor.run {
                connection.unsubscribeSession(previousSessionId)
            }
        }

        if let pendingUnsub = await MainActor.run(body: {
            connection.pendingUnsubscribeTasks.removeValue(forKey: sessionId)
        }) {
            pendingUnsub.cancel()
        }

        await MainActor.run {
            connection.activeSessionId = sessionId
            connection.sender.activeSessionId = sessionId
            connection.toolCallCorrelator.reset()
            connection.chatState.thinkingLevel = .medium
            Task {
                await SentryService.shared.setSessionContext(sessionId: sessionId, workspaceId: workspaceId)
            }
        }

        let wsStatus = await MainActor.run { connection.wsClient?.status }
        let transport = await MainActor.run { connection.transportPath.rawValue }

        await MainActor.run {
            connection.connectStream()
        }

        let streamOpenStart = ContinuousClock.now
        let streamOpenStatus: String
        if await MainActor.run(body: { connection.wsClient?.status == .connected }) {
            streamOpenStatus = "already_connected"
        } else if await connection.waitForConnectedStream(timeout: .seconds(10)) {
            streamOpenStatus = "connected"
        } else {
            streamOpenStatus = "timeout"
        }
        let streamOpenMs = Int((ContinuousClock.now - streamOpenStart) / .milliseconds(1))

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .streamOpenMs,
                value: Double(streamOpenMs),
                unit: .ms,
                sessionId: sessionId,
                tags: [
                    "transport": transport,
                    "status": streamOpenStatus,
                ]
            )
        }

        let perSessionStream = await MainActor.run {
            AsyncStream<ServerMessage> { continuation in
                connection.sessionContinuations[sessionId] = continuation

                continuation.onTermination = { [weak connection] _ in
                    Task { @MainActor in
                        connection?.sessionContinuations.removeValue(forKey: sessionId)
                    }
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
            subscribeErrorKind = await connection.telemetryErrorKind(from: error)
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

        await scheduleQueueSync(connection: connection, sessionId: sessionId, transport: transport)

        let totalMs = Int((ContinuousClock.now - streamStart) / .milliseconds(1))
        let endpointHost = await MainActor.run { connection.streamEndpointHostForMetrics() }

        streamCoordinatorLogger.info(
            "streamSession(\(sessionId, privacy: .public)): wsStatus=\(String(describing: wsStatus), privacy: .public) streamOpen=\(streamOpenMs)ms subscribeAck=\(subscribeAckMs)ms total=\(totalMs)ms transport=\(transport, privacy: .public) host=\(endpointHost, privacy: .public)"
        )

        await MainActor.run {
            ClientLog.info("StreamSession", "\(sessionId.prefix(8))", metadata: [
                "wsStatus": String(describing: wsStatus),
                "streamOpenMs": String(streamOpenMs),
                "subscribeAckMs": String(subscribeAckMs),
                "queueSyncMs": "0",
                "queueSyncStatus": "async",
                "totalMs": String(totalMs),
                "transport": transport,
                "endpointHost": endpointHost,
                // Keep legacy keys for compatibility with existing local analysis scripts.
                "connectMs": String(streamOpenMs),
                "subscribeMs": String(subscribeAckMs),
            ])
        }

        await syncNotificationSubscriptions(connection: connection)

        return perSessionStream
    }

    func handleStreamReconnected(connection: ServerConnection) async {
        let hasClient = await MainActor.run { connection.wsClient != nil }
        guard hasClient else { return }

        // Cancel any in-flight queue sync from the previous WS connection.
        // The deferred task would send get_queue on the new WS before
        // resubscription completes, hitting an empty subscription map
        // and triggering "not subscribed at level=full" errors.
        await cancelDeferredQueueSync(connection: connection)

        if let activeSessionId = await MainActor.run(body: { connection.activeSessionId }) {
            transition(to: .resubscribing(sessionId: activeSessionId), event: .streamConnected)
        }

        await resubscribeTrackedSessions(connection: connection)
    }

    func syncNotificationSubscriptions(connection: ServerConnection) async {
        let hasClient = await MainActor.run { connection.wsClient != nil }
        guard hasClient else { return }

        if let activeSessionId = await MainActor.run(body: { connection.activeSessionId }) {
            await MainActor.run {
                connection.notificationSessionIds.remove(activeSessionId)
                connection.pendingNotificationSubscriptionIds.remove(activeSessionId)
            }
        }

        let desired = await desiredNotificationSessionIds(connection: connection)
        let tracked = await MainActor.run(body: { connection.notificationSessionIds })
        let pending = await MainActor.run(body: { connection.pendingNotificationSubscriptionIds })

        let toRemove = tracked.subtracting(desired)
        let toAdd = desired.subtracting(tracked).subtracting(pending)

        for sessionId in toRemove {
            await MainActor.run {
                _ = connection.notificationSessionIds.remove(sessionId)
                _ = connection.pendingNotificationSubscriptionIds.remove(sessionId)
            }
            try? await connection.wsClient?.send(
                .unsubscribe(sessionId: sessionId, requestId: UUID().uuidString)
            )
        }

        for sessionId in toAdd {
            if let pendingUnsub = await MainActor.run(body: {
                connection.pendingUnsubscribeTasks.removeValue(forKey: sessionId)
            }) {
                pendingUnsub.cancel()
            }

            await MainActor.run {
                _ = connection.pendingNotificationSubscriptionIds.insert(sessionId)
            }

            do {
                _ = try await connection.sendCommandAwaitingResult(
                    command: "subscribe",
                    timeout: .seconds(6)
                ) { requestId in
                    .subscribe(sessionId: sessionId, level: .notifications, requestId: requestId)
                }

                let stillDesired = await desiredNotificationSessionIds(connection: connection).contains(sessionId)
                if stillDesired {
                    await MainActor.run {
                        _ = connection.notificationSessionIds.insert(sessionId)
                    }
                } else {
                    try? await connection.wsClient?.send(
                        .unsubscribe(sessionId: sessionId, requestId: UUID().uuidString)
                    )
                    await MainActor.run {
                        _ = connection.notificationSessionIds.remove(sessionId)
                    }
                }
            } catch {
                streamCoordinatorLogger.warning(
                    "Notification subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            await MainActor.run {
                _ = connection.pendingNotificationSubscriptionIds.remove(sessionId)
            }
        }
    }

    func triggerFullSubscriptionRecovery(
        connection: ServerConnection,
        sessionId: String,
        serverError: String
    ) async {
        guard recoveryReservationSessionId != sessionId else { return }
        recoveryReservationSessionId = sessionId

        var launchedRecovery = false
        defer {
            if !launchedRecovery,
               recoveryReservationSessionId == sessionId {
                recoveryReservationSessionId = nil
            }
        }

        guard await MainActor.run(body: { connection.activeSessionId == sessionId }) else { return }

        if let inFlight = await MainActor.run(body: { connection.fullSubscriptionRecoveryTask }), !inFlight.isCancelled {
            return
        }

        if let lastAttempt = await MainActor.run(body: { connection.lastFullSubscriptionRecoveryAt }),
           Date().timeIntervalSince(lastAttempt) < Self.fullSubscriptionRecoveryCooldown {
            return
        }

        transition(to: .recoveringFullSubscription(sessionId: sessionId), event: .recoveryStarted)

        let task = Task { @MainActor [weak connection] in
            guard let connection else {
                Task {
                    await self.finishRecoveryReservation(sessionId: sessionId)
                }
                return
            }
            defer {
                connection.lastFullSubscriptionRecoveryAt = Date()
                connection.fullSubscriptionRecoveryTask = nil
                Task {
                    await self.transition(to: .streaming(sessionId: sessionId), event: .recoveryFinished)
                    await self.finishRecoveryReservation(sessionId: sessionId)
                }
            }

            streamCoordinatorLogger.warning(
                "Detected missing full subscription for \(sessionId, privacy: .public): \(serverError, privacy: .public). Attempting auto-recover"
            )

            do {
                _ = try await connection.sendCommandAwaitingResult(
                    command: "subscribe",
                    timeout: .seconds(6)
                ) { requestId in
                    .subscribe(sessionId: sessionId, level: .full, requestId: requestId)
                }

                Task { @MainActor [weak connection] in
                    guard let connection else { return }
                    try? await connection.requestState()
                    try? await connection.requestMessageQueue(
                        timeout: ServerConnection.deferredQueueSyncTimeout
                    )
                }
                ClientLog.info(
                    "WebSocket",
                    "Recovered full subscription",
                    metadata: ["sessionId": sessionId]
                )
            } catch {
                streamCoordinatorLogger.error(
                    "Auto-recover subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                connection.reducer.appendSystemEvent("Connection hiccup — trying to resync session")
            }
        }

        launchedRecovery = true
        await MainActor.run {
            connection.fullSubscriptionRecoveryTask = task
        }
    }

    func cancelDeferredQueueSync(connection: ServerConnection) async {
        await MainActor.run {
            connection.cancelDeferredQueueSync()
        }
    }

    func noteStreamDisconnected() {
        transition(to: .idle, event: .disconnected)
    }

    private func finishRecoveryReservation(sessionId: String) {
        if recoveryReservationSessionId == sessionId {
            recoveryReservationSessionId = nil
        }
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
    ) async {
        await MainActor.run {
            connection.cancelDeferredQueueSync()
        }

        let task = Task { @MainActor [weak connection] in
            guard let connection else { return }
            guard !Task.isCancelled,
                  connection.activeSessionId == sessionId else {
                return
            }

            await self.transition(to: .queueSync(sessionId: sessionId, phase: .initial), event: .queueSyncStarted)

            let initialSucceeded = await self.performQueueSyncAttempt(
                connection: connection,
                sessionId: sessionId,
                transport: transport,
                timeout: ServerConnection.initialQueueSyncTimeout,
                phase: .initial
            )

            guard !initialSucceeded else {
                await self.transition(to: .streaming(sessionId: sessionId), event: .queueSyncFinished)
                return
            }

            try? await Task.sleep(for: ServerConnection.deferredQueueSyncDelay)
            guard !Task.isCancelled,
                  connection.activeSessionId == sessionId else {
                return
            }

            await self.transition(to: .queueSync(sessionId: sessionId, phase: .retry), event: .queueSyncStarted)
            _ = await self.performQueueSyncAttempt(
                connection: connection,
                sessionId: sessionId,
                transport: transport,
                timeout: ServerConnection.deferredQueueSyncTimeout,
                phase: .retry
            )
            await self.transition(to: .streaming(sessionId: sessionId), event: .queueSyncFinished)
        }

        await MainActor.run {
            connection.deferredQueueSyncTask = task
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
            queueSyncErrorKind = await connection.telemetryErrorKind(from: error)
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
        let hasClient = await MainActor.run { connection.wsClient != nil }
        guard hasClient else { return }

        var activeResubscribed = false
        if let activeSessionId = await MainActor.run(body: { connection.activeSessionId }) {
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
                await MainActor.run {
                    ClientLog.error(
                        "WebSocket",
                        "Resubscription failed for active session",
                        metadata: ["sessionId": activeSessionId]
                    )
                    connection.reducer.appendSystemEvent("Connection recovered but session sync failed")
                }
            }
        }

        let notificationSessionIds = await MainActor.run(body: { connection.notificationSessionIds })
        let activeSessionId = await MainActor.run(body: { connection.activeSessionId })

        // Only resubscribe a bounded number of notification sessions on reconnect.
        // The full set will be reconciled by the debounced syncNotificationSubscriptions().
        // This prevents the death spiral: reconnect → flood subscribes → server overwhelmed
        // → ping timeout → reconnect → bigger flood.
        let notificationResubscribeLimit = Self.maxNotificationSubscriptions
        let sortedNotifications = Array(notificationSessionIds.filter { $0 != activeSessionId })
        let batch = sortedNotifications.prefix(notificationResubscribeLimit)

        if sortedNotifications.count > notificationResubscribeLimit {
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

            // Re-sync message queue after successful resubscription.
            // The old deferred queue sync was cancelled in handleStreamReconnected()
            // to prevent it from racing ahead of resubscription on the new WS.
            if activeResubscribed {
                let transport = await MainActor.run { connection.transportPath.rawValue }
                await scheduleQueueSync(
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
            let hasClient = await MainActor.run { connection.wsClient != nil }
            guard hasClient else { return false }

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

    private func desiredNotificationSessionIds(connection: ServerConnection) async -> Set<String> {
        await MainActor.run {
            let active = connection.activeSessionId
            let candidates = connection.sessionStore.sessions
                .filter { $0.status != .stopped && $0.id != active }
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                .prefix(Self.maxNotificationSubscriptions)
                .map(\.id)
            return Set(candidates)
        }
    }

    /// Apply a state transition, logging unexpected ones.
    ///
    /// The transition table is advisory — unexpected transitions are logged
    /// but still applied. Hard rejection would risk leaving the coordinator
    /// stuck in a stale state after edge-case races.
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
        case .idle:
            return .idle
        case .connectingTransport:
            return .connectingTransport
        case .awaitingSubscribeAck:
            return .awaitingSubscribeAck
        case .queueSync:
            return .queueSync
        case .streaming:
            return .streaming
        case .resubscribing:
            return .resubscribing
        case .recoveringFullSubscription:
            return .recoveringFullSubscription
        }
    }
}
