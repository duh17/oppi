import AppKit
import Testing
@testable import Oppi

@Suite("Mac syntax highlighter")
struct MacSyntaxHighlighterTests {
    @Test func highlightsSwiftTokensWithSharedScanner() throws {
        let code = "let value = 42\n// comment"
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift)

        #expect(attributed.string.contains("1  let value = 42"))
        #expect(attributed.string.contains("2  // comment"))

        let keywordRange = (attributed.string as NSString).range(of: "let")
        let commentRange = (attributed.string as NSString).range(of: "// comment")
        let keywordColor = try #require(attributed.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor)
        let commentColor = try #require(attributed.attribute(.foregroundColor, at: commentRange.location, effectiveRange: nil) as? NSColor)

        #expect(keywordColor == MacSyntaxHighlighter.color(for: .keyword))
        #expect(commentColor == MacSyntaxHighlighter.color(for: .comment))
    }

    @Test func omitsLineNumbersWhenRequested() throws {
        let code = "let café = \"crème\""
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift, includeLineNumbers: false)

        #expect(attributed.string == code)
        let stringRange = (attributed.string as NSString).range(of: "\"crème\"")
        let stringColor = try #require(attributed.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil) as? NSColor)
        #expect(stringColor == MacSyntaxHighlighter.color(for: .string))
    }
}
