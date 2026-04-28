import Testing
import UIKit
@testable import Oppi

/// Tests for keyboard suppression in PastableUITextView.
///
/// **Why this exists:**
///
/// Voice input and keyboard typing are mutually exclusive modes in the composer.
/// During voice recording the cursor must be visible (for feedback that transcribed
/// text will appear) but the keyboard must NOT appear (it wastes screen space and
/// the user cannot type while transcription is streaming anyway — any typed characters
/// would be overwritten by the next transcript update).
///
/// The solution: set `inputView = UIView()` on the text view, which tells UIKit to
/// show an empty input view instead of the system keyboard. The text view stays first
/// responder (cursor visible) but no keyboard slides up.
///
/// When the user taps the text field during recording, a gesture recognizer restores
/// the keyboard (`inputView = nil` + `reloadInputViews()`) and fires a callback so
/// ChatInputBar can stop voice recording — making typing and voice seamlessly toggle.
///
/// These tests protect that contract so future changes don't accidentally break the
/// voice/keyboard interaction.
@Suite("Keyboard Suppression — Voice/Typing Mutual Exclusivity")
@MainActor
struct KeyboardSuppressionTests {

    // MARK: - Suppression State

    @Test("Initial state: keyboard not suppressed, inputView is nil")
    func initialState() {
        let textView = PastableUITextView()
        #expect(!textView.isKeyboardSuppressed)
        #expect(textView.inputView == nil)
    }

    @Test("Suppressing keyboard sets empty inputView to hide system keyboard")
    func suppressSetsEmptyInputView() {
        let textView = PastableUITextView()
        textView.setKeyboardSuppressed(true)

        #expect(textView.isKeyboardSuppressed)
        #expect(textView.inputView != nil, "Empty UIView suppresses system keyboard")
    }

    @Test("Restoring keyboard clears inputView to show system keyboard")
    func restoreClearsInputView() {
        let textView = PastableUITextView()
        textView.setKeyboardSuppressed(true)
        textView.setKeyboardSuppressed(false)

        #expect(!textView.isKeyboardSuppressed)
        #expect(textView.inputView == nil, "nil inputView restores system keyboard")
    }

    @Test("Suppression survives full toggle cycle without state drift")
    func toggleCycle() {
        let textView = PastableUITextView()

        // Cycle: suppress → restore → suppress → restore
        for _ in 0..<3 {
            textView.setKeyboardSuppressed(true)
            #expect(textView.isKeyboardSuppressed)
            #expect(textView.inputView != nil)

            textView.setKeyboardSuppressed(false)
            #expect(!textView.isKeyboardSuppressed)
            #expect(textView.inputView == nil)
        }
    }

    // MARK: - Restore Gesture

    @Test("Restore gesture is installed and tracks suppression state")
    func gestureTracksSuppressionState() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        let tap = textView.keyboardRestoreTap
        #expect(textView.gestureRecognizers?.contains(tap) == true, "Tap gesture should be installed")
        #expect(tap.isEnabled == false, "Gesture disabled when keyboard not suppressed")

        textView.setKeyboardSuppressed(true)
        #expect(tap.isEnabled == true, "Gesture enabled during keyboard suppression")

