import Foundation

struct OppiMacInspectorMetadataRow: Equatable, Sendable {
    let key: String
    let value: String
}

struct OppiMacInspectorDocument: Equatable, Sendable {
    let title: String
    let timestamp: Date
    let detailTitle: String
    let detailText: String
    let metadataRows: [OppiMacInspectorMetadataRow]
}

enum OppiMacInspectorDocumentBuilder {
    static func build(from item: ReviewTimelineItem) -> OppiMacInspectorDocument {
        OppiMacInspectorDocument(
            title: item.title,
            timestamp: item.timestamp,
            detailTitle: detailTitle(for: item.kind),
            detailText: normalizedDetail(item.detail),
            metadataRows: item.metadata
                .map { OppiMacInspectorMetadataRow(key: $0.key, value: $0.value) }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        )
    }

    private static func detailTitle(for kind: ReviewTimelineKind) -> String {
        switch kind {
        case .toolCall:
            return "Arguments"
        case .toolResult:
            return "Output"
        case .thinking:
            return "Reasoning"
        default:
            return "Detail"
        }
    }

    private static func normalizedDetail(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : detail
    }
}
