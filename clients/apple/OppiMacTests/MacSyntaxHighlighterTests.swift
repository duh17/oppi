import AppKit
import Testing
@testable import Oppi

@Suite("Mac syntax highlighter")
struct MacSyntaxHighlighterTests {
    @Test func highlightsSwiftTokensWithSharedScanner() throws {
        let code = "let value = 42\n// comment"
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift)

        #expect(attributed.string == code)
        #expect(!attributed.string.contains("1  let"))

        let keywordRange = (attributed.string as NSString).range(of: "let")
        let commentRange = (attributed.string as NSString).range(of: "// comment")
        let keywordColor = try #require(attributed.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor)
        let commentColor = try #require(attributed.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor)

        #expect(keywordColor == MacSyntaxHighlighter.color(for: .keyword))
        #expect(commentColor == MacSyntaxHighlighter.color(for: .comment))
    }

    @Test func preservesUnicodeSourceWithoutLineNumbers() throws {
        let code = "let café = \"crème\""
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift)

        #expect(attributed.string == code)
        let stringRange = (attributed.string as NSString).range(of: "\"crème\"")
        let stringColor = try #require(attributed.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil) as? NSColor)
        #expect(stringColor == MacSyntaxHighlighter.color(for: .string))
    }

    @Test func paintsShellTokensFromSharedTreeSitterProvider() throws {
        let code = "echo hello"
        #expect(TreeSitterHighlighter.supports(.shell))
        // Fallback scanner tags `echo` as a keyword; tree-sitter tags it as a function.
        #expect(TreeSitterHighlighter.scanTokenRanges(code, language: .shell) != nil)
        let ranges = TreeSitterHighlighter.resolvedTokenRanges(code, language: .shell)
        #expect(ranges.contains { $0.kind == .function })

        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .shell)
        #expect(attributed.string == code)

        for token in ranges {
            guard let expected = MacSyntaxHighlighter.color(for: token.kind) else { continue }
            let color = try #require(
                attributed.attribute(.foregroundColor, at: token.location, effectiveRange: nil) as? NSColor
            )
            #expect(color == expected)
        }
    }

    @Test func shellMultilineStringUsesTreeSitterNotLineScanner() throws {
        let code = """
        git commit -m "feat: show blue
        when agent asks"
        """
        let ranges = TreeSitterHighlighter.resolvedTokenRanges(code, language: .shell)
        let utf16 = Array(code.utf16)
        let functionTexts = ranges.compactMap { range -> String? in
            guard range.kind == .function else { return nil }
            let end = range.location + range.length
            guard range.location >= 0, end <= utf16.count else { return nil }
            return String(utf16CodeUnits: Array(utf16[range.location..<end]), count: range.length)
        }
        #expect(functionTexts.contains("git"))
        #expect(!functionTexts.contains("when"))

        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .shell)
        let whenRange = (attributed.string as NSString).range(of: "when")
        let whenColor = try #require(
            attributed.attribute(.foregroundColor, at: whenRange.location, effectiveRange: nil) as? NSColor
        )
        #expect(whenColor == MacSyntaxHighlighter.color(for: .string))
    }
}