        textView.setKeyboardSuppressed(false)
        #expect(tap.isEnabled == false, "Gesture disabled after suppression ends")
    }

    @Test("Restore gesture can be disabled while suppression is active")
    func restoreGestureCanBeDisabled() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()
        textView.setKeyboardSuppressed(true)

        let tap = textView.keyboardRestoreTap
        #expect(tap.isEnabled == true)

        textView.setAllowKeyboardRestoreOnTap(false)
        #expect(!textView.allowsKeyboardRestoreOnTap)
        #expect(tap.isEnabled == false, "Gesture should disable when restore-on-tap is disallowed")

        textView.setAllowKeyboardRestoreOnTap(true)
        #expect(textView.allowsKeyboardRestoreOnTap)
        #expect(tap.isEnabled == true, "Gesture should re-enable when restore-on-tap is allowed")
    }

    @Test("Tap restore is ignored when restore-on-tap is disabled")
    func restoreTapIgnoredWhenDisabled() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()
        textView.setKeyboardSuppressed(true)
        textView.setAllowKeyboardRestoreOnTap(false)

        var callbackFired = false
        textView.onKeyboardRestoreRequest = { callbackFired = true }

        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))

        #expect(!callbackFired, "Callback must not fire when restore-on-tap is disabled")
        #expect(textView.isKeyboardSuppressed, "Suppression should remain active")
        #expect(textView.inputView != nil, "Keyboard should stay hidden")
    }

    @Test("Restore callback fires when tap occurs during suppression")
    func restoreCallbackFires() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()
        textView.setKeyboardSuppressed(true)

        var callbackFired = false
        textView.onKeyboardRestoreRequest = { callbackFired = true }

        // Invoke the @objc tap handler via ObjC runtime (private but @objc).
        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))

        #expect(callbackFired, "Callback must fire so ChatInputBar can stop voice recording")
        #expect(!textView.isKeyboardSuppressed, "Keyboard should be restored after tap")
        #expect(textView.inputView == nil, "inputView should be nil after restore")
    }

    @Test("Restore gesture is disabled after tap restores keyboard")
    func gestureDisabledAfterRestore() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()
        textView.setKeyboardSuppressed(true)

        let tap = textView.keyboardRestoreTap
        #expect(tap.isEnabled == true)

        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))
        #expect(tap.isEnabled == false, "Gesture should disable itself after restoring keyboard")
    }

    @Test("Tap handler is no-op when keyboard is not suppressed")
    func tapHandlerNoOpWhenNotSuppressed() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        var callbackFired = false
        textView.onKeyboardRestoreRequest = { callbackFired = true }

        // Keyboard is NOT suppressed — tap should be ignored
        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))

        #expect(!callbackFired, "Should not fire callback when keyboard is not suppressed")
        #expect(textView.inputView == nil, "inputView should remain nil")
    }

    // MARK: - SwiftUI/UIKit State Sync (Regression)

    @Test("Regression: UIKit restore followed by stale SwiftUI re-suppress")
    func regressionStaleSuppressAfterRestore() {
        // Bug: User taps mic (suppressKeyboard=true), taps mic again to stop,
        // but suppressKeyboard stays true. User taps text field, UIKit restores
        // keyboard, but SwiftUI's updateUIView sees the mismatch and re-suppresses.
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        // 1. Voice recording starts — suppress keyboard
        textView.setKeyboardSuppressed(true)
        #expect(textView.isKeyboardSuppressed)

        // 2. Voice recording stops — but simulate stale SwiftUI state
        //    (suppressKeyboard was not reset to false — the bug)

        // 3. User taps text field — UIKit restores correctly
        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))
        #expect(!textView.isKeyboardSuppressed, "UIKit restored keyboard")
        #expect(textView.inputView == nil, "inputView cleared")

        // 4. THE BUG: SwiftUI updateUIView runs with stale suppressKeyboard=true
        //    and re-suppresses. This simulates what updateUIView does:
        let staleSuppressKeyboard = true
        if textView.isKeyboardSuppressed != staleSuppressKeyboard {
            textView.setKeyboardSuppressed(staleSuppressKeyboard)
        }
        // Keyboard is suppressed again — user can't type
        #expect(textView.isKeyboardSuppressed, "Stale state causes re-suppression")
        #expect(textView.inputView != nil, "Keyboard hidden again by stale state")

        // 5. THE FIX: When SwiftUI resets suppressKeyboard=false (as it should),
        //    the sync is clean:
        let fixedSuppressKeyboard = false
        if textView.isKeyboardSuppressed != fixedSuppressKeyboard {
            textView.setKeyboardSuppressed(fixedSuppressKeyboard)
        }
        #expect(!textView.isKeyboardSuppressed, "Fixed state keeps keyboard visible")
        #expect(textView.inputView == nil, "inputView stays nil with correct state")
    }

    @Test("Restore callback fires regardless of external recording state")
    func restoreCallbackAlwaysFires() {
        // Regression: handleKeyboardRestore in ChatInputBar guarded on
        // isRecording — after mic-stop the guard bailed and suppressKeyboard
        // was never reset. The UIKit callback must fire unconditionally so
        // the SwiftUI handler can always clean up.
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()
        textView.setKeyboardSuppressed(true)

        var callbackCount = 0
        textView.onKeyboardRestoreRequest = { callbackCount += 1 }

        // First restore — simulates tap during recording
        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))
        #expect(callbackCount == 1)
        #expect(!textView.isKeyboardSuppressed)

        // Re-suppress and restore again — simulates tap after recording stopped
        textView.setKeyboardSuppressed(true)
        textView.perform(NSSelectorFromString("handleKeyboardRestoreTap"))
        #expect(callbackCount == 2, "Callback must fire every time, not just during recording")
        #expect(!textView.isKeyboardSuppressed)
    }

    // MARK: - Cursor Retention During Programmatic Updates

    @Test("IME composition defers attributed text replacement for matching preedit text")
    func imeCompositionDefersAttributedReplacement() {
        #expect(
            PastableUITextView.shouldDeferStyledTextUpdateWhileComposing(
                hasMarkedText: true,
                currentText: "jiugongge",
                incomingText: "jiugongge"
            )
        )
        #expect(
            PastableUITextView.shouldDeferStyledTextUpdateWhileComposing(
                hasMarkedText: true,
                currentText: "nvhai",
                incomingText: "nvhai"
            )
        )
        #expect(
            !PastableUITextView.shouldDeferStyledTextUpdateWhileComposing(
                hasMarkedText: true,
                currentText: "jiugongge",
                incomingText: "九宫格"
            )
        )
        #expect(
            !PastableUITextView.shouldDeferStyledTextUpdateWhileComposing(
                hasMarkedText: true,
                currentText: "jiugongge",
                incomingText: "jiugongge "
            )
        )
        #expect(
            !PastableUITextView.shouldDeferStyledTextUpdateWhileComposing(
                hasMarkedText: false,
                currentText: "jiugongge",
                incomingText: "jiugongge"
            )
        )
    }

    @Test("Active IME composition preserves existing attributes for matching preedit text")
    func activeImeCompositionPreservesExistingAttributes() throws {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        let incoming = "jiugongge"
        let original = NSMutableAttributedString(
            string: incoming,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.systemRed,
            ]
        )
        textView.attributedText = original
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.systemRed,
        ]
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.markedTextRangeOverrideForTesting = FakeTextRange()

        textView.applyStyledText(
            incoming,
            font: font,
            baseColor: .label,
            volatileSuffixLength: 4,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2),
            correctionRanges: [NSRange(location: 1, length: 3)],
            correctionUnderlineColor: .systemOrange
        )

        let attributed = try #require(textView.attributedText)
        let foreground = attributed.attribute(.foregroundColor, at: incoming.count - 1, effectiveRange: nil) as? UIColor
        let background = attributed.attribute(.backgroundColor, at: incoming.count - 1, effectiveRange: nil) as? UIColor
        let underline = attributed.attribute(.underlineStyle, at: 2, effectiveRange: nil) as? Int

        #expect(attributed.string == incoming)
        #expect(foreground?.isEqual(UIColor.systemRed) == true, "Deferred update must not repaint active preedit text")
        #expect(background == nil, "Deferred update must not add volatile background during composition")
        #expect(underline == nil, "Deferred update must not add correction underlines during composition")
        #expect(textView.selectedRange == NSRange(location: 3, length: 0), "Deferred update must not move the caret")
        #expect((textView.typingAttributes[.foregroundColor] as? UIColor)?.isEqual(UIColor.systemRed) == true)
    }

    @Test("Committed Chinese text still applies styled update even if marked text was active")
    func committedChineseTextStillAppliesStyledUpdate() throws {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        textView.text = "jiugongge"
        textView.markedTextRangeOverrideForTesting = FakeTextRange()

        textView.applyStyledText(
            "九宫格",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 1,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2),
            correctionRanges: [NSRange(location: 0, length: 2)],
            correctionUnderlineColor: .systemOrange
        )

        let attributed = try #require(textView.attributedText)
        let foreground = attributed.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor
        let background = attributed.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? UIColor
        let underline = attributed.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int

        #expect(attributed.string == "九宫格")
        #expect(foreground?.isEqual(UIColor.systemBlue) == true)
        #expect(background != nil)
        #expect(underline == NSUnderlineStyle.single.rawValue)
    }

    @Test("Different preedit text still updates while marked text is active")
    func differentPreeditTextStillUpdates() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        textView.text = "jiu"
        textView.markedTextRangeOverrideForTesting = FakeTextRange()

        textView.applyStyledText(
            "jiugong",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 4,
            volatileColor: .systemBlue
        )

        #expect(textView.attributedText?.string == "jiugong")
    }

    @Test("Once composition ends the same text can be restyled normally")
    func restyleRunsAfterCompositionEnds() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        textView.text = "jiugongge"
        textView.markedTextRangeOverrideForTesting = FakeTextRange()

        textView.applyStyledText(
            "jiugongge",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 4,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2)
        )
        let deferredBackground = textView.attributedText?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? UIColor
        #expect(deferredBackground == nil)

        textView.markedTextRangeOverrideForTesting = nil
        textView.applyStyledText(
            "jiugongge",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 4,
            volatileColor: .systemBlue,
            volatileBackgroundColor: .systemBlue.withAlphaComponent(0.2)
        )

        let appliedBackground = textView.attributedText?.attribute(.backgroundColor, at: 7, effectiveRange: nil) as? UIColor
        #expect(appliedBackground != nil, "Styling should resume after IME composition finishes")
    }

    @Test("Deferred IME update does not poison the cache for the later real style pass")
    func deferredImeUpdateDoesNotPoisonStyleCache() throws {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        let volatileBackground = UIColor.systemBlue.withAlphaComponent(0.2)
        textView.text = "nvhai"
        textView.markedTextRangeOverrideForTesting = FakeTextRange()

        textView.applyStyledText(
            "nvhai",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 2,
            volatileColor: .systemBlue,
            volatileBackgroundColor: volatileBackground
        )

        textView.markedTextRangeOverrideForTesting = nil
        textView.applyStyledText(
            "nvhai",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 2,
            volatileColor: .systemBlue,
            volatileBackgroundColor: volatileBackground
        )

        let attributed = try #require(textView.attributedText)
        let background = attributed.attribute(.backgroundColor, at: 4, effectiveRange: nil) as? UIColor
        #expect(background?.isEqual(volatileBackground) == true)
    }

    @Test("Programmatic transcript updates keep a trailing caret pinned to the end")
    func programmaticUpdatesKeepTrailingCaretAtEnd() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)

        textView.applyStyledText(
            "Hello",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)

        textView.applyStyledText(
            "Hello there",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 5,
            volatileColor: .systemBlue
        )

        #expect(textView.selectedRange == NSRange(location: textView.textStorage.length, length: 0))
    }

    @Test("Programmatic transcript updates from empty input move the caret to the new end")
    func programmaticUpdatesFromEmptyInputMoveCaretToEnd() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)

        #expect(textView.selectedRange == NSRange(location: 0, length: 0))

        textView.applyStyledText(
            "Let’s try to find ways to fix this warning",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 7,
            volatileColor: .systemBlue
        )

        #expect(textView.selectedRange == NSRange(location: textView.textStorage.length, length: 0))
    }

    @Test("Programmatic transcript updates preserve non-terminal selections")
    func programmaticUpdatesPreserveNonTerminalSelections() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)

        textView.applyStyledText(
            "Hello there",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 0,
            volatileColor: .systemBlue
        )
        textView.selectedRange = NSRange(location: 2, length: 0)

        textView.applyStyledText(
            "Hello there!",
            font: font,
            baseColor: .label,
            volatileSuffixLength: 1,
            volatileColor: .systemBlue
        )

        #expect(textView.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("Programmatic transcript updates tint the volatile suffix blue")
    func programmaticUpdatesTintVolatileSuffix() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        let baseColor = UIColor.label
        let volatileColor = UIColor.systemBlue
        let text = "Hello there"

        textView.applyStyledText(
            text,
            font: font,
            baseColor: baseColor,
            volatileSuffixLength: 5,
            volatileColor: volatileColor
        )

        let attributed = textView.attributedText ?? NSAttributedString()
        let stableColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let volatileColorAtEnd = attributed.attribute(.foregroundColor, at: text.count - 1, effectiveRange: nil) as? UIColor

        #expect(stableColor?.isEqual(baseColor) == true)
        #expect(volatileColorAtEnd?.isEqual(volatileColor) == true)
    }

    @Test("Programmatic transcript updates add a real background to the volatile suffix")
    func programmaticUpdatesAddVolatileSuffixBackground() {
        let textView = PastableUITextView()
        let font = UIFont.preferredFont(forTextStyle: .body)
        let baseColor = UIColor.label
        let volatileColor = UIColor.systemBlue
        let volatileBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.14)
        let text = "Hello there"

        textView.applyStyledText(
            text,
            font: font,
            baseColor: baseColor,
            volatileSuffixLength: 5,
            volatileColor: volatileColor,
            volatileBackgroundColor: volatileBackgroundColor
        )

        let attributed = textView.attributedText ?? NSAttributedString()
        let stableBackground = attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? UIColor
        let volatileBackgroundAttribute = attributed.attribute(.backgroundColor, at: text.count - 1, effectiveRange: nil) as? UIColor

        #expect(stableBackground == nil)
        #expect(volatileBackgroundAttribute?.isEqual(volatileBackgroundColor) == true)
    }

    // MARK: - Keyboard Shortcuts

    @Test("Key commands expose Command+Enter and Alt+Enter")
    func keyCommandsExposeCommandAndAltEnter() {
        let textView = PastableUITextView()
        guard let keyCommands = textView.keyCommands else {
            Issue.record("Expected key commands")
            return
        }

        let hasCommandEnter = keyCommands.contains {
            $0.input == "\r" && $0.modifierFlags == .command
        }
        let hasAltEnter = keyCommands.contains {
            $0.input == "\r" && $0.modifierFlags == .alternate
        }

        #expect(hasCommandEnter)
        #expect(hasAltEnter)
    }

    @Test("Alt+Enter handler triggers alternate callback")
    func altEnterTriggersAlternateCallback() {
        let textView = PastableUITextView()
        var fired = false
        textView.onAlternateEnter = { fired = true }

        textView.perform(NSSelectorFromString("handleAlternateReturn"))

        #expect(fired)
    }

    // MARK: - Simultaneous Gesture Recognition

    @Test("Restore gesture allows simultaneous recognition to not block text selection")
    func simultaneousGestureRecognition() {
        let textView = PastableUITextView()
        textView.installKeyboardRestoreGesture()

        let tap = textView.keyboardRestoreTap
        let otherGesture = UITapGestureRecognizer()

        // The delegate should allow simultaneous recognition for our tap gesture
        // so it doesn't interfere with UITextView's built-in selection gestures.
        let allowSimultaneous = textView.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: otherGesture)
        #expect(allowSimultaneous == true, "Must allow simultaneous recognition to avoid blocking text selection")

        // But not for random other gestures
        let otherResult = textView.gestureRecognizer(otherGesture, shouldRecognizeSimultaneouslyWith: tap)
        #expect(otherResult == false, "Should only return true for the keyboard restore gesture")
    }
}

private final class FakeTextPosition: UITextPosition {}

private final class FakeTextRange: UITextRange {
    override var start: UITextPosition { FakeTextPosition() }
    override var end: UITextPosition { FakeTextPosition() }
    override var isEmpty: Bool { false }
}
