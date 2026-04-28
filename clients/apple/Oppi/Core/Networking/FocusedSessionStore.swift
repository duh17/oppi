import Foundation

struct FocusedSessionContext: Equatable, Sendable {
    let sessionId: String
    let workspaceId: String?
    let generation: Int
}

@MainActor
final class FocusedSessionStore {
    private(set) var focused: FocusedSessionContext?
    private var generation = 0

    @discardableResult
    func focus(sessionId: String, workspaceId: String?) -> FocusedSessionContext {
        generation += 1
        let context = FocusedSessionContext(
            sessionId: sessionId,
            workspaceId: workspaceId,
            generation: generation
        )
        focused = context
        return context
    }

    func clearIfCurrent(_ context: FocusedSessionContext) {
        guard focused == context else { return }
        focused = nil
    }

    func clearIfCurrent(sessionId: String) {
        guard focused?.sessionId == sessionId else { return }
        focused = nil
    }

    func clear() {
        focused = nil
    }

    func isFocused(_ sessionId: String) -> Bool {
        focused?.sessionId == sessionId
    }
}
