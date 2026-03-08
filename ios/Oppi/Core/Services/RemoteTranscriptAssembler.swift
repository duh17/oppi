import Foundation

enum RemoteTranscriptAssembler {
    private static let fillerTokens: Set<String> = [
        "uh", "um", "ah", "oh", "er", "hmm", "mm",
    ]

    private static let acknowledgementTokens: Set<String> = [
        "ok", "okay",
    ]

    static func normalizedChunkText(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }

        var tokens = collapsed.split(separator: " ").map(String.init)

        while let first = tokens.first {
            let normalized = normalizedToken(first)
            guard fillerTokens.contains(normalized) else { break }
            tokens.removeFirst()
        }

        while let last = tokens.last {
            let normalized = normalizedToken(last)
            guard fillerTokens.contains(normalized) else { break }
            tokens.removeLast()
        }

        tokens = trimAcknowledgementEdges(tokens)
        guard !tokens.isEmpty else { return "" }

        var text = tokens.joined(separator: " ")
        text = text.replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func merge(existing: String, incoming: String) -> String {
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else {
            return incoming
        }

        let existingTokens = trimmedExisting.split(separator: " ").map(String.init)
        var incomingTokens = incoming.split(separator: " ").map(String.init)
        guard !existingTokens.isEmpty else { return incoming }
        guard !incomingTokens.isEmpty else { return trimmedExisting }

        if shouldSuppressAcknowledgementChunk(
            incomingTokens,
            existingTokens: existingTokens
        ) {
            return trimmedExisting
        }

        incomingTokens = trimLeadingAcknowledgement(
            incomingTokens,
            existingTokens: existingTokens
        )
        guard !incomingTokens.isEmpty else { return trimmedExisting }

        let maxOverlap = min(8, min(existingTokens.count, incomingTokens.count))
        var overlap = maxOverlap

        while overlap > 0 {
            let existingSuffix = existingTokens.suffix(overlap).map(normalizedToken)
            let incomingPrefix = incomingTokens.prefix(overlap).map(normalizedToken)
            if !existingSuffix.isEmpty, existingSuffix == incomingPrefix {
                let remainder = incomingTokens.dropFirst(overlap)
                guard !remainder.isEmpty else {
                    return trimmedExisting
                }
                return trimmedExisting + " " + remainder.joined(separator: " ")
            }
            overlap -= 1
        }

        if normalizedToken(existingTokens.last ?? "")
            == normalizedToken(incomingTokens.first ?? ""), incomingTokens.count > 1 {
            return trimmedExisting + " " + incomingTokens.dropFirst().joined(separator: " ")
        }

        return trimmedExisting + " " + incomingTokens.joined(separator: " ")
    }

    private static func trimAcknowledgementEdges(_ tokens: [String]) -> [String] {
        var trimmed = tokens

        while trimmed.count >= 3,
              let first = trimmed.first,
              acknowledgementTokens.contains(normalizedToken(first)) {
            trimmed.removeFirst()
        }

        while trimmed.count >= 4,
              let last = trimmed.last,
              acknowledgementTokens.contains(normalizedToken(last)) {
            trimmed.removeLast()
        }

        return trimmed
    }

    private static func trimLeadingAcknowledgement(
        _ incomingTokens: [String],
        existingTokens: [String]
    ) -> [String] {
        guard incomingTokens.count > 1 else { return incomingTokens }
        guard existingTokens.count >= 4 else { return incomingTokens }

        let lastToken = existingTokens.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let lastChar = lastToken.last, ".!?".contains(lastChar) else {
            return incomingTokens
        }

        let firstToken = incomingTokens.first ?? ""
        guard acknowledgementTokens.contains(normalizedToken(firstToken)) else {
            return incomingTokens
        }

        return Array(incomingTokens.dropFirst())
    }

    private static func shouldSuppressAcknowledgementChunk(
        _ incomingTokens: [String],
        existingTokens: [String]
    ) -> Bool {
        guard incomingTokens.count <= 2 else { return false }
        guard existingTokens.count >= 4 else { return false }

        let normalizedIncoming = incomingTokens
            .map(normalizedToken)
            .filter { !$0.isEmpty }
        guard !normalizedIncoming.isEmpty else { return false }
        guard normalizedIncoming.allSatisfy({ acknowledgementTokens.contains($0) }) else {
            return false
        }

        let lastToken = existingTokens.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let lastChar = lastToken.last else { return false }
        return ".!?".contains(lastChar)
    }

    private static func normalizedToken(_ token: String) -> String {
        let filteredScalars = token.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }
}
