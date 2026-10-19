import Foundation
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
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)

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
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
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
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)

        // No changes → no hunks
        #expect(hunks.isEmpty)
    }

    @Test func contextLinesHaveNoSpans() {
        let lines = DiffEngine.compute(
            old: "line1\nline2\nline3",
            new: "line1\nchanged\nline3"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
        let contextLines = hunks.flatMap(\.lines).filter { $0.kind == .context }

        for line in contextLines {
            #expect(line.spans == nil, "Context lines should not have spans")
        }
    }

    @Test func addedOnlyLinesHaveNoSpans() {
        // Pure addition — no removed line to pair with
        let lines = DiffEngine.compute(
            old: "",
            new: "new line here"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
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
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
        let removedLines = hunks.flatMap(\.lines).filter { $0.kind == .removed }

        for line in removedLines {
            #expect(line.spans == nil, "Removed-only lines have no added pair for word diff")
        }
    }

    /// An edited line pairs with its edit, not with the comment added above it.
    /// The comment stays line-level, and the edit paints as one run.
    @Test func removedLinePairsWithItsEditNotTheLineInItsPosition() throws {
        let lines = DiffEngine.compute(
            old: "    var output = \"\"\n    func map(_ offset: Int) -> Int {\n        var shift = 0",
            new: """
                var output = ""
                /// A selection that starts at a line start keeps starting there, so
                /// whole selected lines stay whole.
                func map(_ offset: Int, keepsLineStart: Bool = false) -> Int {
                    var shift = 0
            """
        )
        let changed = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines).flatMap(\.lines).filter { $0.kind != .context }
        let comments = changed.filter { $0.text.contains("///") }
        #expect(comments.count == 2)
        #expect(comments.allSatisfy { $0.spans == nil })

        let edit = try #require(changed.first { $0.kind == .added && $0.text.contains("func map") })
        let runs = WorkspaceReviewDiffSpan.paintRuns(try #require(edit.spans), in: edit.text)
        #expect(runs.map { (edit.text as NSString).substring(with: $0) } == [", keepsLineStart: Bool = false"])
    }

    /// A one-word edit in a long paragraph marks that word, as server diffs do.
    @Test func longParagraphEditMarksOnlyTheChangedWord() throws {
        let words = (0..<150).map { "word\($0)" }
        var edited = words
        edited[120] = "changed"
        let lines = DiffEngine.compute(old: words.joined(separator: " "), new: edited.joined(separator: " "))
        let added = try #require(WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines).flatMap(\.lines).first { $0.kind == .added })
        let spans = try #require(added.spans)
        #expect(spans.map { (added.text as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) } == ["changed"])
    }

    /// Edits far apart in one long line still mark just those words.
    @Test func longParagraphWithDistantEditsMarksEachWord() throws {
        let words = (0..<150).map { "word\($0)" }
        var edited = words
        edited[2] = "first"
        edited[147] = "last"
        let lines = DiffEngine.compute(old: words.joined(separator: " "), new: edited.joined(separator: " "))
        let added = try #require(WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines).flatMap(\.lines).first { $0.kind == .added })
        let spans = try #require(added.spans)
        #expect(spans.map { (added.text as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) } == ["first", "last"])
    }

    /// Two short lines that share little text still mark words when only a
    /// few places change.
    @Test func shortUnrelatedLookingEditKeepsWordSpans() throws {
        let lines = DiffEngine.compute(old: "foo()", new: "bar()")
        let added = try #require(WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines).flatMap(\.lines).first { $0.kind == .added })
        #expect(added.spans == [WorkspaceReviewDiffSpan(start: 0, end: 3, kind: .changed)])
    }

    /// A rewrite with nothing in common stays line-level instead of boxing every word.
    @Test func unrelatedRewriteStaysLineLevel() {
        let lines = DiffEngine.compute(
            old: "return cached.value(for: key) ?? fallback",
            new: "throw ValidationError.missing(field: name, in: record)"
        )
        let changed = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines).flatMap(\.lines).filter { $0.kind != .context }
        #expect(changed.count == 2)
        #expect(changed.allSatisfy { $0.spans == nil })
    }

    @Test func paintRunsJoinOnlyAcrossBlanks() {
        let spans = [
            WorkspaceReviewDiffSpan(start: 0, end: 1, kind: .changed),
            WorkspaceReviewDiffSpan(start: 2, end: 3, kind: .changed),
            WorkspaceReviewDiffSpan(start: 5, end: 6, kind: .changed),
        ]
        #expect(WorkspaceReviewDiffSpan.paintRuns(spans, in: "a b.cd") == [NSRange(location: 0, length: 3), NSRange(location: 5, length: 1)])
    }

    @Test func spanOffsetsAreUTF16Based() {
        // Verify span offsets work for ASCII text (UTF-8 == UTF-16 offsets for ASCII)
        let lines = DiffEngine.compute(
            old: "abc def",
            new: "abc xyz"
        )
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
        let added = hunks.flatMap(\.lines).first { $0.kind == .added }

        if let span = added?.spans?.first {
            // "xyz" starts at index 4 in "abc xyz"
            #expect(span.start == 4)
            #expect(span.end == 7)
        }
    }

    @Test func spanOffsetsRemainUTF16AfterEmoji() throws {
        let family = "👨‍👩‍👧‍👦"
        let oldText = "let family = \"\(family)\"; oldName"
        let newText = "let family = \"\(family)\"; newName"
        let lines = DiffEngine.compute(old: oldText, new: newText)
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines)
        let added = try #require(hunks.flatMap(\.lines).first { $0.kind == .added })
        let span = try #require(added.spans?.first)
        let expectedRange = (newText as NSString).range(of: "newName")

        #expect(span.start == expectedRange.location)
        #expect(span.end == expectedRange.location + expectedRange.length)
        let spanRange = NSRange(location: span.start, length: span.end - span.start)
        #expect((newText as NSString).substring(with: spanRange) == "newName")
    }
}
