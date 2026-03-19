import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("DiffAttributedStringBuilder syntax offset")
@MainActor
struct DiffSyntaxHighlightOffsetTests {

    /// The first character of each diff line's code text must receive the correct
    /// syntax highlight color, not the default foreground. Regression test for an
    /// off-by-one in batchCharOffsets where the offset was recorded before the
    /// inter-line newline, causing all lines after the first to shift tokens
    /// right by one character.
    @Test func firstCharOfEachLineGetsCorrectColor() throws {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1,
                oldCount: 3,
                newStart: 1,
                newCount: 2,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .context,
                        text: "/// Returns true",
                        oldLine: 1,
                        newLine: 1,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "// periphery:ignore",
                        oldLine: 2,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "var isShowing: Bool",
                        oldLine: 3,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added,
                        text: "var isShowing: Bool",
                        oldLine: nil,
                        newLine: 2,
                        spans: nil
                    ),
                ]
            )
        ]

        let result = DiffAttributedStringBuilder.build(hunks: hunks, filePath: "test.swift")
        let text = result.string as NSString
        let keywordColor = try #require(SyntaxHighlighter.color(for: .keyword))
        let commentColor = try #require(SyntaxHighlighter.color(for: .comment))

        // Line 2 (removed): "// periphery:ignore" — first "/" must be comment color
        let commentRange = text.range(of: "// periphery:ignore")
        guard commentRange.location != NSNotFound else {
            Issue.record("Expected '// periphery:ignore' in diff output")
            return
        }
        let firstSlash = result.attribute(
            .foregroundColor, at: commentRange.location, effectiveRange: nil
        ) as? UIColor
        let secondSlash = result.attribute(
            .foregroundColor, at: commentRange.location + 1, effectiveRange: nil
        ) as? UIColor
        #expect(firstSlash == commentColor, "First '/' of comment must be comment color, got \(String(describing: firstSlash))")
        #expect(secondSlash == commentColor, "Second '/' of comment must be comment color")
        #expect(firstSlash == secondSlash, "Both '/' chars must have the same color")

        // Line 3 (removed): "var isShowing" — first "v" must be keyword color
        let varRange = text.range(of: "var")
        guard varRange.location != NSNotFound else {
            Issue.record("Expected 'var' in diff output")
            return
        }
        let vColor = result.attribute(
            .foregroundColor, at: varRange.location, effectiveRange: nil
        ) as? UIColor
        let aColor = result.attribute(
            .foregroundColor, at: varRange.location + 1, effectiveRange: nil
        ) as? UIColor
        let rColor = result.attribute(
            .foregroundColor, at: varRange.location + 2, effectiveRange: nil
        ) as? UIColor
        #expect(vColor == keywordColor, "First char 'v' of 'var' must be keyword color, got \(String(describing: vColor))")
        #expect(aColor == keywordColor, "'a' of 'var' must be keyword color")
        #expect(rColor == keywordColor, "'r' of 'var' must be keyword color")
    }

    @Test func decoratorFirstCharOnNonFirstLine() throws {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1,
                oldCount: 3,
                newStart: 1,
                newCount: 2,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "@MainActor",
                        oldLine: 1,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "@Observable",
                        oldLine: 2,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added,
                        text: "@MainActor @Observable",
                        oldLine: nil,
                        newLine: 1,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .context,
                        text: "final class AnnotationStore {",
                        oldLine: 3,
                        newLine: 2,
                        spans: nil
                    ),
                ]
            )
        ]

        let result = DiffAttributedStringBuilder.build(hunks: hunks, filePath: "test.swift")
        let text = result.string as NSString
        let typeColor = try #require(SyntaxHighlighter.color(for: .type))
        let keywordColor = try #require(SyntaxHighlighter.color(for: .keyword))

        // Second line: "@Observable" — the "@" must be type color
        let observableRange = text.range(of: "@Observable")
        guard observableRange.location != NSNotFound else {
            Issue.record("Expected '@Observable' in diff output")
            return
        }
        let atColor = result.attribute(
            .foregroundColor, at: observableRange.location, effectiveRange: nil
        ) as? UIColor
        #expect(atColor == typeColor, "'@' of @Observable must be type color, got \(String(describing: atColor))")

        // Fourth line: "final class AnnotationStore {" — "f" of "final" must be keyword
        let finalRange = text.range(of: "final")
        guard finalRange.location != NSNotFound else {
            Issue.record("Expected 'final' in diff output")
            return
        }
        let fColor = result.attribute(
            .foregroundColor, at: finalRange.location, effectiveRange: nil
        ) as? UIColor
        #expect(fColor == keywordColor, "'f' of 'final' must be keyword color, got \(String(describing: fColor))")
    }

    @Test func multiHunkOffsetCorrectness() throws {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1,
                oldCount: 2,
                newStart: 1,
                newCount: 2,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "let x = 1",
                        oldLine: 1,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added,
                        text: "let x = 2",
                        oldLine: nil,
                        newLine: 1,
                        spans: nil
                    ),
                ]
            ),
            WorkspaceReviewDiffHunk(
                oldStart: 10,
                oldCount: 2,
                newStart: 10,
                newCount: 2,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "return nil",
                        oldLine: 10,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added,
                        text: "return true",
                        oldLine: nil,
                        newLine: 10,
                        spans: nil
                    ),
                ]
            ),
        ]

        let result = DiffAttributedStringBuilder.build(hunks: hunks, filePath: "test.swift")
        let text = result.string as NSString
        let keywordColor = try #require(SyntaxHighlighter.color(for: .keyword))

        // "return" in second hunk — first char must be keyword
        let returnRange = text.range(of: "return")
        guard returnRange.location != NSNotFound else {
            Issue.record("Expected 'return' in diff output")
            return
        }
        let rColor = result.attribute(
            .foregroundColor, at: returnRange.location, effectiveRange: nil
        ) as? UIColor
        #expect(rColor == keywordColor, "'r' of 'return' must be keyword color")
    }
}
