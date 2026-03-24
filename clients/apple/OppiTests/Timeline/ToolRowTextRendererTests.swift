import SwiftUI
import Testing
import UIKit
@testable import Oppi

// MARK: - ANSI / Syntax Output Presentation

@Suite("ToolRowTextRenderer — ANSI Output")
struct ANSIOutputTests {
    @Test func smallTextProducesAttributedString() {
        let result = ToolRowTextRenderer.makeANSIOutputPresentation("hello world", isError: false)
        #expect(result.attributedText != nil)
        #expect(result.plainText == nil)
    }

    @Test func errorFlagDoesNotCrash() {
        let result = ToolRowTextRenderer.makeANSIOutputPresentation("error: bad", isError: true)
        #expect(result.attributedText != nil || result.plainText != nil)
    }

    @Test func oversizedTextFallsBackToPlain() {
        let huge = String(repeating: "x", count: ToolRowTextRenderer.maxANSIHighlightBytes + 1)
        let result = ToolRowTextRenderer.makeANSIOutputPresentation(huge, isError: false)
        #expect(result.attributedText == nil)
        #expect(result.plainText != nil)
    }

    @Test func ansiCodesStrippedInPlainFallback() {
        let huge = "\u{1B}[31m" + String(repeating: "x", count: ToolRowTextRenderer.maxANSIHighlightBytes + 1) + "\u{1B}[0m"
        let result = ToolRowTextRenderer.makeANSIOutputPresentation(huge, isError: false)
        #expect(result.plainText?.contains("\u{1B}") == false)
    }
}

@Suite("ToolRowTextRenderer — Syntax Output")
struct SyntaxOutputTests {
    @Test func unknownLanguageReturnsPlainText() {
        let result = ToolRowTextRenderer.makeSyntaxOutputPresentation("some code", language: .unknown)
        #expect(result.attributedText == nil)
        #expect(result.plainText == "some code")
    }

    @Test func knownLanguageProducesAttributedString() {
        let result = ToolRowTextRenderer.makeSyntaxOutputPresentation("let x = 1", language: .swift)
        #expect(result.attributedText != nil)
    }

    @Test func knownLanguageUsesMonospaceFontAcrossHighlightedRuns() throws {
        let result = ToolRowTextRenderer.makeSyntaxOutputPresentation("let x = 1", language: .swift)
        let attributed = try #require(result.attributedText)
        let expected = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        var sawMissingFont = false
        var sawUnexpectedFont = false

        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let font = value as? UIFont else {
                sawMissingFont = true
                return
            }

            if font.fontName != expected.fontName || abs(font.pointSize - expected.pointSize) > 0.01 {
                sawUnexpectedFont = true
            }
        }

        #expect(!sawMissingFont)
        #expect(!sawUnexpectedFont)
    }

    @Test func oversizedSyntaxFallsBackToPlain() {
        let huge = String(repeating: "a", count: ToolRowTextRenderer.maxSyntaxHighlightBytes + 1)
        let result = ToolRowTextRenderer.makeSyntaxOutputPresentation(huge, language: .swift)
        #expect(result.attributedText == nil)
        #expect(result.plainText == huge)
    }
}

// MARK: - Markdown

@Suite("ToolRowTextRenderer — Markdown")
struct MarkdownTests {
    @Test func rendersSimpleMarkdown() {
        let result = ToolRowTextRenderer.makeMarkdownAttributedText("**bold** text")
        #expect(result.length > 0)
    }

    @Test func emptyStringProducesEmptyResult() {
        let result = ToolRowTextRenderer.makeMarkdownAttributedText("")
        #expect(result.length == 0)
    }

    @Test func invalidMarkdownDoesNotCrash() {
        // Unterminated code fences — should not crash, may return partial or empty
        let result = ToolRowTextRenderer.makeMarkdownAttributedText("```unterminated")
        _ = result // No crash = pass
    }
}

// MARK: - Code

