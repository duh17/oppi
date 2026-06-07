import Testing
import UIKit
@testable import Oppi

@Suite("inlineComposerHeight")
struct InlineComposerHeightTests {

    @Test func clampsToMinimumSingleLineHeight() {
        let height = inlineComposerHeight(
            rawContentHeight: 2,
            lineHeight: 20,
            verticalInsets: 8,
            maxLines: 10
        )
        #expect(height == 28)
    }

    @Test func preservesInRangeHeight() {
        let height = inlineComposerHeight(
            rawContentHeight: 64,
            lineHeight: 20,
            verticalInsets: 8,
            maxLines: 10
        )
        #expect(height == 64)
    }

    @Test func clampsToConfiguredMaxLines() {
        let height = inlineComposerHeight(
            rawContentHeight: 400,
            lineHeight: 20,
            verticalInsets: 8,
            maxLines: 3
        )
        #expect(height == 68) // (20 * 3) + 8
    }

    @Test func guardsInvalidMaxLinesAndInsets() {
        let height = inlineComposerHeight(
            rawContentHeight: 0,
            lineHeight: 20,
            verticalInsets: -100,
            maxLines: 0
        )
        #expect(height == 20) // falls back to 1 line, no negative inset
    }
}

@Suite("PastableUITextView styled text updates")
@MainActor
struct PastableUITextViewStyledTextTests {
    @Test func matchingPlainNativeEditDoesNotReassignAttributedText() {
        let textView = CountingPastableTextView()
        let font = UIFont.systemFont(ofSize: 17)
        textView.applyStyledText(
            "first",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )

        let editedText = "first\nsecond"
        textView.text = editedText
        textView.selectedRange = NSRange(location: (editedText as NSString).length, length: 0)
        let assignmentsBeforeRefresh = textView.attributedTextAssignments

        textView.applyStyledText(
            editedText,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )

        #expect(textView.attributedTextAssignments == assignmentsBeforeRefresh)
        #expect(textView.selectedRange.location == (editedText as NSString).length)
    }

    @Test func volatileTextStillReassignsWhenTextMatches() {
        let textView = CountingPastableTextView()
        let font = UIFont.systemFont(ofSize: 17)
        textView.applyStyledText(
            "first",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )

        let editedText = "first\nsecond"
        textView.text = editedText
        let assignmentsBeforeRefresh = textView.attributedTextAssignments

        textView.applyStyledText(
            editedText,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 6,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2)
        )

        #expect(textView.attributedTextAssignments == assignmentsBeforeRefresh + 1)
    }

    private final class CountingPastableTextView: PastableUITextView {
        var attributedTextAssignments = 0

        override var attributedText: NSAttributedString! {
            get { super.attributedText }
            set {
                attributedTextAssignments += 1
                super.attributedText = newValue
            }
        }
    }
}

@Suite("inlineComposerShouldFastPathToMaxHeight")
struct InlineComposerFastPathTests {

    @Test func falseForShortText() {
        let shouldFastPath = inlineComposerShouldFastPathToMaxHeight(
            textLength: 280,
            containerWidth: 320,
            lineHeight: 20,
            maxLines: 8
        )
        #expect(shouldFastPath == false)
    }

    @Test func trueForVeryLongText() {
        let shouldFastPath = inlineComposerShouldFastPathToMaxHeight(
            textLength: 800,
            containerWidth: 320,
            lineHeight: 20,
            maxLines: 8
        )
        #expect(shouldFastPath)
    }

    @Test func guardsInvalidInputs() {
        let small = inlineComposerShouldFastPathToMaxHeight(
            textLength: 39,
            containerWidth: 0,
            lineHeight: 0,
            maxLines: 0
        )
        let large = inlineComposerShouldFastPathToMaxHeight(
            textLength: 41,
            containerWidth: 0,
            lineHeight: 0,
            maxLines: 0
        )

        #expect(small == false)
        #expect(large)
    }

    @Test func handlesInfiniteWidthWithoutCrashing() {
        let shouldFastPath = inlineComposerShouldFastPathToMaxHeight(
            textLength: 500,
            containerWidth: .infinity,
            lineHeight: 20,
            maxLines: 8
        )
        #expect(shouldFastPath)
    }

    @Test func handlesHugeFiniteWidthWithoutIntegerOverflow() {
        let shouldFastPath = inlineComposerShouldFastPathToMaxHeight(
            textLength: 10_000,
            containerWidth: .greatestFiniteMagnitude,
            lineHeight: 20,
            maxLines: 8
        )
        #expect(shouldFastPath == false)
    }
}
