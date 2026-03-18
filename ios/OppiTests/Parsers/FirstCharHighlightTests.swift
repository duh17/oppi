import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("FirstCharHighlight")
@MainActor
struct FirstCharHighlightTests {

    // MARK: - Direct highlight (no conversion)

    @Test func directHighlightFirstCharKeyword() {
        let code = "let x = 42"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        let keywordColor = UIColor(Color.themeSyntaxKeyword)

        // All 3 chars of "let" should be keyword color
        for i in 0..<3 {
            let color = result.attribute(.foregroundColor, at: i, effectiveRange: nil) as? UIColor
            #expect(color == keywordColor, "Position \(i) should be keyword color")
        }
    }

    @Test func directHighlightFirstCharComment() {
        let code = "// comment"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        let commentColor = UIColor(Color.themeSyntaxComment)

        let color0 = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let color1 = result.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor
        #expect(color0 == commentColor, "First '/' should be comment color")
        #expect(color1 == commentColor, "Second '/' should be comment color")
    }

    // MARK: - Round-trip conversion (the async path)

    @Test func roundTripConversionPreservesFirstCharColor() {
        let code = "let x = 42"
        let original = SyntaxHighlighter.highlight(code, language: .swift)

        // This is the exact conversion path used in scheduleHighlight
        let sendable = AttributedString(original)
        let roundTripped = NSAttributedString(sendable)

        let keywordColor = UIColor(Color.themeSyntaxKeyword)

        // Check original
        let origColor0 = original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(origColor0 == keywordColor, "Original position 0 should be keyword")

        // Check round-tripped
        let rtColor0 = roundTripped.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let rtColor1 = roundTripped.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor
        let rtColor2 = roundTripped.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor

        print("Original pos 0: \(String(describing: origColor0))")
        print("RoundTrip pos 0: \(String(describing: rtColor0))")
        print("RoundTrip pos 1: \(String(describing: rtColor1))")
        print("RoundTrip pos 2: \(String(describing: rtColor2))")
        print("Expected keyword: \(keywordColor)")

        #expect(rtColor0 == keywordColor, "Round-tripped position 0 should be keyword")
        #expect(rtColor1 == keywordColor, "Round-tripped position 1 should be keyword")
        #expect(rtColor2 == keywordColor, "Round-tripped position 2 should be keyword")
    }

    @Test func roundTripConversionPreservesAllTokenColors() {
        let code = "let x = 42 // comment"
        let original = SyntaxHighlighter.highlight(code, language: .swift)

        let sendable = AttributedString(original)
        let roundTripped = NSAttributedString(sendable)

        // Compare every position
        for i in 0..<original.length {
            let origColor = original.attribute(.foregroundColor, at: i, effectiveRange: nil) as? UIColor
            let rtColor = roundTripped.attribute(.foregroundColor, at: i, effectiveRange: nil) as? UIColor

            if origColor != rtColor {
                let char = (original.string as NSString).substring(with: NSRange(location: i, length: 1))
                print("MISMATCH at position \(i) (char '\(char)'): original=\(String(describing: origColor)) roundTripped=\(String(describing: rtColor))")
            }
        }

        // Verify first char explicitly
        let origFirst = original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let rtFirst = roundTripped.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(origFirst == rtFirst, "First char color should survive round-trip")
    }

    @Test func roundTripCommentFirstChar() {
        let code = "// this is a comment"
        let original = SyntaxHighlighter.highlight(code, language: .swift)

        let sendable = AttributedString(original)
        let roundTripped = NSAttributedString(sendable)

        let commentColor = UIColor(Color.themeSyntaxComment)

        let origColor = original.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let rtColor = roundTripped.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor

        print("Comment orig pos 0: \(String(describing: origColor))")
        print("Comment RT pos 0: \(String(describing: rtColor))")
        print("Expected comment: \(commentColor)")

        #expect(rtColor == commentColor, "Comment first char should survive round-trip")
    }

    // MARK: - applyHighlightedCode path

    @Test func applyHighlightedCodePreservesFirstChar() {
        let code = "let x = 42"
        let highlighted = SyntaxHighlighter.highlight(code, language: .swift)

        // Simulate applyHighlightedCode
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)

