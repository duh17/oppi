import Foundation

/// Cheap, deterministic vocabulary for the next on-device dictation take.
///
/// Terms come from the latest assistant message in this conversation — not a
/// product glossary and not raw ASR. Keep phrases to one or two words so they
/// can be spoken without pausing.
enum DictationHintExtractor {
    static let maxPhraseCount = 100
    static let maxFoundationModelCharacters = 2_000

    static func extract(from text: String) -> [String] {
        merge(primary: rankedCandidates(from: text), extra: [])
    }

    static func merge(primary: [String], extra: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(min(maxPhraseCount, primary.count + extra.count))
        for phrase in primary + extra {
            guard let normalized = speakablePhrase(phrase) else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
            if result.count == maxPhraseCount { break }
        }
        return result
    }

    static func truncatedSource(from text: String) -> String {
        var stripped = text
        stripped.replace(/```[\s\S]*?```/, with: "\n")
        stripped.replace(/~~~[\s\S]*?~~~/, with: "\n")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxFoundationModelCharacters {
            return trimmed
        }
        return String(trimmed.prefix(maxFoundationModelCharacters))
    }

    static func lastAssistantMessageText(in items: [ChatItem]) -> String? {
        for item in items.reversed() {
            if case .assistantMessage(_, let text, _) = item {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func rankedCandidates(from text: String) -> [String] {
        let backtickSpans = text.matches(of: /`([^`\n]+)`/).map { String($0.1) }
        let wikiLinks = text.matches(of: /\[\[([^\]]+)\]\]/).map { wikiParts(from: String($0.1)) }

        var ranked: [String] = []
        ranked.reserveCapacity(32)

        for span in backtickSpans {
            if let phrase = speakablePhrase(span) {
                ranked.append(phrase)
            }
        }

        for link in wikiLinks {
            if let label = link.label, let phrase = speakablePhrase(label) {
                ranked.append(phrase)
            }
            if let fileName = link.fileName, let phrase = speakablePhrase(fileName) {
                ranked.append(phrase)
            }
        }

        for span in backtickSpans {
            if speakablePhrase(span) == nil {
                ranked.append(contentsOf: identifiers(in: span))
            }
        }

        ranked.append(contentsOf: identifiers(in: strippingMarkup(text)))
        return ranked
    }

    private static func identifiers(in text: String) -> [String] {
        let dotted = /[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+/
        let camel = /[A-Za-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*/
        var matches: [(Range<String.Index>, String)] = []

        for match in text.matches(of: dotted) {
            let value = String(match.output)
            guard !value.contains("://") else { continue }
            matches.append((match.range, value))
        }

        for match in text.matches(of: camel) {
            let range = match.range
            if matches.contains(where: { $0.0.overlaps(range) }) { continue }
            matches.append((range, String(match.output)))
        }

        matches.sort { $0.0.lowerBound < $1.0.lowerBound }
        return matches.map(\.1)
    }

    private static func strippingMarkup(_ text: String) -> String {
        var result = text
        result.replace(/`[^`\n]+`/, with: " ")
        result.replace(/\[\[[^\]]+\]\]/, with: " ")
        return result
    }

    private static func wikiParts(from raw: String) -> (label: String?, fileName: String?) {
        let pieces = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pieces.first.map(String.init) ?? raw
        let label = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let pathWithoutFragment = path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? path
        let fileName = pathWithoutFragment
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init)
        return (label?.isEmpty == false ? label : nil, fileName)
    }

    private static func speakablePhrase(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0.isNewline || $0 == "," || $0 == ";" || $0 == "!" || $0 == "?" || $0 == "/" }) {
            return nil
        }
        if trimmed.contains("—") || trimmed.contains("…") {
            return nil
        }
        let words = trimmed.split { $0.isWhitespace }.map(String.init)
        guard (1...2).contains(words.count) else { return nil }
        guard words.allSatisfy({ (1...64).contains($0.count) }) else { return nil }
        return words.joined(separator: " ")
    }
}
