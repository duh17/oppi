import Foundation

/// The one search matcher behind every Oppi search field: file paths,
/// commands, models, session titles, catalog lists, and the session timeline.
///
/// Matching rules (all case- and diacritic-insensitive):
/// - The query splits on whitespace into terms; every term must match (any
///   order). A multi-term query that also matches as one phrase ranks higher.
/// - A term matches when its characters appear in order. Between two matched
///   characters the candidate may skip only:
///   - nothing (a contiguous run, the strongest signal),
///   - up to two characters anywhere (typos and dropped vowels: `cmpct`),
///   - the rest of a word, landing on a later word start inside the same
///     whitespace-delimited token (camelCase humps, `_`, `-`, `.`: `fbv`),
///   - into the first word of the next token (acronyms across prose: `wf`
///     for "web fetch"),
///   - any number of `/` path segments (`oppichatview`).
///   Arbitrary scatter across prose ("w…e…b" spread over a paragraph) does
///   not match, so long text stays as precise as literal search.
/// - Scoring is fzf-like: contiguous runs, word starts, the first character,
///   and the path filename earn bonuses; skipped characters cost a little.
///   Exact candidate and exact filename matches outrank every partial match.
///
/// Performance: ASCII candidates are scanned in place through their UTF-8
/// storage with no allocation. A subsequence pre-scan rejects most
/// candidates in O(c) before the O(q·c) DP. `search` scores everything
/// without position tracking and backtracks only the top results.
///
/// Positions are Unicode scalar indices for use with `String.unicodeScalars`.
enum FuzzyMatch {

    struct Result: Sendable, Equatable {
        let score: Int
        /// Unicode scalar indices of matched characters, ascending.
        let positions: [Int]
    }

    struct ScoredPath: Sendable {
        let path: String
        let score: Int
        /// Unicode scalar indices for highlighting. Use with `String.unicodeScalars`.
        let positions: [Int]
    }

    struct RankedCandidate: Sendable, Equatable {
        /// Index into the candidate array passed to `rank`.
        let index: Int
        let score: Int
        let positions: [Int]
    }

    /// A query folded and split once, then reused across many candidates.
    struct Query: Sendable {
        fileprivate let terms: [[UInt32]]
        /// All terms joined by single spaces; nil for one-term queries.
        fileprivate let phrase: [UInt32]?
        /// True when every folded query unit is ASCII, so ASCII-only
        /// candidates can be scanned in place.
        fileprivate let isASCII: Bool

        init?(_ raw: String) {
            var terms: [[UInt32]] = []
            var current: [UInt32] = []
            var ascii = true
            for scalar in raw.unicodeScalars {
                if scalar.properties.isWhitespace {
                    if !current.isEmpty { terms.append(current); current = [] }
                    continue
                }
                let unit = FuzzyMatch.fold(scalar)
                if unit >= 0x80 { ascii = false }
                current.append(unit)
            }
            if !current.isEmpty { terms.append(current) }
            guard !terms.isEmpty else { return nil }

            self.terms = terms
            if terms.count > 1 {
                var joined: [UInt32] = []
                for (index, term) in terms.enumerated() {
                    if index > 0 { joined.append(FuzzyMatch.spaceUnit) }
                    joined.append(contentsOf: term)
                }
                phrase = joined
            } else {
                phrase = nil
            }
            isASCII = ascii
        }
    }

    // MARK: - Scoring Constants

    private static let consecutiveBonus = 8
    private static let boundaryBonus = 10
    private static let firstCharBonus = 6
    private static let filenameBonus = 5
    private static let gapPenalty = -1
    private static let matchBase = 1
    /// Longest run of skipped characters allowed anywhere (typo tolerance).
    private static let maxFreeSkip = 2
    /// A multi-term query that also reads as one phrase in the candidate.
    private static let phraseBonus = 50
    /// Guarantee exact matches rank above non-exact fuzzy matches.
    private static let exactFilenameBonus = 10_000
    private static let exactPathBonus = 20_000

