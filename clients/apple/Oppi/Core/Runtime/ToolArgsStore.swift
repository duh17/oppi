import Foundation

/// Stores structured tool call arguments keyed by tool call ID.
///
/// Separate from ChatItem to avoid Equatable cost on the `[String: JSONValue]` dict.
/// Tool timeline rows read from this to render tool-specific headers (bash command, file path, etc).
@MainActor @Observable
final class ToolArgsStore {
    private var store: [String: [String: JSONValue]] = [:]

    static let maxPreviewStringBytes = 256 * 1024

    func set(_ args: [String: JSONValue], for id: String) {
        store[id] = args
    }

    func setPreview(_ args: [String: JSONValue], for id: String) {
        store[id] = Self.previewArgs(args)
    }

    func args(for id: String) -> [String: JSONValue]? {
        store[id]
    }

    // periphery:ignore - API surface for granular tool store cleanup
    func clear(itemIDs: Set<String>) {
        guard !itemIDs.isEmpty else { return }
        for id in itemIDs {
            store.removeValue(forKey: id)
        }
    }

    func clearAll() {
        store.removeAll()
    }

    private static func previewArgs(_ args: [String: JSONValue]) -> [String: JSONValue] {
        args.mapValues(previewValue)
    }

    private static func previewValue(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let string):
            guard string.utf8.count > maxPreviewStringBytes else { return value }
            return .string(prefixByUTF8Cap(string, maxBytes: maxPreviewStringBytes))
        case .array(let values):
            return .array(values.map(previewValue))
        case .object(let object):
            return .object(object.mapValues(previewValue))
        case .number, .bool, .null:
            return value
        }
    }

    private static func prefixByUTF8Cap(_ text: String, maxBytes: Int) -> String {
        var out = ""
        out.reserveCapacity(maxBytes)
        var bytes = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard bytes + scalarBytes <= maxBytes else { break }
            out.unicodeScalars.append(scalar)
            bytes += scalarBytes
        }
        return out
    }
}
