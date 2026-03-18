/// Fuzzy file path matcher optimized for content discovery.
///
/// Implements fzf-style scoring: characters in the query can match non-contiguously
/// in the candidate path. Scoring rewards consecutive matches, word boundary matches
/// (after `/`, `.`, `_`, `-`), camelCase transitions, and filename matches.
///
/// Algorithm:
/// 1. Quick scan — verify all query chars exist in candidate (in order). O(n).
/// 2. DP scoring — find optimal match positions that maximize total score. O(n*m).
/// 3. Backtrack — extract the actual matched positions for highlighting.
enum FuzzyMatch {

    /// Result of a successful fuzzy match.
    struct Result: Sendable {
        /// Overall match score (higher = better match).
        let score: Int
        /// Indices into the candidate string where query characters matched.
        let positions: [Int]
    }

    // MARK: - Scoring Constants

    /// Bonus for consecutive matched characters.
    private static let consecutiveBonus = 8
    /// Bonus for matching at a word boundary (after separator or camelCase).
    private static let boundaryBonus = 10
    /// Bonus for matching the first character of the candidate.
    private static let firstCharBonus = 6
    /// Bonus for matching in the filename (after last `/`).
    private static let filenameBonus = 5
    /// Penalty per gap character between matches.
    private static let gapPenalty = -1
    /// Base score per matched character.
    private static let matchBase = 1

    // MARK: - Public API

