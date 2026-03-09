import Foundation

struct WorkspaceReviewFilesResponse: Codable, Sendable, Equatable {
    let workspaceId: String
    let isGitRepo: Bool
    let branch: String?
    let headSha: String?
    let ahead: Int?
    let behind: Int?
    let changedFileCount: Int
    let stagedFileCount: Int
    let unstagedFileCount: Int
    let untrackedFileCount: Int
    let addedLines: Int
    let removedLines: Int
    let selectedSessionId: String?
    let selectedSessionTouchedCount: Int
    let files: [WorkspaceReviewFile]
}

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
            hunks: WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
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

enum WorkspaceReviewHistoryEntryKind: String, Sendable {
    case edit
    case write

    var icon: String {
        switch self {
        case .edit: return "pencil"
        case .write: return "square.and.pencil"
        }
    }

    var label: String {
        switch self {
        case .edit: return "Edit"
        case .write: return "Write"
        }
    }

    var detailActionLabel: String {
        switch self {
        case .edit: return "Modify existing file"
        case .write: return "Create or overwrite file"
        }
    }
}

struct WorkspaceReviewHistoryEntry: Identifiable, Sendable, Equatable {
    let id: String
    let kind: WorkspaceReviewHistoryEntryKind
    let path: String
    let oldText: String?
    let newText: String?
    let writeContent: String?
    let addedLines: Int
    let removedLines: Int
    let order: Int
}

struct ReviewHistoryOverallDiff: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        enum Kind: Sendable {
            case context
            case added
            case removed
        }

        let kind: Kind
        let text: String
    }

    let revisionCount: Int
    let baselineText: String
    let currentText: String
    let diffLines: [Line]
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
            let currentIndex = mergedWindows.index(before: mergedWindows.endIndex)
            if next.start <= mergedWindows[currentIndex].end + 1 {
                mergedWindows[currentIndex].end = max(mergedWindows[currentIndex].end, next.end)
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

enum WorkspaceReviewHistoryBuilder {
    static func buildEntries(trace: [TraceEvent], path: String) -> [WorkspaceReviewHistoryEntry] {
        var entries: [WorkspaceReviewHistoryEntry] = []
        entries.reserveCapacity(trace.count)

        for (index, event) in trace.enumerated() {
            guard event.type == .toolCall else { continue }

            let toolName = normalizeToolName(event.tool)
            guard toolName == "edit" || toolName == "write" else { continue }

            guard let rawPath = ToolCallFormatting.filePath(from: event.args) else { continue }
            guard matchesPath(rawPath, target: path) else { continue }

            if toolName == "edit" {
                let editText = ToolCallFormatting.editOldAndNewText(from: event.args)
                let stats = ToolCallFormatting.editDiffStats(from: event.args)
                entries.append(WorkspaceReviewHistoryEntry(
                    id: event.id,
                    kind: .edit,
                    path: rawPath,
                    oldText: editText?.oldText,
                    newText: editText?.newText,
                    writeContent: nil,
                    addedLines: stats?.added ?? 0,
                    removedLines: stats?.removed ?? 0,
                    order: index
                ))
            } else {
                let content = ToolCallFormatting.writeContent(from: event.args)
                entries.append(WorkspaceReviewHistoryEntry(
                    id: event.id,
                    kind: .write,
                    path: rawPath,
                    oldText: nil,
                    newText: nil,
                    writeContent: content,
                    addedLines: content.map(lineCount(of:)) ?? 0,
                    removedLines: 0,
                    order: index
                ))
            }
        }

        return entries.sorted { $0.order > $1.order }
    }

    static func matchesPath(_ candidate: String, target: String) -> Bool {
        let normalizedCandidate = normalizePath(candidate)
        let normalizedTarget = normalizePath(target)
        guard !normalizedCandidate.isEmpty, !normalizedTarget.isEmpty else { return false }

        return normalizedCandidate == normalizedTarget
            || normalizedCandidate.hasSuffix("/" + normalizedTarget)
    }

    private static func normalizeToolName(_ raw: String?) -> String {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.split(separator: ".").last.map(String.init) ?? normalized
    }

    private static func normalizePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        return normalized.replacingOccurrences(of: "\\", with: "/")
    }

    private static func lineCount(of text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
