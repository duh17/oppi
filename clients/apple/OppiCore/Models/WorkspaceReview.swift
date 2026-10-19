import Foundation

struct WorkspaceReviewFile: Codable, Sendable, Equatable, Identifiable {
    let path: String
    let status: String
    let addedLines: Int?
    let removedLines: Int?
    let isStaged: Bool
    let isUnstaged: Bool
    let isUntracked: Bool
    let selectedSessionTouched: Bool

    var id: String { path }

    var statusLabel: String {
        GitFileStatus(status: status, path: path, addedLines: addedLines, removedLines: removedLines).label
    }
}

struct WorkspaceReviewDiffResponse: Codable, Sendable, Equatable {
    let workspaceId: String
    let path: String
    let baselineText: String
    let currentText: String
    let addedLines: Int
    let removedLines: Int
    let hunks: [WorkspaceReviewDiffHunk]
    /// Number of trace mutations (session diff only).
    let revisionCount: Int?
    /// Cache key for client-side caching (session diff only).
    let cacheKey: String?
}

struct WorkspaceQuickActionOption: Codable, Sendable, Equatable, Identifiable {
    enum Source: String, Codable, Sendable, Equatable {
        case prompt
    }

    let id: String
    let title: String
    let commandName: String
    let description: String?
    let argumentHint: String?
    let source: Source
    let sourceScope: String?
    let promptTemplateName: String

    var progressTitle: String { "Starting /\(commandName)…" }
}

struct WorkspaceQuickActionsResponse: Codable, Sendable, Equatable {
    let actions: [WorkspaceQuickActionOption]
}

struct WorkspaceQuickActionSelectionResponse: Codable, Sendable, Equatable {
    let promptTemplateName: String
    let selectedPathCount: Int
    let visiblePrompt: String
    let filePaths: [String]
}

struct WorkspaceQuickActionSessionResponse: Codable, Sendable, Equatable {
    let promptTemplateName: String
    let selectedPathCount: Int
    let session: Session
    let visiblePrompt: String
    let filePaths: [String]
}

/// Navigation destination for a launched session.
/// Carries optional repo file pointers so the destination chat can populate review-file context.
/// `commitSha`/`commitMessage` attach a git commit instead of changed-file paths.
struct QuickActionSessionNavDestination: Identifiable, Hashable {
    let id: String
    let inputText: String
    let filePaths: [String]
    let fileDisplayPrefix: String
    let commitSha: String
    let commitMessage: String

    init(
        id: String,
        inputText: String,
        filePaths: [String],
        fileDisplayPrefix: String,
        commitSha: String = "",
        commitMessage: String = ""
    ) {
        self.id = id
        self.inputText = inputText
        self.filePaths = filePaths
        self.fileDisplayPrefix = fileDisplayPrefix
        self.commitSha = commitSha
        self.commitMessage = commitMessage
    }
}

extension QuickActionSessionNavDestination {
    static func empty(sessionId: String) -> Self {
        Self(id: sessionId, inputText: "", filePaths: [], fileDisplayPrefix: "")
    }

    static func attaching(sessionId: String, filePath: String) -> Self {
        attaching(sessionId: sessionId, filePaths: [filePath])
    }

    static func attaching(sessionId: String, filePaths: [String]) -> Self {
        Self(id: sessionId, inputText: "", filePaths: filePaths, fileDisplayPrefix: "")
    }

    static func attachingCommit(sessionId: String, sha: String, message: String) -> Self {
        Self(
            id: sessionId,
            inputText: "",
            filePaths: [],
            fileDisplayPrefix: "",
            commitSha: sha,
            commitMessage: message
        )
    }
}

// MARK: - Review Comments

enum ReviewCommentAuthor: String, Codable, Sendable, Equatable {
    case human
    case agent
}

enum ReviewCommentStatus: String, Codable, Sendable, Equatable {
    case staged
    case sent
    case open
    case resolved
    case dismissed
}

enum ReviewCommentSeverity: String, Codable, Sendable, Equatable {
    case error
    case warning
    case info
}

