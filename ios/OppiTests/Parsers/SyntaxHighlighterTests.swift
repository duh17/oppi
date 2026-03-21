import Testing
import SwiftUI
import UIKit
@testable import Oppi

@Suite("SyntaxLanguage")
struct SyntaxLanguageTests {

    @Test func detectSwift() {
        #expect(SyntaxLanguage.detect("swift") == .swift)
    }

    @Test func detectTypeScript() {
        #expect(SyntaxLanguage.detect("ts") == .typescript)
        #expect(SyntaxLanguage.detect("tsx") == .typescript)
        #expect(SyntaxLanguage.detect("typescript") == .typescript)
    }

    @Test func detectJavaScript() {
        #expect(SyntaxLanguage.detect("js") == .javascript)
        #expect(SyntaxLanguage.detect("jsx") == .javascript)
        #expect(SyntaxLanguage.detect("mjs") == .javascript)
    }

    @Test func detectPython() {
        #expect(SyntaxLanguage.detect("py") == .python)
        #expect(SyntaxLanguage.detect("pyi") == .python)
        #expect(SyntaxLanguage.detect("python") == .python)
    }

    @Test func detectGo() {
        #expect(SyntaxLanguage.detect("go") == .go)
        #expect(SyntaxLanguage.detect("golang") == .go)
    }

    @Test func detectRust() {
        #expect(SyntaxLanguage.detect("rs") == .rust)
        #expect(SyntaxLanguage.detect("rust") == .rust)
    }

    @Test func detectShell() {
        #expect(SyntaxLanguage.detect("sh") == .shell)
        #expect(SyntaxLanguage.detect("bash") == .shell)
        #expect(SyntaxLanguage.detect("zsh") == .shell)
    }

    @Test func detectJSON() {
        #expect(SyntaxLanguage.detect("json") == .json)
        #expect(SyntaxLanguage.detect("jsonl") == .json)
    }

    @Test func detectCpp() {
        #expect(SyntaxLanguage.detect("cpp") == .cpp)
        #expect(SyntaxLanguage.detect("cc") == .cpp)
        #expect(SyntaxLanguage.detect("hpp") == .cpp)
    }

    @Test func caseInsensitive() {
        #expect(SyntaxLanguage.detect("SWIFT") == .swift)
        #expect(SyntaxLanguage.detect("Py") == .python)
        #expect(SyntaxLanguage.detect("JSON") == .json)
    }

    @Test func unknownExtension() {
        #expect(SyntaxLanguage.detect("xyz") == .unknown)
        #expect(SyntaxLanguage.detect("") == .unknown)
    }

    @Test func displayNames() {
        #expect(SyntaxLanguage.swift.displayName == "Swift")
        #expect(SyntaxLanguage.typescript.displayName == "TypeScript")
        #expect(SyntaxLanguage.unknown.displayName == "Text")
        #expect(SyntaxLanguage.cpp.displayName == "C++")
    }

    @Test func lineCommentPrefixes() {
        #expect(SyntaxLanguage.swift.lineCommentPrefix == ["/", "/"])
        #expect(SyntaxLanguage.python.lineCommentPrefix == ["#"])
        #expect(SyntaxLanguage.sql.lineCommentPrefix == ["-", "-"])
        #expect(SyntaxLanguage.json.lineCommentPrefix == nil)
    }

    @Test func blockCommentSupport() {
        #expect(SyntaxLanguage.swift.hasBlockComments)
        #expect(SyntaxLanguage.typescript.hasBlockComments)
        #expect(!SyntaxLanguage.python.hasBlockComments)
        #expect(!SyntaxLanguage.shell.hasBlockComments)
        #expect(!SyntaxLanguage.json.hasBlockComments)
    }

