import Foundation

enum AssistantMarkdownFallbackHeuristics {
    private static let blockPattern = try! NSRegularExpression(
        pattern: #"(?m)^\s{0,3}(?:#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s|```|~~~)"#,
        options: []
    )

    private static let tableDividerPattern = try! NSRegularExpression(
        pattern: #"(?m)^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$"#,
        options: []
    )

    static func shouldFallbackToSwiftUI(_ text: String, isStreaming: Bool) -> Bool {
        guard !isStreaming else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        if blockPattern.firstMatch(in: trimmed, options: [], range: range) != nil {
            return true
        }

        if tableDividerPattern.firstMatch(in: trimmed, options: [], range: range) != nil {
            return true
        }

        return false
    }
}