    /// Attempt to fuzzy-match `query` against `candidate`.
    ///
    /// Returns `nil` if the query characters don't all appear (in order) in the candidate.
    /// Otherwise returns a `Result` with a score and the matched character positions.
    static func match(query: String, candidate: String) -> Result? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }

        let queryChars = Array(query.lowercased().unicodeScalars)
        let candChars = Array(candidate.unicodeScalars)
        let candLower = Array(candidate.lowercased().unicodeScalars)
        let qLen = queryChars.count
        let cLen = candChars.count

        guard qLen <= cLen else { return nil }

        // Phase 1: quick scan — all query chars present in order?
        var qi = 0
        for ci in 0..<cLen {
            if qi < qLen, candLower[ci] == queryChars[qi] {
                qi += 1
            }
        }
        guard qi == qLen else { return nil }

        // Pre-compute boundary flags and filename start
        let boundaries = computeBoundaries(candChars)
        let filenameStart = computeFilenameStart(candChars)

        // Phase 2: DP scoring
        // dp[q][c] = best score matching query[0..<q] against candidate[0..<c]
        // Using two rows to save memory.
        let NEG_INF = Int.min / 2

        // score[q][c]: best score ending with query[q-1] matched at candidate[c-1]
        // We need to track: (score, consecutive count) for the bonus calculation.
        // Simplified approach: compute score matrix with match/skip choices.

        // For each (qi, ci) where query[qi] matches candidate[ci]:
        //   matchScore = bestScoreEndingBefore(qi-1, ci-1) + charScore(qi, ci, consecutive?)
        // We pick the assignment that maximizes total score.

        // Track: for each query position qi (0-indexed), the best score achievable
        // matching query[0..qi] to some prefix of candidate, along with the last
        // matched candidate index.

        // Full DP: score[qi][ci] = best score matching query[0..qi] with last match at ci
        //   score[qi][ci] defined only when candLower[ci] == queryChars[qi]
        //   score[qi][ci] = max over valid ci' < ci of:
        //     score[qi-1][ci'] + gap(ci' → ci) + charBonus(qi, ci, consecutive: ci == ci'+1)

        // This is O(qLen * cLen) which is fine for file paths (both small).

        // Flatten to 1D arrays for performance
        // prevBest[ci] = best score for matching query[0..qi-1] ending at candidate ci
        // prevBestAny = max(prevBest[0..ci]) = best score achievable for query[0..qi-1]

        var prevRow = [Int](repeating: NEG_INF, count: cLen)
        var currRow = [Int](repeating: NEG_INF, count: cLen)
        // Track the previous match index for backtracking
        var prevFrom = [[Int]](repeating: [Int](repeating: -1, count: cLen), count: qLen)

        for qi in 0..<qLen {
            for ci in qi..<cLen { // ci >= qi (can't match more query chars than candidate chars)
                guard candLower[ci] == queryChars[qi] else { continue }

                var score: Int
                if qi == 0 {
                    // First query char: no previous match needed
                    score = charScore(qi: qi, ci: ci, consecutive: false,
                                      boundaries: boundaries, filenameStart: filenameStart)
                    // Gap from start
                    if ci > 0 {
                        score += ci * gapPenalty
                    }
                    prevFrom[qi][ci] = -1
                } else {
                    // Need a previous match at some ci' < ci
                    // Update bestPrevScore/bestPrevIdx up to ci-1
                    // We process ci in order, so we can incrementally track the best
                    // previous score including the gap penalty up to position ci.

                    // Actually, let's track best prev score correctly.
                    // We want: max over ci' < ci of (prevRow[ci'] + gap(ci', ci))
                    // gap(ci', ci) = (ci - ci' - 1) * gapPenalty

                    // Since gapPenalty is negative, the best prev is the one maximizing:
                    //   prevRow[ci'] + (ci - ci' - 1) * gapPenalty
                    // = prevRow[ci'] - ci' * gapPenalty + (ci - 1) * gapPenalty
                    // = (prevRow[ci'] - ci' * gapPenalty) + (ci - 1) * gapPenalty

                    // So we can track: maxAdjusted = max(prevRow[ci'] + ci' * |gapPenalty|)
                    // and then: bestScore = maxAdjusted - (ci - 1) * |gapPenalty|
                    // But this complicates consecutive tracking.

                    // Simpler: just track best-so-far with recalculation.
                    // For file paths (cLen < 200 typically), this is fast enough.

                    // Scan all valid previous positions
                    var best = NEG_INF
                    var bestIdx = -1
                    for pi in (qi - 1)..<ci {
                        guard prevRow[pi] > NEG_INF else { continue }
                        let gapSize = ci - pi - 1
                        let adjusted = prevRow[pi] + gapSize * gapPenalty
                        if adjusted > best {
                            best = adjusted
                            bestIdx = pi
                        }
                    }

                    guard best > NEG_INF else { continue }

                    let isConsecutive = bestIdx == ci - 1
                    score = best + charScore(qi: qi, ci: ci, consecutive: isConsecutive,
                                             boundaries: boundaries, filenameStart: filenameStart)
                    prevFrom[qi][ci] = bestIdx
                }

                currRow[ci] = score
            }

            // Swap rows
            prevRow = currRow
            currRow = [Int](repeating: NEG_INF, count: cLen)
        }

        // Find best final score
        var bestScore = NEG_INF
        var bestEnd = -1
        for ci in (qLen - 1)..<cLen where prevRow[ci] > bestScore {
            bestScore = prevRow[ci]
            bestEnd = ci
        }

        guard bestScore > NEG_INF else { return nil }

        // Backtrack to find positions
        var positions = [Int](repeating: 0, count: qLen)
        var ci = bestEnd
        for qi in stride(from: qLen - 1, through: 0, by: -1) {
            positions[qi] = ci
            ci = prevFrom[qi][ci]
        }

        return Result(score: bestScore, positions: positions)
    }

    /// Score a batch of candidates against a query, returning matched results sorted by score.
    ///
    /// This is the main entry point for the file browser. Filters and sorts in one pass.
    /// - Parameter limit: Maximum number of results to return.
    static func search(query: String, candidates: [String], limit: Int = 100) -> [ScoredPath] {
        guard !query.isEmpty else { return [] }

        var results: [ScoredPath] = []
        results.reserveCapacity(min(candidates.count, limit * 2))

        for (index, candidate) in candidates.enumerated() {
            guard let result = match(query: query, candidate: candidate) else { continue }
            results.append(ScoredPath(path: candidate, index: index, score: result.score, positions: result.positions))
        }

        // Sort by score descending, then by path length ascending (shorter = more relevant)
        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.path.count < b.path.count
        }

        if results.count > limit {
            results.removeSubrange(limit...)
        }

        return results
    }

    /// A scored search result with the original path and match positions.
    struct ScoredPath: Sendable {
        let path: String
        let index: Int
        let score: Int
        let positions: [Int]
    }

    // MARK: - Internals

    private static func charScore(
        qi: Int,
        ci: Int,
        consecutive: Bool,
        boundaries: [Bool],
        filenameStart: Int
    ) -> Int {
        var score = matchBase

        if consecutive {
            score += consecutiveBonus
        }

        if ci < boundaries.count, boundaries[ci] {
            score += boundaryBonus
        }

        if ci == 0 {
            score += firstCharBonus
        }

        if ci >= filenameStart {
            score += filenameBonus
        }

        return score
    }

    /// Compute word boundary flags for each character position.
    /// A position is a boundary if the character follows a separator (/ . _ - space)
    /// or is an uppercase letter preceded by a lowercase letter (camelCase).
    private static func computeBoundaries(_ chars: [Unicode.Scalar]) -> [Bool] {
        var result = [Bool](repeating: false, count: chars.count)
        if !chars.isEmpty {
            result[0] = true // first char is always a boundary
        }
        for i in 1..<chars.count {
            let prev = chars[i - 1]
            let curr = chars[i]
            if isSeparator(prev) {
                result[i] = true
            } else if CharacterProperties.isUppercase(curr) && CharacterProperties.isLowercase(prev) {
                result[i] = true
            }
        }
        return result
    }

    /// Find the index where the filename starts (after the last `/`).
    private static func computeFilenameStart(_ chars: [Unicode.Scalar]) -> Int {
        for i in stride(from: chars.count - 1, through: 0, by: -1) where chars[i] == "/" {
            return i + 1
        }
        return 0
    }

    private static func isSeparator(_ c: Unicode.Scalar) -> Bool {
        c == "/" || c == "." || c == "_" || c == "-" || c == " "
    }
}

/// Lightweight Unicode property checks without Foundation overhead.
private enum CharacterProperties {
    static func isUppercase(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x41 && s.value <= 0x5A // A-Z
    }

    static func isLowercase(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0x61 && s.value <= 0x7A // a-z
    }
}