    fileprivate static let spaceUnit: UInt32 = 0x20
    private static let slashUnit: UInt32 = 0x2F

    // MARK: - Public API

    /// Match one candidate. Returns nil when any query term does not match.
    static func match(query: String, candidate: String) -> Result? {
        guard let prepared = Query(query) else { return nil }
        return match(prepared, candidate: candidate)
    }

    /// Match one candidate with a prepared query, including highlight positions.
    static func match(_ query: Query, candidate: String) -> Result? {
        evaluate(query, candidate: candidate, track: true).map {
            Result(score: $0.score, positions: $0.positions)
        }
    }

    /// Score one candidate without computing positions. Use for filtering.
    static func score(_ query: Query, candidate: String) -> Int? {
        evaluate(query, candidate: candidate, track: false)?.score
    }

    /// Best score across several fields of one item (name, id, provider, …).
    static func bestScore(_ query: Query, fields: [String?]) -> Int? {
        var best: Int?
        for field in fields {
            guard let field, let score = score(query, candidate: field) else { continue }
            if best.map({ score > $0 }) ?? true { best = score }
        }
        return best
    }

    /// True when any field matches. Empty or whitespace queries match everything.
    static func matchesAny(query: String, fields: [String?]) -> Bool {
        guard let prepared = Query(query) else { return true }
        return fields.contains { field in
            field.map { score(prepared, candidate: $0) != nil } ?? false
        }
    }

