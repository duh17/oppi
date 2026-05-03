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

    /// Maximum notification-level sessions to subscribe after reconnect.
    private static let maxNotificationSubscriptions = 20

    private(set) var state: StreamState = .idle
    private var lastSeenSeqBySession: [String: Int] = [:]
    /// Coalesces multiple not-subscribed errors into a single resubscribe attempt.
    private(set) var silentResubscribeTask: Task<Bool, Never>?
    // MARK: - Session lifecycle

    func streamSession(
        connection: ServerConnection,
        sessionId: String,
        workspaceId: String
    ) async -> AsyncStream<SessionStreamEvent>? {
        guard connection.wsClient != nil else { return nil }

        transition(to: .connectingTransport(sessionId: sessionId), event: .beginSession)

        let streamStart = ContinuousClock.now

        // Cancel any pending unsubscribe for the session we're about to subscribe.
        connection.cancelPendingUnsubscribe(for: sessionId)

        connection.focusSession(sessionId)
        connection.subscriptionRegistry.setDesired(.full, for: sessionId)
        let subscriptionGeneration = connection.subscriptionRegistry.generation(for: sessionId)
        connection.chatState.thinkingLevel = .medium
        Task {
            await SentryService.shared.setSessionContext(sessionId: sessionId, workspaceId: workspaceId)
        }

        let wsStatus = connection.wsClient?.status
        let transport = connection.transportPath.rawValue

        connection.connectStream()

        // Wait for transport to be connected before opening the per-session stream.
        let streamOpenStart = ContinuousClock.now
        let statusBeforeWait = statusTag(connection.wsClient?.status)
        var waitOutcome = "already_connected"
        if connection.wsClient?.status == .connected {
            // already connected
        } else if await connection.waitForConnectedStream(timeout: .seconds(10)) {
            waitOutcome = "connected"
        } else {
            waitOutcome = "timeout"
            // timeout — proceed anyway, subscribe will fail and be handled
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

        let perSessionStream = AsyncStream<SessionStreamEvent> { continuation in
            connection.sessionEventContinuations[sessionId] = continuation

            continuation.onTermination = { [weak connection] _ in
                Task { @MainActor in
                    connection?.sessionEventContinuations.removeValue(forKey: sessionId)
                }
            }
        }

        transition(to: .awaitingSubscribeAck(sessionId: sessionId), event: .transportReady)

        let subscribeStart = ContinuousClock.now
        var subscribeStatus = "ok"
        var subscribeErrorKind: String?

        do {
            var subscribeRequestId: String?
            _ = try await connection.sendCommandAwaitingResult(
                command: "subscribe",
                timeout: .seconds(10)
            ) { requestId in
                subscribeRequestId = requestId
                connection.subscriptionRegistry.markSubscribeSent(
                    sessionId: sessionId,
                    requestId: requestId,
                    level: .full
                )
                return .subscribe(
                    sessionId: sessionId,
                    level: .full,
                    requestId: requestId,
                    subscriptionGeneration: subscriptionGeneration
                )
            }
            if let subscribeRequestId {
                connection.subscriptionRegistry.markSubscribeAck(
                    sessionId: sessionId,
                    requestId: subscribeRequestId
                )
            }
            transition(to: .queueSync(sessionId: sessionId, phase: .initial), event: .subscribeAck)
        } catch {
            subscribeStatus = "error"
            subscribeErrorKind = connection.telemetryErrorKind(from: error)
            streamCoordinatorLogger.error(
                "Subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        let subscribeGateMs = Int((ContinuousClock.now - subscribeStart) / .milliseconds(1))

        Task.detached(priority: .utility) {
            var tags: [String: String] = [
                "transport": transport,
                "status": subscribeStatus,
                "level": "full",
            ]
            if let subscribeErrorKind {
                tags["error_kind"] = subscribeErrorKind
            }
            await ChatMetricsService.shared.record(
                metric: .subscribeGateMs,
                value: Double(subscribeGateMs),
                unit: .ms,
                sessionId: sessionId,
                tags: tags
            )
        }

        scheduleQueueSync(connection: connection, sessionId: sessionId, transport: transport)

        let totalMs = Int((ContinuousClock.now - streamStart) / .milliseconds(1))
        let endpointHost = connection.streamEndpointHostForMetrics()

        streamCoordinatorLogger.info(
            "streamSession(\(sessionId, privacy: .public)): wsStatus=\(String(describing: wsStatus), privacy: .public) streamOpen=\(streamOpenMs)ms subscribeGate=\(subscribeGateMs)ms total=\(totalMs)ms transport=\(transport, privacy: .public) host=\(endpointHost, privacy: .public)"
        )

        ClientLog.info("StreamSession", "\(sessionId.prefix(8))", metadata: [
            "wsStatus": String(describing: wsStatus),
            "streamOpenMs": String(streamOpenMs),
            "subscribeGateMs": String(subscribeGateMs),
            "queueSyncMs": "0",
            "queueSyncStatus": "async",
            "totalMs": String(totalMs),
            "transport": transport,
            "endpointHost": endpointHost,
            "connectMs": String(streamOpenMs),
            "subscribeMs": String(subscribeGateMs),
        ])

        await syncNotificationSubscriptions(connection: connection)

        return perSessionStream
    }

    func handleStreamReconnected(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }

        // Cancel any in-flight silent resubscribe — the full reconnect flow
        // will resubscribe all tracked sessions from scratch.
        silentResubscribeTask?.cancel()
        silentResubscribeTask = nil

        // Cancel any in-flight queue sync from the previous WS connection.
        connection.cancelDeferredQueueSync()

        if let focusedSessionId = connection.focusedSessionId {
            transition(to: .resubscribing(sessionId: focusedSessionId), event: .streamConnected)
        }

        await resubscribeTrackedSessions(connection: connection)
    }

    func syncNotificationSubscriptions(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }

        let desiredOrdered = orderedDesiredNotificationSessionIds(connection: connection).filter {
            connection.subscriptionRegistry.desiredLevel(for: $0) != .full
        }
        let desired = Set(desiredOrdered)

        for sessionId in desiredOrdered {
            connection.subscriptionRegistry.setDesired(.notifications, for: sessionId)
        }
        await clearStaleNotificationDesiredEntries(connection: connection, desired: desired)

        let tracked = connection.subscriptionRegistry.sessionIds(acked: .notifications)
        let pending = connection.subscriptionRegistry.sessionIds(inFlight: .notifications)
        let toAdd = desired.subtracting(tracked).subtracting(pending)

        for sessionId in desiredOrdered where toAdd.contains(sessionId) {
            if let pendingUnsub = connection.pendingUnsubscribeTasks.removeValue(forKey: sessionId) {
                pendingUnsub.cancel()
            }

            var subscribeRequestId: String?
            do {
                _ = try await connection.sendCommandAwaitingResult(
                    command: "subscribe",
                    timeout: .seconds(6)
                ) { requestId in
                    subscribeRequestId = requestId
                    connection.subscriptionRegistry.markSubscribeSent(
                        sessionId: sessionId,
                        requestId: requestId,
                        level: .notifications
                    )
                    return .subscribe(
                        sessionId: sessionId,
                        level: .notifications,
                        requestId: requestId,
                        subscriptionGeneration: connection.subscriptionRegistry.generation(for: sessionId)
                    )
                }

                if let subscribeRequestId {
                    connection.subscriptionRegistry.markSubscribeAck(
                        sessionId: sessionId,
                        requestId: subscribeRequestId
                    )
                }

                let latestDesired = Set(orderedDesiredNotificationSessionIds(connection: connection))
                let stillDesired = latestDesired.contains(sessionId)
                    && connection.subscriptionRegistry.desiredLevel(for: sessionId) != .full
                if !stillDesired {
                    let generation = connection.subscriptionRegistry.generation(for: sessionId)
                    connection.subscriptionRegistry.markUnsubscribeSent(
                        sessionId: sessionId,
                        generation: generation
                    )
                    try? await connection.wsClient?.send(
                        .unsubscribe(
                            sessionId: sessionId,
                            requestId: UUID().uuidString,
                            subscriptionGeneration: generation
                        )
                    )
                }
            } catch {
                if let subscribeRequestId {
                    connection.subscriptionRegistry.markSubscribeFailed(
                        sessionId: sessionId,
                        requestId: subscribeRequestId,
                        reason: error.localizedDescription
                    )
                }
                streamCoordinatorLogger.warning(
                    "Notification subscribe failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func noteStreamDisconnected() {
        silentResubscribeTask?.cancel()
        silentResubscribeTask = nil
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

    private func resubscribeTrackedSessions(connection: ServerConnection) async {
        guard connection.wsClient != nil else { return }

        let focusedSessionId = connection.focusedSessionId
        var focusedResubscribed = false

        for sessionId in orderedFullSubscriptionSessionIds(connection: connection) {
            let ok = await resubscribeWithRetry(
                connection: connection,
                sessionId: sessionId,
                level: .full,
                maxAttempts: ServerConnection.resubscribeMaxAttempts,
                reason: "stream_reconnect"
            )
            if sessionId == focusedSessionId {
                if ok {
                    focusedResubscribed = true
                } else {
                    streamCoordinatorLogger.error(
                        "Resubscription failed for focused session \(sessionId, privacy: .public)"
                    )
                    ClientLog.error(
                        "WebSocket",
                        "Resubscription failed for focused session",
                        metadata: ["sessionId": sessionId]
                    )
                    ClientLog.error("StreamCoordinator", "Connection recovered but session sync failed", metadata: ["sessionId": sessionId])
                }
            } else if !ok {
                streamCoordinatorLogger.error(
                    "Resubscription failed for background full session \(sessionId, privacy: .public)"
                )
            }
        }

        let notificationCandidates = orderedNotificationCandidateSessionIds(connection: connection).filter {
            $0 != focusedSessionId && connection.subscriptionRegistry.desiredLevel(for: $0) != .full
        }
        let batch = Array(notificationCandidates.prefix(Self.maxNotificationSubscriptions))
        let desiredNotifications = Set(batch)

        for sessionId in batch {
            connection.subscriptionRegistry.setDesired(.notifications, for: sessionId)
        }
        await clearStaleNotificationDesiredEntries(connection: connection, desired: desiredNotifications)

        if notificationCandidates.count > Self.maxNotificationSubscriptions {
            streamCoordinatorLogger.info(
                "Reconnect: resubscribing \(batch.count)/\(notificationCandidates.count) notification sessions (capped)"
            )
        }

        for sessionId in batch {
            _ = await resubscribeWithRetry(
                connection: connection,
                sessionId: sessionId,
                level: .notifications,
                maxAttempts: 1,
                reason: "stream_reconnect"
            )
        }

        if let focusedSessionId {
            transition(to: .streaming(sessionId: focusedSessionId), event: .queueSyncFinished)

            if focusedResubscribed {
                let transport = connection.transportPath.rawValue
                scheduleQueueSync(
                    connection: connection,
                    sessionId: focusedSessionId,
                    transport: transport
                )
            }
        }
    }

    private func resubscribeWithRetry(
        connection: ServerConnection,
        sessionId: String,
        level: StreamSubscriptionLevel,
        maxAttempts: Int,
        reason: String
    ) async -> Bool {
        connection.cancelPendingUnsubscribe(for: sessionId)

        let startedAt = ContinuousClock.now
        var lastErrorKind: String?
        for attempt in 1...maxAttempts {
            guard connection.wsClient != nil else {
                recordResubscribeMetric(
                    elapsed: ContinuousClock.now - startedAt,
                    connection: connection,
                    sessionId: sessionId,
                    level: level,
                    reason: reason,
                    attempt: attempt,
                    outcome: "error",
                    errorKind: "not_connected"
                )
                return false
            }

            var subscribeRequestId: String?
            do {
                let desiredLevel: DesiredSubscriptionLevel = level == .full ? .full : .notifications
                connection.subscriptionRegistry.setDesired(desiredLevel, for: sessionId)
                _ = try await connection.sendCommandAwaitingResult(
                    command: "subscribe",
                    timeout: ServerConnection.resubscribeAckTimeout
                ) { requestId in
                    subscribeRequestId = requestId
                    connection.subscriptionRegistry.markSubscribeSent(
                        sessionId: sessionId,
                        requestId: requestId,
                        level: desiredLevel
                    )
                    return .subscribe(
                        sessionId: sessionId,
                        level: level,
                        requestId: requestId,
                        subscriptionGeneration: connection.subscriptionRegistry.generation(for: sessionId)
                    )
                }
                if let subscribeRequestId {
                    connection.subscriptionRegistry.markSubscribeAck(
                        sessionId: sessionId,
                        requestId: subscribeRequestId
                    )
                }
                recordResubscribeMetric(
                    elapsed: ContinuousClock.now - startedAt,
                    connection: connection,
                    sessionId: sessionId,
                    level: level,
                    reason: reason,
                    attempt: attempt,
                    outcome: "ok"
                )
                return true
            } catch {
                lastErrorKind = connection.telemetryErrorKind(from: error)
                if let subscribeRequestId {
                    connection.subscriptionRegistry.markSubscribeFailed(
                        sessionId: sessionId,
                        requestId: subscribeRequestId,
                        reason: error.localizedDescription
                    )
                }
                let delayMs = Int(500 * attempt)
                streamCoordinatorLogger.warning(
                    "Resubscribe attempt \(attempt)/\(maxAttempts) failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        }

        recordResubscribeMetric(
            elapsed: ContinuousClock.now - startedAt,
            connection: connection,
            sessionId: sessionId,
            level: level,
            reason: reason,
            attempt: maxAttempts,
            outcome: "error",
            errorKind: lastErrorKind
        )
        return false
    }

    // MARK: - Silent resubscribe on not-subscribed errors

    /// Silently resubscribe the active session when the server reports it is
    /// not subscribed at `level=full`. Debounced so multiple rapid errors
    /// (common after a reconnect) trigger only one resubscribe attempt.
    ///
    /// Returns `true` if the error was recognized and will be handled silently.
    func handleNotSubscribedError(
        connection: ServerConnection,
        sessionId: String
    ) -> Bool {
        guard canRecoverNotSubscribed(connection: connection, sessionId: sessionId) else {
            return false
        }

        recordMetric(
            .subscriptionRaceCount,
            value: 1,
            unit: .count,
            sessionId: sessionId,
            tags: [
                "transport": connection.transportPath.rawValue,
                "state": silentResubscribeTask == nil ? "starting" : "coalesced",
            ]
        )

        if silentResubscribeTask == nil {
            silentResubscribeTask = startSilentResubscribe(
                connection: connection,
                sessionId: sessionId,
                debounce: true
            )
        }

        return true
    }

    /// Ensure a full subscription is restored before a user turn is retried.
    /// Without waiting here the retry can race ahead of the silent resubscribe
    /// and surface the same rejected prompt to the composer.
    func recoverNotSubscribedBeforeRetry(
        connection: ServerConnection,
        sessionId: String
    ) async -> Bool {
        guard canRecoverNotSubscribed(connection: connection, sessionId: sessionId) else {
            return false
        }

        if let silentResubscribeTask {
            return await silentResubscribeTask.value
        }

        let task = startSilentResubscribe(
            connection: connection,
            sessionId: sessionId,
            debounce: false
        )
        silentResubscribeTask = task
        return await task.value
    }

    private func canRecoverNotSubscribed(
        connection: ServerConnection,
        sessionId: String
    ) -> Bool {
        connection.isFocusedSession(sessionId) && connection.wsClient != nil
    }

    private func startSilentResubscribe(
        connection: ServerConnection,
        sessionId: String,
        debounce: Bool
    ) -> Task<Bool, Never> {
        streamCoordinatorLogger.info(
            "Silently resubscribing \(sessionId, privacy: .public) after not-subscribed error"
        )

        return Task { [weak self, weak connection] in
            guard let self, let connection else { return false }

            if debounce {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return false }
            }

            let ok = await self.resubscribeWithRetry(
                connection: connection,
                sessionId: sessionId,
                level: .full,
                maxAttempts: 2,
                reason: debounce ? "silent_resubscribe" : "turn_retry"
            )

            self.recordMetric(
                .silentResubscribeCount,
                value: 1,
                unit: .count,
                sessionId: sessionId,
                tags: [
                    "transport": connection.transportPath.rawValue,
                    "outcome": ok ? "ok" : "error",
                    "reason": debounce ? "stream_error" : "turn_retry",
                ]
            )

            if ok {
                streamCoordinatorLogger.info(
                    "Silent resubscribe succeeded for \(sessionId, privacy: .public)"
                )
                self.scheduleQueueSync(
                    connection: connection,
                    sessionId: sessionId,
                    transport: connection.transportPath.rawValue
                )
            } else {
                streamCoordinatorLogger.error(
                    "Silent resubscribe failed for \(sessionId, privacy: .public)"
                )
            }

            if self.silentResubscribeTask != nil {
                self.silentResubscribeTask = nil
            }
            return ok
        }
    }

    private func orderedFullSubscriptionSessionIds(connection: ServerConnection) -> [String] {
        var fullSessionIds = connection.subscriptionRegistry.sessionIds(desired: .full)
        if let focusedSessionId = connection.focusedSessionId {
            fullSessionIds.insert(focusedSessionId)
        }
        return orderedSessionIds(fullSessionIds, connection: connection, focusedFirst: true)
    }

    private func orderedDesiredNotificationSessionIds(connection: ServerConnection) -> [String] {
        Array(orderedNotificationCandidateSessionIds(connection: connection).prefix(Self.maxNotificationSubscriptions))
    }

    private func orderedNotificationCandidateSessionIds(connection: ServerConnection) -> [String] {
        let active = connection.focusedSessionId
        return connection.sessionStore.sessions
            .filter { $0.status != .stopped && $0.id != active }
            .sorted { lhs, rhs in
                let lhsActivity = lhs.lastActivity ?? .distantPast
                let rhsActivity = rhs.lastActivity ?? .distantPast
                if lhsActivity != rhsActivity {
                    return lhsActivity > rhsActivity
                }
                return lhs.id < rhs.id
            }
            .map(\.id)
    }

    private func clearStaleNotificationDesiredEntries(
        connection: ServerConnection,
        desired: Set<String>
    ) async {
        let staleDesired = connection.subscriptionRegistry
            .sessionIds(desired: .notifications)
            .subtracting(desired)
        for sessionId in orderedSessionIds(staleDesired, connection: connection, focusedFirst: false) {
            switch connection.subscriptionRegistry.ackState(for: sessionId) {
            case .acked:
                let generation = connection.subscriptionRegistry.generation(for: sessionId)
                connection.subscriptionRegistry.markUnsubscribeSent(
                    sessionId: sessionId,
                    generation: generation
                )
                try? await connection.wsClient?.send(
                    .unsubscribe(
                        sessionId: sessionId,
                        requestId: UUID().uuidString,
                        subscriptionGeneration: generation
                    )
                )
            case .inFlight:
                // Let the in-flight subscribe settle; the post-ack desired check
                // below will unsubscribe if it no longer belongs in the window.
                continue
            case .failed, .idle:
                connection.subscriptionRegistry.setDesired(.none, for: sessionId)
            }
        }
    }

    private func orderedSessionIds(
        _ sessionIds: Set<String>,
        connection: ServerConnection,
        focusedFirst: Bool
    ) -> [String] {
        let activityBySessionId = Dictionary(
            uniqueKeysWithValues: connection.sessionStore.sessions.map { session in
                (session.id, session.lastActivity ?? .distantPast)
            }
        )
        let focusedSessionId = connection.focusedSessionId

        return sessionIds.sorted { lhs, rhs in
            if focusedFirst, let focusedSessionId {
                if lhs == focusedSessionId, rhs != focusedSessionId { return true }
                if rhs == focusedSessionId, lhs != focusedSessionId { return false }
            }

            let lhsActivity = activityBySessionId[lhs] ?? .distantPast
            let rhsActivity = activityBySessionId[rhs] ?? .distantPast
            if lhsActivity != rhsActivity {
                return lhsActivity > rhsActivity
            }
            return lhs < rhs
        }
    }

    private func recordResubscribeMetric(
        elapsed: Duration,
        connection: ServerConnection,
        sessionId: String,
        level: StreamSubscriptionLevel,
        reason: String,
        attempt: Int,
        outcome: String,
        errorKind: String? = nil
    ) {
        var tags: [String: String] = [
            "transport": connection.transportPath.rawValue,
            "level": level.rawValue,
            "reason": reason,
            "attempt": String(attempt),
            "outcome": outcome,
        ]
        if let errorKind {
            tags["error_kind"] = errorKind
        }
        recordMetric(.resubscribeMs, value: Int(elapsed / .milliseconds(1)), sessionId: sessionId, tags: tags)
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
