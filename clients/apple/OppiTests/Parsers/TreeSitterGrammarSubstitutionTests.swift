import Foundation
import Testing
@testable import Oppi

@Suite("TreeSitter — grammar substitution")
struct TreeSitterGrammarSubstitutionTests {
    @Test func pythonJavaScriptAndTypeScriptReplaceScanner() {
        #expect(TreeSitterHighlighter.supports(.python))
        #expect(TreeSitterHighlighter.supports(.javascript))
        #expect(TreeSitterHighlighter.supports(.typescript))
        #expect(TreeSitterHighlighter.supports(.jsx))
        #expect(TreeSitterHighlighter.supports(.tsx))
        #expect(!TreeSitterHighlighter.supports(.swift))
        #expect(!TreeSitterHighlighter.supports(.yaml))
        #expect(!TreeSitterHighlighter.supports(.toml))

        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .python) != nil)
        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .javascript) != nil)
        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .typescript) != nil)
        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .jsx) != nil)
        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .tsx) != nil)
    }

    @Test func easyGrammarsReplaceScanner() {
        for language in EasyGrammarFixture.all.map(\.language) {
            #expect(TreeSitterHighlighter.supports(language))
            #expect(
                TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: language) != nil,
                "\(language.displayName) must load a real highlights query"
            )
        }
    }

    @Test func jsonXmlAndDiffStayOnDedicatedScanners() {
        #expect(!TreeSitterHighlighter.supports(.json))
        #expect(!TreeSitterHighlighter.supports(.xml))
        #expect(!TreeSitterHighlighter.supports(.diff))

        let json = "{\"a\": 1}"
        let xml = "<root attr=\"x\"/>"
        let diff = "+added line"
        #expect(
            TreeSitterHighlighter.resolvedTokenRanges(json, language: .json)
                == SyntaxTokenScanner.scanTokenRanges(json, language: .json)
        )
        #expect(
            TreeSitterHighlighter.resolvedTokenRanges(xml, language: .xml)
                == SyntaxTokenScanner.scanTokenRanges(xml, language: .xml)
        )
        #expect(
            TreeSitterHighlighter.resolvedTokenRanges(diff, language: .diff)
                == SyntaxTokenScanner.scanTokenRanges(diff, language: .diff)
        )
    }

    @Test func htmlTreeSitterDoesNotClaimXML() {
        #expect(TreeSitterHighlighter.supports(.html))
        #expect(!TreeSitterHighlighter.supports(.xml))
        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .html) != nil)
        #expect(TreeSitterHighlighter.GrammarRegistry.shared.highlightsQuery(for: .xml) == nil)

        let markup = "<root attr=\"x\"/>"
        let htmlRanges = TreeSitterHighlighter.resolvedTokenRanges(markup, language: .html)
        let xmlRanges = TreeSitterHighlighter.resolvedTokenRanges(markup, language: .xml)
        #expect(!htmlRanges.isEmpty)
        #expect(htmlRanges != xmlRanges)
        #expect(xmlRanges == SyntaxTokenScanner.scanTokenRanges(markup, language: .xml))
    }

    @Test(arguments: EasyGrammarFixture.all)
    func easyGrammarMultilineUsesTreeSitterNotScanner(sample: EasyGrammarFixture) {
        let treeSitter = TreeSitterHighlighter.scanTokenRanges(sample.code, language: sample.language)
        #expect(treeSitter != nil)
        let resolved = TreeSitterHighlighter.resolvedTokenRanges(sample.code, language: sample.language)
        let scanner = SyntaxTokenScanner.scanTokenRanges(sample.code, language: sample.language)
        #expect(resolved == treeSitter)
        #expect(resolved != scanner)
        expectKind(sample.multilineKind, covering: sample.multilineNeedle, in: resolved, source: sample.code)
        expectKind(sample.tokenKind, covering: sample.tokenNeedle, in: resolved, source: sample.code)
    }

    @Test(arguments: EasyGrammarFixture.all)
    func iosPainterUsesSubstitutedEasyGrammarRanges(sample: EasyGrammarFixture) {
        #expect(TreeSitterHighlighter.scanTokenRanges(sample.code, language: sample.language) != nil)
        let resolved = TreeSitterHighlighter.resolvedTokenRanges(sample.code, language: sample.language)
        #expect(
            SyntaxHighlighter.scanTokenRanges(sample.code, language: sample.language) == resolved
        )
        #expect(
            TreeSitterHighlighter.resolvedTokenRangesUTF8(sample.code, language: sample.language) == resolved
        )
        let highlighted = SyntaxHighlighter.highlight(sample.code, language: sample.language)
        #expect(highlighted.string == sample.code)
        expectKind(sample.tokenKind, covering: sample.tokenNeedle, in: resolved, source: sample.code)
    }

    @Test func pythonMultilineStringUsesTreeSitterNotScanner() {
        let code = """
        s = \"\"\"hello
        world\"\"\"
        print(s)
        """
        let treeSitter = TreeSitterHighlighter.scanTokenRanges(code, language: .python)
        #expect(treeSitter != nil)
        let resolved = TreeSitterHighlighter.resolvedTokenRanges(code, language: .python)
        let scanner = SyntaxTokenScanner.scanTokenRanges(code, language: .python)
        #expect(resolved == treeSitter)
        #expect(resolved != scanner)
        expectKind(.string, covering: "world", in: resolved, source: code)
        expectKind(.function, covering: "print", in: resolved, source: code)
    }

    @Test func javascriptTemplateStringAndCommentLoadRealQueries() {
        let code = """
        const name = `hello
        world`
        // done
        foo()
        """
        let ranges = TreeSitterHighlighter.scanTokenRanges(code, language: .javascript)
        #expect(ranges != nil)
        let resolved = TreeSitterHighlighter.resolvedTokenRanges(code, language: .javascript)
        #expect(resolved == ranges)
        #expect(resolved != SyntaxTokenScanner.scanTokenRanges(code, language: .javascript))
        expectKind(.keyword, covering: "const", in: resolved, source: code)
        expectKind(.string, covering: "world", in: resolved, source: code)
        expectKind(.comment, covering: "// done", in: resolved, source: code)
        expectKind(.function, covering: "foo", in: resolved, source: code)
    }

    @Test func typescriptIsNotTSX() {
        #expect(SyntaxLanguage.detect("tsx") == .tsx)
        #expect(SyntaxLanguage.detect("ts") == .typescript)
        #expect(TreeSitterHighlighter.supports(.typescript))
        #expect(TreeSitterHighlighter.supports(.tsx))

        let tsx = "const el = <div className=\"x\" />"
        let tsxRanges = TreeSitterHighlighter.resolvedTokenRanges(tsx, language: .tsx)
        let tsRanges = TreeSitterHighlighter.resolvedTokenRanges(tsx, language: .typescript)
        #expect(!tsxRanges.isEmpty)
        #expect(tsxRanges != tsRanges)
        expectKind(.keyword, covering: "div", in: tsxRanges, source: tsx)
    }

    @Test func jsxIsNotJavaScriptAlias() {
        #expect(SyntaxLanguage.detect("jsx") == .jsx)
        #expect(SyntaxLanguage.detect("js") == .javascript)

        let jsx = "const el = <div className=\"x\" />"
        let jsxRanges = TreeSitterHighlighter.resolvedTokenRanges(jsx, language: .jsx)
        let jsRanges = TreeSitterHighlighter.resolvedTokenRanges(jsx, language: .javascript)
        #expect(!jsxRanges.isEmpty)
        #expect(jsxRanges != jsRanges)
        expectKind(.keyword, covering: "div", in: jsxRanges, source: jsx)
    }

    @Test func missingQueryFileDoesNotSilentlyAliasAnotherGrammar() {
        #expect(
            TreeSitterHighlighter.GrammarRegistry.queryFileURL(
                bundleURL: URL(fileURLWithPath: "/tmp/oppi-missing-grammar.bundle"),
                fileName: "highlights.scm"
            ) == nil
        )
    }

    @Test func iosPainterUsesSubstitutedPythonRanges() {
        let code = "def foo():\n    return 1\n"
        #expect(TreeSitterHighlighter.scanTokenRanges(code, language: .python) != nil)
        let resolved = TreeSitterHighlighter.resolvedTokenRanges(code, language: .python)
        #expect(
            SyntaxHighlighter.scanTokenRanges(code, language: .python) == resolved
        )
        #expect(
            TreeSitterHighlighter.resolvedTokenRangesUTF8(code, language: .python) == resolved
        )
        expectKind(.function, covering: "foo", in: resolved, source: code)
        let highlighted = SyntaxHighlighter.highlight(code, language: .python)
        #expect(highlighted.string == code)
    }
}