@Suite("ToolRowTextRenderer — Code")
struct CodeTests {
    @Test func addsLineNumbers() {
        let result = ToolRowTextRenderer.makeCodeAttributedText(text: "line1\nline2\nline3", language: nil, startLine: 1)
        let text = result.string
        #expect(text.contains("1"))
        #expect(text.contains("│"))
        #expect(text.contains("line1"))
    }

    @Test func respectsStartLineOffset() {
        let result = ToolRowTextRenderer.makeCodeAttributedText(text: "hello", language: nil, startLine: 42)
        #expect(result.string.contains("42"))
    }

    @Test func negativeStartLineClampedToOne() {
        let result = ToolRowTextRenderer.makeCodeAttributedText(text: "hello", language: nil, startLine: -5)
        #expect(result.string.contains("1"))
    }

    @Test func emptyLinesGetSpaces() {
        let result = ToolRowTextRenderer.makeCodeAttributedText(text: "a\n\nb", language: nil, startLine: 1)
        // Empty line should still have content (space placeholder)
        #expect(result.string.contains("│"))
    }

    @Test func syntaxHighlightsCodeWithLanguage() {
        let result = ToolRowTextRenderer.makeCodeAttributedText(text: "let x = 1", language: .swift, startLine: 1)
        #expect(result.length > 0)
    }

    /// Regression test: shell syntax tokens must not bleed into the next line's
    /// gutter (line number + separator). This happened when scanStringEndPos/
    /// scanShellVariable used chars.count instead of the line-end bound, causing
    /// cross-line tokens whose color range extended into gutter characters.
    @Test func shellSyntaxDoesNotColorNextLineGutter() {
        // Line 1 ends with an unmatched " that the scanner sees as a string opener.
        // Before the fix, scanStringEndPos would scan past \n into line 2 to find
        // the closing ", creating a cross-line token that colored line 2's gutter.
        let text = """
        SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        BASE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
        OPPI_ROOT="${OPPI_ROOT:-${PIOS_ROOT:-$HOME/workspace/oppi}}"
        """

        let result = ToolRowTextRenderer.makeCodeAttributedText(
            text: text, language: .shell, startLine: 1
        )

        // The guttered string is: " 1 │ <code>\n 2 │ <code>\n 3 │ <code>"
        // Gutter characters (line number + separator) must keep their assigned
        // colors (lineNumberColor / separatorColor) — no syntax color override.
        let gutterRanges = findGutterRanges(in: result)
        let lineNumberColor = UIColor(Color.themeComment.opacity(0.55))
        let separatorColor = UIColor(Color.themeComment.opacity(0.35))

        for gutter in gutterRanges {
            // Check line number portion
            var numEffective = NSRange()
            let numColor = result.attribute(.foregroundColor, at: gutter.lineNumStart, effectiveRange: &numEffective) as? UIColor
            #expect(numColor == lineNumberColor, "Line \(gutter.lineNumber) number colored by syntax token")

            // Check separator portion
            var sepEffective = NSRange()
            let sepColor = result.attribute(.foregroundColor, at: gutter.sepStart, effectiveRange: &sepEffective) as? UIColor
            #expect(sepColor == separatorColor, "Line \(gutter.lineNumber) separator colored by syntax token")
        }
    }

    /// Verify that $() and ${} variable expressions don't cross line boundaries
    /// and bleed .type color into the next line's gutter.
    @Test func shellVariableDoesNotColorNextLineGutter() {
        let text = """
        echo $(incomplete_subshell
        next_line
        """

        let result = ToolRowTextRenderer.makeCodeAttributedText(
            text: text, language: .shell, startLine: 1
        )

        let gutterRanges = findGutterRanges(in: result)
        let lineNumberColor = UIColor(Color.themeComment.opacity(0.55))

        // Line 2's gutter must not be colored by a cross-line $() token
        if let line2 = gutterRanges.first(where: { $0.lineNumber == 2 }) {
            let numColor = result.attribute(.foregroundColor, at: line2.lineNumStart, effectiveRange: nil) as? UIColor
            #expect(numColor == lineNumberColor, "Line 2 number colored by cross-line $() token")
        }
    }
}

