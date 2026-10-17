import Foundation

extension FileSuggestion {
    /// Rank workspace paths for `@file` mentions.
    ///
    /// Empty query: shortest paths first, matching iOS `fetchFileSuggestions`.
    /// Non-empty query: precision literal matches, then FuzzyMatch with file-path rerank.
    ///
    /// Builds a throwaway `FileSuggestionIndex`. Production and C1 should reuse
    /// `FileSuggestionIndex.ranked` built once per index load.
    static func ranked(
        query: String,
        paths: [String],
        limit: Int = ComposerAutocomplete.maxSuggestions
    ) -> [FileSuggestion] {
        FileSuggestionIndex(paths: paths).ranked(query: query, limit: limit)
    }

    /// Rank against a precomputed index. UI-framework-free; C1's suggestion list
    /// can call this from any queue.
    static func ranked(
        query: String,
        index: FileSuggestionIndex,
        limit: Int = ComposerAutocomplete.maxSuggestions
    ) -> [FileSuggestion] {
        index.ranked(query: query, limit: limit)
    }
}

/// Precomputed `@file` index. Built once per workspace index load.
///
/// Stores lowercased path, basename, extension class, and test-path flag so
/// each keystroke does not re-derive them. Empty-query top-N is the prefix of
/// a path-length order computed at init.
///
/// UI-framework-free. Slice C1 should hold one of these and call `ranked`.
struct FileSuggestionIndex: Sendable {
    struct Entry: Sendable {
        let path: String
        let pathLower: String
        let basenameLower: String
        let ext: String
        let isDirectory: Bool
        let isCodeFile: Bool
        let isMediaFile: Bool
        let isTestPath: Bool
        let pathCount: Int
        let basenameScalarCount: Int
    }

    let entries: [Entry]
    let paths: [String]
    /// Indices of `entries` sorted by path length (shortest first).
    /// Built on the first empty query so non-empty-only callers skip the 50k sort.
    private let emptyOrder = EmptyOrderCache()
    private let entryByPath: [String: Int]

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    init(paths: [String]) {
        var entries: [Entry] = []
        entries.reserveCapacity(paths.count)
        var entryByPath: [String: Int] = [:]
        entryByPath.reserveCapacity(paths.count)

        for path in paths {
            let pathLower = path.lowercased()
            let basenameLower = basename(pathLower)
            let ext = fileExtensionFromBasename(basenameLower)
            let entry = Entry(
                path: path,
                pathLower: pathLower,
                basenameLower: basenameLower,
                ext: ext,
                isDirectory: path.hasSuffix("/"),
                isCodeFile: codeFileExtensions.contains(ext),
                isMediaFile: mediaFileExtensions.contains(ext),
                isTestPath: isTestPath(pathLower),
                pathCount: path.count,
                basenameScalarCount: basenameLower.unicodeScalars.count
            )
            if entryByPath[path] == nil {
                entryByPath[path] = entries.count
            }
            entries.append(entry)
        }

        self.entries = entries
        self.paths = paths
        self.entryByPath = entryByPath
    }

    func ranked(
        query: String,
        limit: Int = ComposerAutocomplete.maxSuggestions
    ) -> [FileSuggestion] {
        suggestions(query: query, candidateIndices: nil, limit: limit)
    }

    func entry(for path: String) -> Entry? {
        guard let index = entryByPath[path] else { return nil }
        return entries[index]
    }

    fileprivate func emptySuggestions(limit: Int) -> [FileSuggestion] {
        guard limit > 0, !entries.isEmpty else { return [] }
        return emptyOrder.order(for: entries).prefix(limit).map { index in
            let entry = entries[index]
            return FileSuggestion(path: entry.path, isDirectory: entry.isDirectory)
        }
    }

    fileprivate func suggestions(
        query: String,
        candidateIndices: [Int]?,
        limit: Int
    ) -> [FileSuggestion] {
        guard limit > 0, !entries.isEmpty else { return [] }

        if query.isEmpty {
            return emptySuggestions(limit: limit)
        }

        return rankFileSuggestionPaths(
            query: query,
            index: self,
            candidateIndices: candidateIndices,
            limit: limit
        ).map { scored in
            FileSuggestion(
                path: scored.path,
                isDirectory: entry(for: scored.path)?.isDirectory ?? scored.path.hasSuffix("/"),
                matchPositions: scored.positions
            )
        }
    }
}

