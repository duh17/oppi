import Foundation
@testable import Oppi

@MainActor
final class ServerConnectionScenario {
    let connection: ServerConnection
    let activeSessionId: String
    private let pipe: TestEventPipeline

    /// Per-session pipeline for tests — mirrors ChatSessionManager ownership.
    var reducer: TimelineReducer { pipe.reducer }

    init(sessionId: String = "s1") {
        let testConnection = makeTestConnection(sessionId: sessionId)
        self.connection = testConnection.conn
        self.pipe = testConnection.pipe
        self.activeSessionId = sessionId
    }

    @discardableResult
    func givenStoredSession(
        id: String? = nil,
        status: SessionStatus,
        workspaceId: String? = nil,
        thinkingLevel: String? = nil
    ) -> Self {
        connection.sessionStore.upsert(
            makeTestSession(
                id: id ?? activeSessionId,
                workspaceId: workspaceId,
                status: status,
                thinkingLevel: thinkingLevel
            )
        )
        return self
    }

    @discardableResult
    func whenHandle(
        _ message: ServerMessage,
        sessionId: String? = nil,
        flushAfter: Bool = false
    ) -> Self {
        let sid = sessionId ?? activeSessionId
        if sid == activeSessionId {
            pipe.handle(message, sessionId: sid)
        } else {
            _ = connection.applySharedStoreUpdate(for: message, sessionId: sid)
        }
        if flushAfter {
            pipe.flushNow()
        }
        return self
    }

    @discardableResult
    func whenFlush() -> Self {
        pipe.flushNow()
        return self
    }

    func firstSessionStatus() -> SessionStatus? {
        connection.sessionStore.sessions.first?.status
    }

    func timelineItemCount(of kind: ScenarioTimelineItemKind) -> Int {
        reducer.items.filter { item in
            switch kind {
            case .assistantMessage:
                if case .assistantMessage = item { return true }
            case .systemEvent:
                if case .systemEvent = item { return true }
            case .error:
                if case .error = item { return true }
            case .thinking:
                if case .thinking = item { return true }
            case .toolCall:
                if case .toolCall = item { return true }
            }
            return false
        }.count
    }

}

enum ScenarioTimelineItemKind {
    case assistantMessage
    case systemEvent
    case error
    case thinking
    case toolCall
}
