import Foundation

/// Stores structured tool result details keyed by tool call ID.
///
/// Details are forwarded from pi's `tool_execution_end.result.details` through
/// the oppi server's `tool_end` message. They contain per-tool structured data:
/// - bash: `{ exitCode, durationMs }`
/// - read: `{ path, lines, bytes }`
/// - remember: `{ file, redacted }`
/// - recall: `{ matches, scope, topHeader, topScore }`
///
/// Stored externally from ChatItem (like ToolArgsStore) to avoid Equatable cost.
/// Consumed by ToolPresentationBuilder for richer collapsed/expanded rendering.
@MainActor @Observable
final class ToolDetailsStore {
    private var store: [String: JSONValue] = [:]

    func set(_ details: JSONValue, for id: String) {
        store[id] = details
    }

    func details(for id: String) -> JSONValue? {
        store[id]
    }

    func clear(itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        for id in itemIDs {
            store.removeValue(forKey: id)
        }
    }

    func clearAll() {
        store.removeAll()
    }
}