enum ReviewCommentReferenceSource: String, Codable, Sendable, Equatable {
    case gitDiff = "git_diff"
    case file
    case timelineText = "timeline_text"
    case toolOutput = "tool_output"
    case terminalOutput = "terminal_output"
    case image
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ReviewCommentReference: Codable, Sendable, Equatable {
    let source: ReviewCommentReferenceSource
    var label: String?
    var path: String?
    var side: String?
    var startLine: Int?
    var endLine: Int?
    var selectedText: String?
    var languageHint: String? = nil
    var toolCallId: String?
    var timelineItemId: String?
    var url: String?
    /// DOM-only rendered-element anchor. Older drafts omit this key.
    var htmlDOMAnchor: HTMLDOMElementAnchor? = nil
    /// Local persisted diagram-object reference. Older drafts omit this key.
    var semanticAnchor: ReviewCommentSemanticAnchor? = nil
}

extension ReviewCommentReference {
    private enum CodingKeys: String, CodingKey {
        case source, label, path, side, startLine, endLine, selectedText, languageHint
        case toolCallId, timelineItemId, url, htmlDOMAnchor, semanticAnchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(ReviewCommentReferenceSource.self, forKey: .source)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        side = try container.decodeIfPresent(String.self, forKey: .side)
        startLine = try container.decodeIfPresent(Int.self, forKey: .startLine)
        endLine = try container.decodeIfPresent(Int.self, forKey: .endLine)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText)
        languageHint = try container.decodeIfPresent(String.self, forKey: .languageHint)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        timelineItemId = try container.decodeIfPresent(String.self, forKey: .timelineItemId)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        do {
            htmlDOMAnchor = try container.decodeIfPresent(HTMLDOMElementAnchor.self, forKey: .htmlDOMAnchor)
        } catch {
            htmlDOMAnchor = nil
        }
        semanticAnchor = try container.decodeIfPresent(ReviewCommentSemanticAnchor.self, forKey: .semanticAnchor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(side, forKey: .side)
        try container.encodeIfPresent(startLine, forKey: .startLine)
        try container.encodeIfPresent(endLine, forKey: .endLine)
        try container.encodeIfPresent(selectedText, forKey: .selectedText)
        try container.encodeIfPresent(languageHint, forKey: .languageHint)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(timelineItemId, forKey: .timelineItemId)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(htmlDOMAnchor, forKey: .htmlDOMAnchor)
        try container.encodeIfPresent(semanticAnchor, forKey: .semanticAnchor)
    }
}

extension ReviewCommentReference {
    var displayPath: String? {
        Self.displayPath(from: path)
    }

    static func displayPath(from rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let patchPath = pathFromPatchHeader(trimmed) {
            return normalizedDisplayPath(patchPath)
        }

        if trimmed.contains("\n") {
            return nil
        }

        if let patchLabel = trimmed.removingPrefix("patch:") {
            let normalized = normalizedDisplayPath(patchLabel)
            return normalized.isEmpty ? nil : normalized
        }

        return normalizedDisplayPath(trimmed)
    }

    private static func pathFromPatchHeader(_ text: String) -> String? {
        let markers = ["*** Update File:", "*** Add File:", "*** Delete File:"]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in markers where trimmedLine.hasPrefix(marker) {
                let value = trimmedLine.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func normalizedDisplayPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let workspaceRange = trimmed.range(of: "/workspace/") {
            let tail = trimmed[workspaceRange.upperBound...]
            if let slash = tail.firstIndex(of: "/") {
                return String(tail[tail.index(after: slash)...])
            }
        }

        return trimmed
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ReviewCommentAttachment: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let kind: String
    let mimeType: String
    var width: Int?
    var height: Int?
    let storageKey: String
}

struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let workspaceId: String
    var sessionId: String?
    var turnId: String?
    let author: ReviewCommentAuthor
    var status: ReviewCommentStatus
    var severity: ReviewCommentSeverity?
    var body: String
    var attachments: [ReviewCommentAttachment]?
    let reference: ReviewCommentReference
    let createdAt: Int64
    var updatedAt: Int64
    var sentAt: Int64?
}

struct WorkspaceReviewDiffHunk: Codable, Sendable, Equatable, Identifiable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [WorkspaceReviewDiffLine]

