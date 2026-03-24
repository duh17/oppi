/// Fuzzy file path matcher optimized for content discovery.
///
/// Implements fzf-style scoring: characters in the query can match non-contiguously
/// in the candidate path. Scoring rewards consecutive matches, word boundary matches
/// (after `/`, `.`, `_`, `-`), camelCase transitions, and filename matches.
///
/// Algorithm:
/// 1. Quick scan — verify all query chars exist in candidate (in order). O(c).
/// 2. DP scoring — running-max DP finds optimal match positions. O(q*c).
/// 3. Backtrack — extract the actual matched positions for highlighting. O(q).
///
/// search() uses a two-phase approach:
///   Phase 1: score-only pass over all candidates (no backtracking allocation).
///   Phase 2: full match with positions only for the top-K results.
enum FuzzyMatch {

    /// Result of a successful fuzzy match.
    /// `positions` are unicode scalar indices suitable for use with `String.unicodeScalars`.
    struct Result: Sendable {
        let score: Int
        let positions: [Int]
    }

    // MARK: - Scoring Constants

    private static let consecutiveBonus = 8
    private static let boundaryBonus = 10
    private static let firstCharBonus = 6
    private static let filenameBonus = 5
    private static let gapPenalty = -1
    private static let matchBase = 1

    // MARK: - ASCII Helpers

