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
