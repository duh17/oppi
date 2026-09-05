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

    @Test func attributedCodePreservesSourceBeyondMaxLines() {
        let code = overBudgetSource(prefix: "let first = 1", tail: "let last = 10001")
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift)

        #expect(code.split(separator: "\n", omittingEmptySubsequences: false).count == SyntaxTokenScanner.maxLines + 1)
        #expect(attributed.string == code)
        #expect(attributed.length == (code as NSString).length)
        #expect(attributed.string.utf16.count == code.utf16.count)
        #expect(attributed.length > (SyntaxTokenScanner.truncatedCode(code) as NSString).length)
    }

    @Test func remainderBeyondMaxLinesUsesNeutralBaseColor() throws {
        let tail = "plainTail10001 = 10001"
        let code = overBudgetSource(prefix: "let first = 1", tail: tail)
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift)
        #expect(attributed.string == code)

        let tailRange = (attributed.string as NSString).range(of: tail)
        #expect(tailRange.location != NSNotFound)
        let tailColor = try #require(
            attributed.attribute(.foregroundColor, at: tailRange.location, effectiveRange: nil) as? NSColor
        )
        let plain = NSColor(ThemeRuntimeState.currentThemeID().appTheme.syntax.plain)
        #expect(tailColor == plain)
        #expect(tailColor != MacSyntaxHighlighter.color(for: .keyword))
    }

    @Test func unicodeRangesStayUTF16AcrossTokenBudget() throws {
        let prefix = "let café = \"crème 🎉\""
        let tail = "let naïve = \"fin\""
        let code = overBudgetSource(prefix: prefix, tail: tail)
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .swift)

        #expect(attributed.string == code)
        #expect(attributed.length == (code as NSString).length)

        let ns = attributed.string as NSString
        let stringRange = ns.range(of: "\"crème 🎉\"")
        #expect(stringRange.location != NSNotFound)
        #expect(stringRange.length == ("\"crème 🎉\"" as NSString).length)
        let stringColor = try #require(
            attributed.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil) as? NSColor
        )
        #expect(stringColor == MacSyntaxHighlighter.color(for: .string))

        let tailRange = ns.range(of: tail)
        #expect(tailRange.location != NSNotFound)
        let tailColor = try #require(
            attributed.attribute(.foregroundColor, at: tailRange.location, effectiveRange: nil) as? NSColor
        )
        #expect(tailColor == NSColor(ThemeRuntimeState.currentThemeID().appTheme.syntax.plain))
    }

    @Test func treeSitterShellPreservesSourceBeyondMaxLines() throws {
        let tail = "echo lastcommand"
        let code = overBudgetSource(prefix: "echo first", tail: tail)
        let attributed = MacSyntaxHighlighter.attributedCode(code, language: .shell)
        #expect(attributed.string == code)

        let tailRange = (attributed.string as NSString).range(of: tail)
        #expect(tailRange.location != NSNotFound)
        let tailColor = try #require(
            attributed.attribute(.foregroundColor, at: tailRange.location, effectiveRange: nil) as? NSColor
        )
        #expect(tailColor == NSColor(ThemeRuntimeState.currentThemeID().appTheme.syntax.plain))
        #expect(tailColor != MacSyntaxHighlighter.color(for: .function))
    }

    private func overBudgetSource(prefix: String, tail: String) -> String {
        var lines: [String] = [prefix]
        let fillerCount = max(SyntaxTokenScanner.maxLines - 1, 0)
        lines.reserveCapacity(SyntaxTokenScanner.maxLines + 1)
        if fillerCount > 0 {
            lines.append(contentsOf: (1...fillerCount).map { "plainFiller\($0)" })
        }
        lines.append(tail)
        return lines.joined(separator: "\n")
    }
}