    /// Every matching candidate with positions, best score first; equal
    /// scores keep the input order (chronological lists stay chronological).
    ///
    /// Each item is ranked by its best-matching field. `positions` index the
    /// first field (the text a row highlights) and are empty when only another
    /// field matched.
    static func rank(query: String, fields: [[String?]]) -> [RankedCandidate] {
        guard let prepared = Query(query) else { return [] }
        var ranked: [RankedCandidate] = []
        for (index, itemFields) in fields.enumerated() {
            var best: Int?
            var positions: [Int] = []
            for (fieldIndex, field) in itemFields.enumerated() {
                guard let field,
                      let hit = evaluate(prepared, candidate: field, track: fieldIndex == 0)
                else { continue }
                if fieldIndex == 0 { positions = hit.positions }
                if best.map({ hit.score > $0 }) ?? true { best = hit.score }
            }
            guard let best else { continue }
            ranked.append(RankedCandidate(index: index, score: best, positions: positions))
        }
        ranked.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
        }
        return ranked
    }

    /// Top `limit` matches for large candidate sets (file indexes), best score
    /// first; equal scores prefer shorter candidates.
    static func search(query: String, candidates: [String], limit: Int = 100) -> [ScoredPath] {
        guard limit > 0, let prepared = Query(query) else { return [] }

        // Phase 1: score-only pass, no position tracking.
        struct Scored {
            let index: Int
            let score: Int
        }
        var scored: [Scored] = []
        scored.reserveCapacity(min(candidates.count, limit * 2))
        var minThreshold = Int.min
        func ranksBefore(_ a: Scored, _ b: Scored) -> Bool {
            if a.score != b.score { return a.score > b.score }
            let aCount = candidates[a.index].utf8.count
            let bCount = candidates[b.index].utf8.count
            return aCount != bCount ? aCount < bCount : a.index < b.index
        }

        for (index, candidate) in candidates.enumerated() {
            guard let score = evaluate(prepared, candidate: candidate, track: false)?.score else { continue }
            // Equal scores still enter: a shorter path can win the next compaction.
            if scored.count >= limit && score < minThreshold { continue }
            scored.append(Scored(index: index, score: score))

            // Periodically compact to keep memory bounded, with the final order.
            if scored.count > limit * 4 {
                scored.sort(by: ranksBefore)
                scored.removeSubrange(limit...)
                minThreshold = scored.last?.score ?? Int.min
            }
        }

        scored.sort(by: ranksBefore)
        if scored.count > limit {
            scored.removeSubrange(limit...)
        }

        // Phase 2: positions only for the survivors.
        return scored.map { entry in
            let candidate = candidates[entry.index]
            let positions = evaluate(prepared, candidate: candidate, track: true)?.positions ?? []
            return ScoredPath(path: candidate, score: entry.score, positions: positions)
        }
    }

    // MARK: - Evaluation

    private struct Hit {
        let score: Int
        let positions: [Int]
    }

    private enum FastPath {
        case done(Hit?)
        case needsScalars
    }

    private static func evaluate(_ query: Query, candidate: String, track: Bool) -> Hit? {
        guard !candidate.isEmpty else { return nil }

        // Native Swift strings expose contiguous UTF-8. ASCII candidates are
        // rejected in place; only plausible ones pay for column setup.
        let fast = candidate.utf8.withContiguousStorageIfAvailable { bytes -> FastPath in
            for byte in bytes where byte >= 0x80 { return .needsScalars }
            guard query.isASCII else { return .done(nil) }
            for term in query.terms where !isSubsequence(term, of: bytes) { return .done(nil) }
            return .done(withColumns(
                count: bytes.count,
                fill: { builder in
                    for byte in bytes {
                        builder.append(unit: UInt32(asciiLower(byte)), kind: asciiKind(byte))
                    }
                },
                body: { evaluate(query, columns: $0, track: track) }
            ))
        }
        if case .done(let hit) = fast { return hit }

        let scalarCount = candidate.unicodeScalars.count
        return withColumns(
            count: scalarCount,
            fill: { builder in
                for scalar in candidate.unicodeScalars {
                    builder.append(unit: fold(scalar), kind: kind(of: scalar))
                }
            },
            body: { evaluate(query, columns: $0, track: track) }
        )
    }

    private static func isSubsequence(_ term: [UInt32], of bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var qi = 0
        let qLen = term.count
        for byte in bytes where UInt32(asciiLower(byte)) == term[qi] {
            qi += 1
            if qi == qLen { return true }
        }
        return false
    }

    private static func evaluate(_ query: Query, columns: Columns, track: Bool) -> Hit? {
        if query.terms.count == 1 {
            return matchTerm(query.terms[0], columns: columns, track: track)
        }

        var total = 0
        var positions: [Int] = []
        for term in query.terms {
            guard let hit = matchTerm(term, columns: columns, track: track) else { return nil }
            total += hit.score
            if track { positions.append(contentsOf: hit.positions) }
        }

        if let phrase = query.phrase,
           let hit = matchTerm(phrase, columns: columns, track: track),
           hit.score + phraseBonus > total {
            return Hit(score: hit.score + phraseBonus, positions: hit.positions)
        }

        if track {
            positions.sort()
            var unique: [Int] = []
            unique.reserveCapacity(positions.count)
            for position in positions where unique.last != position { unique.append(position) }
            positions = unique
        }
        return Hit(score: total, positions: positions)
    }

    // MARK: - Columns

    /// Per-column facts, computed in one pass per candidate so the DP reads
    /// one byte per column instead of re-deriving character classes per row.
    private struct ColumnFlags {
        static let wordStart: UInt8 = 1
        /// The first word start of its whitespace-delimited token.
        static let firstWordInToken: UInt8 = 2
        /// First non-whitespace column after whitespace.
        static let tokenStart: UInt8 = 4
        /// The previous column is `/`.
        static let afterSlash: UInt8 = 8
        /// Whitespace or punctuation; a phrase's space matches it.
        static let spaceLike: UInt8 = 16
    }

    private struct Columns {
        let units: UnsafeMutablePointer<UInt32>
        let flags: UnsafeMutablePointer<UInt8>
        let count: Int
        let filenameStart: Int
    }

    private struct ColumnBuilder {
        let units: UnsafeMutablePointer<UInt32>
        let flags: UnsafeMutablePointer<UInt8>
        var count = 0
        private var previousKind: CharKind = .whitespace
        private var kindBeforePrevious: CharKind = .whitespace
        private var previousUnit: UInt32 = 0
        private var sawWordStartInToken = false
        private var lastSlash = -1
        private var sawWhitespace = false

        init(units: UnsafeMutablePointer<UInt32>, flags: UnsafeMutablePointer<UInt8>) {
            self.units = units
            self.flags = flags
        }

        @inline(__always)
        mutating func append(unit: UInt32, kind: CharKind) {
            var flag: UInt8 = 0
            if kind == .whitespace {
                sawWhitespace = true
                flag |= ColumnFlags.spaceLike
            } else {
                // previousKind starts as whitespace, so column 0 opens a token.
                if previousKind == .whitespace {
                    flag |= ColumnFlags.tokenStart
                    sawWordStartInToken = false
                }
                if kind == .separator { flag |= ColumnFlags.spaceLike }
                if kind.isWord,
                   !previousKind.isWord
                   || (kind == .upper && (previousKind == .lower || previousKind == .digit)) {
                    flag |= ColumnFlags.wordStart
                    if !sawWordStartInToken { flag |= ColumnFlags.firstWordInToken }
                    sawWordStartInToken = true
                }
                // The last capital of an acronym starts the next word:
                // HTTPServer -> S, JSONDecoder -> D. The acronym's first
                // capital already opened a word, so this is never the first.
                if kind == .lower, previousKind == .upper, kindBeforePrevious == .upper {
                    flags[count - 1] |= ColumnFlags.wordStart
                }
            }
            if previousUnit == FuzzyMatch.slashUnit { flag |= ColumnFlags.afterSlash }
            if unit == FuzzyMatch.slashUnit { lastSlash = count }

            units[count] = unit
            flags[count] = flag
            kindBeforePrevious = previousKind
            previousKind = kind
            previousUnit = unit
            count += 1
        }

        /// Path-like candidates get a filename region after the last `/`.
        /// Text with whitespace is prose: everything counts as filename so a
        /// URL inside a sentence does not reorder otherwise equal matches.
        var filenameStart: Int { sawWhitespace ? 0 : lastSlash + 1 }
    }

    private static func withColumns(
        count: Int,
        fill: (inout ColumnBuilder) -> Void,
        body: (Columns) -> Hit?
    ) -> Hit? {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: max(count, 1)) { units in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: max(count, 1)) { flags in
                guard let unitBase = units.baseAddress, let flagBase = flags.baseAddress else { return nil }
                var builder = ColumnBuilder(units: unitBase, flags: flagBase)
                fill(&builder)
                return body(Columns(
                    units: builder.units,
                    flags: builder.flags,
                    count: builder.count,
                    filenameStart: builder.filenameStart
                ))
            }
        }
    }

    // MARK: - Core DP

    /// One term against one candidate. Row `qi` holds, per column, the best
    /// score with term unit `qi` matched there; transitions admit only the
    /// jumps documented on the type.
    private static func matchTerm(_ term: [UInt32], columns: Columns, track: Bool) -> Hit? {
        let qLen = term.count
        let cLen = columns.count
        guard qLen > 0, cLen >= qLen else { return nil }
        let units = columns.units
        let flags = columns.flags

        @inline(__always)
        func matches(_ unit: UInt32, _ index: Int) -> Bool {
            unit == spaceUnit ? flags[index] & ColumnFlags.spaceLike != 0 : units[index] == unit
        }

        let neg = Int.min / 4
        var prevFrom: [Int32] = []

        let best: (score: Int, end: Int)? = withUnsafeTemporaryAllocation(
            of: Int.self,
            capacity: cLen * 2 + qLen * 2
        ) { storage -> (score: Int, end: Int)? in
            // Earliest and latest feasible column per term unit. Rows only
            // scan that window; nothing outside it can be on a match path.
            guard let base = storage.baseAddress else { return nil }
            let first = base + cLen * 2
            let last = first + qLen
            var qi = 0
            var ci = 0
            while qi < qLen, ci < cLen {
                if matches(term[qi], ci) { first[qi] = ci; qi += 1 }
                ci += 1
            }
            guard qi == qLen else { return nil }
            qi = qLen - 1
            ci = cLen - 1
            while qi >= 0 {
                if matches(term[qi], ci) { last[qi] = ci; qi -= 1 }
                ci -= 1
            }

            if track { prevFrom = [Int32](repeating: -1, count: qLen * cLen) }
            var prev = base
            var curr = prev + cLen
            prev.update(repeating: neg, count: cLen)

            for qi in 0..<qLen {
                curr.update(repeating: neg, count: cLen)
                let unit = term[qi]
                let rowOffset = qi * cLen
                let start = qi == 0 ? first[0] : first[qi - 1] + 1
                let end = last[qi]

                // Running maxima of prev[j] + j over j <= ci - 2, scoped to the
                // current whitespace token, the previous token onward, and
                // the whole candidate (for `/` segment jumps).
                var tokenMax = neg, tokenArg = -1
                var prevTokenMax = neg, prevTokenArg = -1
                var allMax = neg, allArg = -1

                var ci = start
                while ci <= end {
                    let flag = flags[ci]
                    if flag & ColumnFlags.tokenStart != 0 {
                        prevTokenMax = tokenMax; prevTokenArg = tokenArg
                        tokenMax = neg; tokenArg = -1
                    }
                    if qi > 0, ci >= 2 {
                        let j = ci - 2
                        let value = prev[j]
                        if value > neg {
                            let adjusted = value + j
                            if adjusted > allMax { allMax = adjusted; allArg = j }
                            if adjusted > prevTokenMax { prevTokenMax = adjusted; prevTokenArg = j }
                            // A token starting at ci - 1 or ci excludes j.
                            if flags[ci - 1] & ColumnFlags.tokenStart == 0,
                               flag & ColumnFlags.tokenStart == 0,
                               adjusted > tokenMax {
                                tokenMax = adjusted; tokenArg = j
                            }
                        }
                    }

                    guard matches(unit, ci) else { ci += 1; continue }

                    let isWordStart = flag & ColumnFlags.wordStart != 0
                    var score = matchBase
                    if isWordStart { score += boundaryBonus }
                    if ci == 0 { score += firstCharBonus }
                    if ci >= columns.filenameStart { score += filenameBonus }

                    if qi == 0 {
                        curr[ci] = score + ci * gapPenalty
                        ci += 1
                        continue
                    }

                    var bestPrev = neg
                    var bestFrom = -1
                    if isWordStart {
                        // A later word start in this token, or the first word
                        // of the next token.
                        let firstInToken = flag & ColumnFlags.firstWordInToken != 0
                        let jumpMax = firstInToken ? prevTokenMax : tokenMax
                        if jumpMax > neg {
                            let candidate = jumpMax + (ci - 1) * gapPenalty
                            if candidate > bestPrev {
                                bestPrev = candidate
                                bestFrom = firstInToken ? prevTokenArg : tokenArg
                            }
                        }
                    }
                    if flag & ColumnFlags.afterSlash != 0, allMax > neg {
                        let candidate = allMax + (ci - 1) * gapPenalty
                        if candidate > bestPrev { bestPrev = candidate; bestFrom = allArg }
                    }
                    var skip = maxFreeSkip
                    while skip >= 1 {
                        let j = ci - 1 - skip
                        if j >= 0, prev[j] > neg {
                            let candidate = prev[j] + skip * gapPenalty
                            if candidate > bestPrev { bestPrev = candidate; bestFrom = j }
                        }
                        skip -= 1
                    }
                    // Adjacent wins ties so highlights stay contiguous.
                    if ci > 0, prev[ci - 1] > neg {
                        let candidate = prev[ci - 1] + consecutiveBonus
                        if candidate >= bestPrev { bestPrev = candidate; bestFrom = ci - 1 }
                    }

                    if bestPrev > neg {
                        curr[ci] = score + bestPrev
                        if track { prevFrom[rowOffset + ci] = Int32(bestFrom) }
                    }
                    ci += 1
                }

                swap(&prev, &curr)
            }

            var bestScore = neg
            var bestEnd = -1
            for ci in first[qLen - 1]...last[qLen - 1] where prev[ci] > bestScore {
                bestScore = prev[ci]
                bestEnd = ci
            }
            return bestScore > neg ? (bestScore, bestEnd) : nil
        }

        guard let best else { return nil }
        let score = best.score + exactBonus(term, columns: columns)
        guard track else { return Hit(score: score, positions: []) }

        var positions = [Int](repeating: 0, count: qLen)
        var column = best.end
        for qi in stride(from: qLen - 1, through: 0, by: -1) {
            positions[qi] = column
            if qi > 0 { column = Int(prevFrom[qi * cLen + column]) }
        }
        return Hit(score: score, positions: positions)
    }

    private static func exactBonus(_ term: [UInt32], columns: Columns) -> Int {
        let qLen = term.count
        var bonus = 0
        if columns.count == qLen, unitsEqual(term, columns, from: 0) {
            bonus += exactPathBonus
        }
        if columns.count - columns.filenameStart == qLen, unitsEqual(term, columns, from: columns.filenameStart) {
            bonus += exactFilenameBonus
        }
        return bonus
    }

    private static func unitsEqual(_ term: [UInt32], _ columns: Columns, from start: Int) -> Bool {
        for (offset, unit) in term.enumerated() {
            let index = start + offset
            let equal = unit == spaceUnit
                ? columns.flags[index] & ColumnFlags.spaceLike != 0
                : columns.units[index] == unit
            if !equal { return false }
        }
        return true
    }

    // MARK: - Folding

    fileprivate static func fold(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value < 0x80 { return UInt32(asciiLower(UInt8(value))) }
        if value < UInt32(foldTable.count) { return foldTable[Int(value)] }
        return value
    }

    /// Case and diacritic folding for Latin, Greek, and Cyrillic, built once.
    /// Other scripts compare as-is.
    private static let foldTable: [UInt32] = (0..<0x500).map { value in
        guard let scalar = Unicode.Scalar(UInt32(value)) else { return UInt32(value) }
        let folded = String(scalar).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = folded.unicodeScalars
        if scalars.count == 1, let first = scalars.first { return first.value }
        return UInt32(value)
    }

    @inline(__always)
    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    @inline(__always)
    private static func asciiKind(_ byte: UInt8) -> CharKind {
        switch byte {
        case 0x41...0x5A: .upper
        case 0x61...0x7A: .lower
        case 0x30...0x39: .digit
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: .whitespace
        default: .separator
        }
    }

    private static func kind(of scalar: Unicode.Scalar) -> CharKind {
        if scalar.isASCII { return asciiKind(UInt8(scalar.value)) }
        let properties = scalar.properties
        if properties.isWhitespace { return .whitespace }
        if properties.isUppercase { return .upper }
        if properties.isLowercase { return .lower }
        if properties.numericType != nil { return .digit }
        if properties.isAlphabetic { return .letter }
        return .separator
    }

    private enum CharKind: UInt8 {
        case whitespace
        case separator
        case upper
        case lower
        case digit
        /// Letters without case (CJK, Arabic, …).
        case letter

        var isWord: Bool { rawValue >= Self.upper.rawValue }
    }
}
