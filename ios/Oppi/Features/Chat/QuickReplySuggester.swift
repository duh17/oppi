import Foundation
import SwiftUI

enum QuickReplySuggester {
    static let maxSuggestions = 4

    private static let maxTailTokensForPrompt = 200
    private static let maxCandidateLength = 96

    private static let inlineTodoRegex = try? NSRegularExpression(
        pattern: #"(?i)(?:todo|action item|next step)s?\s*:\s*(.+)$"#
    )
    private static let checklistRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s+)?\[[ xX]\]\s+(.+)$"#
    )
    private static let listItemRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*]\s+|\d+[\).]\s+)(.+)$"#
    )

    static func suggestions(
        forAssistantText assistantText: String,
        recentUserReplies _: [String],
        limit: Int = maxSuggestions
    ) -> [String] {
        suggestions(
            forAssistantText: assistantText,
            recentUserReplies: [],
            modelCandidates: [],
            limit: limit
        )
    }

    static func suggestions(
        forAssistantText assistantText: String,
        recentUserReplies _: [String],
        modelCandidates: [String],
        limit: Int = maxSuggestions
    ) -> [String] {
        guard limit > 0 else { return [] }

        let heuristicTodos = extractTodoCandidates(fromAssistantText: assistantText, limit: limit)

        if modelCandidates.isEmpty {
            return Array(heuristicTodos.prefix(limit))
        }

        let merged = sanitizeCandidates(modelCandidates + heuristicTodos)
        return Array(merged.prefix(limit))
    }

    static func shouldAttemptModelTodoExtraction(forAssistantText assistantText: String) -> Bool {
        let tail = assistantTailPreservingLines(assistantText, maxTokens: maxTailTokensForPrompt)
        let normalizedTail = normalizeKey(tail)
        guard !normalizedTail.isEmpty else { return false }

        let markers = ["todo", "todos", "next step", "next steps", "action item", "action items"]
        if markers.contains(where: { normalizedTail.contains($0) }) {
            return true
        }

        return tail.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil
    }

    static func makeModelPrompt(
        forAssistantText assistantText: String,
        recentUserReplies _: [String],
        limit: Int = maxSuggestions
    ) -> String {
        let requestedCount = min(max(limit, 1), 6)
        let tail = assistantTailPreservingLines(assistantText, maxTokens: maxTailTokensForPrompt)

        return """
        Extract up to \(requestedCount) actionable TODO items from the assistant response tail below.
        Use only TODOs that appear in the text.
        If there are no TODOs, return exactly: NONE

        Output rules:
        - one TODO per line
        - no numbering
        - no bullets
        - no quotes

        Assistant response tail (last \(maxTailTokensForPrompt) tokens):
        \(tail)
        """
    }

    static func parseModelOutput(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if normalizeKey(trimmed) == "none" {
            return []
        }

        if let data = trimmed.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            let sanitized = sanitizeCandidates(array)
            if sanitized.count == 1, normalizeKey(sanitized[0]) == "none" {
                return []
            }
            return sanitized
        }

        var parts = trimmed
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)

        if parts.count <= 1 {
            for delimiter in ["||", "|", ";", "•"] {
                let split = trimmed
                    .components(separatedBy: delimiter)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if split.count > 1 {
                    parts = split
                    break
                }
            }
        }

        let sanitized = sanitizeCandidates(parts)
        if sanitized.count == 1, normalizeKey(sanitized[0]) == "none" {
            return []
        }
        return sanitized
    }

    private static func extractTodoCandidates(fromAssistantText assistantText: String, limit: Int) -> [String] {
        let tail = assistantTailPreservingLines(assistantText, maxTokens: maxTailTokensForPrompt)
        guard !tail.isEmpty else { return [] }

        let lines = tail
            .split(maxSplits: .max, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map(String.init)

        var candidates: [String] = []
        var inTodoSection = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                inTodoSection = false
                continue
            }

            let normalized = normalizeKey(line)

            if isTodoHeading(normalized) {
                inTodoSection = true
                if let inlineTodo = extractInlineTodo(from: line) {
                    candidates.append(inlineTodo)
                }
                continue
            }

            if let checklistItem = extractChecklistItem(from: line) {
                candidates.append(checklistItem)
                continue
            }

            if let inlineTodo = extractInlineTodo(from: line) {
                candidates.append(inlineTodo)
                continue
            }

            if inTodoSection,
               let listItem = extractListItem(from: line) {
                candidates.append(listItem)
                continue
            }
        }

        return Array(sanitizeCandidates(candidates).prefix(limit))
    }

    private static func assistantTailPreservingLines(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lines = trimmed.components(separatedBy: .newlines)
        var selected: [String] = []
        var tokenCount = 0

        for line in lines.reversed() {
            let lineTokenCount = line.split(whereSeparator: { $0.isWhitespace }).count

            if selected.isEmpty, lineTokenCount > maxTokens {
                selected.append(tailTokens(of: line, maxTokens: maxTokens))
                tokenCount = maxTokens
                break
            }

            if tokenCount >= maxTokens {
                break
            }

            if tokenCount + lineTokenCount > maxTokens, !selected.isEmpty {
                break
            }

            selected.append(line)
            tokenCount += lineTokenCount
        }

        return selected
            .reversed()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tailTokens(of line: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }

        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count > maxTokens else { return line }
        return tokens.suffix(maxTokens).joined(separator: " ")
    }

    private static func isTodoHeading(_ normalizedLine: String) -> Bool {
        let markers = ["todo", "todos", "next step", "next steps", "action item", "action items"]

        for marker in markers {
            if normalizedLine == marker || normalizedLine == "\(marker):" || normalizedLine.hasPrefix("\(marker):") {
                return true
            }
        }

        return false
    }

    private static func extractInlineTodo(from line: String) -> String? {
        guard let captured = extractFirstCapture(in: line, using: inlineTodoRegex) else {
            return nil
        }

        let normalized = normalizeKey(captured)
        guard !normalized.isEmpty else { return nil }
        guard !normalized.hasPrefix("/") else { return nil }
        guard !normalized.contains("`") else { return nil }

        let nestedMarkers = ["todo:", "action item:", "next step:"]
        guard !nestedMarkers.contains(where: { normalized.contains($0) }) else {
            return nil
        }

        return captured
    }

    private static func extractChecklistItem(from line: String) -> String? {
        extractFirstCapture(in: line, using: checklistRegex)
    }

    private static func extractListItem(from line: String) -> String? {
        extractFirstCapture(in: line, using: listItemRegex)
    }

    private static func extractFirstCapture(in line: String, using regex: NSRegularExpression?) -> String? {
        guard let regex else { return nil }

        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }

        let captureRange = match.range(at: 1)
        guard captureRange.location != NSNotFound else { return nil }
        return nsLine.substring(with: captureRange)
    }

    private static func sanitizeCandidates(_ values: [String]) -> [String] {
        var output: [String] = []
        output.reserveCapacity(values.count)

        var seen = Set<String>()

        for value in values {
            guard let cleaned = cleanCandidate(value) else { continue }
            let key = normalizeKey(cleaned)
            guard !seen.contains(key) else { continue }

            seen.insert(key)
            output.append(cleaned)
        }

        return output
    }

    private static func cleanCandidate(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = text.replacingOccurrences(
            of: #"^\s*(?:[-*•]\s+|\d+[\).]\s+|\[[ xX]\]\s+)"#,
            with: "",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: #"(?i)^\s*(?:todo|action item|next step)s?\s*:\s*"#,
            with: "",
            options: .regularExpression
        )

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’[]()* "))
        text = collapseWhitespace(text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))

        guard !text.isEmpty else { return nil }

        if text.count > maxCandidateLength {
            text = String(text.prefix(maxCandidateLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let normalized = normalizeKey(text)
        guard !normalized.isEmpty else { return nil }
        guard normalized != "none", normalized != "n/a", normalized != "na" else { return nil }
        guard !looksLikeMetaInstruction(normalized) else { return nil }

        return text
    }

    private static func looksLikeMetaInstruction(_ normalized: String) -> Bool {
        let blockedFragments = [
            "todo-only extraction",
            "only extraction",
            "updated ios/",
            "supports:",
            "action item:",
            "next step:",
        ]

        if blockedFragments.contains(where: { normalized.contains($0) }) {
            return true
        }

        if normalized == "description" || normalized.hasPrefix("description ") {
            return true
        }

        if normalized.hasPrefix("/") || normalized.contains("/ `") {
            return true
        }

        return false
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func normalizeKey(_ text: String) -> String {
        collapseWhitespace(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct QuickReplySuggestionList: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "checklist.unchecked")
                                .font(.caption2)
                                .foregroundStyle(.tokyoCyan)
                            Text("TODO")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tokyoCyan)
                            Spacer(minLength: 0)
                            Text("Description")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tokyoComment)
                        }

                        Text(suggestion)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tokyoFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.quickReply.\(index)")
            }
        }
        .accessibilityIdentifier("chat.quickReplies")
    }
}

struct QuickReplySuggestionLoadingRow: View {
    @State private var pulse = 0.45

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .opacity(pulse)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
        .accessibilityIdentifier("chat.quickReplies.loading")
    }
}