    @Test func keywordSetsNonEmpty() {
        #expect(!SyntaxLanguage.swift.keywords.isEmpty)
        #expect(!SyntaxLanguage.python.keywords.isEmpty)
        #expect(!SyntaxLanguage.go.keywords.isEmpty)
        #expect(SyntaxLanguage.json.keywords.isEmpty)
        #expect(SyntaxLanguage.unknown.keywords.isEmpty)
    }
}

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {

    @Test func highlightEmptyString() {
        let result = SyntaxHighlighter.highlight("", language: .swift)
        #expect(result.string.isEmpty)
    }

    @Test func highlightPreservesText() {
        let code = "let x = 42"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightMultiLine() {
        let code = "let x = 1\nlet y = 2"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightSingleLinePreservesText() {
        let line = "func hello() -> String {"
        let result = SyntaxHighlighter.highlight(line, language: .swift)
        #expect(result.string == line)
    }

    @Test func highlightJSONPreservesText() {
        let json = """
        {"key": "value", "num": 42, "flag": true, "n": null}
        """
        let result = SyntaxHighlighter.highlight(json, language: .json)
        #expect(result.string == json)
    }

    @Test func highlightStringLiteral() {
        let code = #"let s = "hello""#
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightLineComment() {
        let code = "x = 1 // comment"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightHashComment() {
        let code = "x = 1 # comment"
        let result = SyntaxHighlighter.highlight(code, language: .python)
        #expect(result.string == code)
    }

    @Test func highlightBlockComment() {
        let code = "a /* block */ b"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightMultiLineBlockComment() {
        let code = "a /* start\ncontinue */ b"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightDecorator() {
        let code = "@Observable class Foo"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightHexNumber() {
        let code = "let n = 0xFF"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightFloat() {
        let code = "let pi = 3.14"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightEscapedString() {
        let code = #"let s = "hello \"world\"""#
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func maxLinesEnforced() {
        let lines = (0..<600).map { "line \($0)" }.joined(separator: "\n")
        let result = SyntaxHighlighter.highlight(lines, language: .swift)
        let outputLines = result.string.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(outputLines.count <= SyntaxHighlighter.maxLines)
    }

    @Test func unknownLanguagePassesThrough() {
        let code = "just some text"
        let result = SyntaxHighlighter.highlight(code, language: .unknown)
        #expect(result.string == code)
    }

    @Test func jsonHighlightUsesExpectedTokenColors() {
        let json = #"{ "key": "value", "num": -42.5e+1, "flag": true, "missing": null }"#
        let result = SyntaxHighlighter.highlight(json, language: .json)

        #expect(result.string == json)
        #expect(foregroundColor(of: #""key""#, in: result) == UIColor(Color.themeSyntaxType))
        #expect(foregroundColor(of: #""value""#, in: result) == UIColor(Color.themeSyntaxString))
        #expect(foregroundColor(of: "-42.5e+1", in: result) == UIColor(Color.themeSyntaxNumber))
        #expect(foregroundColor(of: "true", in: result) == UIColor(Color.themeSyntaxKeyword))
        #expect(foregroundColor(of: "null", in: result) == UIColor(Color.themeSyntaxComment))
        #expect(foregroundColor(of: ":", in: result) == UIColor(Color.themeSyntaxPunctuation))
    }

    @Test func jsonHighlightColorsWhitespaceAsPunctuation() {
        let json = "{\n  \"key\": 1\n}"
        let result = SyntaxHighlighter.highlight(json, language: .json)
        let text = result.string as NSString
        let whitespaceRange = text.range(of: "  ")

        guard whitespaceRange.location != NSNotFound else {
            Issue.record("Expected JSON indentation whitespace")
            return
        }

        let color = result.attribute(.foregroundColor, at: whitespaceRange.location, effectiveRange: nil) as? UIColor
        #expect(color == UIColor(Color.themeSyntaxPunctuation))
    }

    @MainActor
    @Test func shellBlockHighlightingOnMainThreadUsesHeuristicScanner() {
        let command = "xcodebuild -scheme Oppi"
        let result = SyntaxHighlighter.highlight(command, language: .shell)

        #expect(result.string == command)
        #expect(foregroundColor(of: "xcodebuild", in: result) == UIColor(Color.themeSyntaxFunction))
        #expect(foregroundColor(of: "-scheme", in: result) == UIColor(Color.themeSyntaxVariable))
    }

    @Test func shellHighlightingUsesShellHeuristics() {
        let line = "xcodebuild -scheme OppiUIReliability 2>&1 | grep -E '(passed|skipped)'"
        let result = SyntaxHighlighter.highlight(line, language: .shell)

        #expect(result.string == line)
        #expect(foregroundColor(of: "xcodebuild", in: result) == UIColor(Color.themeSyntaxFunction))
        #expect(foregroundColor(of: "-scheme", in: result) == UIColor(Color.themeSyntaxVariable))
        #expect(foregroundColor(of: "OppiUIReliability", in: result) == UIColor(Color.themeSyntaxVariable))
        #expect(foregroundColor(of: "2>&1", in: result) == UIColor(Color.themeSyntaxOperator))
        #expect(foregroundColor(of: "grep", in: result) == UIColor(Color.themeSyntaxFunction))
        #expect(foregroundColor(of: "-E", in: result) == UIColor(Color.themeSyntaxVariable))
        #expect(foregroundColor(of: "'(passed|skipped)'", in: result) == UIColor(Color.themeSyntaxString))
    }

    @Test func shellCommentDetectionRespectsTokenBoundaries() {
        let line = "echo foo#bar # trailing comment"
        let result = SyntaxHighlighter.highlight(line, language: .shell)

        #expect(result.string == line)
        #expect(foregroundColor(of: "foo#bar", in: result) == UIColor(Color.themeSyntaxVariable))
        #expect(foregroundColor(of: "# trailing comment", in: result) == UIColor(Color.themeSyntaxComment))
    }

    @Test func shellAssignmentsKeepCommandPosition() {
        let line = "FOO=bar xcodebuild --scheme $SCHEME"
        let result = SyntaxHighlighter.highlight(line, language: .shell)

        #expect(result.string == line)
        #expect(foregroundColor(of: "FOO=bar", in: result) == UIColor(Color.themeSyntaxType))
        #expect(foregroundColor(of: "xcodebuild", in: result) == UIColor(Color.themeSyntaxFunction))
        #expect(foregroundColor(of: "--scheme", in: result) == UIColor(Color.themeSyntaxVariable))
        #expect(foregroundColor(of: "$SCHEME", in: result) == UIColor(Color.themeSyntaxType))
    }

    @Test func shellHighlightingBridgesToUIKitForegroundColors() {
        let line = "xcodebuild -scheme Oppi"
        let result = SyntaxHighlighter.highlight(line, language: .shell)
        let text = result.string as NSString

        let commandRange = text.range(of: "xcodebuild")
        let optionRange = text.range(of: "-scheme")
        guard commandRange.location != NSNotFound,
              optionRange.location != NSNotFound else {
            Issue.record("Expected shell tokens in bridged attributed string")
            return
        }

        let commandColor = result.attribute(.foregroundColor, at: commandRange.location, effectiveRange: nil) as? UIColor
        let optionColor = result.attribute(.foregroundColor, at: optionRange.location, effectiveRange: nil) as? UIColor

        #expect(commandColor == UIColor(Color.themeSyntaxFunction))
        #expect(optionColor == UIColor(Color.themeSyntaxVariable))
    }

    // MARK: - Helpers

    private func foregroundColor(of substring: String, in attributed: NSAttributedString) -> UIColor? {
        let text = attributed.string
        guard let range = (text as NSString).range(of: substring) as NSRange?,
              range.location != NSNotFound else { return nil }
        return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }
}
