import Foundation

extension FileSuggestion {
    /// Rank workspace paths for `@file` mentions.
    ///
    /// Empty query: shortest paths first, matching iOS `fetchFileSuggestions`.
    /// Non-empty query: precision literal matches, then FuzzyMatch with file-path rerank.
    static func ranked(
        query: String,
        paths: [String],
        limit: Int = ComposerAutocomplete.maxSuggestions
    ) -> [FileSuggestion] {
        guard limit > 0, !paths.isEmpty else { return [] }

        if query.isEmpty {
            return paths
                .sorted { $0.count < $1.count }
                .prefix(limit)
                .map { FileSuggestion(path: $0, isDirectory: $0.hasSuffix("/")) }
        }

        return rankFileSuggestionPaths(query: query, candidates: paths, limit: limit).map { scored in
            FileSuggestion(
                path: scored.path,
                isDirectory: scored.path.hasSuffix("/"),
                matchPositions: scored.positions
            )
        }
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
    let positions: [Int]
    let literalClass: LiteralMatchClass
    let fileNameLength: Int
    let isCodeFile: Bool
    let isMediaFile: Bool
    let isTestPath: Bool
}

private func rankFileSuggestionPaths(
    query: String,
    candidates: [String],
    limit: Int
) -> [FuzzyMatch.ScoredPath] {
    // Precision-first: prefer literal filename/path matches for @mentions.
    let literal = precisionLiteralMatches(query: query, candidates: candidates, limit: limit)
    if literal.count >= limit {
        return literal
    }

    // Fuzzy fallback for abbreviation-style queries.
    let preLimit = min(candidates.count, max(limit * 8, 64))
    let fuzzy = FuzzyMatch.search(query: query, candidates: candidates, limit: preLimit)
    let rerankedFuzzy = rerankFileSuggestions(query: query, results: fuzzy, limit: preLimit)
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
    candidates: [String],
    limit: Int
) -> [FuzzyMatch.ScoredPath] {
    guard limit > 0 else { return [] }

    let queryLower = query.lowercased()
    let queryScalarCount = query.unicodeScalars.count
    guard !queryLower.isEmpty, queryScalarCount > 0 else { return [] }

    let prefersTests = queryLower.contains("test")

    var literalCandidates: [PrecisionLiteralCandidate] = []
    literalCandidates.reserveCapacity(min(candidates.count, 256))

    for (index, path) in candidates.enumerated() {
        let pathLower = path.lowercased()
        let fileNameLower = basename(pathLower)

        let literalClass = literalMatchClass(
            queryLower: queryLower,
            pathLower: pathLower,
            fileNameLower: fileNameLower
        )
        if literalClass == .none {
            continue
        }

        let ext = fileExtension(pathLower)
        let positions = literalMatchPositions(query: query, path: path, literalClass: literalClass)

        literalCandidates.append(
            PrecisionLiteralCandidate(
                path: path,
                index: index,
                positions: positions,
                literalClass: literalClass,
                fileNameLength: fileNameLower.unicodeScalars.count,
                isCodeFile: codeFileExtensions.contains(ext),
                isMediaFile: mediaFileExtensions.contains(ext),
                isTestPath: isTestPath(pathLower)
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
                positions: candidate.positions
            )
        }
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
                scored: scored
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
    scored: FuzzyMatch.ScoredPath
) -> Int {
    var score = scored.score

    let pathLower = scored.path.lowercased()
    let fileNameLower = basename(pathLower)
    let ext = fileExtension(pathLower)

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
        if mediaFileExtensions.contains(ext) {
            score -= 30
        } else if codeFileExtensions.contains(ext) {
            score += 8
        }
    }

    // Prefer implementation paths over test trees unless query asks for tests.
    if queryScalarCount >= 5,
       !queryLower.contains("test"),
       isTestPath(pathLower) {
        score -= 14
    }

    return score
}

private func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

private func fileExtension(_ path: String) -> String {
    let name = basename(path)
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
