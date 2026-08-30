import Foundation

/// Platform-neutral stream decision for entering a focused session.
enum FocusedSessionConnectionAction: Equatable, Sendable {
    case openStream
    case refreshHistoryBeforeStreamDecision
    case remainHistoryOnly
}

/// Prevents a focused stream from implicitly resuming a stopped session.
enum FocusedSessionConnectionPolicy {
    static func initialAction(for status: SessionStatus?) -> FocusedSessionConnectionAction {
        status == .stopped ? .refreshHistoryBeforeStreamDecision : .openStream
    }

    static func actionAfterHistoryRefresh(for status: SessionStatus?) -> FocusedSessionConnectionAction {
        status == .stopped ? .remainHistoryOnly : .openStream
    }
}
