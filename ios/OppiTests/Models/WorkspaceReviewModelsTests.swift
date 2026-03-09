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

    @Test func historyBuilderExtractsEditAndWriteEntriesForMatchingPath() {
        let trace: [TraceEvent] = [
            TraceEvent(
                id: "tool-1",
                type: .toolCall,
                timestamp: "2026-03-08T00:00:00Z",
                text: nil,
                tool: "functions.edit",
                args: [
                    "path": "./Sources/App.swift",
                    "oldText": "let value = oldName\n",
                    "newText": "let value = newName\n"
                ],
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                details: nil,
                thinking: nil
            ),
            TraceEvent(
                id: "tool-2",
                type: .toolCall,
                timestamp: "2026-03-08T00:00:01Z",
                text: nil,
                tool: "write",
                args: [
                    "path": "/Users/chenda/workspace/oppi/Sources/App.swift",
                    "content": "line one\nline two\n"
                ],
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                details: nil,
                thinking: nil
            ),
            TraceEvent(
                id: "tool-3",
                type: .toolCall,
                timestamp: "2026-03-08T00:00:02Z",
                text: nil,
                tool: "write",
                args: [
                    "path": "README.md",
                    "content": "ignore me\n"
                ],
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                details: nil,
                thinking: nil
            )
        ]

        let entries = WorkspaceReviewHistoryBuilder.buildEntries(trace: trace, path: "Sources/App.swift")

        #expect(entries.count == 2)
        #expect(entries.map(\.id) == ["tool-2", "tool-1"])
        #expect(entries[0].kind == .write)
        #expect(entries[0].addedLines == 3)
        #expect(entries[1].kind == .edit)
        #expect(entries[1].removedLines == 1)
        #expect(entries[1].addedLines == 1)
    }

    @Test func historyBuilderMatchesAbsoluteAndRelativePaths() {
        #expect(WorkspaceReviewHistoryBuilder.matchesPath("./Sources/App.swift", target: "Sources/App.swift"))
        #expect(WorkspaceReviewHistoryBuilder.matchesPath("/tmp/project/Sources/App.swift", target: "Sources/App.swift"))
        #expect(!WorkspaceReviewHistoryBuilder.matchesPath("Sources/Other.swift", target: "Sources/App.swift"))
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
            hunks: []
        )

        #expect(WorkspaceReviewFileDetailPhase.resolve(diff: diff, error: "boom") == .loaded(diff))
    }
}
