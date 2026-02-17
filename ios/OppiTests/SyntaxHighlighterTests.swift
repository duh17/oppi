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
        #expect(String(result.characters) == "")
    }

    @Test func highlightPreservesText() {
        let code = "let x = 42"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightMultiLine() {
        let code = "let x = 1\nlet y = 2"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightLinePreservesText() {
        let line = "func hello() -> String {"
        let result = SyntaxHighlighter.highlightLine(line, language: .swift)
        #expect(String(result.characters) == line)
    }

    @Test func highlightJSONPreservesText() {
        let json = """
        {"key": "value", "num": 42, "flag": true, "n": null}
        """
        let result = SyntaxHighlighter.highlight(json, language: .json)
        #expect(String(result.characters) == json)
    }

    @Test func highlightStringLiteral() {
        let code = #"let s = "hello""#
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightLineComment() {
        let code = "x = 1 // comment"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightHashComment() {
        let code = "x = 1 # comment"
        let result = SyntaxHighlighter.highlight(code, language: .python)
        #expect(String(result.characters) == code)
    }

    @Test func highlightBlockComment() {
        let code = "a /* block */ b"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightMultiLineBlockComment() {
        let code = "a /* start\ncontinue */ b"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightDecorator() {
        let code = "@Observable class Foo"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightHexNumber() {
        let code = "let n = 0xFF"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightFloat() {
        let code = "let pi = 3.14"
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func highlightEscapedString() {
        let code = #"let s = "hello \"world\"""#
        let result = SyntaxHighlighter.highlight(code, language: .swift)
        #expect(String(result.characters) == code)
    }

    @Test func maxLinesEnforced() {
        let lines = (0..<600).map { "line \($0)" }.joined(separator: "\n")
        let result = SyntaxHighlighter.highlight(lines, language: .swift)
        let outputLines = String(result.characters).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(outputLines.count <= SyntaxHighlighter.maxLines)
    }

    @Test func unknownLanguagePassesThrough() {
        let code = "just some text"
        let result = SyntaxHighlighter.highlight(code, language: .unknown)
        #expect(String(result.characters) == code)
    }

    @MainActor
    @Test func shellBlockHighlightingOnMainThreadUsesHeuristicScanner() {
        let command = "xcodebuild -scheme Oppi"
        let result = SyntaxHighlighter.highlight(command, language: .shell)

        #expect(String(result.characters) == command)
        #expect(foregroundColor(of: "xcodebuild", in: result) == .tokyoCyan)
        #expect(foregroundColor(of: "-scheme", in: result) == .tokyoYellow)
    }

    @Test func shellHighlightingUsesShellHeuristics() {
        let line = "xcodebuild -scheme OppiUIReliability 2>&1 | grep -E '(passed|skipped)'"
        let result = SyntaxHighlighter.highlightLine(line, language: .shell)

        #expect(String(result.characters) == line)
        #expect(foregroundColor(of: "xcodebuild", in: result) == .tokyoCyan)
        #expect(foregroundColor(of: "-scheme", in: result) == .tokyoYellow)
        #expect(foregroundColor(of: "OppiUIReliability", in: result) == .tokyoFg)
        #expect(foregroundColor(of: "2>&1", in: result) == .tokyoPurple)
        #expect(foregroundColor(of: "grep", in: result) == .tokyoCyan)
        #expect(foregroundColor(of: "-E", in: result) == .tokyoYellow)
        #expect(foregroundColor(of: "'(passed|skipped)'", in: result) == .tokyoGreen)
    }

    @Test func shellCommentDetectionRespectsTokenBoundaries() {
        let line = "echo foo#bar # trailing comment"
        let result = SyntaxHighlighter.highlightLine(line, language: .shell)

        #expect(String(result.characters) == line)
        #expect(foregroundColor(of: "foo#bar", in: result) == .tokyoFg)
        #expect(foregroundColor(of: "# trailing comment", in: result) == .tokyoComment)
    }

    @Test func shellAssignmentsKeepCommandPosition() {
        let line = "FOO=bar xcodebuild --scheme $SCHEME"
        let result = SyntaxHighlighter.highlightLine(line, language: .shell)

        #expect(String(result.characters) == line)
        #expect(foregroundColor(of: "FOO=bar", in: result) == .tokyoCyan)
        #expect(foregroundColor(of: "xcodebuild", in: result) == .tokyoCyan)
        #expect(foregroundColor(of: "--scheme", in: result) == .tokyoYellow)
        #expect(foregroundColor(of: "$SCHEME", in: result) == .tokyoCyan)
    }

    @Test func shellHighlightingBridgesToUIKitForegroundColors() {
        let line = "xcodebuild -scheme Oppi"
        let highlighted = SyntaxHighlighter.highlightLine(line, language: .shell)
        let bridged = NSAttributedString(highlighted)
        let text = bridged.string as NSString

        let commandRange = text.range(of: "xcodebuild")
        let optionRange = text.range(of: "-scheme")
        guard commandRange.location != NSNotFound,
              optionRange.location != NSNotFound else {
            Issue.record("Expected shell tokens in bridged attributed string")
            return
        }

        let commandColor = bridged.attribute(.foregroundColor, at: commandRange.location, effectiveRange: nil) as? UIColor
        let optionColor = bridged.attribute(.foregroundColor, at: optionRange.location, effectiveRange: nil) as? UIColor

        #expect(commandColor == UIColor(Color.tokyoCyan))
        #expect(optionColor == UIColor(Color.tokyoYellow))
    }

    private func foregroundColor(of substring: String, in attributed: AttributedString) -> Color? {
        let text = String(attributed.characters)
        guard let offset = characterOffset(of: substring, in: text) else { return nil }
        return foregroundColor(at: offset, in: attributed)
    }

    private func foregroundColor(at offset: Int, in attributed: AttributedString) -> Color? {
        guard offset >= 0, offset < attributed.characters.count else { return nil }
        let index = attributed.characters.index(attributed.characters.startIndex, offsetBy: offset)
        for run in attributed.runs where run.range.contains(index) {
            return run.foregroundColor
        }
        return nil
    }

    private func characterOffset(of substring: String, in text: String) -> Int? {
        guard let range = text.range(of: substring) else { return nil }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }
}
