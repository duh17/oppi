/// Composite key for ChatView's session connection `.task(id:)`.
///
/// Includes both `sessionId` and `connectionGeneration` so the task
/// re-fires when either changes:
/// - sessionId changes → view reused for a different session (onChange self-healing)
/// - generation changes → reconnect after network drop
///
/// Without sessionId in the key, two consecutive managers both start at
/// generation 0 — SwiftUI sees the same id and silently skips reconnection
/// for the new session, leaving the timeline blank.
struct ConnectionTaskKey: Equatable {
    let sessionId: String
    let generation: Int
}

/// Composite key for ChatView's local review-comment load task.
///
/// Draft review comments are persisted by a local scope and session. Workspace
/// sessions use their workspace ID; declared control sessions use a fixed local
/// scope because they intentionally have no workspace owner.
struct ReviewCommentLoadKey: Equatable {
    let localScopeId: String?
    let sessionId: String

    init(localScopeId: String?, sessionId: String) {
        self.localScopeId = localScopeId
        self.sessionId = sessionId
    }

    init(workspaceId: String?, sessionId: String) {
        self.init(localScopeId: workspaceId, sessionId: sessionId)
    }
}