// MARK: - Test Helpers

private struct GutterInfo {
    let lineNumber: Int
    let lineNumStart: Int  // UTF-16 offset of line number in attributed string
    let sepStart: Int      // UTF-16 offset of separator character
}

/// Find the gutter positions (line number + separator) in a makeCodeAttributedText result.
private func findGutterRanges(in attributed: NSAttributedString) -> [GutterInfo] {
    let text = attributed.string
    var results: [GutterInfo] = []
    var lineNumber = 0
    var pos = 0
    let nsText = text as NSString

    while pos < nsText.length {
        lineNumber += 1
        // Skip leading spaces in line number
        var numStart = pos
        while numStart < nsText.length, nsText.character(at: numStart) == 0x20 /* space */ {
            numStart += 1
        }
        // Find the separator character │ (U+2502)
        var sepPos = pos
        while sepPos < nsText.length {
            let ch = nsText.character(at: sepPos)
            if ch == 0x2502 { break } // │
            if ch == 0x0A { break }   // newline — no separator found
            sepPos += 1
        }

        if sepPos < nsText.length, nsText.character(at: sepPos) == 0x2502 {
            results.append(GutterInfo(lineNumber: lineNumber, lineNumStart: pos, sepStart: sepPos))
        }

        // Advance to next line
        while pos < nsText.length, nsText.character(at: pos) != 0x0A {
            pos += 1
        }
        pos += 1 // skip newline
    }

    return results
}

// MARK: - Diff Helpers

@Suite("ToolRowTextRenderer — Diff Helpers")
struct DiffHelperTests {
    @Test func paddedLineNumberFormatsCorrectly() {
        #expect(ToolRowTextRenderer.paddedLineNumber(1, digits: 3) == "  1")
        #expect(ToolRowTextRenderer.paddedLineNumber(42, digits: 3) == " 42")
        #expect(ToolRowTextRenderer.paddedLineNumber(100, digits: 3) == "100")
    }

    @Test func paddedLineNumberNilReturnsSpaces() {
        #expect(ToolRowTextRenderer.paddedLineNumber(nil, digits: 3) == "   ")
    }

    @Test func paddedHeaderTruncatesLongValues() {
        #expect(ToolRowTextRenderer.paddedHeader("abcde", digits: 3) == "cde")
    }

    @Test func paddedHeaderPadsShortValues() {
        #expect(ToolRowTextRenderer.paddedHeader("ab", digits: 4) == "  ab")
    }

    @Test func diffLanguageDetectsSwift() {
        let lang = ToolRowTextRenderer.diffLanguage(for: "src/main.swift")
        #expect(lang == .swift)
    }

    @Test func diffLanguageDetectsTypeScript() {
        let lang = ToolRowTextRenderer.diffLanguage(for: "index.ts")
        #expect(lang == .typescript)
    }

    @Test func diffLanguageReturnsNilForPlainText() {
        let lang = ToolRowTextRenderer.diffLanguage(for: "README.md")
        #expect(lang == nil)
    }

    @Test func diffLanguageReturnsNilForEmptyPath() {
        #expect(ToolRowTextRenderer.diffLanguage(for: nil) == nil)
        #expect(ToolRowTextRenderer.diffLanguage(for: "") == nil)
    }

    @Test func largeDiffWindowIncludesChangedLines() {
        let leadingContextCount = ToolRowTextRenderer.maxRenderedDiffLines + 60
        var lines = makeContextLines(count: leadingContextCount)

        lines.append(DiffLine(kind: .removed, text: "old changed line"))
        lines.append(DiffLine(kind: .added, text: "new changed line"))
        lines.append(DiffLine(kind: .context, text: "trailing context"))

        let rendered = renderDiff(lines)

        #expect(rendered.contains("old changed line"))
        #expect(rendered.contains("new changed line"))
        #expect(rendered.contains("omitted above"))
    }

