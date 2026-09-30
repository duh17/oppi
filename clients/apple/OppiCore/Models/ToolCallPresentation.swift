import Foundation

struct ToolInputPresentation: Codable, Equatable, Sendable {
    var codeFields: [String: String]
}

/// Status is a string deliberately: a future Pi status must not reject a trace.
struct NestedToolCallRecord: Codable, Equatable, Sendable {
    var id: String
    var name: String
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
