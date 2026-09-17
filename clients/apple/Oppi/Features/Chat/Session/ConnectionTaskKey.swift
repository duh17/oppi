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
