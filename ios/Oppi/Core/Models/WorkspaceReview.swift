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

    static func buildHunks(oldText: String, newText: String) -> [WorkspaceReviewDiffHunk] {
        buildHunks(from: DiffEngine.compute(old: oldText, new: newText))
    }

    static func buildHunks(from lines: [DiffLine]) -> [WorkspaceReviewDiffHunk] {
        let numberedLines = number(lines)
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
}