        let keywordColor = UIColor(Color.themeSyntaxKeyword)
        let color0 = mutable.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(color0 == keywordColor)
    }

    // MARK: - Full async path simulation

    @Test func fullAsyncPathSimulation() {
        let code = "let x = 42"

        // Simulate the exact Task.detached path from scheduleHighlight
        let highlighted = SyntaxHighlighter.highlight(code, language: .swift)
        let sendable = AttributedString(highlighted)
        let backToNS = NSAttributedString(sendable)

        // Simulate applyHighlightedCode
        let mutable = NSMutableAttributedString(attributedString: backToNS)
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)

        let keywordColor = UIColor(Color.themeSyntaxKeyword)

        for i in 0..<3 {
            let color = mutable.attribute(.foregroundColor, at: i, effectiveRange: nil) as? UIColor
            print("Full path pos \(i): \(String(describing: color))")
        }

        let color0 = mutable.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let color1 = mutable.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor

        #expect(color0 == keywordColor, "First char should be keyword after full path")
        #expect(color1 == keywordColor, "Second char should be keyword after full path")
        #expect(color0 == color1, "First and second char should match")
    }

    // MARK: - Gutter-mapped highlight (ToolRowTextRenderer path)

    @Test func makeCodeAttributedTextFirstCharSyntax() {
        let code = "let x = 42"
        let result = ToolRowTextRenderer.makeCodeAttributedText(
            text: code, language: .swift, startLine: 1
        )

        let text = result.string as NSString
        let letRange = text.range(of: "let")
        guard letRange.location != NSNotFound else {
            Issue.record("'let' not found in guttered text")
            return
        }

        let keywordColor = UIColor(Color.themeSyntaxKeyword)

        for i in 0..<3 {
            let pos = letRange.location + i
            let color = result.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? UIColor
            let char = text.substring(with: NSRange(location: pos, length: 1))
            print("Guttered pos \(pos) (char '\(char)'): \(String(describing: color))")
            #expect(color == keywordColor, "Char '\(char)' at guttered pos \(pos) should be keyword color")
        }
    }

    // MARK: - DiffAttributedStringBuilder path

    @Test func diffBuilderFirstCharSyntax() {
        let hunks = [
            WorkspaceReviewDiffHunk(
                oldStart: 1,
                oldCount: 3,
                newStart: 1,
                newCount: 3,
                lines: [
                    WorkspaceReviewDiffLine(
                        kind: .removed,
                        text: "let x = 42",
                        oldLine: 1,
                        newLine: nil,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .added,
                        text: "let x = 99",
                        oldLine: nil,
                        newLine: 1,
                        spans: nil
                    ),
                    WorkspaceReviewDiffLine(
                        kind: .context,
                        text: "print(x)",
                        oldLine: 2,
                        newLine: 2,
                        spans: nil
                    ),
                ]
            )
        ]

        let result = DiffAttributedStringBuilder.build(hunks: hunks, filePath: "test.swift")
        let text = result.string as NSString

        // Find "let" in the diff output
        let letRange = text.range(of: "let")
        guard letRange.location != NSNotFound else {
            Issue.record("'let' not found in diff output")
            return
        }

        let keywordColor = SyntaxHighlighter.color(for: .keyword)!

        for i in 0..<3 {
            let pos = letRange.location + i
            let color = result.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? UIColor
            let char = text.substring(with: NSRange(location: pos, length: 1))
            print("Diff pos \(pos) (char '\(char)'): color=\(String(describing: color))")
            #expect(color == keywordColor, "Char '\(char)' in diff should be keyword color")
        }
    }

    // MARK: - ToolRowTextRenderer makeDiffAttributedText path

    @Test func toolRowDiffFirstCharSyntax() {
        let diffLines = [
            DiffLine(kind: .removed, text: "let x = 42"),
            DiffLine(kind: .added, text: "let x = 99"),
            DiffLine(kind: .context, text: "print(x)"),
        ]

        let result = ToolRowTextRenderer.makeDiffAttributedText(
            lines: diffLines, filePath: "test.swift"
        )
        let text = result.string as NSString

        let letRange = text.range(of: "let")
        guard letRange.location != NSNotFound else {
            Issue.record("'let' not found in tool row diff")
            return
        }

        let keywordColor = SyntaxHighlighter.color(for: .keyword)!

        for i in 0..<3 {
            let pos = letRange.location + i
            let color = result.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? UIColor
            let char = text.substring(with: NSRange(location: pos, length: 1))
            print("ToolRow diff pos \(pos) (char '\(char)'): color=\(String(describing: color))")
        }

        let color0 = result.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? UIColor
        let color1 = result.attribute(.foregroundColor, at: letRange.location + 1, effectiveRange: nil) as? UIColor

        #expect(color0 == keywordColor, "First char of 'let' in tool row diff should be keyword")
        #expect(color0 == color1, "First and second char should match in tool row diff")
    }

    // MARK: - Inline per-line highlight path (ToolRowTextRenderer.makeDiffAttributedText with SyntaxHighlighter.highlight per line)

    @Test func perLineDiffHighlightFirstChar() {
        // This is the inline diff path where each line is highlighted independently
        let displayText = "let x = 42"
        let highlighted = SyntaxHighlighter.highlight(displayText, language: .swift)

        let keywordColor = SyntaxHighlighter.color(for: .keyword)!

        // Check directly from highlight()
        let color0 = highlighted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        print("Per-line direct pos 0: \(String(describing: color0))")
        #expect(color0 == keywordColor, "Per-line highlight first char should be keyword")

        // Now simulate what makeDiffAttributedText does:
        let codeFont = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttributes(
            [.font: codeFont, .paragraphStyle: paragraph],
            range: fullRange
        )

        // "Fill in missing foreground colors" step
        let fgColor = UIColor(Color.themeFg)
        mutable.enumerateAttribute(
            .foregroundColor, in: fullRange, options: []
        ) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: fgColor, range: range)
                print("FOUND NIL foreground at range \(range)!")
            }
        }

        let afterColor0 = mutable.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        print("Per-line after addAttributes pos 0: \(String(describing: afterColor0))")
        #expect(afterColor0 == keywordColor, "After addAttributes, first char should still be keyword")
    }
}