    @Test func largeDiffWindowIncludesTrailingOmissionMarker() {
        let trailingContextCount = ToolRowTextRenderer.maxRenderedDiffLines + 60
        var lines: [DiffLine] = [
            DiffLine(kind: .removed, text: "old changed line"),
            DiffLine(kind: .added, text: "new changed line"),
        ]
        lines.append(contentsOf: makeContextLines(count: trailingContextCount, prefix: "tail"))

        let rendered = renderDiff(lines)

        #expect(rendered.contains("old changed line"))
        #expect(rendered.contains("new changed line"))
        #expect(rendered.contains("omitted below"))
    }

    private func makeContextLines(count: Int, prefix: String = "context") -> [DiffLine] {
        guard count > 0 else { return [] }

        var lines: [DiffLine] = []
        lines.reserveCapacity(count)

        for index in 1...count {
            lines.append(DiffLine(kind: .context, text: "\(prefix) \(index)"))
        }

        return lines
    }

    private func renderDiff(_ lines: [DiffLine]) -> String {
        ToolRowTextRenderer.makeDiffAttributedText(lines: lines, filePath: nil).string
    }
}

// MARK: - Shell / ANSI

@Suite("ToolRowTextRenderer — Shell")
struct ShellTests {
    @Test func shellHighlightedProducesAttributedString() {
        let result = ToolRowTextRenderer.shellHighlighted("ls -la /tmp")
        #expect(result.length > 0)
    }

    @Test func ansiHighlightedHandlesPlainText() {
        let result = ToolRowTextRenderer.ansiHighlighted("no ansi here")
        #expect(result.string == "no ansi here")
    }

    @Test func ansiHighlightedHandlesANSICodes() {
        let result = ToolRowTextRenderer.ansiHighlighted("\u{1B}[31mred\u{1B}[0m normal")
        #expect(result.string.contains("red"))
        #expect(result.string.contains("normal"))
    }
}

// MARK: - Title

@Suite("ToolRowTextRenderer — Title")
struct TitleTests {
    @Test func styledTitleNoPrefix() {
        let result = ToolRowTextRenderer.styledTitle(title: "Read file", toolNamePrefix: nil, toolNameColor: .red)
        #expect(result.string == "Read file")
    }

    @Test func styledTitleWithPrefix() {
        let result = ToolRowTextRenderer.styledTitle(title: "bash ls -la", toolNamePrefix: "bash", toolNameColor: .blue)
        #expect(result.string == "bash ls -la")
        // Prefix portion should have color applied
        #expect(result.length > 0)
    }

    @Test func styledTitleEmptyPrefix() {
        let result = ToolRowTextRenderer.styledTitle(title: "test", toolNamePrefix: "", toolNameColor: .red)
        #expect(result.string == "test")
    }
}

// MARK: - Truncation

@Suite("ToolRowTextRenderer — Truncation")
struct TruncationTests {
    @Test func shortTextNotTruncated() {
        let result = ToolRowTextRenderer.truncatedDisplayText("hello", maxCharacters: 100, note: "…")
        #expect(result == "hello")
    }

    @Test func longTextTruncatedWithNote() {
        let result = ToolRowTextRenderer.truncatedDisplayText("abcdefghij", maxCharacters: 5, note: "…trunc")
        #expect(result == "abcde…trunc")
    }

    @Test func displayCommandTextKeepsLongCommandsIntact() {
        let long = String(repeating: "x", count: ToolRowTextRenderer.maxRenderedCommandCharacters + 100)
        let result = ToolRowTextRenderer.displayCommandText(long)
        #expect(result == long)
    }

    @Test func displayOutputTextKeepsLongOutputIntact() {
        let long = String(repeating: "y", count: ToolRowTextRenderer.maxRenderedOutputCharacters + 100)
        let result = ToolRowTextRenderer.displayOutputText(long)
        #expect(result == long)
    }

    @Test func shortCommandNotTruncated() {
        let result = ToolRowTextRenderer.displayCommandText("ls -la")
        #expect(result == "ls -la")
    }
}
