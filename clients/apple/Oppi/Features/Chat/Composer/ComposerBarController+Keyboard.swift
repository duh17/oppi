import UIKit

/// The text view's delegate callbacks and the keyboard language report.
extension ComposerBarController {
    func textViewDidBeginEditing(_ textView: UITextView) {
        isInputFocused = true
        if let pastable = textView as? PastableUITextView, pastable.isKeyboardSuppressed {
        } else {
            updateKeyboardLanguage()
        }
        applyChrome()
        // After the chrome: the host measures the bar with its new action row.
        host?.setInputFocused(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        isInputFocused = false
        applyChrome()
        host?.setInputFocused(false)
    }

    /// A call's live transcript is display-only; typing waits until the user stops talking.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        callTranscript == nil
    }

    func textViewDidChange(_ textView: UITextView) {
        guard callTranscript == nil else { return }
        let incoming = textView.text ?? ""
        if let pastable = textView as? PastableUITextView,
           !pastable.shouldCommitUserEdit(incoming) {
            return
        }
        var next = incoming
        if host?.content.text.hasPrefix("$ ") == true {
            next = incoming.isEmpty ? "" : "$ " + incoming
        }
        askClearing.textRevision &+= 1
        host?.setText(next)
        if let host {
            host.notifyFileSuggestionContext(for: host.content.text)
        }
        applyChrome()
    }

    func updateKeyboardLanguage() {
        if textView.isKeyboardSuppressed { return }
        guard textView.isFirstResponder else { return }
        let lang = textView.textInputMode?.primaryLanguage
        host?.setKeyboardLanguage(lang)
        AppPreferences.Keyboard.save(lang)
        if let manager = host?.content.voiceInputManager,
           AppPreferences.Keyboard.normalize(lang) != nil {
            Task {
                await manager.prewarm(keyboardLanguage: lang, source: "inline_keyboard_change")
            }
        }
    }
}
