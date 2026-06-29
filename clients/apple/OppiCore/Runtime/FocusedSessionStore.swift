import Foundation

struct FocusedSessionContext: Equatable, Sendable {
    let sessionId: String
    let generation: Int
}

@MainActor
final class FocusedSessionStore {
    private(set) var focused: FocusedSessionContext?
    private var generation = 0

    @discardableResult
    func focus(sessionId: String) -> FocusedSessionContext {
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
}
