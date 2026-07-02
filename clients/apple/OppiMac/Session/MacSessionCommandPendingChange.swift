import Foundation

/// Tracks optimistic Mac-only header updates while the server command is in flight.
///
/// WebSocket command failures arrive asynchronously as `command_result`, so the
/// selected-session store needs enough information to undo only the value it
/// optimistically applied. The rollback is intentionally conditional: if a newer
/// state update or user action already changed the same field, stale failures do
/// not clobber that newer value.
enum MacSessionCommandPendingChange: Equatable, Sendable {
    case model(previous: String?, optimistic: String)
    case thinking(previous: String?, optimistic: String)

    var displayName: String {
        switch self {
        case .model:
            "Model"
        case .thinking:
            "Thinking level"
        }
    }

    @discardableResult
    func rollbackIfStillOptimistic(session: inout Session?) -> Bool {
        switch self {
        case .model(let previous, let optimistic):
            guard session?.model == optimistic else { return false }
            session?.model = previous
            return true
        case .thinking(let previous, let optimistic):
            guard session?.thinkingLevel == optimistic else { return false }
            session?.thinkingLevel = previous
            return true
        }
    }
}
