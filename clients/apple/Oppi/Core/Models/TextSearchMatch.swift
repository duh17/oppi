import Foundation

/// Literal text matcher for prose-style search.
///
/// Unlike `FuzzyMatch`, this intentionally does not allow arbitrary
/// non-contiguous character matches. It behaves closer to grep/ripgrep for chat
/// text: exact case-insensitive substrings match first, then multi-term queries
/// may match when every term appears as a contiguous substring.
enum TextSearchMatch {
    struct Result: Sendable {
        let score: Int
        /// Unicode scalar positions suitable for existing timeline highlighting.
        let positions: [Int]
    }

    struct ScoredCandidate: Sendable {
        let candidate: String
        let index: Int
        let score: Int
        let positions: [Int]
    }

    private struct PreparedQuery {
        let phrase: String
        let terms: [String]
        let uniqueTerms: [String]
    }

    private static let exactPhraseBase = 1_000_000
    private static let termMatchBase = 500_000
    private static let exactCandidateBonus = 25_000
    private static let prefixBonus = 10_000
    private static let boundaryBonus = 5_000
    private static let occurrenceBonus = 400

    /// Match a query against prose text using case-insensitive literal search.
    static func match(query: String, candidate: String) -> Result? {
        guard let prepared = prepare(query: query) else { return nil }
        return match(prepared: prepared, candidate: candidate)
    }

    /// Score a candidate set and return the top matches.
    static func search(query: String, candidates: [String], limit: Int = 100) -> [ScoredCandidate] {
        guard limit > 0, let prepared = prepare(query: query) else { return [] }

        var scored: [ScoredCandidate] = []
        scored.reserveCapacity(min(candidates.count, limit * 2))

        for (index, candidate) in candidates.enumerated() {
            guard let result = match(prepared: prepared, candidate: candidate) else { continue }
            scored.append(ScoredCandidate(
                candidate: candidate,
                index: index,
                score: result.score,
                positions: result.positions
            ))
        }

        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.index < right.index
        }

        if scored.count > limit {
            scored.removeSubrange(limit...)
        }
        return scored
    }

    private static func match(prepared: PreparedQuery, candidate: String) -> Result? {
        guard !candidate.isEmpty else { return nil }

        let phraseRanges = ranges(of: prepared.phrase, in: candidate)
        if !phraseRanges.isEmpty {
            return Result(
                score: exactPhraseScore(
                    phrase: prepared.phrase,
                    ranges: phraseRanges,
                    candidate: candidate
                ),
                positions: scalarPositions(for: phraseRanges, in: candidate)
            )
        }

        guard prepared.terms.count > 1 else { return nil }

        var allRanges: [Range<String.Index>] = []
        var firstRanges: [Range<String.Index>] = []
        for term in prepared.uniqueTerms {
            let termRanges = ranges(of: term, in: candidate)
            guard let first = termRanges.first else { return nil }
            firstRanges.append(first)
            allRanges.append(contentsOf: termRanges)
        }

        return Result(
            score: termScore(
                ranges: allRanges,
                firstRanges: firstRanges,
                candidate: candidate
            ),
            positions: scalarPositions(for: allRanges, in: candidate)
        )
    }

    private static func prepare(query: String) -> PreparedQuery? {
        let terms = queryTerms(from: query)
        guard !terms.isEmpty else { return nil }
        return PreparedQuery(
            phrase: terms.joined(separator: " "),
            terms: terms,
            uniqueTerms: uniqueTerms(terms)
        )
    }

    private static func queryTerms(from query: String) -> [String] {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace }
            .map(String.init)
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(terms.count)

        for term in terms {
            let key = term.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(term)
        }
        return result
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty, !haystack.isEmpty else { return [] }

        var result: [Range<String.Index>] = []
        var searchRange = haystack.startIndex..<haystack.endIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        while searchRange.lowerBound < haystack.endIndex,
              let range = haystack.range(of: needle, options: options, range: searchRange, locale: nil) {
            guard !range.isEmpty else { break }
            result.append(range)
            searchRange = range.upperBound..<haystack.endIndex
        }

        return result
    }

    private static func exactPhraseScore(
        phrase: String,
        ranges: [Range<String.Index>],
        candidate: String
    ) -> Int {
        guard let first = ranges.first else { return Int.min }

        let start = scalarStart(of: first, in: candidate)
        let phraseLength = phrase.unicodeScalars.count
        let candidateLength = candidate.unicodeScalars.count
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPhrase = phrase.lowercased()

        var score = exactPhraseBase
        if normalizedCandidate == normalizedPhrase {
            score += exactCandidateBonus
        }
        if start == 0 {
            score += prefixBonus
        }
        if isBoundary(at: first.lowerBound, in: candidate) {
            score += boundaryBonus
        }
        score += min(ranges.count, 20) * occurrenceBonus
        score += min(phraseLength, 200)
        score -= min(start, 10_000)
        score -= min(candidateLength / 20, 1_000)
        return score
    }

    private static func termScore(
        ranges: [Range<String.Index>],
        firstRanges: [Range<String.Index>],
        candidate: String
    ) -> Int {
        let starts = firstRanges.map { scalarStart(of: $0, in: candidate) }
        let ends = firstRanges.map { scalarEnd(of: $0, in: candidate) }
        let earliest = starts.min() ?? 0
        let latest = ends.max() ?? earliest
        let span = max(0, latest - earliest)
        let boundaryHits = firstRanges.filter { isBoundary(at: $0.lowerBound, in: candidate) }.count
        let candidateLength = candidate.unicodeScalars.count

        var score = termMatchBase
        score += firstRanges.count * 2_000
        score += boundaryHits * 1_000
        score += min(ranges.count, 20) * occurrenceBonus
        score += max(0, 10_000 - span)
        score -= min(earliest, 10_000)
        score -= min(candidateLength / 20, 1_000)
        return score
    }

    private static func scalarPositions(
        for ranges: [Range<String.Index>],
        in candidate: String
    ) -> [Int] {
        var positions = Set<Int>()

        for range in ranges {
            let start = scalarStart(of: range, in: candidate)
            let length = candidate[range].unicodeScalars.count
            for position in start..<(start + length) {
                positions.insert(position)
            }
        }

        return positions.sorted()
    }

    private static func scalarStart(of range: Range<String.Index>, in candidate: String) -> Int {
        candidate[..<range.lowerBound].unicodeScalars.count
    }

    private static func scalarEnd(of range: Range<String.Index>, in candidate: String) -> Int {
        candidate[..<range.upperBound].unicodeScalars.count
    }

    private static func isBoundary(at index: String.Index, in candidate: String) -> Bool {
        guard index > candidate.startIndex else { return true }
        let previous = candidate[candidate.index(before: index)]
        return previous.isWhitespace
            || previous == "/"
            || previous == "."
            || previous == "_"
            || previous == "-"
            || previous == "|"
            || previous == "("
            || previous == "["
            || previous == "{"
    }
}
