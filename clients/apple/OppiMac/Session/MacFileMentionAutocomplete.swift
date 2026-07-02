import Foundation

struct MacFileMentionSuggestion: Identifiable, Sendable, Equatable {
    let path: String
    let score: Int

    var id: String { path }

    var displayName: String {
        (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }

    var parentPath: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent + "/"
    }
}

enum MacFileMentionAutocomplete {
    static func activeToken(in text: String) -> String? {
        guard let last = text.last, !last.isWhitespace,
              let token = text.split(whereSeparator: { $0.isWhitespace }).last.map(String.init),
              token.hasPrefix("@") else {
            return nil
        }
        return String(token.dropFirst())
    }

    static func suggestions(
        for query: String,
        paths: [String],
        limit: Int = 8
    ) -> [MacFileMentionSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return paths
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count < rhs.count }
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
                .prefix(limit)
                .map { MacFileMentionSuggestion(path: $0, score: 0) }
        }

        return paths.compactMap { path -> MacFileMentionSuggestion? in
            guard let score = score(query: trimmed, candidate: path) else { return nil }
            return MacFileMentionSuggestion(path: path, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    static func insert(_ suggestion: MacFileMentionSuggestion, into text: String) -> String {
        guard let range = activeTokenRange(in: text) else { return text }
        var updated = text
        updated.replaceSubrange(range, with: "@\(suggestion.path) ")
        return updated
    }

    private static func activeTokenRange(in text: String) -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let tokenEnd = text.endIndex
        var index = text.index(before: tokenEnd)
        while true {
            if text[index].isWhitespace {
                let start = text.index(after: index)
                guard start < tokenEnd, text[start] == "@" else { return nil }
                return start..<tokenEnd
            }
            if index == text.startIndex {
                guard text[index] == "@" else { return nil }
                return index..<tokenEnd
            }
            index = text.index(before: index)
        }
    }

    private static func score(query: String, candidate: String) -> Int? {
        let lowerQuery = query.lowercased()
        let lowerCandidate = candidate.lowercased()
        let fileName = (lowerCandidate as NSString).lastPathComponent

        if fileName == lowerQuery { return 10_000 - candidate.count }
        if lowerCandidate == lowerQuery { return 9_000 - candidate.count }
        if fileName.hasPrefix(lowerQuery) { return 8_000 - candidate.count }
        if lowerCandidate.hasPrefix(lowerQuery) { return 7_000 - candidate.count }
        if fileName.contains(lowerQuery) { return 6_000 - candidate.count }
        if lowerCandidate.contains(lowerQuery) { return 5_000 - candidate.count }

        guard isSubsequence(lowerQuery, of: lowerCandidate) else { return nil }
        var score = 1_000 - candidate.count
        if lowerCandidate.contains("/\(lowerQuery)") { score += 500 }
        return score
    }

    private static func isSubsequence(_ query: String, of candidate: String) -> Bool {
        var candidateIndex = candidate.startIndex
        for character in query {
            guard let found = candidate[candidateIndex...].firstIndex(of: character) else {
                return false
            }
            candidateIndex = candidate.index(after: found)
        }
        return true
    }
}
