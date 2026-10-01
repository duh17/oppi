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

    init(fields: [String: Field]) { self.fields = fields }
    private enum CodingKeys: String, CodingKey { case fields }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        fields = (try? c?.decode([String: Field].self, forKey: .fields)) ?? [:]
    }
}

/// Unknown semantics degrade to the generic document, never a name fallback.
struct ToolOutputPresentation: Codable, Equatable, Sendable {
    var kind: String
    init(kind: String) { self.kind = kind }
    private enum CodingKeys: String, CodingKey { case kind }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c?.decode(String.self, forKey: .kind)) ?? ""
    }
}

struct ToolOutputAvailability: Codable, Equatable, Sendable {
    var complete: Bool
    var totalBytes: Int? = nil
    var source: String? = nil
    var hasSidecar: Bool { source == "sidecar" }
    init(complete: Bool, totalBytes: Int? = nil, source: String? = nil) {
        self.complete = complete
        self.totalBytes = totalBytes
        self.source = source
    }
    private enum CodingKeys: String, CodingKey { case complete, totalBytes, source }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        complete = (try? c?.decode(Bool.self, forKey: .complete)) ?? false
        totalBytes = try? c?.decode(Int.self, forKey: .totalBytes)
        if let bytes = totalBytes, bytes < 0 { totalBytes = nil }
        source = try? c?.decode(String.self, forKey: .source)
    }
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