    var id: String {
        "\(oldStart):\(oldCount):\(newStart):\(newCount)"
    }

    var headerText: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }

}

struct WorkspaceReviewDiffLine: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case context
        case added
        case removed

        // periphery:ignore
        var prefix: String {
            switch self {
            case .context: return " "
            case .added: return "+"
            case .removed: return "-"
            }
        }
    }

    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    let spans: [WorkspaceReviewDiffSpan]?

    var id: String {
        "\(kind.rawValue):\(oldLine ?? -1):\(newLine ?? -1):\(text)"
    }
}

/// Intra-line diff span. `start`/`end` are UTF-16 code-unit offsets,
/// matching the server contract and `NSRange` used by renderers.
struct WorkspaceReviewDiffSpan: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case changed
    }

    let start: Int
    let end: Int
    let kind: Kind

    /// Word highlights as painted. Spans stay the minimal word edit (server
    /// and client agree on them), but two spans separated only by spaces or
    /// tabs paint as one run, so `, keepsLineStart: Bool = false` reads as one
    /// edit instead of a box per word.
    static func paintRuns(_ spans: [WorkspaceReviewDiffSpan], in text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var runs: [NSRange] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start >= 0, span.end > span.start, span.end <= units.count else { continue }
            if let last = runs.last, NSMaxRange(last) <= span.start,
               units[NSMaxRange(last)..<span.start].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                runs[runs.count - 1].length = span.end - last.location
            } else {
                runs.append(NSRange(location: span.start, length: span.end - span.start))
            }
        }
        return runs
    }
}

enum WorkspaceReviewDiffHunkBuilder {
    private static let contextLines = 3
    // Word-span pairing mirrors server `workspace-review-diff.ts`, so a diff
    // the client builds (tool calls, conflict review) marks the same words as
    // a server review diff.

    /// A removed and an added line are the same line edited only when at least
    /// half of their combined non-whitespace text is shared. Below that, word
    /// spans mark almost every token of two unrelated lines: noise, not a diff.
    private static let wordPairMinSimilarity = 0.5
    /// How many added lines past the previous pair a removed line may look for its edit.
    private static let wordPairLookahead = 8
    /// Most changed places per side for a positional pair that is not similar.
    private static let wordFallbackMaxRegions = 3
    /// Token-LCS cells for one similar pair.
    private static let maxTokenDiffCells = 40_000
    /// Token-LCS cells for one positional fallback pair: a few dozen token edits.
    private static let wordFallbackMaxCells = 4_096
    /// Token-LCS cells for one whole diff; past it, remaining lines stay line-level.
    private static let wordDiffMaxCells = 4_000_000

    /// Build hunks from diff lines with word-level change spans.
    ///
    /// This is the single owner of intra-line spans for client-computed diffs:
    /// pairs of removed/added lines within each change group get token-LCS
    /// spans, so every diff surface (timeline row, full screen, review) shows
    /// the same word highlights.
    static func buildHunks(from lines: [DiffLine]) -> [WorkspaceReviewDiffHunk] {
        var numberedLines = number(lines)
        applyWordLevelHighlights(&numberedLines)
        guard !numberedLines.isEmpty else { return [] }

        var changeWindows: [(start: Int, end: Int)] = []
        var index = 0

        while index < numberedLines.count {
            if numberedLines[index].kind == .context {
                index += 1
                continue
            }

            var end = index
            while end + 1 < numberedLines.count, numberedLines[end + 1].kind != .context {
                end += 1
            }

            changeWindows.append((
                start: max(0, index - contextLines),
                end: min(numberedLines.count - 1, end + contextLines)
            ))
            index = end + 1
        }

        guard let firstWindow = changeWindows.first else { return [] }
        var mergedWindows: [(start: Int, end: Int)] = [firstWindow]

        for next in changeWindows.dropFirst() {
            let lastIndex = mergedWindows.count - 1
            if next.start <= mergedWindows[lastIndex].end + 1 {
                mergedWindows[lastIndex].end = max(mergedWindows[lastIndex].end, next.end)
            } else {
                mergedWindows.append(next)
            }
        }

        return mergedWindows.map { window in
            let slice = Array(numberedLines[window.start...window.end])
            let oldNumbers = slice.compactMap(\.oldLine)
            let newNumbers = slice.compactMap(\.newLine)

            return WorkspaceReviewDiffHunk(
                oldStart: oldNumbers.first ?? 0,
                oldCount: oldNumbers.count,
                newStart: newNumbers.first ?? 0,
                newCount: newNumbers.count,
                lines: slice
            )
        }
    }

