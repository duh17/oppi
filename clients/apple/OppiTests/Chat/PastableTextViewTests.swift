import SwiftUI
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

@Suite("inline composer dictation follow")
@MainActor
struct InlineComposerDictationFollowTests {
    @Test func streamedTerminalTranscriptKeepsLastLineVisibleAfterEightLineClamp() async throws {
        let font = UIFont.systemFont(ofSize: 17)
        let draft = InlineComposerFollowDraft()
        let width: CGFloat = 320
        let maxLines = ComposerInputMetrics.inlineMaxLines
        let clampedHeight = inlineComposerHeight(
            rawContentHeight: .greatestFiniteMagnitude,
            lineHeight: font.lineHeight,
            verticalInsets: 12,
            maxLines: maxLines
        )

        let host = UIHostingController(
            rootView: InlineComposerFollowHost(
                draft: draft,
                font: font,
                width: width,
                height: clampedHeight,
                maxLines: maxLines
            )
        )
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: clampedHeight + 24)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()

        let lines = (1...16).map { index in
            "Line \(index) of streamed dictation keeps newest words visible in the compact composer."
        }
        for index in lines.indices {
            draft.text = lines[0...index].joined(separator: "\n")
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await yieldMainQueueTurn()
        }

        let textView = try #require(findPastableTextView(in: host.view))
        #expect(textView.bounds.height <= clampedHeight + 0.5)
        #expect(textView.clipsToBounds)
        #expect(textView.isScrollEnabled)
        #expect(textView.textStorage.length == (draft.text as NSString).length)
        #expect(textView.selectedRange == NSRange(location: textView.textStorage.length, length: 0))

        let followed = await waitForMainActorCondition {
            guard let textView = findPastableTextView(in: host.view) else { return false }
            textView.layoutIfNeeded()
            return terminalLineIsVisible(in: textView)
        }
        #expect(
            followed,
            "\(inlineFollowDebugDescription(textView))"
        )
    }

    @Test func streamedUpdateDoesNotFollowTailWhenCaretIsOffEnd() async throws {
        let font = UIFont.systemFont(ofSize: 17)
        let (textView, window) = try makeClampedInlineComposerTextView(font: font)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let prefix = (1...12).map { index in
            "Line \(index) of an already overflowing compact composer draft."
        }.joined(separator: "\n")
        applyInlineDictationTranscript(prefix, to: textView, font: font, scrollCaretToVisible: true)
        await yieldMainQueueTurn()
        textView.layoutIfNeeded()

        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.setContentOffset(.zero, animated: false)
        let offsetBefore = textView.contentOffset.y

        applyInlineDictationTranscript(
            prefix + "\nMore words after the user moved the caret.",
            to: textView,
            font: font,
            scrollCaretToVisible: true
        )
        await yieldMainQueueTurn()
        textView.layoutIfNeeded()

        #expect(textView.selectedRange == NSRange(location: 0, length: 0))
        #expect(abs(textView.contentOffset.y - offsetBefore) < 1)
        #expect(!terminalLineIsVisible(in: textView))
    }
}

@MainActor @Observable
private final class InlineComposerFollowDraft {
    var text = ""
    var keyboardLanguage: String? = nil
}

private struct InlineComposerFollowHost: View {
    @Bindable var draft: InlineComposerFollowDraft
    let font: UIFont
    let width: CGFloat
    let height: CGFloat
    let maxLines: Int

    var body: some View {
        PastableTextView(
            text: $draft.text,
            placeholder: "",
            font: font,
            textColor: .label,
            tintColor: .systemBlue,
            volatileSuffixLength: min(18, draft.text.count),
            correctionRanges: [],
            maxLines: maxLines,
            autocorrectionEnabled: true,
            onPasteImages: { _ in },
            onCommandEnter: nil,
            onAlternateEnter: nil,
            onOverflowChange: nil,
            onLineCountChange: nil,
            onFocusChange: nil,
            onDictationStateChange: nil,
            focusRequestID: 0,
            blurRequestID: 0,
            dictationRequestID: 0,
            suppressKeyboard: true,
            allowKeyboardRestoreOnTap: false,
            onKeyboardRestoreRequest: nil,
            accessibilityIdentifier: "test.inline.dictation.composer",
            keyboardLanguage: $draft.keyboardLanguage
        )
        .frame(width: width, height: height)
    }
}

@MainActor
private func makeClampedInlineComposerTextView(
    font: UIFont,
    width: CGFloat = 320,
    maxLines: Int = ComposerInputMetrics.inlineMaxLines
) throws -> (PastableUITextView, UIWindow) {
    let textView = PastableUITextView()
    textView.font = font
    textView.textColor = .label
    textView.backgroundColor = .clear
    textView.clipsToBounds = true
    textView.isScrollEnabled = true
    textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    textView.textContainer.lineFragmentPadding = 0
    _ = textView.layoutManager

    let height = inlineComposerHeight(
        rawContentHeight: .greatestFiniteMagnitude,
        lineHeight: font.lineHeight,
        verticalInsets: textView.textContainerInset.top + textView.textContainerInset.bottom,
        maxLines: maxLines
    )
    textView.frame = CGRect(x: 0, y: 0, width: width, height: height)

    let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let window = UIWindow(windowScene: scene)
    window.frame = textView.frame
    let host = UIViewController()
    host.view.frame = window.frame
    host.view.addSubview(textView)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    return (textView, window)
}

private func applyInlineDictationTranscript(
    _ text: String,
    to textView: PastableUITextView,
    font: UIFont,
    scrollCaretToVisible: Bool
) {
    textView.applyStyledText(
        text,
        font: font,
        baseColor: .label,
        volatileSuffixLength: min(18, text.count),
        volatileColor: .systemBlue,
        volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2),
        scrollCaretToVisible: scrollCaretToVisible
    )
}

@MainActor
private func findPastableTextView(in view: UIView) -> PastableUITextView? {
    if let textView = view as? PastableUITextView {
        return textView
    }
    for subview in view.subviews {
        if let found = findPastableTextView(in: subview) {
            return found
        }
    }
    return nil
}

@MainActor
private func terminalLineIsVisible(in textView: UITextView, slop: CGFloat = 2) -> Bool {
    let length = textView.textStorage.length
    guard length > 0, textView.bounds.height > 1 else { return false }
    textView.layoutManager.ensureLayout(for: textView.textContainer)
    let glyphCount = textView.layoutManager.numberOfGlyphs
    guard glyphCount > 0 else { return false }

    let lastCharacter = NSRange(location: length - 1, length: 1)
    let glyphRange = textView.layoutManager.glyphRange(
        forCharacterRange: lastCharacter,
        actualCharacterRange: nil
    )
    let glyphIndex = min(max(glyphRange.location, 0), glyphCount - 1)
    var lineRect = textView.layoutManager.lineFragmentUsedRect(
        forGlyphAt: glyphIndex,
        effectiveRange: nil
    )
    lineRect.origin.y += textView.textContainerInset.top
    lineRect.origin.x += textView.textContainerInset.left

    let visibleMinY = textView.contentOffset.y
    let visibleMaxY = textView.contentOffset.y + textView.bounds.height
    return lineRect.maxY <= visibleMaxY + slop && lineRect.minY >= visibleMinY - lineRect.height - slop
}

@MainActor
private func inlineFollowDebugDescription(_ textView: UITextView) -> String {
    "contentOffset.y=\(textView.contentOffset.y) contentSize=\(textView.contentSize) bounds=\(textView.bounds) selected=\(textView.selectedRange) length=\(textView.textStorage.length)"
}

private func yieldMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
