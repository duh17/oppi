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
    /// Number of trace mutations (session overall-diff only).
    let revisionCount: Int?
    /// Cache key for client-side caching (session overall-diff only).
    let cacheKey: String?

    static func local(
        path: String,
        baselineText: String,
        currentText: String,
        precomputedLines: [DiffLine]? = nil
    ) -> Self {
        let lines = precomputedLines ?? DiffEngine.compute(old: baselineText, new: currentText)
        let stats = DiffEngine.stats(lines)
        return WorkspaceReviewDiffResponse(
            workspaceId: "local-history",
            path: path,
            baselineText: baselineText,
            currentText: currentText,
            addedLines: stats.added,
            removedLines: stats.removed,
            hunks: WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines),
            revisionCount: nil,
            cacheKey: nil
        )
    }
}

enum WorkspaceReviewSessionAction: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case review
    case reflect
    case prepareCommit = "prepare_commit"

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .review:
            return "Review changes"
        case .reflect:
            return "Reflect & next steps"
        case .prepareCommit:
            return "Prepare commit"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .review:
            return "Review"
        case .reflect:
            return "Reflect"
        case .prepareCommit:
            return "Prepare commit"
        }
    }

    var fileMenuTitle: String {
        switch self {
        case .review:
            return "Review this file"
        case .reflect:
            return "Reflect on this file"
        case .prepareCommit:
            return "Prepare commit for this file"
        }
    }

    var progressTitle: String {
        switch self {
        case .review:
            return "Starting review…"
        case .reflect:
            return "Starting reflection…"
        case .prepareCommit:
            return "Preparing commit session…"
        }
    }
}

struct WorkspaceReviewSessionResponse: Codable, Sendable, Equatable {
    let action: WorkspaceReviewSessionAction
    let selectedPathCount: Int
    let session: Session
    let visiblePrompt: String
    let contextSummary: [ContextSummary]
}

struct ContextSummary: Codable, Sendable, Equatable {
    let kind: String
    let path: String
    let addedLines: Int
    let removedLines: Int
}

/// Display-only context summary for the input bar pill strip.
struct ContextPill: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let path: String
    let addedLines: Int
    let removedLines: Int

    init(from summary: ContextSummary) {
        self.id = summary.path
        self.path = summary.path
        self.addedLines = summary.addedLines
        self.removedLines = summary.removedLines
    }

    var displayTitle: String {
        (path as NSString).lastPathComponent
    }

    var displaySubtitle: String? {
        let parts = [
            addedLines > 0 ? "+\(addedLines)" : nil,
            removedLines > 0 ? "-\(removedLines)" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Synthesize a review file for presenting the diff detail sheet.
    /// Context pills come from the review bundle where the file is already known
    /// to be modified, so "M" is the correct default status.
    func toReviewFile() -> WorkspaceReviewFile {
        WorkspaceReviewFile(
            path: path,
            status: "M",
            addedLines: addedLines > 0 ? addedLines : nil,
            removedLines: removedLines > 0 ? removedLines : nil,
            isStaged: false,
            isUnstaged: true,
            isUntracked: false,
            selectedSessionTouched: true
        )
    }
}

/// Navigation destination for a created review session, carrying pill context
/// and the pre-filled input text to show in ChatView.
struct ReviewSessionNavDestination: Identifiable, Hashable {
    let id: String
    let pills: [ContextPill]
    let inputText: String
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

struct WorkspaceReviewDiffSpan: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case changed
    }

    let start: Int
    let end: Int
    let kind: Kind
}

enum WorkspaceReviewDiffHunkBuilder {
    private static let contextLines = 3
    private static let maxTokenDiffCells = 40_000

    static func buildHunks(oldText: String, newText: String) -> [WorkspaceReviewDiffHunk] {
        buildHunks(from: DiffEngine.compute(old: oldText, new: newText))
    }

    /// Build hunks from diff lines, optionally computing word-level change spans.
    ///
    /// When `withWordSpans` is true (default), pairs of removed/added lines
    /// within each change group get intra-line highlighting via token LCS.
    static func buildHunks(from lines: [DiffLine], withWordSpans: Bool = true) -> [WorkspaceReviewDiffHunk] {
        var numberedLines = number(lines)
        if withWordSpans {
            applyWordLevelHighlights(&numberedLines)
        }
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

    /// Walk change groups (contiguous removed+added runs) and compute word-level
    /// spans for each removed/added pair using token LCS.
    private static func applyWordLevelHighlights(_ lines: inout [WorkspaceReviewDiffLine]) {
        var index = 0

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

            // Pair removed/added lines and compute word spans
            let pairCount = min(removed.count, added.count)
            for pairIndex in 0..<pairCount {
                let ri = removed[pairIndex]
                let ai = added[pairIndex]
                let spans = computeWordSpans(oldText: lines[ri].text, newText: lines[ai].text)

                if !spans.old.isEmpty {
                    lines[ri] = lines[ri].withSpans(spans.old)
                }
                if !spans.new.isEmpty {
                    lines[ai] = lines[ai].withSpans(spans.new)
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
    }

    /// Tokenize text into words, whitespace runs, and punctuation groups.
    private static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }

        var tokens: [Token] = []
        let scalars = text.unicodeScalars
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let start = scalars.distance(from: scalars.startIndex, to: index)
            let startScalar = scalars[index]

            if startScalar.properties.isWhitespace {
                // Whitespace run
                var end = scalars.index(after: index)
                while end < scalars.endIndex, scalars[end].properties.isWhitespace {
                    end = scalars.index(after: end)
                }
                let endOffset = scalars.distance(from: scalars.startIndex, to: end)
                let value = String(scalars[index..<end])
                tokens.append(Token(value: value, start: start, end: endOffset))
                index = end
            } else if startScalar.properties.isAlphabetic
                || startScalar.properties.numericType != nil
                || startScalar == "_"
            {
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
                let endOffset = scalars.distance(from: scalars.startIndex, to: end)
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
                        && s != "_"
                    {
                        end = scalars.index(after: end)
                    } else {
                        break
                    }
                }
                let endOffset = scalars.distance(from: scalars.startIndex, to: end)
                let value = String(scalars[index..<end])
                tokens.append(Token(value: value, start: start, end: endOffset))
                index = end
            }
        }

