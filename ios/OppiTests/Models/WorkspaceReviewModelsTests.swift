import Testing
@testable import Oppi

@Suite("Workspace review models")
struct WorkspaceReviewModelsTests {

    @Test func diffHunkHeaderTextUsesUnifiedFormat() {
        let hunk = WorkspaceReviewDiffHunk(
            oldStart: 4,
            oldCount: 2,
            newStart: 4,
            newCount: 3,
            lines: []
        )

        #expect(hunk.headerText == "@@ -4,2 +4,3 @@")
    }

    @Test func diffLineKindPrefixesMatchDiffMarkers() {
        #expect(WorkspaceReviewDiffLine.Kind.context.prefix == " ")
        #expect(WorkspaceReviewDiffLine.Kind.added.prefix == "+")
        #expect(WorkspaceReviewDiffLine.Kind.removed.prefix == "-")
    }

    @Test func localDiffResponseBuildsHunksFromTexts() {
        let response = WorkspaceReviewDiffResponse.local(
            path: "Sources/App.swift",
            baselineText: "let a = 1\nlet b = 2\n",
            currentText: "let a = 1\nlet b = 3\nlet c = 4\n"
        )

        #expect(response.addedLines == 2)
        #expect(response.removedLines == 1)
        #expect(response.hunks.count == 1)

        let lines = response.hunks[0].lines
        #expect(lines.contains { $0.kind == .removed && $0.oldLine == 2 && $0.newLine == nil })
        #expect(lines.contains { $0.kind == .added && $0.oldLine == nil && $0.newLine == 2 })
        #expect(lines.contains { $0.kind == .added && $0.oldLine == nil && $0.newLine == 3 })
    }

    @Test func localDiffResponseUsesPrecomputedLines() {
        let precomputedLines = [
            DiffLine(kind: .context, text: "same"),
            DiffLine(kind: .removed, text: "before"),
            DiffLine(kind: .added, text: "after")
        ]

        let response = WorkspaceReviewDiffResponse.local(
            path: "Sources/App.swift",
            baselineText: "ignored old text",
            currentText: "ignored new text",
            precomputedLines: precomputedLines
        )

        #expect(response.addedLines == 1)
        #expect(response.removedLines == 1)
        #expect(response.hunks.count == 1)
        #expect(response.hunks[0].lines.map(\.kind) == [.context, .removed, .added])
    }

    @Test func reviewFileStatusLabelUsesGitStatusMapping() {
        let file = WorkspaceReviewFile(
            path: "README.md",
            status: "??",
            addedLines: nil,
            removedLines: nil,
            isStaged: false,
            isUnstaged: false,
            isUntracked: true,
            selectedSessionTouched: false
        )

        #expect(file.statusLabel == "Untracked")
    }

    @Test func sessionActionLabelsMatchReviewWorkflowCopy() {
        #expect(WorkspaceReviewSessionAction.review.menuTitle == "Review changes")
        #expect(WorkspaceReviewSessionAction.review.primaryButtonTitle == "Review")
        #expect(WorkspaceReviewSessionAction.reflect.menuTitle == "Reflect & next steps")
        #expect(WorkspaceReviewSessionAction.prepareCommit.fileMenuTitle == "Prepare commit for this file")
    }

    @Test func treePathCompareUsesDirectoryHierarchy() {
        let paths = [
            "Sources/Review/Row.swift",
            "README.md",
            "Sources/App.swift",
            "Sources/Review/Detail/View.swift"
        ]

        let sorted = paths.sorted { lhs, rhs in
            lhs.localizedTreePathCompare(to: rhs) == .orderedAscending
        }

        #expect(sorted == [
            "README.md",
            "Sources/App.swift",
            "Sources/Review/Detail/View.swift",
            "Sources/Review/Row.swift"
        ])
    }

    @Test func treePathCompareNormalizesRelativeSeparators() {
        #expect("./Sources\\App.swift".localizedTreePathCompare(to: "Sources/App.swift/") == .orderedSame)
    }

    @Test func contextPillDisplayTitleIsLastPathComponent() {
        let summary = ContextSummary(kind: "file_diff", path: "Sources/Features/App.swift", addedLines: 3, removedLines: 1)
        let pill = ContextPill(from: summary)
        #expect(pill.displayTitle == "App.swift")
    }

    @Test func contextPillDisplaySubtitleShowsAddedAndRemoved() {
        let summary = ContextSummary(kind: "file_diff", path: "README.md", addedLines: 5, removedLines: 2)
        let pill = ContextPill(from: summary)
        #expect(pill.displaySubtitle == "+5 -2")
    }

    @Test func contextPillDisplaySubtitleOmitsZeroCounts() {
        let addedOnly = ContextPill(from: ContextSummary(kind: "file_diff", path: "a.swift", addedLines: 3, removedLines: 0))
        #expect(addedOnly.displaySubtitle == "+3")

        let removedOnly = ContextPill(from: ContextSummary(kind: "file_diff", path: "b.swift", addedLines: 0, removedLines: 4))
        #expect(removedOnly.displaySubtitle == "-4")

        let neither = ContextPill(from: ContextSummary(kind: "file_diff", path: "c.swift", addedLines: 0, removedLines: 0))
        #expect(neither.displaySubtitle == nil)
    }

    @Test func contextPillUsesPathAsID() {
        let summary = ContextSummary(kind: "file_diff", path: "Sources/App.swift", addedLines: 1, removedLines: 0)
        let pill = ContextPill(from: summary)
        #expect(pill.id == "Sources/App.swift")
    }

    @Test func contextPillToReviewFilePreservesPathAndLineCounts() {
        let pill = ContextPill(from: ContextSummary(
            kind: "file_diff", path: "Sources/App.swift", addedLines: 10, removedLines: 3
        ))
        let file = pill.toReviewFile()

        #expect(file.path == "Sources/App.swift")
        #expect(file.addedLines == 10)
        #expect(file.removedLines == 3)
        #expect(file.status == "M")
        #expect(file.isUnstaged)
        #expect(!file.isStaged)
        #expect(!file.isUntracked)
        #expect(file.selectedSessionTouched)
    }

    @Test func contextPillToReviewFileNilsZeroLineCounts() {
        let pill = ContextPill(from: ContextSummary(
            kind: "file_diff", path: "empty.txt", addedLines: 0, removedLines: 0
        ))
        let file = pill.toReviewFile()

        #expect(file.addedLines == nil)
        #expect(file.removedLines == nil)
    }

    @Test func contextPillToReviewFileUsesPathAsID() {
        let pill = ContextPill(from: ContextSummary(
            kind: "file_diff", path: "Sources/Foo.swift", addedLines: 1, removedLines: 0
        ))
        let file = pill.toReviewFile()

        #expect(file.id == "Sources/Foo.swift")
    }

    @Test func fileDetailPhaseTreatsInitialNilStateAsLoading() {
        #expect(WorkspaceReviewFileDetailPhase.resolve(diff: nil, error: nil) == .loading)
    }

    @Test func fileDetailPhasePrefersLoadedContentOverStaleError() {
        let diff = WorkspaceReviewDiffResponse(
            workspaceId: "w1",
            path: "Sources/App.swift",
            baselineText: "old",
            currentText: "new",
            addedLines: 1,
            removedLines: 1,
            hunks: [],
            revisionCount: nil,
            cacheKey: nil
        )

        #expect(WorkspaceReviewFileDetailPhase.resolve(diff: diff, error: "boom") == .loaded(diff))
    }
}