    private static func number(_ lines: [DiffLine]) -> [WorkspaceReviewDiffLine] {
        var oldLine = 1
        var newLine = 1

        return lines.map { line in
            switch line.kind {
            case .context:
                if let explicitOld = line.oldLineNumber { oldLine = explicitOld }
                if let explicitNew = line.newLineNumber { newLine = explicitNew }
                let numbered = WorkspaceReviewDiffLine(
                    kind: .context,
                    text: line.text,
                    oldLine: oldLine,
                    newLine: newLine,
                    spans: nil
                )
                oldLine += 1
                newLine += 1
                return numbered
            case .removed:
                if let explicitOld = line.oldLineNumber { oldLine = explicitOld }
                let numbered = WorkspaceReviewDiffLine(
                    kind: .removed,
                    text: line.text,
                    oldLine: oldLine,
                    newLine: nil,
                    spans: nil
                )
                oldLine += 1
                return numbered
            case .added:
                if let explicitNew = line.newLineNumber { newLine = explicitNew }
                let numbered = WorkspaceReviewDiffLine(
                    kind: .added,
                    text: line.text,
                    oldLine: nil,
                    newLine: newLine,
                    spans: nil
                )
                newLine += 1
                return numbered
            }
        }
    }

    // MARK: - Word-Level Span Computation

    /// Word spans within each change block, in two passes that keep both sides
    /// in order:
    /// 1. Each removed line pairs with the first similar added line at or after
    ///    the previous pair (within `wordPairLookahead`).
    /// 2. Lines left between two pairs pair by position when the word diff
    ///    stays small (`fewChangeWordSpans`).
    /// Lines that pair with nothing stay line-level.
    private static func applyWordLevelHighlights(_ lines: inout [WorkspaceReviewDiffLine]) {
        var index = 0
        var budget = wordDiffMaxCells

        while index < lines.count {
            guard lines[index].kind != .context else {
                index += 1
                continue
            }

            // Collect contiguous change group
            var removed: [Int] = []
            var added: [Int] = []
            var cursor = index

            while cursor < lines.count, lines[cursor].kind != .context {
                if lines[cursor].kind == .removed { removed.append(cursor) }
                if lines[cursor].kind == .added { added.append(cursor) }
                cursor += 1
            }

            if !removed.isEmpty, !added.isEmpty {
                let removedWords = removed.map { WordLine(lines[$0].text) }
                let addedWords = added.map { WordLine(lines[$0].text) }
                func apply(_ spans: WordSpans, removed removedIndex: Int, added addedIndex: Int) {
                    if !spans.old.isEmpty { lines[removed[removedIndex]] = lines[removed[removedIndex]].withSpans(spans.old) }
                    if !spans.new.isEmpty { lines[added[addedIndex]] = lines[added[addedIndex]].withSpans(spans.new) }
                }

                var pairs: [(removed: Int, added: Int)] = []
                var nextAdded = 0
                for removedIndex in removed.indices {
                    let searchEnd = min(added.count, nextAdded + wordPairLookahead)
                    for candidate in nextAdded..<max(nextAdded, searchEnd) {
                        guard let spans = similarLineWordSpans(removedWords[removedIndex], addedWords[candidate], budget: &budget) else {
                            continue
                        }
                        apply(spans, removed: removedIndex, added: candidate)
                        pairs.append((removedIndex, candidate))
                        nextAdded = candidate + 1
                        break
                    }
                }

                var previousRemoved = -1
                var previousAdded = -1
                for pair in pairs + [(removed.count, added.count)] {
                    let gap = min(pair.removed - previousRemoved, pair.added - previousAdded) - 1
                    if gap > 0 {
                        for offset in 1...gap {
                            let removedIndex = previousRemoved + offset
                            let addedIndex = previousAdded + offset
                            if let spans = fewChangeWordSpans(removedWords[removedIndex], addedWords[addedIndex], budget: &budget) {
                                apply(spans, removed: removedIndex, added: addedIndex)
                            }
                        }
                    }
                    previousRemoved = pair.removed
                    previousAdded = pair.added
                }
            }

            index = cursor
        }
    }

