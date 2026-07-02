import Foundation
import Testing
@testable import Oppi

@Suite("Mac session diff preview plan")
struct WorkspaceReviewDiffPreviewPlanTests {
    @Test func keepsSmallDiffsUnchanged() {
        let diff = Self.diff(hunks: [Self.hunk(start: 1, lineCount: 2)])

        let plan = WorkspaceReviewDiffPreviewPlan(diff: diff, maxVisibleHunks: 4, maxVisibleLinesPerHunk: 80)

        #expect(plan.hunks.count == 1)
        #expect(plan.hunks.first?.lines.count == 2)
        #expect(plan.hiddenHunkCount == 0)
        #expect(plan.hiddenLineCount == 0)
        #expect(plan.truncationMessage == nil)
    }

    @Test func reportsHiddenHunksAndLinesForLargeDiffs() {
        let diff = Self.diff(hunks: [
            Self.hunk(start: 1, lineCount: 3),
            Self.hunk(start: 10, lineCount: 5),
            Self.hunk(start: 20, lineCount: 2),
        ])

        let plan = WorkspaceReviewDiffPreviewPlan(diff: diff, maxVisibleHunks: 2, maxVisibleLinesPerHunk: 3)

        #expect(plan.hunks.count == 2)
        #expect(plan.hunks.map(\.lines.count) == [3, 3])
        #expect(plan.hunks.map(\.hiddenLineCount) == [0, 2])
        #expect(plan.hiddenHunkCount == 1)
        #expect(plan.hiddenLineCount == 4)
        #expect(plan.truncationMessage == "Preview truncated: 1 hunk and 4 lines hidden.")
    }

    @Test func clampsNegativeLimitsToEmptyPreview() {
        let diff = Self.diff(hunks: [Self.hunk(start: 1, lineCount: 2)])

        let plan = WorkspaceReviewDiffPreviewPlan(diff: diff, maxVisibleHunks: -1, maxVisibleLinesPerHunk: -1)

        #expect(plan.hunks.isEmpty)
        #expect(plan.hiddenHunkCount == 1)
        #expect(plan.hiddenLineCount == 2)
        #expect(plan.truncationMessage == "Preview truncated: 1 hunk and 2 lines hidden.")
    }

    private static func diff(hunks: [WorkspaceReviewDiffHunk]) -> WorkspaceReviewDiffResponse {
        WorkspaceReviewDiffResponse(
            workspaceId: "ws-1",
            path: "Sources/App.swift",
            baselineText: "",
            currentText: "",
            addedLines: 0,
            removedLines: 0,
            hunks: hunks,
            revisionCount: nil,
            cacheKey: nil
        )
    }

    private static func hunk(start: Int, lineCount: Int) -> WorkspaceReviewDiffHunk {
        WorkspaceReviewDiffHunk(
            oldStart: start,
            oldCount: lineCount,
            newStart: start,
            newCount: lineCount,
            lines: (0..<lineCount).map { offset in
                WorkspaceReviewDiffLine(
                    kind: .context,
                    text: "line \(start + offset)",
                    oldLine: start + offset,
                    newLine: start + offset,
                    spans: nil
                )
            }
        )
    }
}