/// Lazily sorts path-length order once, the first time an empty query needs it.
private final class EmptyOrderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [Int]?

    func order(for entries: [FileSuggestionIndex.Entry]) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let computed = entries.indices.sorted { entries[$0].pathCount < entries[$1].pathCount }
        cached = computed
        return computed
    }
}

/// Ranking owner for `@file` suggestions. Keeps the previous query's matching
/// candidate set so an extending keystroke only ranks over that subset.
/// Literal containment and fuzzy subsequence are monotone under extension.
///
/// Reset on index reload (new instance) or a non-extending edit (backspace,
/// paste, another token). UI-framework-free; C1 should hold one of these.
final class FileSuggestionRanker: @unchecked Sendable {
    let index: FileSuggestionIndex

    private let lock = NSLock()
    private var ticket: UInt64 = 0
    private var lastQuery: String?
    /// Indices into `index.entries` that matched `lastQuery`. Nil means the
    /// full index (empty query or a reset).
    private var lastPool: [Int]?

    init(index: FileSuggestionIndex) {
        self.index = index
    }

    func ranked(
        query: String,
        limit: Int = ComposerAutocomplete.maxSuggestions
    ) -> [FileSuggestion] {
        lock.lock()
        ticket &+= 1
        let ticketSnapshot = ticket
        let previousQuery = lastQuery
        let previousPool = lastPool
        lock.unlock()

        if query.isEmpty {
            let results = index.emptySuggestions(limit: limit)
            install(ticket: ticketSnapshot, query: "", pool: nil)
            return results
        }

        let extending = previousQuery.map { !$0.isEmpty && query.hasPrefix($0) } ?? false
        let startPool = extending ? previousPool : nil
        let queryLower = query.lowercased()
        var nextPool: [Int] = []
        nextPool.reserveCapacity(startPool?.count ?? min(index.entries.count, 1_024))

        forEachCandidate(index: index, candidateIndices: startPool) { offset, entry in
            if hasSubsequence(queryLower: queryLower, pathLower: entry.pathLower) {
                nextPool.append(offset)
            }
        }

        let results = index.suggestions(query: query, candidateIndices: nextPool, limit: limit)
        install(ticket: ticketSnapshot, query: query, pool: nextPool)
        return results
    }

    private func install(ticket expected: UInt64, query: String, pool: [Int]?) {
        lock.lock()
        defer { lock.unlock() }
        guard ticket == expected else { return }
        lastQuery = query
        lastPool = pool
    }
}

// MARK: - File Suggestion Ranking

private enum LiteralMatchClass: Int {
    case none = 0
    case pathContains = 1
    case filenameContains = 2
    case filenamePrefix = 3
    case filenameExact = 4
    case pathExact = 5
}

private struct PrecisionLiteralCandidate {
    let path: String
    let index: Int
    let literalClass: LiteralMatchClass
    let fileNameLength: Int
    let isCodeFile: Bool
    let isMediaFile: Bool
    let isTestPath: Bool
}

private func rankFileSuggestionPaths(
    query: String,
    index: FileSuggestionIndex,
    candidateIndices: [Int]?,
    limit: Int
) -> [FuzzyMatch.ScoredPath] {
    // Precision-first: prefer literal filename/path matches for @mentions.
    let literal = precisionLiteralMatches(
        query: query,
        index: index,
        candidateIndices: candidateIndices,
        limit: limit
    )
    if literal.count >= limit {
        return literal
    }

    // Fuzzy fallback for abbreviation-style queries.
    let candidates: [String]
    if let candidateIndices {
        candidates = candidateIndices.map { index.entries[$0].path }
    } else {
        candidates = index.paths
    }
    let preLimit = min(candidates.count, max(limit * 8, 64))
    let fuzzy = FuzzyMatch.search(query: query, candidates: candidates, limit: preLimit)
    let rerankedFuzzy = rerankFileSuggestions(query: query, results: fuzzy, index: index, limit: preLimit)
    return mergeSuggestions(primary: literal, secondary: rerankedFuzzy, limit: limit)
}