    // MARK: - Token Diff

    private struct Token {
        let value: String
        let start: Int
        let end: Int

        var isSpace: Bool { value.unicodeScalars.first?.properties.isWhitespace ?? false }
    }

    /// Tokenized line text with its non-whitespace length, the unit of similarity.
    private struct WordLine {
        let tokens: [Token]
        let contentChars: Int

        init(_ text: String) {
            tokens = WorkspaceReviewDiffHunkBuilder.tokenize(text)
            contentChars = tokens.reduce(0) { $0 + ($1.isSpace ? 0 : $1.end - $1.start) }
        }
    }

    private typealias WordSpans = (old: [WorkspaceReviewDiffSpan], new: [WorkspaceReviewDiffSpan])

    /// Tokenize text into words, whitespace runs, and punctuation groups.
    /// Token offsets are UTF-16 code units so spans can be applied directly as
    /// `NSRange` and match the server's JavaScript string offsets.
    private static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }

        var tokens: [Token] = []
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let start = utf16Offset(of: index, in: text)
            let startScalar = scalars[index]

            if startScalar.properties.isWhitespace {
                // Whitespace run
                var end = scalars.index(after: index)
                while end < scalars.endIndex, scalars[end].properties.isWhitespace {
                    end = scalars.index(after: end)
                }
                let endOffset = utf16Offset(of: end, in: text)
                let value = String(scalars[index..<end])
                tokens.append(Token(value: value, start: start, end: endOffset))
                index = end
            } else if startScalar.properties.isAlphabetic
                || startScalar.properties.numericType != nil
                || startScalar == "_" {
                // Word (letters, digits, underscores)
                var end = scalars.index(after: index)
                while end < scalars.endIndex {
                    let s = scalars[end]
                    if s.properties.isAlphabetic || s.properties.numericType != nil || s == "_" {
                        end = scalars.index(after: end)
                    } else {
                        break
                    }
                }
                let endOffset = utf16Offset(of: end, in: text)
                let value = String(scalars[index..<end])
                tokens.append(Token(value: value, start: start, end: endOffset))
                index = end
            } else {
                // Punctuation / operator group
                var end = scalars.index(after: index)
                while end < scalars.endIndex {
                    let s = scalars[end]
                    if !s.properties.isWhitespace
                        && !s.properties.isAlphabetic
                        && s.properties.numericType == nil
                        && s != "_" {
                        end = scalars.index(after: end)
                    } else {
                        break
                    }
                }
                let endOffset = utf16Offset(of: end, in: text)
                let value = String(scalars[index..<end])
                tokens.append(Token(value: value, start: start, end: endOffset))
                index = end
            }
        }

        return tokens
    }

    private static func utf16Offset(
        of index: String.UnicodeScalarView.Index,
        in text: String
    ) -> Int {
        guard let utf16Index = index.samePosition(in: text.utf16) else {
            return text.utf16.count
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }

    /// Word spans for a removed/added pair, or nil when the lines are not the
    /// same line edited. Spans mark the tokens outside a longest common token
    /// subsequence. Pairs sharing under `wordPairMinSimilarity` of their
    /// non-whitespace text are unrelated rewrites and stay line-level. The two
    /// cheap bounds reject most unrelated pairs before the LCS runs.
    private static func similarLineWordSpans(_ old: WordLine, _ new: WordLine, budget: inout Int) -> WordSpans? {
        let total = Double(old.contentChars + new.contentChars)
        func similar(_ shared: Int) -> Bool { total == 0 || 2 * Double(shared) / total >= wordPairMinSimilarity }
        // At most the shorter side can be shared.
        guard similar(min(old.contentChars, new.contentChars)) else { return nil }
        // Nor more than the multiset intersection of their tokens.
        var counts: [String: Int] = [:]
        for token in old.tokens where !token.isSpace { counts[token.value, default: 0] += 1 }
        var bound = 0
        for token in new.tokens where !token.isSpace {
            guard let available = counts[token.value], available > 0 else { continue }
            counts[token.value] = available - 1
            bound += token.end - token.start
        }
        guard similar(bound),
              let match = matchTokens(old.tokens, new.tokens, maxCells: maxTokenDiffCells, budget: &budget) else { return nil }
        var shared = 0
        for (index, token) in old.tokens.enumerated() where match.old[index] && !token.isSpace {
            shared += token.end - token.start
        }
        guard similar(shared) else { return nil }
        return (unmatchedSpans(old.tokens, match.old), unmatchedSpans(new.tokens, match.new))
    }

    /// Word spans for a positional pair that failed the similarity test, kept
    /// only when at most `wordFallbackMaxRegions` places change per side.
    /// Short edits such as `foo()` -> `bar()` share little text yet read best
    /// with words marked; unrelated lines change many places and stay line-level.
    private static func fewChangeWordSpans(_ old: WordLine, _ new: WordLine, budget: inout Int) -> WordSpans? {
        guard let match = matchTokens(old.tokens, new.tokens, maxCells: wordFallbackMaxCells, budget: &budget) else {
            return nil
        }
        let spans = (unmatchedSpans(old.tokens, match.old), unmatchedSpans(new.tokens, match.new))
        guard spans.0.count <= wordFallbackMaxRegions, spans.1.count <= wordFallbackMaxRegions else { return nil }
        return spans
    }

    private static func unmatchedSpans(_ tokens: [Token], _ matched: [Bool]) -> [WorkspaceReviewDiffSpan] {
        mergeSpans(tokens.indices.compactMap { index in
            matched[index] ? nil : WorkspaceReviewDiffSpan(start: tokens[index].start, end: tokens[index].end, kind: .changed)
        })
    }

    /// Token LCS. Which tokens of each side are in the common subsequence, or
    /// nil when the table would exceed `maxCells` or the diff's remaining budget.
    private static func matchTokens(
        _ oldTokens: [Token],
        _ newTokens: [Token],
        maxCells: Int,
        budget: inout Int
    ) -> (old: [Bool], new: [Bool])? {
        let m = oldTokens.count
        let n = newTokens.count
        let cells = m * n
        guard cells <= maxCells, cells <= budget else { return nil }
        budget -= cells

        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if oldTokens[i].value == newTokens[j].value {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j])
                }
            }
        }

        // Backtrace, marking matched tokens.
        var oldMatched = Array(repeating: false, count: m)
        var newMatched = Array(repeating: false, count: n)
        var i = m, j = n

        while i > 0, j > 0 {
            if oldTokens[i - 1].value == newTokens[j - 1].value {
                oldMatched[i - 1] = true
                newMatched[j - 1] = true
                i -= 1; j -= 1
            } else if dp[i][j - 1] >= dp[i - 1][j] {
                j -= 1
            } else {
                i -= 1
            }
        }
        return (oldMatched, newMatched)
    }

    private static func mergeSpans(_ spans: [WorkspaceReviewDiffSpan]) -> [WorkspaceReviewDiffSpan] {
        guard spans.count > 1 else { return spans }

        var merged: [WorkspaceReviewDiffSpan] = [spans[0]]
        for i in 1..<spans.count {
            let span = spans[i]
            let lastIndex = merged.count - 1
            if merged[lastIndex].end >= span.start {
                merged[lastIndex] = WorkspaceReviewDiffSpan(
                    start: merged[lastIndex].start,
                    end: max(merged[lastIndex].end, span.end),
                    kind: .changed
                )
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

private extension WorkspaceReviewDiffLine {
    /// Create a copy with spans replaced.
    func withSpans(_ spans: [WorkspaceReviewDiffSpan]) -> Self {
        WorkspaceReviewDiffLine(kind: kind, text: text, oldLine: oldLine, newLine: newLine, spans: spans)
    }
}
