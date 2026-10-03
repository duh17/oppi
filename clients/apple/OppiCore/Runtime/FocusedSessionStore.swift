import Foundation

/// Focused-session routing target. `generation` doubles as the ownership claim
/// a chat runtime holds: only the holder of the current context may release it.
struct FocusedSessionContext: Equatable, Sendable {
    let sessionId: String
    let generation: Int
}

@MainActor
final class FocusedSessionStore {
    private(set) var focused: FocusedSessionContext?
    private var generation = 0

    /// Route commands to `sessionId`. Re-routing to the already focused session
    /// keeps its context so an owner's claim survives routine re-binds
    /// (stream open, re-entry); a different session gets a new context.
    @discardableResult
    func focus(sessionId: String) -> FocusedSessionContext {
        if let focused, focused.sessionId == sessionId {
            return focused
        }
        return claim(sessionId: sessionId)
    }

    /// Start a new ownership claim for `sessionId`, even if it is already
    /// focused. Any older claim on the same session stops matching.
    @discardableResult
    func claim(sessionId: String) -> FocusedSessionContext {
        generation += 1
        let context = FocusedSessionContext(
            sessionId: sessionId,
            generation: generation
        )
        focused = context
        return context
    }

    func clear() {
        focused = nil
    }

    func isFocused(_ sessionId: String) -> Bool {
        focused?.sessionId == sessionId
    }

    func isCurrent(_ claim: FocusedSessionContext) -> Bool {
        focused == claim
    }
}
