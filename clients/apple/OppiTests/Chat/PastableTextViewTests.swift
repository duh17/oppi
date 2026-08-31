import Testing
import UIKit
@testable import Oppi

@Suite("composer input assistant")
@MainActor
struct ComposerInputAssistantTests {
    @Test(arguments: [true, false])
    func hidesShortcutBarGroupsInBothAutocorrectionModes(autocorrectionEnabled: Bool) {
        let textView = UITextView()
        let seededGroup = UIBarButtonItemGroup(
            barButtonItems: [UIBarButtonItem(barButtonSystemItem: .done, target: nil, action: nil)],
            representativeItem: nil
        )
        textView.inputAssistantItem.leadingBarButtonGroups = [seededGroup]
        textView.inputAssistantItem.trailingBarButtonGroups = [seededGroup]

        applyComposerInputTraits(to: textView, autocorrectionEnabled: autocorrectionEnabled)

        #expect(textView.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        #expect(textView.inputAssistantItem.trailingBarButtonGroups.isEmpty)
        #expect(textView.textContentType == .none)
        if autocorrectionEnabled {
            #expect(textView.autocorrectionType == .default)
            #expect(textView.writingToolsBehavior == .complete)
        } else {
            #expect(textView.autocorrectionType == .no)
            #expect(textView.writingToolsBehavior == .none)
        }
    }
}

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

    @Test func volatileTranscriptUpdateMutatesTextStorageWithoutReplacingAttributedText() {
        let textView = CountingPastableTextView()
        let font = UIFont.systemFont(ofSize: 17)
        textView.applyStyledText(
            "first",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        let assignmentsBeforeRefresh = textView.attributedTextAssignments

        let updatedText = "first\nsecond"
        textView.applyStyledText(
            updatedText,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 6,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2)
        )

        #expect(textView.attributedTextAssignments == assignmentsBeforeRefresh)
        #expect(textView.text == updatedText)
        #expect(textView.selectedRange == NSRange(location: textView.textStorage.length, length: 0))
        let background = textView.textStorage.attribute(
            .backgroundColor,
            at: textView.textStorage.length - 1,
            effectiveRange: nil
        ) as? UIColor
        #expect(background?.isEqual(UIColor.systemBlue.withAlphaComponent(0.2)) == true)
    }

    @Test func minimalReplacementKeepsSharedEmojiAndSuffixOutsideEdit() {
        let replacement = PastableUITextView.minimalTextReplacement(
            current: "Say 👨‍👩‍👧 now please",
            incoming: "Say 👨‍👩‍👧 this please"
        )

        #expect(("Say 👨‍👩‍👧 now please" as NSString).substring(with: replacement.current) == "now")
        #expect(("Say 👨‍👩‍👧 this please" as NSString).substring(with: replacement.incoming) == "this")
    }

    @Test func minimalReplacementDistinguishesCanonicalRepresentationsInBothDirections() {
        let precomposed = "prefix \u{00E9} suffix"
        let decomposed = "prefix e\u{301} suffix"

        let toDecomposed = PastableUITextView.minimalTextReplacement(
            current: precomposed,
            incoming: decomposed
        )
        #expect((precomposed as NSString).substring(with: toDecomposed.current) == "\u{00E9}")
        #expect((decomposed as NSString).substring(with: toDecomposed.incoming) == "e\u{301}")

        let toPrecomposed = PastableUITextView.minimalTextReplacement(
            current: decomposed,
            incoming: precomposed
        )
        #expect((decomposed as NSString).substring(with: toPrecomposed.current) == "e\u{301}")
        #expect((precomposed as NSString).substring(with: toPrecomposed.incoming) == "\u{00E9}")
    }

    @Test func styledTextStoresExactCanonicalRepresentationBeforeStyling() {
        let textView = CountingPastableTextView()
        let font = UIFont.systemFont(ofSize: 17)
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{301}"

        textView.applyStyledText(
            precomposed,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )
        textView.applyStyledText(
            decomposed,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 1,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2)
        )
        #expect(Array(textView.textStorage.string.utf16) == Array(decomposed.utf16))
        #expect(textView.textStorage.length == 2)
        #expect(textView.textStorage.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)

        textView.applyStyledText(
            precomposed,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue,
            correctionRanges: [NSRange(location: 0, length: 1)],
            correctionUnderlineColor: .systemOrange
        )
        #expect(Array(textView.textStorage.string.utf16) == Array(precomposed.utf16))
        #expect(textView.textStorage.length == 1)
        #expect(textView.textStorage.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
    }

    @Test func streamedUpdatesKeepTerminalCaretImmediatelyAndAfterDeferredCorrection() async {
        let textView = CountingPastableTextView()
        let font = UIFont.systemFont(ofSize: 17)
        textView.applyStyledText(
            "Start",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)

        var observations: [(PastableUITextView.SelectionProbePhase, NSRange, Int)] = []
        textView.selectionProbeForTesting = { phase, selection, storageLength in
            observations.append((phase, selection, storageLength))
        }

        for transcript in ["Start streaming", "Start streaming more", "Start streaming more text"] {
            observations.removeAll()
            textView.applyStyledText(
                transcript,
                font: font,
                baseColor: .label,
                volatileSuffixLength: 4,
                volatileColor: .systemBlue
            )

            let expected = NSRange(location: (transcript as NSString).length, length: 0)
            #expect(observations.first?.0 == .immediate)
            #expect(observations.first?.1 == expected)
            #expect(observations.first?.2 == expected.location)

            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }

            #expect(observations.last?.0 == .deferred)
            #expect(observations.last?.1 == expected)
            #expect(observations.last?.2 == expected.location)
            #expect(textView.selectedRange == expected)
        }
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
