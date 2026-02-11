import Foundation

struct OppiMacTimelineRow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ReviewTimelineKind
    let symbolName: String
    let title: String
    let subtitle: String
    let timestamp: Date
    let toolCallId: String?
    let commandText: String?
    let outputText: String?
    let isError: Bool
    let estimatedHeight: Double
}

enum OppiMacTimelineRowBuilder {
    static func build(from items: [ReviewTimelineItem]) -> [OppiMacTimelineRow] {
        items.map { item in
            let subtitle = normalizedSubtitle(item.preview)
            let toolCallId = normalizedField(item.metadata["tool_call_id"])

            let commandText: String?
            if item.kind == .toolCall {
                commandText = extractedToolCommand(from: item) ?? normalizedField(item.detail)
            } else {
                commandText = nil
            }

            let outputText: String?
            if item.kind == .toolResult {
                outputText = normalizedField(snippetForToolOutput(item.detail))
            } else {
                outputText = nil
            }

            let isError = item.metadata["is_error"] == "true"

            return OppiMacTimelineRow(
                id: item.id,
                kind: item.kind,
                symbolName: item.kind.symbolName,
                title: item.title,
                subtitle: subtitle,
                timestamp: item.timestamp,
                toolCallId: toolCallId,
                commandText: commandText,
                outputText: outputText,
                isError: isError,
                estimatedHeight: estimatedHeight(
                    kind: item.kind,
                    subtitle: subtitle,
                    commandText: commandText,
                    outputText: outputText
                )
            )
        }
    }

    private static func normalizedSubtitle(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    private static func normalizedField(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func extractedToolCommand(from item: ReviewTimelineItem) -> String? {
        guard let detailData = item.detail.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any]
        else {
            return nil
        }

        if let command = json["command"] as? String {
            return command
        }

        if let args = json["args"] as? [String: Any],
           let command = args["command"] as? String {
            return command
        }

        if let input = json["input"] as? [String: Any],
           let command = input["command"] as? String {
            return command
        }

        return nil
    }

    private static func snippetForToolOutput(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard lines.count > 24 else {
            return normalized
        }

        let head = lines.prefix(6)
        let tail = lines.suffix(8)
        let omitted = lines.count - head.count - tail.count

        return (head + ["… \(omitted) lines omitted …"] + tail).joined(separator: "\n")
    }

    private static func estimatedHeight(
        kind: ReviewTimelineKind,
        subtitle: String,
        commandText: String?,
        outputText: String?
    ) -> Double {
        var height: Double = 30

        if kind == .toolCall || kind == .toolResult {
            height += 12
        } else {
            height += Double(min(3, approxLineCount(subtitle, charsPerLine: 94))) * 13
        }

        if let commandText {
            height += 10
            height += 14
            height += Double(min(4, approxLineCount(commandText, charsPerLine: 110))) * 14
        }

        if let outputText {
            height += 10
            height += 14
            height += Double(min(6, approxLineCount(outputText, charsPerLine: 115))) * 13
        }

        height += 12

        return min(max(height, 58), 250)
    }

    private static func approxLineCount(_ text: String, charsPerLine: Int) -> Int {
        guard !text.isEmpty else { return 1 }

        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lines = 0
        for paragraph in paragraphs {
            let count = paragraph.count
            lines += max(1, Int(ceil(Double(count) / Double(charsPerLine))))
        }
        return max(lines, 1)
    }
}