/// Merge suggestions while preserving the order of primary results.
private func mergeSuggestions(
    primary: [FuzzyMatch.ScoredPath],
    secondary: [FuzzyMatch.ScoredPath],
    limit: Int
) -> [FuzzyMatch.ScoredPath] {
    guard limit > 0 else { return [] }

    var merged: [FuzzyMatch.ScoredPath] = []
    merged.reserveCapacity(min(limit, primary.count + secondary.count))

    var seen = Set<String>()

    for candidate in primary where merged.count < limit {
        if seen.insert(candidate.path).inserted {
            merged.append(candidate)
        }
    }

    for candidate in secondary where merged.count < limit {
        if seen.insert(candidate.path).inserted {
            merged.append(candidate)
        }
    }

    return merged
}

/// Precision-first literal ranking for @file mentions.
///
/// We prioritize contiguous filename/path matches before fuzzy fallback so
/// users typing explicit file tokens get deterministic top hits.
private func precisionLiteralMatches(
    query: String,
    index: FileSuggestionIndex,
    candidateIndices: [Int]?,
    limit: Int
) -> [FuzzyMatch.ScoredPath] {
    guard limit > 0 else { return [] }

    let queryLower = query.lowercased()
    let queryScalarCount = query.unicodeScalars.count
    guard !queryLower.isEmpty, queryScalarCount > 0 else { return [] }

    let prefersTests = queryLower.contains("test")

    var literalCandidates: [PrecisionLiteralCandidate] = []
    literalCandidates.reserveCapacity(min(candidateIndices?.count ?? index.entries.count, 256))

    forEachCandidate(index: index, candidateIndices: candidateIndices) { offset, entry in
        let literalClass = literalMatchClass(
            queryLower: queryLower,
            pathLower: entry.pathLower,
            fileNameLower: entry.basenameLower
        )
        if literalClass == .none {
            return
        }

        literalCandidates.append(
            PrecisionLiteralCandidate(
                path: entry.path,
                index: offset,
                literalClass: literalClass,
                fileNameLength: entry.basenameScalarCount,
                isCodeFile: entry.isCodeFile,
                isMediaFile: entry.isMediaFile,
                isTestPath: entry.isTestPath
            )
        )
    }

    if literalCandidates.isEmpty {
        return []
    }

    literalCandidates.sort { lhs, rhs in
        if lhs.literalClass != rhs.literalClass {
            return lhs.literalClass.rawValue > rhs.literalClass.rawValue
        }

        // For non-exact matches, prefer code files over media assets.
        if queryScalarCount >= 3,
           lhs.literalClass.rawValue <= LiteralMatchClass.filenamePrefix.rawValue {
            let lhsTypeRank = lhs.isMediaFile ? -1 : (lhs.isCodeFile ? 1 : 0)
            let rhsTypeRank = rhs.isMediaFile ? -1 : (rhs.isCodeFile ? 1 : 0)
            if lhsTypeRank != rhsTypeRank {
                return lhsTypeRank > rhsTypeRank
            }
        }

        // Unless explicitly searching tests, prefer implementation paths.
        if !prefersTests, lhs.isTestPath != rhs.isTestPath {
            return !lhs.isTestPath
        }

        // Prefer filenames closer in length to query.
        if lhs.literalClass.rawValue >= LiteralMatchClass.filenameContains.rawValue {
            let lhsDelta = abs(lhs.fileNameLength - queryScalarCount)
            let rhsDelta = abs(rhs.fileNameLength - queryScalarCount)
            if lhsDelta != rhsDelta {
                return lhsDelta < rhsDelta
            }
        }

        if lhs.path.count != rhs.path.count {
            return lhs.path.count < rhs.path.count
        }

        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }

        return lhs.index < rhs.index
    }

    return literalCandidates
        .prefix(limit)
        .enumerated()
        .map { rank, candidate in
            FuzzyMatch.ScoredPath(
                path: candidate.path,
                score: (candidate.literalClass.rawValue * 10_000) - rank,
                positions: literalMatchPositions(
                    query: query,
                    path: candidate.path,
                    literalClass: candidate.literalClass
                )
            )
        }
}

