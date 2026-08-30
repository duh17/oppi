import Foundation

/// iOS compatibility surface for the shared `ChatSessionManager` runtime.
///
/// Existing callers keep the same type name and connection/store arguments;
/// this layer only binds those app services to the three OppiCore ports.
extension ChatSessionManager {
    convenience init(
        sessionId: String,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil
    ) {
        let adapter = IOSChatSessionRuntimeAdapter()
        self.init(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: routeScope,
            historyPort: adapter,
            focusedStreamPort: adapter,
            effectsStatePort: adapter,
            reducer: TimelineReducer(environment: .app()),
            coalescer: DeltaCoalescer(telemetry: .appMetrics)
        )
    }

    func connect(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async {
        bindIOSRuntime(connection: connection, sessionStore: sessionStore)
        await connect()
    }

    func reloadTimelineAfterPresentationOverflow(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) {
        bindIOSRuntime(connection: connection, sessionStore: sessionStore)
        reloadTimelineAfterPresentationOverflow()
    }

    func reconcileAfterStop(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) {
        bindIOSRuntime(connection: connection, sessionStore: sessionStore)
        reconcileAfterStop()
    }

    func flushSnapshotIfNeeded(
        connection: ServerConnection,
        force: Bool = false
    ) async {
        bindIOSRuntime(
            connection: connection,
            sessionStore: connection.sessionStore
        )
        await flushSnapshotIfNeeded(force: force)
    }

    @discardableResult
    func loadOlderTracePage(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> Bool {
        bindIOSRuntime(connection: connection, sessionStore: sessionStore)
        return await loadOlderTracePage()
    }

    @discardableResult
    func loadTracePageAround(
        entryId: String,
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> Bool {
        bindIOSRuntime(connection: connection, sessionStore: sessionStore)
        return await loadTracePageAround(entryId: entryId)
    }

    @discardableResult
    func forceHistoryReload(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) async -> Bool {
        bindIOSRuntime(connection: connection, sessionStore: sessionStore)
        return await forceHistoryReload()
    }

    private func bindIOSRuntime(
        connection: ServerConnection,
        sessionStore: SessionStore
    ) {
        guard let adapter = historyPort as? IOSChatSessionRuntimeAdapter else {
            preconditionFailure("ChatSessionManager was not constructed with the iOS runtime adapter")
        }
        adapter.bind(connection: connection, sessionStore: sessionStore)
    }
}
