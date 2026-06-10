import Testing
import UIKit
@testable import Oppi

@Suite("Review comment selection text formatting")
struct ReviewCommentSelectionTextFormatterTests {
    @Test func normalizesLineEndingsAndTrimsOuterWhitespace() {
        let result = ReviewCommentSelectionTextFormatter.normalizedSelectedText("  first\r\nsecond\rthird  \n")
        #expect(result == "first\nsecond\nthird")
    }

    @Test func preservesInternalWhitespace() {
        let result = ReviewCommentSelectionTextFormatter.normalizedSelectedText("let  value = 42")
        #expect(result == "let  value = 42")
    }

    @MainActor
    @Test func sourceContextBaseLineOffsetsSelectedTextLine() {
        let textView = UITextView()
        textView.text = "alpha\nbeta\ngamma"
        let range = (textView.text as NSString).range(of: "beta")
        let sourceContext = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenSource,
            filePath: "notes.txt",
            lineRange: 20...22
        )

        let lineRange = ReviewCommentSelectionEditMenuSupport.sourceLineRange(
            in: textView,
            range: range,
            sourceContext: sourceContext
        )

        #expect(lineRange == 21...21)
    }

    @MainActor
    @Test func attributedLineNumbersOverrideTextLineFallback() {
        let textView = UITextView()
        let attributed = NSMutableAttributedString(string: "rendered row")
        attributed.addAttribute(
            reviewLineNumberAttributeKey,
            value: 42,
            range: NSRange(location: 0, length: attributed.length)
        )
        textView.attributedText = attributed
        let sourceContext = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenDiff,
            filePath: "Sources/App.swift"
        )

        let lineRange = ReviewCommentSelectionEditMenuSupport.sourceLineRange(
            in: textView,
            range: NSRange(location: 0, length: attributed.length),
            sourceContext: sourceContext
        )

        #expect(lineRange == 42...42)
    }

    @MainActor
    @Test func customSourceLineResolverOverridesAttributesAndBaseRange() {
        let textView = BaselineSafeTextView()
        let attributed = NSMutableAttributedString(string: "rendered row")
        attributed.addAttribute(
            reviewLineNumberAttributeKey,
            value: 7,
            range: NSRange(location: 0, length: attributed.length)
        )
        textView.attributedText = attributed
        textView.reviewCommentSourceLineRangeResolver = { _ in 100...102 }
        let sourceContext = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenMarkdown,
            filePath: "docs/readme.md",
            lineRange: 20...22
        )

        let lineRange = ReviewCommentSelectionEditMenuSupport.sourceLineRange(
            in: textView,
            range: NSRange(location: 0, length: attributed.length),
            sourceContext: sourceContext
        )

        #expect(lineRange == 100...102)
    }

    @MainActor
    @Test func baseLineOffsetClampsMultilineSelectionToKnownSourceRange() {
        let textView = UITextView()
        textView.text = "alpha\nbeta\ngamma\ndelta"
        let range = (textView.text as NSString).range(of: "beta\ngamma\ndelta")
        let sourceContext = ReviewCommentSourceContext(
            sessionId: "session-1",
            surface: .fullScreenSource,
            filePath: "notes.txt",
            lineRange: 20...22
        )

        let lineRange = ReviewCommentSelectionEditMenuSupport.sourceLineRange(
            in: textView,
            range: range,
            sourceContext: sourceContext
        )

        #expect(lineRange == 21...22)
    }
}
