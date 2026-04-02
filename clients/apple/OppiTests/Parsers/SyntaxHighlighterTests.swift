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

    // MARK: - New language detection (XML, Protobuf, GraphQL, Diff)

    @Test func detectXML() {
        #expect(SyntaxLanguage.detect("xml") == .xml)
        #expect(SyntaxLanguage.detect("xsl") == .xml)
        #expect(SyntaxLanguage.detect("xslt") == .xml)
        #expect(SyntaxLanguage.detect("xsd") == .xml)
        #expect(SyntaxLanguage.detect("plist") == .xml)
    }

    @Test func detectProtobuf() {
        #expect(SyntaxLanguage.detect("proto") == .protobuf)
        #expect(SyntaxLanguage.detect("protobuf") == .protobuf)
    }

    @Test func detectGraphQL() {
        #expect(SyntaxLanguage.detect("graphql") == .graphql)
        #expect(SyntaxLanguage.detect("gql") == .graphql)
    }

    @Test func detectDiff() {
        #expect(SyntaxLanguage.detect("diff") == .diff)
        #expect(SyntaxLanguage.detect("patch") == .diff)
    }

    @Test func newDisplayNames() {
        #expect(SyntaxLanguage.xml.displayName == "XML")
        #expect(SyntaxLanguage.protobuf.displayName == "Protobuf")
        #expect(SyntaxLanguage.graphql.displayName == "GraphQL")
        #expect(SyntaxLanguage.diff.displayName == "Diff")
    }

    @Test func newCommentPrefixes() {
        #expect(SyntaxLanguage.protobuf.lineCommentPrefix == ["/", "/"])
        #expect(SyntaxLanguage.graphql.lineCommentPrefix == ["/", "/"])
        #expect(SyntaxLanguage.xml.lineCommentPrefix == nil)
        #expect(SyntaxLanguage.diff.lineCommentPrefix == nil)
    }

    @Test func newBlockComments() {
        #expect(SyntaxLanguage.protobuf.hasBlockComments == true)
        #expect(SyntaxLanguage.graphql.hasBlockComments == true)
        #expect(SyntaxLanguage.xml.hasBlockComments == true)
        #expect(SyntaxLanguage.diff.hasBlockComments == false)
    }

    @Test func newKeywordSets() {
        #expect(!SyntaxLanguage.protobuf.keywords.isEmpty)
        #expect(!SyntaxLanguage.graphql.keywords.isEmpty)
        #expect(SyntaxLanguage.xml.keywords.isEmpty)
        #expect(SyntaxLanguage.diff.keywords.isEmpty)
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

    @Test func shellBlockHighlightingOnMainThreadUsesHeuristicScanner() {
        let command = "xcodebuild -scheme Oppi"
        let result = SyntaxHighlighter.highlight(command, language: .shell)

        #expect(result.string == command)
        #expect(foregroundColor(of: "xcodebuild", in: result) == UIColor(Color.themeSyntaxFunction))
        // Tree-sitter: flags starting with '-' are @constant (number color)
        #expect(foregroundColor(of: "-scheme", in: result) == UIColor(Color.themeSyntaxNumber))
    }

    @Test func shellHighlightingUsesShellHeuristics() {
        let line = "xcodebuild -scheme OppiUIReliability 2>&1 | grep -E '(passed|skipped)'"
        let result = SyntaxHighlighter.highlight(line, language: .shell)

        #expect(result.string == line)
        #expect(foregroundColor(of: "xcodebuild", in: result) == UIColor(Color.themeSyntaxFunction))
        // Tree-sitter: file descriptor '2' is a number, '>' is an operator.
        // The old scanner treated '2>&1' as a single operator token.
        #expect(foregroundColor(of: "2", at: 37, in: result) == UIColor(Color.themeSyntaxNumber))
        #expect(foregroundColor(of: "grep", in: result) == UIColor(Color.themeSyntaxFunction))
        #expect(foregroundColor(of: "'(passed|skipped)'", in: result) == UIColor(Color.themeSyntaxString))
    }

    @Test func shellCommentDetectionRespectsTokenBoundaries() {
        let line = "echo foo#bar # trailing comment"
        let result = SyntaxHighlighter.highlight(line, language: .shell)

        #expect(result.string == line)
        #expect(foregroundColor(of: "# trailing comment", in: result) == UIColor(Color.themeSyntaxComment))
    }

    @Test func shellAssignmentsKeepCommandPosition() {
        let line = "FOO=bar xcodebuild --scheme $SCHEME"
        let result = SyntaxHighlighter.highlight(line, language: .shell)

        #expect(result.string == line)
        // Tree-sitter: variable_name 'FOO' is type, '=' and 'bar' are separate.
        #expect(foregroundColor(of: "FOO", in: result) == UIColor(Color.themeSyntaxType))
        #expect(foregroundColor(of: "xcodebuild", in: result) == UIColor(Color.themeSyntaxFunction))
        // Tree-sitter: '$' is operator, 'SCHEME' is type (variable_name).
        #expect(foregroundColor(of: "SCHEME", in: result) == UIColor(Color.themeSyntaxType))
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
        // Tree-sitter: flags starting with '-' are @constant (number color)
        #expect(optionColor == UIColor(Color.themeSyntaxNumber))
    }

    // MARK: - Helpers

    private func foregroundColor(of substring: String, in attributed: NSAttributedString) -> UIColor? {
        let text = attributed.string
        guard let range = (text as NSString).range(of: substring) as NSRange?,
              range.location != NSNotFound else { return nil }
        return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    /// Foreground color at a specific character offset (for disambiguating repeated substrings).
    private func foregroundColor(of substring: String, at offset: Int, in attributed: NSAttributedString) -> UIColor? {
        guard offset < attributed.length else { return nil }
        return attributed.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
    }
}

// MARK: - XML Highlighting

@Suite("XML Highlighting")
struct XMLHighlightingTests {
    @Test func xmlTagsHighlighted() {
        let xml = "<root><child attr=\"value\"/></root>"
        let ranges = SyntaxHighlighter.scanTokenRanges(xml, language: .xml)
        #expect(!ranges.isEmpty, "XML should produce token ranges")
        let keywords = ranges.filter { $0.kind == .keyword }
        #expect(!keywords.isEmpty, "XML tags should be highlighted as keywords")
    }

    @Test func xmlCommentHighlighted() {
        let xml = "<!-- comment --><tag/>"
        let ranges = SyntaxHighlighter.scanTokenRanges(xml, language: .xml)
        let comments = ranges.filter { $0.kind == .comment }
        #expect(!comments.isEmpty, "XML comments should be highlighted")
    }

    @Test func xmlAttributeValuesHighlighted() {
        let xml = "<tag key=\"value\"/>"
        let ranges = SyntaxHighlighter.scanTokenRanges(xml, language: .xml)
        let strings = ranges.filter { $0.kind == .string }
        #expect(!strings.isEmpty, "XML attribute values should be highlighted as strings")
    }

    @Test func xmlEntityHighlighted() {
        let xml = "&amp; &lt;"
        let ranges = SyntaxHighlighter.scanTokenRanges(xml, language: .xml)
        let numbers = ranges.filter { $0.kind == .number }
        #expect(numbers.count == 2, "XML entities should be highlighted")
    }

    @Test func xmlProcessingInstruction() {
        let xml = "<?xml version=\"1.0\"?>"
        let ranges = SyntaxHighlighter.scanTokenRanges(xml, language: .xml)
        let keywords = ranges.filter { $0.kind == .keyword }
        #expect(!keywords.isEmpty, "Processing instructions should be highlighted")
    }

    @Test func xmlAttributeNamesHighlighted() {
        let xml = "<tag key=\"value\" id=\"1\"/>"
        let ranges = SyntaxHighlighter.scanTokenRanges(xml, language: .xml)
        let types = ranges.filter { $0.kind == .type }
        #expect(types.count >= 2, "XML attribute names should be highlighted as types")
    }

    @Test func xmlPreservesText() {
        let xml = "<root><child/></root>"
        let result = SyntaxHighlighter.highlight(xml, language: .xml)
        #expect(result.string == xml)
    }
}

// MARK: - Diff Highlighting

@Suite("Diff Highlighting")
struct DiffHighlightingTests {
    @Test func addedLinesHighlighted() {
        let diff = "+added line"
        let ranges = SyntaxHighlighter.scanTokenRanges(diff, language: .diff)
        let strings = ranges.filter { $0.kind == .string }
        #expect(!strings.isEmpty, "Added lines should be highlighted as strings")
    }

    @Test func removedLinesHighlighted() {
        let diff = "-removed line"
        let ranges = SyntaxHighlighter.scanTokenRanges(diff, language: .diff)
        let comments = ranges.filter { $0.kind == .comment }
        #expect(!comments.isEmpty, "Removed lines should be highlighted as comments")
    }

    @Test func hunkHeaderHighlighted() {
        let diff = "@@ -1,3 +1,4 @@"
        let ranges = SyntaxHighlighter.scanTokenRanges(diff, language: .diff)
        let types = ranges.filter { $0.kind == .type }
        #expect(!types.isEmpty, "Hunk headers should be highlighted as types")
    }

    @Test func diffHeadersHighlighted() {
        let diff = "--- a/file.txt\n+++ b/file.txt"
        let ranges = SyntaxHighlighter.scanTokenRanges(diff, language: .diff)
        let keywords = ranges.filter { $0.kind == .keyword }
        #expect(keywords.count >= 2, "Diff headers should be highlighted as keywords")
    }

    @Test func contextLinesNotHighlighted() {
        let diff = " context line"
        let ranges = SyntaxHighlighter.scanTokenRanges(diff, language: .diff)
        #expect(ranges.isEmpty, "Context lines should have no special highlighting")
    }

    @Test func diffPreservesText() {
        let diff = "--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-old\n+new"
        let result = SyntaxHighlighter.highlight(diff, language: .diff)
        #expect(result.string == diff)
    }
}

// MARK: - Protobuf Highlighting

@Suite("Protobuf Highlighting")
struct ProtobufHighlightingTests {
    @Test func protobufKeywordsHighlighted() {
        let proto = "message User { string name = 1; }"
        let ranges = SyntaxHighlighter.scanTokenRanges(proto, language: .protobuf)
        let keywords = ranges.filter { $0.kind == .keyword }
        let chars = Array(proto)
        let keywordTexts = keywords.map { String(chars[$0.location..<($0.location + $0.length)]) }
        #expect(keywordTexts.contains("message"), "message should be a keyword")
        #expect(keywordTexts.contains("string"), "string should be a keyword")
    }

    @Test func protobufCommentHighlighted() {
        let proto = "// comment\nmessage Foo {}"
        let ranges = SyntaxHighlighter.scanTokenRanges(proto, language: .protobuf)
        let comments = ranges.filter { $0.kind == .comment }
        #expect(!comments.isEmpty, "Protobuf comments should be highlighted")
    }

    @Test func protobufBlockCommentHighlighted() {
        let proto = "/* block comment */\nmessage Bar {}"
        let ranges = SyntaxHighlighter.scanTokenRanges(proto, language: .protobuf)
        let comments = ranges.filter { $0.kind == .comment }
        #expect(!comments.isEmpty, "Protobuf block comments should be highlighted")
    }

    @Test func protobufPreservesText() {
        let proto = "syntax = \"proto3\";\nmessage User { int32 id = 1; }"
        let result = SyntaxHighlighter.highlight(proto, language: .protobuf)
        #expect(result.string == proto)
    }
}

// MARK: - GraphQL Highlighting

@Suite("GraphQL Highlighting")
struct GraphQLHighlightingTests {
    @Test func graphqlKeywordsHighlighted() {
        let gql = "type Query { users: [User] }"
        let ranges = SyntaxHighlighter.scanTokenRanges(gql, language: .graphql)
        let keywords = ranges.filter { $0.kind == .keyword }
        let chars = Array(gql)
        let keywordTexts = keywords.map { String(chars[$0.location..<($0.location + $0.length)]) }
        #expect(keywordTexts.contains("type"), "type should be a keyword")
    }

    @Test func graphqlLineCommentHighlighted() {
        let gql = "// comment\ntype Foo { id: ID }"
        let ranges = SyntaxHighlighter.scanTokenRanges(gql, language: .graphql)
        let comments = ranges.filter { $0.kind == .comment }
        #expect(!comments.isEmpty, "GraphQL // comments should be highlighted")
    }

    @Test func graphqlBlockCommentHighlighted() {
        let gql = "/* block */\ntype Bar { name: String }"
        let ranges = SyntaxHighlighter.scanTokenRanges(gql, language: .graphql)
        let comments = ranges.filter { $0.kind == .comment }
        #expect(!comments.isEmpty, "GraphQL block comments should be highlighted")
    }

    @Test func graphqlPreservesText() {
        let gql = "query { user(id: 1) { name email } }"
        let result = SyntaxHighlighter.highlight(gql, language: .graphql)
        #expect(result.string == gql)
    }
}

// MARK: - Cross-Line Token Regression

@Suite("SyntaxHighlighter — Cross-Line Boundary")
struct CrossLineBoundaryTests {
    /// Verify no shell token spans across a newline boundary.
    /// Before the fix, scanStringEndPos and scanShellVariable used chars.count
    /// instead of the line-end bound, allowing tokens to extend into the next line.
    @Test func shellTokensNeverCrossNewlines() {
        let text = """
        SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        BASE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
        OPPI_ROOT="${OPPI_ROOT:-${PIOS_ROOT:-$HOME/workspace/oppi}}"
        """

        let ranges = SyntaxHighlighter.scanTokenRanges(text, language: .shell)
        let chars = Array(text)

        for token in ranges {
            let tokenEnd = token.location + token.length
            // Check that no character within the token range is a newline
            for pos in token.location..<min(tokenEnd, chars.count) {
                #expect(
                    chars[pos] != "\n",
                    "Token at \(token.location) length \(token.length) kind \(token.kind) crosses newline at position \(pos)"
                )
            }
        }
    }

    /// Verify that an unclosed string at end of line does not produce a cross-line token.
    @Test func unclosedStringStopsAtLineEnd() {
        let text = "echo \"hello\nnext_line"
        let ranges = SyntaxHighlighter.scanTokenRanges(text, language: .shell)
        let chars = Array(text)
        let newlinePos = chars.firstIndex(of: "\n")!

        for token in ranges {
            let tokenEnd = token.location + token.length
            #expect(
                tokenEnd <= newlinePos || token.location > newlinePos,
                "Token at \(token.location) length \(token.length) crosses newline"
            )
        }
    }

    /// Verify $() subshell handling.
    /// Tree-sitter correctly parses `$(incomplete` as a command_substitution
    /// that spans to end-of-input. This is correct bash behavior — an unclosed
    /// $() extends to EOF. The old hand-written scanner stopped at newlines.
    @Test func unclosedSubshellParsedByTreeSitter() {
        let text = "echo $(incomplete\nnext_line"
        let ranges = SyntaxHighlighter.scanTokenRanges(text, language: .shell)
        // tree-sitter should produce tokens (echo as function, etc.)
        let functions = ranges.filter { $0.kind == .function }
        #expect(!functions.isEmpty, "Should have at least echo as function")
    }

    /// Generic (non-shell) scanner: strings must not cross line boundaries.
    @Test func genericStringTokensRespectLineBounds() {
        let text = "let x = \"unterminated\nlet y = 2"
        let ranges = SyntaxHighlighter.scanTokenRanges(text, language: .swift)
        let chars = Array(text)
        let newlinePos = chars.firstIndex(of: "\n")!

        for token in ranges {
            let tokenEnd = token.location + token.length
            #expect(
                tokenEnd <= newlinePos || token.location > newlinePos,
                "Token at \(token.location) length \(token.length) crosses newline"
            )
        }
    }
}
