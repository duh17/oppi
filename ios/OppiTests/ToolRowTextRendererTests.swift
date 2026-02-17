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

    @Test func displayCommandTextTruncatesLongCommands() {
        let long = String(repeating: "x", count: ToolRowTextRenderer.maxRenderedCommandCharacters + 100)
        let result = ToolRowTextRenderer.displayCommandText(long)
        #expect(result.count < long.count)
        #expect(result.hasSuffix("command truncated for display"))
    }

    @Test func displayOutputTextTruncatesLongOutput() {
        let long = String(repeating: "y", count: ToolRowTextRenderer.maxRenderedOutputCharacters + 100)
        let result = ToolRowTextRenderer.displayOutputText(long)
        #expect(result.count < long.count)
        #expect(result.contains("Copy Output"))
    }

    @Test func shortCommandNotTruncated() {
        let result = ToolRowTextRenderer.displayCommandText("ls -la")
        #expect(result == "ls -la")
    }
}
