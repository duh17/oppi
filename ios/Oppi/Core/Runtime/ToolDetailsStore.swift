import Foundation

/// Stores structured tool result details keyed by tool event ID.
///
/// `tool_end.details` can carry dynamic UI payloads (e.g. chart specs)
/// and is kept outside `ChatItem` to preserve cheap timeline diffs.
@MainActor @Observable
final class ToolDetailsStore {
    private var store: [String: JSONValue] = [:]

    func set(_ details: JSONValue, for id: String) {
        store[id] = details
    }

    func details(for id: String) -> JSONValue? {
        store[id]
    }

    func remove(for id: String) {
        store.removeValue(forKey: id)
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
