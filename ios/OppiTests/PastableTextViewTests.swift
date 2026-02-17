import Testing
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
