import Foundation

/// Stores structured tool call arguments keyed by tool call ID.
///
/// Separate from ChatItem to avoid Equatable cost on the `[String: JSONValue]` dict.
/// ToolCallRow reads from this to render tool-specific headers (bash command, file path, etc).
@MainActor @Observable
final class ToolArgsStore {
    private var store: [String: [String: JSONValue]] = [:]

    func set(_ args: [String: JSONValue], for id: String) {
        store[id] = args
    }

    func args(for id: String) -> [String: JSONValue]? {
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
