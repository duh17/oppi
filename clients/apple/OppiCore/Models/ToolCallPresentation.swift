import Foundation

/// A producer identity fact, never a raw-name parser. Malformed/unknown fields
/// do not reject a tool event; an empty title uses the unchanged raw-name path.
struct ToolDisplay: Codable, Equatable, Sendable {
    var title: String
    var group: String?
    var verbatim: Bool

    init(title: String, group: String? = nil, verbatim: Bool = false) {
        self.title = title
        self.group = group
        self.verbatim = verbatim
    }
    private enum CodingKeys: String, CodingKey { case title, group, verbatim }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        title = (try? c?.decode(String.self, forKey: .title)) ?? ""
        group = try? c?.decodeIfPresent(String.self, forKey: .group)
        verbatim = (try? c?.decode(Bool.self, forKey: .verbatim)) ?? false
    }
    func label(fallback: String) -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        let text = verbatim ? title : Self.humanized(title)
        guard let group, !group.isEmpty else { return text }
        return group + " · " + text
    }
    private static func humanized(_ name: String) -> String {
        let words = name
            .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

struct ToolInputPresentation: Codable, Equatable, Sendable {
    struct Field: Codable, Equatable, Sendable {
        var role: String
        var language: String
    }
    var fields: [String: Field]
}

/// Status is a string deliberately: a future Pi status must not reject a trace.
struct NestedToolCallRecord: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var display: ToolDisplay? = nil
    var arguments: [String: JSONValue]? = nil
    var argumentsBytes: Int? = nil
    var status: String
    var durationMs: Double? = nil
    var error: String? = nil
}

struct NestedToolCalls: Codable, Equatable, Sendable {
    var calls: [NestedToolCallRecord]
    var complete: Bool
}
