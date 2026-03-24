import Testing
import UIKit
@testable import Oppi

@Suite("FullScreenCodeHighlighter")
struct FullScreenCodeHighlighterTests {

    // MARK: - buildHighlightedText

    @Test func highlightedTextPreservesFullContent() {
        let code = "let x = 42\nprint(x)\n"
        let result = FullScreenCodeHighlighter.buildHighlightedText(code, language: .swift)
        #expect(result.string == code)
    }

    @Test func highlightedTextHasValidAttributeRanges() {
        let code = "func hello() {\n    return 1\n}\n"
        let result = FullScreenCodeHighlighter.buildHighlightedText(code, language: .swift)
        assertAttributeRangesValid(result)
    }

    @Test func highlightedTextWithEmoji() {
        let code = "let emoji = \"👨‍👩‍👧‍👦\"\nprint(emoji)\n"
        let result = FullScreenCodeHighlighter.buildHighlightedText(code, language: .swift)
        #expect(result.string == code)
        assertAttributeRangesValid(result)
    }

    @Test func highlightedTextWithMultiByteUnicode() {
        let code = "let café = \"über\"\n// résumé\n"
        let result = FullScreenCodeHighlighter.buildHighlightedText(code, language: .swift)
        #expect(result.string == code)
        assertAttributeRangesValid(result)
    }

    @Test func highlightedTextForUnknownLanguage() {
        let code = "just plain text\n"
        let result = FullScreenCodeHighlighter.buildHighlightedText(code, language: .unknown)
        #expect(result.string == code)
        assertAttributeRangesValid(result)
    }

    @Test func highlightedTextPreservesRemainderBeyondMaxLines() {
        // Build content that exceeds SyntaxHighlighter.maxLines
        let lineCount = SyntaxHighlighter.maxLines + 100
        let lines = (1...lineCount).map { "let x\($0) = \($0)" }
        let code = lines.joined(separator: "\n")

        let result = FullScreenCodeHighlighter.buildHighlightedText(code, language: .swift)
        #expect(result.string == code, "All content including remainder must be preserved")
        assertAttributeRangesValid(result)
    }

    @Test func highlightedTextEmptyString() {
        let result = FullScreenCodeHighlighter.buildHighlightedText("", language: .swift)
        #expect(result.string == "")
        assertAttributeRangesValid(result)
    }

    // MARK: - AttributedString round-trip corruption proof

    @Test func attributedStringRoundTripCanAlterAttributes() {
        // Prove the round-trip through AttributedString can alter attribute runs.
        // NSAttributedString supports arbitrary attribute keys; AttributedString
        // silently drops keys it doesn't know about.
        let customKey = NSAttributedString.Key("com.oppi.test.custom")
        let original = NSMutableAttributedString(string: "hello")
        original.addAttribute(customKey, value: "preserved", range: NSRange(location: 0, length: 5))

        // Round-trip: NSAttributedString → AttributedString → NSAttributedString
        let swift = AttributedString(original)
        let roundTripped = NSAttributedString(swift)

        // The custom attribute is lost in the round-trip
        var found = false
        roundTripped.enumerateAttribute(customKey, in: NSRange(location: 0, length: roundTripped.length)) { value, _, _ in
            if value != nil { found = true }
        }
        #expect(!found, "Custom attributes should be lost in round-trip, proving it's lossy")
    }

    // MARK: - SendableNSAttributedString

    @Test func sendableWrapperPreservesIdentity() async {
        let original = NSAttributedString(
            string: "test",
            attributes: [.foregroundColor: UIColor.red]
        )
        let wrapper = SendableNSAttributedString(original)

        // Send across isolation boundary and return the wrapper
        let receivedWrapper = await Task.detached {
            wrapper
        }.value
        let received = receivedWrapper.value

        #expect(received.string == original.string)
        #expect(received.length == original.length)

        // Verify attribute is preserved (not round-tripped)
        let color = received.attribute(
            NSAttributedString.Key.foregroundColor, at: 0, effectiveRange: nil
        ) as? UIColor
        #expect(color == UIColor.red)
    }

    @Test func sendableWrapperPreservesCustomAttributes() async {
        let customKey = NSAttributedString.Key("com.oppi.test.custom")
        let original = NSMutableAttributedString(string: "hello")
        original.addAttribute(customKey, value: "preserved", range: NSRange(location: 0, length: 5))
        let immutable = NSAttributedString(attributedString: original)

        let wrapper = SendableNSAttributedString(immutable)
        let receivedWrapper = await Task.detached { wrapper }.value
        let received = receivedWrapper.value

        let value = received.attribute(customKey, at: 0, effectiveRange: nil) as? String
        #expect(value == "preserved", "Custom attributes must survive Sendable transport")
    }

    // MARK: - Helpers

    private func assertAttributeRangesValid(_ attrStr: NSAttributedString) {
        let length = attrStr.length
        attrStr.enumerateAttributes(
            in: NSRange(location: 0, length: length),
            options: []
        ) { _, range, _ in
            #expect(
                range.location >= 0 && range.location + range.length <= length,
                "Attribute range \(range) exceeds string length \(length)"
            )
        }
    }
}
