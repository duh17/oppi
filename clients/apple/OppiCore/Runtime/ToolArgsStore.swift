import Foundation

/// Stores structured tool call arguments keyed by tool call ID.
///
/// Separate from ChatItem to avoid Equatable cost on the `[String: JSONValue]` dict.
/// Tool timeline rows read from this to render tool-specific headers (bash command, file path, etc).
@MainActor @Observable
final class ToolArgsStore {
    private var store: [String: [String: JSONValue]] = [:]
    private var presentations: [String: ToolInputPresentation] = [:]
    private var displays: [String: ToolDisplay] = [:]
    private var outputs: [String: ToolOutputPresentation] = [:]
    private var availability: [String: ToolOutputAvailability] = [:]
    /// Moves each time a call's arguments are stored. A call's `ChatItem` keeps
    /// only a short argument summary, so a streamed argument that grows past it
    /// (a write's content) leaves the item unchanged; the timeline compares this
    /// to reconfigure the running row and its live reader.
    @ObservationIgnored private var argsRevisions: [String: UInt64] = [:]

    func setOutputPresentation(_ value: ToolOutputPresentation, for id: String) { outputs[id] = value }
    func outputPresentation(for id: String) -> ToolOutputPresentation? { outputs[id] }
    func setOutputAvailability(_ value: ToolOutputAvailability, for id: String) { availability[id] = value }
    func outputAvailability(for id: String) -> ToolOutputAvailability? { availability[id] }

    func setDisplay(_ display: ToolDisplay, for id: String) { displays[id] = display }
    func display(for id: String) -> ToolDisplay? { displays[id] }

    func setInputPresentation(_ presentation: ToolInputPresentation, for id: String) { presentations[id] = presentation }
    func inputPresentation(for id: String) -> ToolInputPresentation? { presentations[id] }

    static let maxPreviewStringBytes = 256 * 1024

    func set(_ args: [String: JSONValue], for id: String) {
        record(args, for: id)
    }

    func setPreview(_ args: [String: JSONValue], for id: String) {
        record(Self.previewArgs(args), for: id)
    }

    /// A replayed update, or a capped preview that no longer grows, stores the
    /// same arguments and keeps the revision.
    private func record(_ args: [String: JSONValue], for id: String) {
        guard store[id] != args else { return }
        store[id] = args
        argsRevisions[id, default: 0] &+= 1
    }

    func args(for id: String) -> [String: JSONValue]? {
        store[id]
    }

    func argsRevision(for id: String) -> UInt64 {
        argsRevisions[id] ?? 0
    }

    func clearAll() {
        store.removeAll()
        argsRevisions.removeAll()
        presentations.removeAll()
        displays.removeAll()
        outputs.removeAll()
        availability.removeAll()
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