        return tokens
    }

    /// Compute word-level change spans between two lines using token LCS.
    private static func computeWordSpans(
        oldText: String,
        newText: String
    ) -> (old: [WorkspaceReviewDiffSpan], new: [WorkspaceReviewDiffSpan]) {
        guard oldText != newText else { return ([], []) }

        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)

        let cellCount = oldTokens.count * newTokens.count
        if cellCount > maxTokenDiffCells {
            return (
                old: fullLineSpan(oldText),
                new: fullLineSpan(newText)
            )
        }

        let m = oldTokens.count
        let n = newTokens.count

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

        // Backtrace to find non-matching tokens
        var oldSpans: [WorkspaceReviewDiffSpan] = []
        var newSpans: [WorkspaceReviewDiffSpan] = []
        var i = m, j = n

        while i > 0 || j > 0 {
            if i > 0, j > 0, oldTokens[i - 1].value == newTokens[j - 1].value {
                i -= 1; j -= 1
                continue
            }

            let left = j > 0 ? dp[i][j - 1] : 0
            let up = i > 0 ? dp[i - 1][j] : 0

            if j > 0, i == 0 || left >= up {
                let token = newTokens[j - 1]
                newSpans.append(WorkspaceReviewDiffSpan(start: token.start, end: token.end, kind: .changed))
                j -= 1
            } else {
                let token = oldTokens[i - 1]
                oldSpans.append(WorkspaceReviewDiffSpan(start: token.start, end: token.end, kind: .changed))
                i -= 1
            }
        }

        return (
            old: mergeSpans(oldSpans.reversed()),
            new: mergeSpans(newSpans.reversed())
        )
    }

    private static func fullLineSpan(_ text: String) -> [WorkspaceReviewDiffSpan] {
        text.isEmpty ? [] : [WorkspaceReviewDiffSpan(start: 0, end: text.count, kind: .changed)]
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

// MARK: - Annotations

enum AnnotationSide: String, Codable, Sendable {
    case old
    case new
    case file
}

enum AnnotationAuthor: String, Codable, Sendable {
    case human
    case agent

    var isAgent: Bool { self == .agent }
    var isHuman: Bool { self == .human }

    var displayLabel: String {
        switch self {
        case .human: return "You"
        case .agent: return "Agent"
        }
    }

    var iconName: String {
        switch self {
        case .human: return "person.fill"
        case .agent: return "cpu"
        }
    }
}

enum AnnotationSeverity: String, Codable, Sendable {
    case info
    case warn
    case error

    var displayLabel: String {
        switch self {
        case .info: return "Info"
        case .warn: return "Warning"
        case .error: return "Error"
        }
    }

    var iconName: String {
        switch self {
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

enum AnnotationResolution: String, Codable, Sendable {
    case pending
    case accepted
    case rejected

    var isPending: Bool { self == .pending }
    var isResolved: Bool { self != .pending }
}

struct AnnotationImageAttachment: Codable, Sendable, Equatable {
    let data: String
    let mimeType: String
}

struct DiffAnnotation: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let workspaceId: String
    let path: String
    let side: AnnotationSide
    let startLine: Int?
    let endLine: Int?
    let body: String
    let author: AnnotationAuthor
    let sessionId: String?
    let severity: AnnotationSeverity?
    let resolution: AnnotationResolution
    let attachments: [AnnotationImageAttachment]?
    let createdAt: Double
    let updatedAt: Double

    /// The primary line number for anchoring in the diff view.
    var anchorLine: Int? { startLine }

    /// True when the annotation targets a whole file, not a specific line.
    var isFileLevel: Bool { side == .file }
}

struct AnnotationsResponse: Codable, Sendable {
    let workspaceId: String
    let annotations: [DiffAnnotation]
}

struct CreateAnnotationBody: Encodable, Sendable {
    let path: String
    let side: AnnotationSide
    let startLine: Int?
    let endLine: Int?
    let body: String
    let author: AnnotationAuthor
    let sessionId: String?
    let severity: AnnotationSeverity?
    let attachments: [AnnotationImageAttachment]?
}

struct UpdateAnnotationBody: Encodable, Sendable {
    let body: String?
    let resolution: AnnotationResolution?
    let severity: AnnotationSeverity?

    init(body: String? = nil, resolution: AnnotationResolution? = nil, severity: AnnotationSeverity? = nil) {
        self.body = body
        self.resolution = resolution
        self.severity = severity
    }
}
