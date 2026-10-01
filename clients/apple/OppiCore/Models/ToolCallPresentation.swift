import Foundation

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
