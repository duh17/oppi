import Foundation

enum ReviewTimelineKind: String, CaseIterable, Identifiable, Sendable {
    case user
    case assistant
    case thinking
    case toolCall
    case toolResult
    case system
    case compaction

    var id: String { rawValue }

    var label: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .thinking: return "Thinking"
        case .toolCall: return "Tool call"
        case .toolResult: return "Tool output"
        case .system: return "System"
        case .compaction: return "Compaction"
        }
    }
}

struct ReviewTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ReviewTimelineKind
    let timestamp: Date
    let title: String
    let preview: String
    let detail: String
    let metadata: [String: String]
}

enum ReviewTimelineBuilder {
    private static let previewLimit = 220

    static func build(from events: [TraceEvent]) -> [ReviewTimelineItem] {
        return events.map { event in
            let timestamp = parseTimestamp(event.timestamp) ?? Date.distantPast
            let kind = mapKind(event.type)
            let title = buildTitle(for: event, kind: kind)
            let preview = buildPreview(for: event, kind: kind)
            let detail = buildDetail(for: event, kind: kind)
            let metadata = buildMetadata(for: event)

            return ReviewTimelineItem(
                id: event.id,
                kind: kind,
                timestamp: timestamp,
                title: title,
                preview: preview,
                detail: detail,
                metadata: metadata
            )
        }
    }

    static func matches(_ item: ReviewTimelineItem, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }

        let lowerNeedle = needle.lowercased()
        if item.title.lowercased().contains(lowerNeedle) { return true }
        if item.preview.lowercased().contains(lowerNeedle) { return true }
        if item.detail.lowercased().contains(lowerNeedle) { return true }

        return item.metadata.contains { key, value in
            key.lowercased().contains(lowerNeedle) || value.lowercased().contains(lowerNeedle)
        }
    }

    private static func mapKind(_ type: TraceEventType) -> ReviewTimelineKind {
        switch type {
        case .user: return .user
        case .assistant: return .assistant
        case .thinking: return .thinking
        case .toolCall: return .toolCall
        case .toolResult: return .toolResult
        case .system: return .system
        case .compaction: return .compaction
        }
    }

    private static func buildTitle(for event: TraceEvent, kind: ReviewTimelineKind) -> String {
        switch kind {
        case .toolCall:
            return "Tool call: \(event.tool ?? "unknown")"
        case .toolResult:
            if event.isError == true {
                return "Tool output (error)"
            }
            if let name = event.toolName, !name.isEmpty {
                return "Tool output: \(name)"
            }
            return kind.label
        default:
            return kind.label
        }
    }

    private static func buildPreview(for event: TraceEvent, kind: ReviewTimelineKind) -> String {
        switch kind {
        case .user, .assistant, .system:
            return clippedPreview(event.text ?? "")

        case .thinking:
            return clippedPreview(event.thinking ?? "")

        case .toolCall:
            guard let args = event.args, !args.isEmpty else {
                return "No arguments"
            }
            let summary = args
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.summary(maxLength: 48))" }
                .joined(separator: ", ")
            return clippedPreview(summary)

        case .toolResult:
            let output = event.output ?? ""
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "(empty output)"
            }
            return clippedPreview(output)

        case .compaction:
            return clippedPreview(event.text ?? "Context compacted")
        }
    }

    private static func buildDetail(for event: TraceEvent, kind: ReviewTimelineKind) -> String {
        switch kind {
        case .toolCall:
            guard let args = event.args, !args.isEmpty else {
                return "No arguments"
            }
            return prettyPrintedJSON(args) ?? "No arguments"

        case .toolResult:
            return event.output ?? ""

        case .thinking:
            return event.thinking ?? ""

        default:
            return event.text ?? ""
        }
    }

    private static func buildMetadata(for event: TraceEvent) -> [String: String] {
        var metadata: [String: String] = [
            "event_id": event.id,
            "timestamp": event.timestamp,
            "type": event.type.rawValue,
        ]

        if let tool = event.tool, !tool.isEmpty {
            metadata["tool"] = tool
        }
        if let toolName = event.toolName, !toolName.isEmpty {
            metadata["tool_name"] = toolName
        }
        if let toolCallId = event.toolCallId, !toolCallId.isEmpty {
            metadata["tool_call_id"] = toolCallId
        }
        if let isError = event.isError {
            metadata["is_error"] = isError ? "true" : "false"
        }

        return metadata
    }

    private static func clippedPreview(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if compact.isEmpty {
            return "(empty)"
        }

        if compact.count <= previewLimit {
            return compact
        }

        return String(compact.prefix(previewLimit - 1)) + "…"
    }

    private static func prettyPrintedJSON(_ value: [String: JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else {
            return nil
        }

        return text
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractionalFormatter.date(from: text) {
            return date
        }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: text)
    }
}

extension ReviewTimelineKind {
    var symbolName: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .thinking: return "brain"
        case .toolCall: return "hammer"
        case .toolResult: return "terminal"
        case .system: return "gearshape"
        case .compaction: return "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}
