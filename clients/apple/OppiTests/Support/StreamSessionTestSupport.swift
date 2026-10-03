import Foundation
@testable import Oppi

/// Claimless stream-open conveniences for transport tests that do not model a
/// chat runtime. Production opens only with the runtime's focus claim; these
/// helpers reproduce the old routing semantics: keep the current context when
/// the session is already focused, otherwise focus it (honoring the
/// external-open block, which then refuses the open as before).
@MainActor
func testStreamClaim(_ connection: ServerConnection, sessionId: String) -> FocusedSessionContext {
    if let focused = connection.focusedSessionStore.focused, focused.sessionId == sessionId {
        return focused
    }
    return connection.claimFocusedSession(sessionId)
        ?? FocusedSessionContext(sessionId: sessionId, generation: -1)
}

extension ServerConnection {
    func streamSession(_ sessionId: String, workspaceId: String) async -> AsyncStream<SessionStreamEvent>? {
        await streamSession(sessionId, routeScope: .workspace(workspaceId))
    }

    func streamSession(_ sessionId: String, routeScope: SessionRouteScope) async -> AsyncStream<SessionStreamEvent>? {
        await streamSession(sessionId, routeScope: routeScope, claim: testStreamClaim(self, sessionId: sessionId))
    }
}

extension SessionStreamCoordinator {
    func streamSession(
        connection: ServerConnection,
        sessionId: String,
        workspaceId: String
    ) async -> AsyncStream<SessionStreamEvent>? {
        await streamSession(connection: connection, sessionId: sessionId, routeScope: .workspace(workspaceId))
    }

    func streamSession(
        connection: ServerConnection,
        sessionId: String,
        routeScope: SessionRouteScope
    ) async -> AsyncStream<SessionStreamEvent>? {
        await streamSession(
            connection: connection,
            claim: testStreamClaim(connection, sessionId: sessionId),
            sessionId: sessionId,
            routeScope: routeScope
        )
    }
}
