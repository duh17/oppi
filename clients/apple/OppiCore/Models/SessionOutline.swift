import Foundation

/// One lightweight row from `GET .../trace-outline`.
///
/// Server JSON is the source of truth. UIKit-free so iOS and Mac share one
/// decode. Platform views paint; they do not re-parse the payload.
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
}

/// Full-session outline snapshot from `GET .../trace-outline`.
struct SessionOutlineSnapshot: Codable, Equatable, Sendable {
    let traceVersion: String
    let entries: [SessionOutlineEntrySnapshot]
    let itemCount: Int
    let sourceCount: Int
    let jsonlBytes: Int
}

/// Timeline outline chips. Tree/fork navigation stays iOS-only.
enum SessionOutlineFilter: String, CaseIterable, Sendable {
    case all = "All"
    case messages = "Messages"
    case tools = "Tools"
}

/// Filter and search the decoded outline. Mac and tests call this instead of
/// each painter inventing its own `contains` rules.
enum SessionOutlineProjection {
    static func displayedEntries(
        _ entries: [SessionOutlineEntrySnapshot],
        filter: SessionOutlineFilter,
        query: String
    ) -> [SessionOutlineEntrySnapshot] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch filter {
            case .all:
                entry.passesAllFilter
            case .messages:
                entry.isMessage
            case .tools:
                entry.isTool
            }
        }.filter { entry in
            guard !trimmed.isEmpty else { return true }
            if entry.summary.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
            return entry.tool?.localizedCaseInsensitiveContains(trimmed) == true
        }
    }
}
