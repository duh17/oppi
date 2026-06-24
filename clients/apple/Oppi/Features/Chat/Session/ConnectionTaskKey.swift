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
/// Draft review comments are persisted locally by workspace and session.
/// When SwiftUI reuses ChatView for another session in the same workspace,
/// this key must change so the load task refreshes the session-scoped draft list.
struct ReviewCommentLoadKey: Equatable {
    let workspaceId: String?
    let sessionId: String
}
