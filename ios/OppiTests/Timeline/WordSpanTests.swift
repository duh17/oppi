import Testing
@testable import Oppi

@Suite("Word-level span computation")
struct WordSpanTests {

    // MARK: - buildHunks with word spans

    @Test func singleWordChange() {
        let lines = DiffEngine.compute(
            old: "let value = oldName",
            new: "let value = newName"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)

        #expect(hunks.count == 1)
        let hunk = hunks[0]

        // Find removed and added lines
        let removed = hunk.lines.first { $0.kind == .removed }
        let added = hunk.lines.first { $0.kind == .added }

        #expect(removed != nil)
        #expect(added != nil)

        // Both should have spans highlighting only the changed word
        #expect(removed?.spans != nil, "Removed line should have word spans")
        #expect(added?.spans != nil, "Added line should have word spans")

        // The span should cover "oldName" / "newName", not the entire line
        if let removedSpans = removed?.spans {
            #expect(removedSpans.count == 1)
            let spanText = String("let value = oldName".dropFirst(removedSpans[0].start).prefix(removedSpans[0].end - removedSpans[0].start))
            #expect(spanText == "oldName")
        }

        if let addedSpans = added?.spans {
            #expect(addedSpans.count == 1)
            let spanText = String("let value = newName".dropFirst(addedSpans[0].start).prefix(addedSpans[0].end - addedSpans[0].start))
            #expect(spanText == "newName")
        }
    }

    @Test func multipleWordChanges() {
        let lines = DiffEngine.compute(
            old: "func foo(x: Int) -> String",
            new: "func bar(x: Double) -> Bool"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        let removed = hunks.flatMap(\.lines).first { $0.kind == .removed }
        let added = hunks.flatMap(\.lines).first { $0.kind == .added }

        // Should highlight "foo", "Int", "String" on removed and "bar", "Double", "Bool" on added
        #expect(removed?.spans != nil)
        #expect(added?.spans != nil)
        #expect((removed?.spans?.count ?? 0) >= 2, "Multiple changes should produce multiple spans")
    }

    @Test func identicalLinesProduceNoSpans() {
        let lines = DiffEngine.compute(
            old: "let x = 1\nlet y = 2",
            new: "let x = 1\nlet y = 2"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)

        // No changes → no hunks
        #expect(hunks.isEmpty)
    }

    @Test func contextLinesHaveNoSpans() {
        let lines = DiffEngine.compute(
            old: "line1\nline2\nline3",
            new: "line1\nchanged\nline3"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        let contextLines = hunks.flatMap(\.lines).filter { $0.kind == .context }

        for line in contextLines {
            #expect(line.spans == nil, "Context lines should not have spans")
        }
    }

    @Test func withoutWordSpansProducesNilSpans() {
        let lines = DiffEngine.compute(
            old: "let value = oldName",
            new: "let value = newName"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: false)
        let allLines = hunks.flatMap(\.lines)

        for line in allLines {
            #expect(line.spans == nil, "Without word spans, all spans should be nil")
        }
    }

    @Test func addedOnlyLinesHaveNoSpans() {
        // Pure addition — no removed line to pair with
        let lines = DiffEngine.compute(
            old: "",
            new: "new line here"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        let addedLines = hunks.flatMap(\.lines).filter { $0.kind == .added }

        // With no removed counterpart, no word spans should be computed
        for line in addedLines {
            #expect(line.spans == nil, "Added-only lines have no removed pair for word diff")
        }
    }

    @Test func removedOnlyLinesHaveNoSpans() {
        let lines = DiffEngine.compute(
            old: "old line here",
            new: ""
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        let removedLines = hunks.flatMap(\.lines).filter { $0.kind == .removed }

        for line in removedLines {
            #expect(line.spans == nil, "Removed-only lines have no added pair for word diff")
        }
    }

    @Test func spanOffsetsAreUTF16Based() {
        // Verify span offsets work for ASCII text (UTF-8 == UTF-16 offsets for ASCII)
        let lines = DiffEngine.compute(
            old: "abc def",
            new: "abc xyz"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        let added = hunks.flatMap(\.lines).first { $0.kind == .added }

        if let span = added?.spans?.first {
            // "xyz" starts at index 4 in "abc xyz"
            #expect(span.start == 4)
            #expect(span.end == 7)
        }
    }
}