private func forEachCandidate(
    index: FileSuggestionIndex,
    candidateIndices: [Int]?,
    _ body: (Int, FileSuggestionIndex.Entry) -> Void
) {
    if let candidateIndices {
        for offset in candidateIndices {
            body(offset, index.entries[offset])
        }
        return
    }
    for (offset, entry) in index.entries.enumerated() {
        body(offset, entry)
    }
}

private func hasSubsequence(queryLower: String, pathLower: String) -> Bool {
    if queryLower.isEmpty { return true }
    let queryBytes = Array(queryLower.utf8)
    var qi = 0
    for byte in pathLower.utf8 {
        if qi < queryBytes.count, byte == queryBytes[qi] {
            qi += 1
        }
    }
    return qi == queryBytes.count
}

private func literalMatchClass(
    queryLower: String,
    pathLower: String,
    fileNameLower: String
) -> LiteralMatchClass {
    if pathLower == queryLower {
        return .pathExact
    }
    if fileNameLower == queryLower {
        return .filenameExact
    }
    if fileNameLower.hasPrefix(queryLower) {
        return .filenamePrefix
    }
    if fileNameLower.contains(queryLower) {
        return .filenameContains
    }
    if pathLower.contains(queryLower) {
        return .pathContains
    }
    return .none
}

private func literalMatchPositions(
    query: String,
    path: String,
    literalClass: LiteralMatchClass
) -> [Int] {
    let queryScalars = Array(query.unicodeScalars)
    let pathScalars = Array(path.unicodeScalars)
    guard !queryScalars.isEmpty, !pathScalars.isEmpty else { return [] }

    let filenameStart = filenameStartScalarIndex(pathScalars)

    switch literalClass {
    case .filenameExact, .filenamePrefix, .filenameContains:
        if let positions = contiguousMatchPositions(
            queryScalars,
            in: pathScalars,
            start: filenameStart,
            end: pathScalars.count
        ) {
            return positions
        }
        return contiguousMatchPositions(queryScalars, in: pathScalars, start: 0, end: pathScalars.count) ?? []

    case .pathExact, .pathContains:
        return contiguousMatchPositions(queryScalars, in: pathScalars, start: 0, end: pathScalars.count) ?? []

    case .none:
        return []
    }
}

private func filenameStartScalarIndex(_ pathScalars: [UnicodeScalar]) -> Int {
    if let slash = pathScalars.lastIndex(of: "/") {
        return slash + 1
    }
    return 0
}

private func contiguousMatchPositions(
    _ queryScalars: [UnicodeScalar],
    in pathScalars: [UnicodeScalar],
    start: Int,
    end: Int
) -> [Int]? {
    let count = queryScalars.count
    guard count > 0 else { return [] }
    guard start >= 0, end <= pathScalars.count, start < end, (end - start) >= count else {
        return nil
    }

    let normalizedQuery = queryScalars.map(normalizedScalar)

    for index in start...(end - count) {
        var matched = true
        for offset in 0..<count {
            if normalizedScalar(pathScalars[index + offset]) != normalizedQuery[offset] {
                matched = false
                break
            }
        }
        if matched {
            return Array(index..<(index + count))
        }
    }

    return nil
}

private func normalizedScalar(_ scalar: UnicodeScalar) -> UInt32 {
    let value = scalar.value
    // ASCII-only fold (paths are predominantly ASCII, keeps this allocation-free).
    if value >= 65, value <= 90 {
        return value + 32
    }
    return value
}

/// File-path specific reranking on top of generic FuzzyMatch scores.
///
/// Goals:
/// - Prefer filename prefix/substring hits over path-segment split matches
/// - Favor compact contiguous matches in filename tails
/// - De-prioritize media files for code-like queries
/// - De-prioritize test files unless the query is explicitly test-oriented
private func rerankFileSuggestions(
    query: String,
    results: [FuzzyMatch.ScoredPath],
    index: FileSuggestionIndex,
    limit: Int
) -> [FuzzyMatch.ScoredPath] {
    guard !results.isEmpty, limit > 0 else { return [] }

    let queryLower = query.lowercased()
    let queryScalarCount = query.unicodeScalars.count

    struct Ranked {
        let scored: FuzzyMatch.ScoredPath
        let adjustedScore: Int
    }

    let ranked = results.map { scored in
        Ranked(
            scored: scored,
            adjustedScore: adjustedFilePathScore(
                queryLower: queryLower,
                queryScalarCount: queryScalarCount,
                scored: scored,
                entry: index.entry(for: scored.path)
            )
        )
    }
    .sorted { lhs, rhs in
        if lhs.adjustedScore != rhs.adjustedScore {
            return lhs.adjustedScore > rhs.adjustedScore
        }
        if lhs.scored.score != rhs.scored.score {
            return lhs.scored.score > rhs.scored.score
        }
        if lhs.scored.path.count != rhs.scored.path.count {
            return lhs.scored.path.count < rhs.scored.path.count
        }
        return lhs.scored.path < rhs.scored.path
    }

    return Array(ranked.prefix(limit).map(\.scored))
}

