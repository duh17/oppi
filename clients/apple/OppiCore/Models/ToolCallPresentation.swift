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
        var language: String? = nil
        private enum CodingKeys: String, CodingKey { case role, language }
        init(role: String, language: String? = nil) { self.role = role; self.language = language }
        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            role = (try? c?.decode(String.self, forKey: .role)) ?? ""
            language = try? c?.decode(String.self, forKey: .language)
        }
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
    var provenance: String? = nil
    var isInteractive: Bool { kind == "interactive" }
    var settingEffect: String? = nil
    /// Producer-declared pattern for a status preamble at the start of the
    /// output. The row already shows status and duration, so readers may hide it.
    var statusHeader: String? = nil
    init(kind: String, provenance: String? = nil, settingEffect: String? = nil, statusHeader: String? = nil) {
        self.kind = kind; self.provenance = provenance; self.settingEffect = settingEffect
        self.statusHeader = statusHeader
    }
    private enum CodingKeys: String, CodingKey { case kind, provenance, settingEffect, statusHeader }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c?.decode(String.self, forKey: .kind)) ?? ""
        provenance = try? c?.decode(String.self, forKey: .provenance)
        settingEffect = try? c?.decode(String.self, forKey: .settingEffect)
        statusHeader = try? c?.decode(String.self, forKey: .statusHeader)
    }

    /// Output without the declared status preamble. Only a match anchored at
    /// the start counts, and only the first 512 characters are searched.
    func hidingStatusHeader(in output: String) -> String {
        guard let statusHeader, !statusHeader.isEmpty,
              let regex = try? NSRegularExpression(pattern: "^(?:" + statusHeader + ")") else { return output }
        let head = String(output.prefix(512))
        guard let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              match.range.length > 0,
              let range = Range(match.range, in: head) else { return output }
        return String(output.dropFirst(head[..<range.upperBound].count))
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

    /// "3 calls · 1 failed · 1 running": one line for the collapsed row and the Calls section.
    /// Statuses are open strings; anything but ok/error/running is only counted as a call.
    var summary: String {
        let failed = calls.filter { $0.status == "error" }.count
        let running = calls.filter { $0.status == "running" }.count
        var parts = ["\(calls.count) \(calls.count == 1 ? "call" : "calls")"]
        if failed > 0 { parts.append("\(failed) failed") }
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ")
    }
}