    @inline(__always)
    private static func asciiLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }

    @inline(__always)
    private static func isSepByte(_ b: UInt8) -> Bool {
        b == 0x2F || b == 0x2E || b == 0x5F || b == 0x2D || b == 0x20
    }

    @inline(__always)
    private static func isUpperByte(_ b: UInt8) -> Bool {
        b >= 0x41 && b <= 0x5A
    }

    @inline(__always)
    private static func isLowerByte(_ b: UInt8) -> Bool {
        b >= 0x61 && b <= 0x7A
    }

    // MARK: - Public API

    /// Fuzzy-match `query` against `candidate`. Returns nil if no subsequence match.
    /// Positions are unicode scalar indices for use with `String.unicodeScalars`.
    static func match(query: String, candidate: String) -> Result? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        let qBytes = Array(query.utf8).map { asciiLower($0) }
        let cBytes = Array(candidate.utf8)
        guard let r = matchBytes(qLower: qBytes, cBytes: cBytes, true) else { return nil }
        return Result(score: r.score, positions: byteToScalarPositions(r.positions, candidate: candidate))
    }

    /// Score a batch of candidates, returning top matches sorted by score.
    static func search(query: String, candidates: [String], limit: Int = 100) -> [ScoredPath] {
        guard !query.isEmpty else { return [] }

        let qBytes = Array(query.utf8).map { asciiLower($0) }
        let qLen = qBytes.count

        // Phase 1: score-only pass — no position tracking, no prevFrom allocation.
        struct Scored {
            let index: Int
            let score: Int
        }
        var scored: [Scored] = []
        scored.reserveCapacity(min(candidates.count, limit * 2))

        // Maintain a running min-score threshold: once we have `limit` results,
        // skip candidates that score below the worst in the current top-K.
        var minThreshold = Int.min
        var heapSize = 0

        for (index, candidate) in candidates.enumerated() {
            var s: Int?
            candidate.utf8.withContiguousStorageIfAvailable { buf in
                s = scoreBuffer(qLower: qBytes, qLen: qLen, buf: buf)
            }
            if s == nil {
                let bytes = Array(candidate.utf8)
                bytes.withUnsafeBufferPointer { buf in
                    s = scoreBuffer(qLower: qBytes, qLen: qLen, buf: buf)
                }
            }
            guard let score = s else { continue }

            if heapSize >= limit && score <= minThreshold { continue }
            scored.append(Scored(index: index, score: score))
            heapSize += 1

            // Periodically compact to keep memory bounded
            if scored.count > limit * 4 {
                scored.sort { $0.score > $1.score }
                scored.removeSubrange(limit...)
                minThreshold = scored.last?.score ?? Int.min
                heapSize = scored.count
            }
        }

        // Partial sort: only fully sort the top `limit` elements.
        // For 194K candidates with limit=100, this avoids O(n log n) full sort.
        if scored.count > limit {
            scored.withUnsafeMutableBufferPointer { buf in
                // nth_element-style: partition around the limit-th element
                var lo = 0, hi = buf.count - 1
                let target = limit
                while lo < hi {
                    let pivot = buf[Int.random(in: lo...hi)]
                    var i = lo, j = hi
                    while i <= j {
                        while buf[i].score > pivot.score || (buf[i].score == pivot.score && candidates[buf[i].index].count < candidates[pivot.index].count) { i += 1 }
                        while buf[j].score < pivot.score || (buf[j].score == pivot.score && candidates[buf[j].index].count > candidates[pivot.index].count) { j -= 1 }
                        if i <= j { buf.swapAt(i, j); i += 1; j -= 1 }
                    }
                    if j < target { lo = i }
                    if i > target { hi = j }
                }
            }
            scored.removeSubrange(limit...)
        }
        // Sort the top `limit` results
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return candidates[a.index].count < candidates[b.index].count
        }

        // Phase 2: compute positions only for top results.
        var results: [ScoredPath] = []
        results.reserveCapacity(scored.count)
        for sc in scored {
            let candidate = candidates[sc.index]
            let cBytes = Array(candidate.utf8)
            if let r = matchBytes(qLower: qBytes, cBytes: cBytes, true) {
                let scalarPositions = byteToScalarPositions(r.positions, candidate: candidate)
                results.append(ScoredPath(path: candidate, index: sc.index,
                                          score: r.score, positions: scalarPositions))
            } else {
                results.append(ScoredPath(path: candidate, index: sc.index,
                                          score: sc.score, positions: []))
            }
        }
        return results
    }

    struct ScoredPath: Sendable {
        let path: String
        let index: Int
        let score: Int
        /// Unicode scalar indices for highlighting. Use with `String.unicodeScalars`.
        let positions: [Int]
    }

    // MARK: - Position Conversion

    /// Convert UTF-8 byte positions to unicode scalar positions.
    /// Fast path for all-ASCII strings (no conversion needed).
    private static func byteToScalarPositions(_ bytePositions: [Int], candidate: String) -> [Int] {
        // Fast path: ASCII-only strings have 1:1 byte-to-scalar mapping
        if candidate.utf8.allSatisfy({ $0 < 0x80 }) { return bytePositions }

        // Slow path: build byte offset → scalar index mapping
        var byteToScalar = [Int: Int]()
        byteToScalar.reserveCapacity(candidate.unicodeScalars.count)
        var byteOffset = 0
        for (scalarIdx, scalar) in candidate.unicodeScalars.enumerated() {
            byteToScalar[byteOffset] = scalarIdx
            byteOffset += scalar.utf8.count
        }
        return bytePositions.map { byteToScalar[$0] ?? $0 }
    }

    // MARK: - Core: Score-Only on UnsafeBufferPointer (hot path)

    /// Score a candidate against a query using zero-copy buffer access.
    /// Returns the score or nil if no match. No position tracking.
    private static func scoreBuffer(
        qLower: [UInt8], qLen: Int, buf: UnsafeBufferPointer<UInt8>
    ) -> Int? {
        let cLen = buf.count
        guard qLen > 0, cLen >= qLen else { return nil }

        // Quick scan: all query chars present in order?
        var qi = 0
        for ci in 0..<cLen {
            if qi < qLen, asciiLower(buf[ci]) == qLower[qi] { qi += 1 }
        }
        guard qi == qLen else { return nil }

        // Compute filename start (last '/')
        var filenameStart = 0
        for i in stride(from: cLen - 1, through: 0, by: -1) { // swiftlint:disable:next for_where
            if buf[i] == 0x2F { filenameStart = i + 1; break }
        }

        let NEG_INF = Int.min / 2

        // Stack-allocated DP rows. Pointer swap avoids per-row copy.
        let rowSize = cLen * MemoryLayout<Int>.stride
        return withUnsafeTemporaryAllocation(byteCount: rowSize * 2, alignment: MemoryLayout<Int>.alignment) { rawBuf in
            guard let baseAddr = rawBuf.baseAddress else { return nil }
            let base = baseAddr.assumingMemoryBound(to: Int.self)
            let rowA = base
            let rowB = base + cLen
            for i in 0..<cLen { rowA[i] = NEG_INF; rowB[i] = NEG_INF }

            var prev = rowA
            var curr = rowB

            for qi in 0..<qLen {
                var runMax = NEG_INF
                var runMaxIdx = -1
                let qb = qLower[qi]

                for ci in qi..<cLen {
                    if qi > 0, ci > 0, prev[ci - 1] > NEG_INF {
                        let adj = prev[ci - 1] + (ci - 1)
                        if adj > runMax { runMax = adj; runMaxIdx = ci - 1 }
                    }

                    guard asciiLower(buf[ci]) == qb else { continue }

                    var score = matchBase
                    if ci == 0 {
                        score += firstCharBonus + boundaryBonus
                    } else {
                        let p = buf[ci - 1]
                        if isSepByte(p) {
                            score += boundaryBonus
                        } else if isUpperByte(buf[ci]) && isLowerByte(p) {
                            score += boundaryBonus
                        }
                    }
                    if ci >= filenameStart { score += filenameBonus }

                    if qi == 0 {
                        if ci > 0 { score += ci * gapPenalty }
                    } else {
                        guard runMax > NEG_INF else { continue }
                        let best = runMax + (ci - 1) * gapPenalty
                        if runMaxIdx == ci - 1 { score += consecutiveBonus }
                        score += best
                    }

                    curr[ci] = score
                }

                // Pointer swap + reset curr for next iteration
                let tmp = prev; prev = curr; curr = tmp
                for i in 0..<cLen { curr[i] = NEG_INF }
            }

            var bestScore = NEG_INF
            for ci in (qLen - 1)..<cLen where prev[ci] > bestScore {
                bestScore = prev[ci]
            }
            return bestScore > NEG_INF ? bestScore : nil
        }
    }

    // MARK: - Core: Full Match with Positions

    /// Match with position backtracking. Used by match() and for top-K position recovery.
    private static func matchBytes(
        qLower: [UInt8], cBytes: [UInt8], _ _needPositions: Bool
    ) -> Result? {
        let qLen = qLower.count
        let cLen = cBytes.count
        guard qLen > 0, cLen > 0, qLen <= cLen else { return nil }

        // Quick scan
        var qi = 0
        for ci in 0..<cLen {
            if qi < qLen, asciiLower(cBytes[ci]) == qLower[qi] { qi += 1 }
        }
        guard qi == qLen else { return nil }

        // Compute boundaries
        var boundaries = [Bool](repeating: false, count: cLen)
        boundaries[0] = true
        for i in 1..<cLen {
            if isSepByte(cBytes[i - 1]) || (isUpperByte(cBytes[i]) && isLowerByte(cBytes[i - 1])) {
                boundaries[i] = true
            }
        }
        var filenameStart = 0
        for i in stride(from: cLen - 1, through: 0, by: -1) { // swiftlint:disable:next for_where
            if cBytes[i] == 0x2F { filenameStart = i + 1; break }
        }

        let NEG_INF = Int.min / 2
        let absGap = 1

        var prevRow = [Int](repeating: NEG_INF, count: cLen)
        var currRow = [Int](repeating: NEG_INF, count: cLen)
        var prevFromFlat = [Int](repeating: -1, count: qLen * cLen)

        for qi in 0..<qLen {
            var runMax = NEG_INF
            var runMaxIdx = -1
            let rowOff = qi * cLen
            let qb = qLower[qi]

            for ci in qi..<cLen {
                if qi > 0, ci > 0, prevRow[ci - 1] > NEG_INF {
                    let adj = prevRow[ci - 1] + (ci - 1) * absGap
                    if adj > runMax { runMax = adj; runMaxIdx = ci - 1 }
                }

                guard asciiLower(cBytes[ci]) == qb else { continue }

                var score = matchBase
                if boundaries[ci] { score += boundaryBonus }
                if ci == 0 { score += firstCharBonus }
                if ci >= filenameStart { score += filenameBonus }

                if qi == 0 {
                    if ci > 0 { score += ci * gapPenalty }
                } else {
                    guard runMax > NEG_INF else { continue }
                    let best = runMax + (ci - 1) * gapPenalty
                    if runMaxIdx == ci - 1 { score += consecutiveBonus }
                    score += best
                    prevFromFlat[rowOff + ci] = runMaxIdx
                }

                currRow[ci] = score
            }

            let tmp = prevRow; prevRow = currRow; currRow = tmp
            for i in 0..<cLen { currRow[i] = NEG_INF }
        }

        var bestScore = NEG_INF
        var bestEnd = -1
        for ci in (qLen - 1)..<cLen where prevRow[ci] > bestScore {
            bestScore = prevRow[ci]; bestEnd = ci
        }
        guard bestScore > NEG_INF else { return nil }

        var positions = [Int](repeating: 0, count: qLen)
        var ci = bestEnd
        for qi in stride(from: qLen - 1, through: 0, by: -1) {
            positions[qi] = ci
            ci = prevFromFlat[qi * cLen + ci]
        }

        return Result(score: bestScore, positions: positions)
    }

}