private func adjustedFilePathScore(
    queryLower: String,
    queryScalarCount: Int,
    scored: FuzzyMatch.ScoredPath,
    entry: FileSuggestionIndex.Entry?
) -> Int {
    var score = scored.score

    let pathLower = entry?.pathLower ?? scored.path.lowercased()
    let fileNameLower = entry?.basenameLower ?? basename(pathLower)
    let ext = entry?.ext ?? fileExtensionFromBasename(fileNameLower)
    let isCode = entry?.isCodeFile ?? codeFileExtensions.contains(ext)
    let isMedia = entry?.isMediaFile ?? mediaFileExtensions.contains(ext)
    let testPath = entry?.isTestPath ?? isTestPath(pathLower)

    // Strongly prefer direct filename matches for user-entered tokens.
    if fileNameLower == queryLower {
        score += 6_000
    } else if fileNameLower.hasPrefix(queryLower) {
        score += 40
    } else if fileNameLower.contains(queryLower) {
        score += 8
    }

    // Prefer matches fully within the filename tail.
    if matchIsFullyInFilename(scored.positions, path: scored.path) {
        score += 12
    }

    // Reward compact contiguous matches over split matches across separators.
    let longestRun = longestContiguousRun(scored.positions)
    if longestRun > 1 {
        score += (longestRun - 1) * 5
    }
    if let span = matchSpan(scored.positions) {
        let extra = max(0, queryScalarCount - (span - queryScalarCount))
        score += extra * 2
    }

    // For code-like queries, demote media assets and lightly boost code files.
    if queryScalarCount >= 3 {
        if isMedia {
            score -= 30
        } else if isCode {
            score += 8
        }
    }

    // Prefer implementation paths over test trees unless query asks for tests.
    if queryScalarCount >= 5,
       !queryLower.contains("test"),
       testPath {
        score -= 14
    }

    return score
}

private func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

private func fileExtensionFromBasename(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else {
        return ""
    }
    return String(name[name.index(after: dot)...])
}

private func isTestPath(_ pathLower: String) -> Bool {
    pathLower.contains("/tests/") ||
        pathLower.contains("/test/") ||
        pathLower.contains("/oppitests/")
}

private func matchIsFullyInFilename(_ positions: [Int], path: String) -> Bool {
    guard !positions.isEmpty else { return false }

    let scalars = Array(path.unicodeScalars)
    var filenameStart = 0
    if let slash = scalars.lastIndex(of: "/") {
        filenameStart = slash + 1
    }

    return positions.allSatisfy { $0 >= filenameStart }
}

private func longestContiguousRun(_ positions: [Int]) -> Int {
    guard !positions.isEmpty else { return 0 }
    var best = 1
    var run = 1
    for i in 1..<positions.count {
        if positions[i] == positions[i - 1] + 1 {
            run += 1
            if run > best { best = run }
        } else {
            run = 1
        }
    }
    return best
}

private func matchSpan(_ positions: [Int]) -> Int? {
    guard let first = positions.first, let last = positions.last else { return nil }
    return (last - first) + 1
}

private let codeFileExtensions: Set<String> = [
    "swift", "m", "mm", "c", "cc", "cpp", "h", "hpp",
    "ts", "tsx", "js", "jsx", "json",
    "go", "rs", "py", "rb", "java", "kt", "kts",
    "sh", "bash", "zsh", "fish",
    "yaml", "yml", "toml", "ini", "conf", "xml", "sql", "proto"
]

private let mediaFileExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf",
    "mov", "mp4", "mp3", "wav", "aac", "m4a"
]
