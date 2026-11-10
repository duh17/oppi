import Foundation

/// One lightweight row from `GET .../trace-outline`.
///
/// Server JSON is the source of truth. Views paint; they do not re-parse the
/// payload.
struct SessionOutlineEntrySnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let summary: String
    let timestamp: String
    let isMessage: Bool
    let isTool: Bool
    let passesAllFilter: Bool
    let isForkable: Bool?
    let tool: String?
    let isError: Bool?
    // Bounded producer facts for rows outside the local trace window.
    var args: [String: JSONValue]? = nil
    var details: JSONValue? = nil
    var display: ToolDisplay? = nil
    var inputPresentation: ToolInputPresentation? = nil
    var outputPresentation: ToolOutputPresentation? = nil
}

/// Full-session outline snapshot from `GET .../trace-outline`.
struct SessionOutlineSnapshot: Codable, Equatable, Sendable {
    let traceVersion: String
    let entries: [SessionOutlineEntrySnapshot]
    let itemCount: Int
    let sourceCount: Int
    let jsonlBytes: Int
}
