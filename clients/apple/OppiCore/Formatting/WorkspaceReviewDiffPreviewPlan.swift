import Foundation

struct WorkspaceReviewDiffPreviewPlan: Sendable, Equatable {
    static let defaultMaxVisibleHunks = 4
    static let defaultMaxVisibleLinesPerHunk = 80

    struct VisibleHunk: Sendable, Equatable, Identifiable {
        let hunk: WorkspaceReviewDiffHunk
        let lines: [WorkspaceReviewDiffLine]
        let hiddenLineCount: Int

        var id: String { hunk.id }
        var headerText: String { hunk.headerText }
    }

    let hunks: [VisibleHunk]
    let hiddenHunkCount: Int
    let hiddenLineCount: Int

    init(
        diff: WorkspaceReviewDiffResponse,
        maxVisibleHunks: Int = Self.defaultMaxVisibleHunks,
        maxVisibleLinesPerHunk: Int = Self.defaultMaxVisibleLinesPerHunk
    ) {
        let hunkLimit = max(0, maxVisibleHunks)
        let lineLimit = max(0, maxVisibleLinesPerHunk)
        let visibleHunks = Array(diff.hunks.prefix(hunkLimit))

        hunks = visibleHunks.map { hunk in
            let lines = Array(hunk.lines.prefix(lineLimit))
            return VisibleHunk(
                hunk: hunk,
                lines: lines,
                hiddenLineCount: max(hunk.lines.count - lines.count, 0)
            )
        }

        let omittedHunks = Array(diff.hunks.dropFirst(hunkLimit))
        hiddenHunkCount = omittedHunks.count
        hiddenLineCount = hunks.reduce(0) { $0 + $1.hiddenLineCount }
            + omittedHunks.reduce(0) { $0 + $1.lines.count }
    }

    var isTruncated: Bool {
        hiddenHunkCount > 0 || hiddenLineCount > 0
    }

    var truncationMessage: String? {
        guard isTruncated else { return nil }
        let parts = [
            Self.countDescription(hiddenHunkCount, singular: "hunk", plural: "hunks"),
            Self.countDescription(hiddenLineCount, singular: "line", plural: "lines"),
        ].compactMap { $0 }
        return "Preview truncated: \(parts.joined(separator: " and ")) hidden."
    }

    private static func countDescription(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}