struct EasyGrammarFixture: Sendable, CustomTestStringConvertible {
    let language: SyntaxLanguage
    let code: String
    let multilineNeedle: String
    let multilineKind: SyntaxTokenKind
    let tokenNeedle: String
    let tokenKind: SyntaxTokenKind

    var testDescription: String { language.displayName }

    static let all: [EasyGrammarFixture] = [
        EasyGrammarFixture(
            language: .go,
            code: """
            func Hello() {
                s := `hello
            world`
            }
            """,
            multilineNeedle: "world",
            multilineKind: .string,
            tokenNeedle: "Hello",
            tokenKind: .function
        ),
        EasyGrammarFixture(
            language: .rust,
            code: """
            fn hello() {
                let s = "hello
            world";
            }
            """,
            multilineNeedle: "world",
            multilineKind: .string,
            tokenNeedle: "hello",
            tokenKind: .function
        ),
        EasyGrammarFixture(
            language: .c,
            code: """
            /* keep
            color */
            int main(void) { return 0; }
            """,
            multilineNeedle: "color",
            multilineKind: .comment,
            tokenNeedle: "main",
            tokenKind: .function
        ),
        EasyGrammarFixture(
            language: .cpp,
            code: """
            /* keep
            color */
            const char* s = R"(hello
            rawline)";
            """,
            multilineNeedle: "rawline",
            multilineKind: .string,
            tokenNeedle: "color",
            tokenKind: .comment
        ),
        EasyGrammarFixture(
            language: .html,
            code: """
            <!-- keep
            color -->
            <div class="x"></div>
            """,
            multilineNeedle: "color",
            multilineKind: .comment,
            tokenNeedle: "div",
            tokenKind: .keyword
        ),
        EasyGrammarFixture(
            language: .css,
            code: """
            /* keep
            color */
            .foo { content: "x"; }
            """,
            multilineNeedle: "color",
            multilineKind: .comment,
            tokenNeedle: "foo",
            tokenKind: .type
        ),
        EasyGrammarFixture(
            language: .ruby,
            code: """
            s = "hello
            world"
            def foo
            end
            """,
            multilineNeedle: "world",
            multilineKind: .string,
            tokenNeedle: "foo",
            tokenKind: .function
        ),
        EasyGrammarFixture(
            language: .java,
            code: """
            /* keep
            color */
            class Foo {
              void bar() {}
            }
            """,
            multilineNeedle: "color",
            multilineKind: .comment,
            tokenNeedle: "bar",
            tokenKind: .function
        ),
    ]
}

private func expectKind(
    _ expected: SyntaxTokenKind,
    covering substring: String,
    in ranges: [SyntaxTokenRange],
    source: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let utf16 = Array(source.utf16)
    let target = Array(substring.utf16)
    guard let found = findUTF16Range(target, in: utf16) else {
        Issue.record("Substring '\(substring)' not found", sourceLocation: sourceLocation)
        return
    }
    let covering = ranges.filter { range in
        let end = range.location + range.length
        return range.location <= found.lowerBound && end >= found.upperBound
    }
    guard let winner = covering.last else {
        Issue.record(
            "No token covers '\(substring)' — expected \(expected)",
            sourceLocation: sourceLocation
        )
        return
    }
    #expect(
        winner.kind == expected,
        "Expected '\(substring)' to be \(expected), got \(winner.kind)",
        sourceLocation: sourceLocation
    )
}

private func findUTF16Range(_ needle: [UInt16], in haystack: [UInt16]) -> Range<Int>? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    let lastStart = haystack.count - needle.count
    for start in 0...lastStart {
        if haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
    }
    return nil
}
