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
    let commandCaption: String
    let outputText: String?
    let outputCaption: String
    let isError: Bool
    let estimatedHeight: Double
}

enum OppiMacTimelineRowBuilder {
    private struct OutputSnippet {
        let text: String
        let truncated: Bool
    }

    private struct FormattedOutput {
        let text: String
        let caption: String
    }

    private struct IndexedToolResult {
        let index: Int
        let item: ReviewTimelineItem
    }

    static func build(from items: [ReviewTimelineItem]) -> [OppiMacTimelineRow] {
        let toolResultBuckets = toolResultBucketsByCorrelationKey(items)
        var consumedToolResultIndices: Set<Int> = []

        var rows: [OppiMacTimelineRow] = []
        rows.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            switch item.kind {
            case .toolCall:
                let key = toolCorrelationKey(for: item)
                let matchedResult = toolResultBuckets[key]?.first {
                    $0.index > index && !consumedToolResultIndices.contains($0.index)
                }

                if let matchedResult {
                    consumedToolResultIndices.insert(matchedResult.index)
                }

                rows.append(buildToolCallRow(callItem: item, resultItem: matchedResult?.item))

            case .toolResult:
                guard !consumedToolResultIndices.contains(index) else {
                    continue
                }
                rows.append(buildStandaloneRow(from: item))

            default:
                rows.append(buildStandaloneRow(from: item))
            }
        }

        return rows
    }

    private static func toolResultBucketsByCorrelationKey(
        _ items: [ReviewTimelineItem]
    ) -> [String: [IndexedToolResult]] {
        var buckets: [String: [IndexedToolResult]] = [:]

        for (index, item) in items.enumerated() where item.kind == .toolResult {
            let key = toolCorrelationKey(for: item)
            buckets[key, default: []].append(.init(index: index, item: item))
        }

        return buckets
    }

    private static func toolCorrelationKey(for item: ReviewTimelineItem) -> String {
        normalizedField(item.metadata["tool_call_id"]) ?? item.id
    }

    private static func buildToolCallRow(
        callItem: ReviewTimelineItem,
        resultItem: ReviewTimelineItem?
    ) -> OppiMacTimelineRow {
        let subtitle = normalizedSubtitle(callItem.preview)
        let commandSection = commandSection(forToolCall: callItem)
        let outputSection = outputSection(forToolResult: resultItem)

        let isError = (resultItem?.metadata["is_error"] == "true") ||
            (callItem.metadata["is_error"] == "true")

        let rowID = resultItem?.id ?? callItem.id
        let toolCallId = normalizedField(callItem.metadata["tool_call_id"]) ??
            normalizedField(resultItem?.metadata["tool_call_id"])

        return OppiMacTimelineRow(
            id: rowID,
            kind: .toolCall,
            symbolName: ReviewTimelineKind.toolCall.symbolName,
            title: callItem.title,
            subtitle: subtitle,
            timestamp: callItem.timestamp,
            toolCallId: toolCallId,
            commandText: commandSection.text,
            commandCaption: commandSection.caption,
            outputText: outputSection.text,
            outputCaption: outputSection.caption,
            isError: isError,
            estimatedHeight: estimatedHeight(
                kind: .toolCall,
                subtitle: subtitle,
                commandText: commandSection.text,
                outputText: outputSection.text
            )
        )
    }

    private static func buildStandaloneRow(from item: ReviewTimelineItem) -> OppiMacTimelineRow {
        let subtitle = normalizedSubtitle(item.preview)
        let toolCallId = normalizedField(item.metadata["tool_call_id"])
        let isError = item.metadata["is_error"] == "true"

        let commandSectionValue: (text: String?, caption: String)
        if item.kind == .toolCall {
            commandSectionValue = commandSection(forToolCall: item)
        } else {
            commandSectionValue = (nil, "Command")
        }

        let outputSectionValue: (text: String?, caption: String)
        if item.kind == .toolResult {
            outputSectionValue = outputSection(forToolResult: item)
        } else {
            outputSectionValue = (nil, "Output")
        }

        return OppiMacTimelineRow(
            id: item.id,
            kind: item.kind,
            symbolName: item.kind.symbolName,
            title: item.title,
            subtitle: subtitle,
            timestamp: item.timestamp,
            toolCallId: toolCallId,
            commandText: commandSectionValue.text,
            commandCaption: commandSectionValue.caption,
            outputText: outputSectionValue.text,
            outputCaption: outputSectionValue.caption,
            isError: isError,
            estimatedHeight: estimatedHeight(
                kind: item.kind,
                subtitle: subtitle,
                commandText: commandSectionValue.text,
                outputText: outputSectionValue.text
            )
        )
    }

    private static func commandSection(forToolCall item: ReviewTimelineItem) -> (text: String?, caption: String) {
        let parsedCommand = extractedToolCommand(from: item)
        let text = parsedCommand ?? normalizedField(item.detail)
        let caption = parsedCommand == nil ? "Arguments" : "Command"
        return (text, caption)
    }

    private static func outputSection(forToolResult item: ReviewTimelineItem?) -> (text: String?, caption: String) {
        guard let item else {
            return (nil, "Output")
        }

        let formatted = formattedToolOutput(item.detail)
        let snippet = snippetForToolOutput(formatted.text)
        let text = normalizedField(snippet.text)
        let caption = snippet.truncated ? "\(formatted.caption) · truncated" : formatted.caption
        return (text, caption)
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

    private static func formattedToolOutput(_ text: String) -> FormattedOutput {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let ansiStripped = stripANSIEscapes(from: normalized)

        if let json = prettyPrintedJSONIfPossible(from: ansiStripped) {
            return .init(text: json, caption: "Output · JSON")
        }

        if looksLikeDiff(ansiStripped) {
            return .init(text: ansiStripped, caption: "Output · Diff")
        }

        if looksLikeMarkdown(ansiStripped) {
            return .init(text: ansiStripped, caption: "Output · Markdown")
        }

        if ansiStripped != normalized {
            return .init(text: ansiStripped, caption: "Output · ANSI")
        }

        return .init(text: ansiStripped, caption: "Output")
    }

    private static func stripANSIEscapes(from text: String) -> String {
        text.replacing(/\u{001B}\[[0-9;]*[A-Za-z]/, with: "")
    }

    private static func prettyPrintedJSONIfPossible(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }

        return pretty
    }

    private static func looksLikeDiff(_ text: String) -> Bool {
        text.contains("diff --git") || text.contains("\n@@")
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.hasPrefix("#") || trimmed.contains("```") {
            return true
        }

        return trimmed.contains("\n- ") || trimmed.contains("\n1. ") || trimmed.contains("\n##")
    }

    private static func snippetForToolOutput(_ text: String) -> OutputSnippet {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard lines.count > 24 else {
            return .init(text: normalized, truncated: false)
        }

        let head = lines.prefix(6)
        let tail = lines.suffix(8)
        let omitted = lines.count - head.count - tail.count
        let compact = (head + ["… \(omitted) lines omitted …"] + tail).joined(separator: "\n")

        return .init(text: compact, truncated: true)
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
