import SwiftUI
import UIKit

@MainActor
private func applyComposerInputTraits(
    to textView: UITextView,
    autocorrectionEnabled: Bool
) {
    if autocorrectionEnabled {
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.spellCheckingType = .default
        textView.smartQuotesType = .default
        textView.smartDashesType = .default
        textView.smartInsertDeleteType = .default
        textView.textContentType = .none
        return
    }

    textView.autocorrectionType = .no
    textView.autocapitalizationType = .none
    textView.spellCheckingType = .no
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.textContentType = .none

    let assistant = textView.inputAssistantItem
    assistant.leadingBarButtonGroups = []
    assistant.trailingBarButtonGroups = []
}

@MainActor
private func requestSystemDictation(for textView: UITextView) {
    // UIKit does not expose a direct public "start dictation now" method.
    // This hints to the system that dictation is expected and ensures the
    // text view is active so keyboard dictation can start immediately when
    // supported by the current keyboard/input mode.
    if #available(iOS 16.4, *) {
        UITextInputContext.current()?.isDictationInputExpected = true
    }

    if !textView.isFirstResponder {
        textView.becomeFirstResponder()
    }

    textView.reloadInputViews()
}

/// Clamp raw inline composer content height to min/max line bounds.
///
/// - Parameters:
///   - rawContentHeight: Measured text content height including vertical insets.
///   - lineHeight: Single-line font height.
///   - verticalInsets: Sum of top + bottom text container inset.
///   - maxLines: Maximum inline lines before internal scrolling.
func inlineComposerHeight(
    rawContentHeight: CGFloat,
    lineHeight: CGFloat,
    verticalInsets: CGFloat,
    maxLines: Int
) -> CGFloat {
    let safeLineHeight = max(lineHeight, 1)
    let safeInsets = max(verticalInsets, 0)
    let safeMaxLines = max(maxLines, 1)

    let minHeight = ceil(safeLineHeight + safeInsets)
    let maxHeight = ceil((safeLineHeight * CGFloat(safeMaxLines)) + safeInsets)
    return min(max(ceil(rawContentHeight), minHeight), maxHeight)
}

/// Heuristic fast path for very large inline composer text.
///
/// For text far beyond visible inline capacity, measuring exact wrapped height
/// requires expensive TextKit layout. Since inline composer height is clamped
/// to `maxLines` anyway, we can safely jump straight to max height.
func inlineComposerShouldFastPathToMaxHeight(
    textLength: Int,
    containerWidth: CGFloat,
    lineHeight: CGFloat,
    maxLines: Int
) -> Bool {
    let safeTextLength = max(textLength, 0)

    let safeContainerWidth: CGFloat
    if containerWidth.isFinite {
        safeContainerWidth = max(containerWidth, 1)
    } else {
        safeContainerWidth = 1
    }

    let safeLineHeight: CGFloat
    if lineHeight.isFinite {
        safeLineHeight = max(lineHeight, 1)
    } else {
        safeLineHeight = 1
    }

    let safeMaxLines = max(maxLines, 1)

    let estimatedCharacterWidth = max(safeLineHeight * 0.5, 1)
    let estimatedCharsPerLine = max(floor(safeContainerWidth / estimatedCharacterWidth), 1)
    let visibleCapacity = estimatedCharsPerLine * CGFloat(safeMaxLines)
    let overflowThreshold = max(visibleCapacity * 2, CGFloat(safeMaxLines) * 40)

    return CGFloat(safeTextLength) > overflowThreshold
}

/// A UITextView wrapper that supports pasting images from the clipboard.
///
/// SwiftUI's `TextField` ignores image paste events. This UIViewRepresentable
/// intercepts `paste:` to check `UIPasteboard.general` for images, forwarding
/// them via `onPasteImages`. Text paste still works normally.
///
/// Inline mode auto-expands with content up to `maxLines`, then keeps
/// scrolling internally for overflow.
struct PastableTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let maxLines: Int
    let autocorrectionEnabled: Bool
    let onPasteImages: ([UIImage]) -> Void
    let onCommandEnter: (() -> Void)?
    let onOverflowChange: ((Bool) -> Void)?
    let onLineCountChange: ((Int) -> Void)?
    let onFocusChange: ((Bool) -> Void)?
    let onDictationStateChange: ((Bool) -> Void)?
    let focusRequestID: Int
    let blurRequestID: Int
    let dictationRequestID: Int
    let suppressKeyboard: Bool
    let onKeyboardRestoreRequest: (() -> Void)?
    let accessibilityIdentifier: String?
    /// BCP 47 language code of the text view's active keyboard (e.g. "zh-Hans", "en-US").
    /// Updated when the keyboard input mode changes. Used by voice input to
    /// select the correct speech model.
    @Binding var keyboardLanguage: String?

    func makeUIView(context: Context) -> PastableUITextView {
        let textView = PastableUITextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        textView.onCommandEnter = onCommandEnter
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        textView.clipsToBounds = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0

        // Keep scrolling enabled at all times.
        // Dynamic toggling (based on frame/height) creates UIKit↔SwiftUI
        // layout loops under chat timeline pressure.
        textView.isScrollEnabled = true
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)

        // Configure input traits for current composer mode.
        // Monospaced mode uses stability traits (no autocorrect); proportional
        // mode re-enables natural-language pipelines.
        applyComposerInputTraits(to: textView, autocorrectionEnabled: autocorrectionEnabled)
        context.coordinator.lastAutocorrectionEnabled = autocorrectionEnabled

        // Force TextKit 1. The default TextKit 2 path showed pathological
        // layout behavior under SwiftUI pressure on device.
        _ = textView.layoutManager

        textView.isAccessibilityElement = true
        textView.accessibilityIdentifier = accessibilityIdentifier

        textView.onKeyboardRestoreRequest = onKeyboardRestoreRequest
        textView.installKeyboardRestoreGesture()
        if suppressKeyboard {
            textView.setKeyboardSuppressed(true)
        }

        return textView
    }

    func updateUIView(_ textView: PastableUITextView, context: Context) {
        let textChanged = textView.text != text
        if textChanged {
            textView.text = text
        }
        textView.onPasteImages = onPasteImages
        textView.onCommandEnter = onCommandEnter
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor

        let traitsChanged = context.coordinator.lastAutocorrectionEnabled != autocorrectionEnabled
        context.coordinator.lastAutocorrectionEnabled = autocorrectionEnabled
        applyComposerInputTraits(to: textView, autocorrectionEnabled: autocorrectionEnabled)
        if traitsChanged {
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                textView.reloadInputViews()
            }
        }

        textView.accessibilityIdentifier = accessibilityIdentifier

        // Manage keyboard suppression — must apply before focus request so
        // inputView is set before becomeFirstResponder fires.
        textView.onKeyboardRestoreRequest = onKeyboardRestoreRequest
        if textView.isKeyboardSuppressed != suppressKeyboard {
            textView.setKeyboardSuppressed(suppressKeyboard)
        }

        if focusRequestID != context.coordinator.lastFocusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                if !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                }
            }
        }

        if blurRequestID != context.coordinator.lastBlurRequestID {
            context.coordinator.lastBlurRequestID = blurRequestID
            DispatchQueue.main.async {
                if textView.isFirstResponder {
                    textView.resignFirstResponder()
                }
            }
        }

        if dictationRequestID != context.coordinator.lastDictationRequestID {
            context.coordinator.lastDictationRequestID = dictationRequestID
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                requestSystemDictation(for: textView)
            }
        }

        // Refresh line count for programmatic text changes (e.g. voice transcription)
        // so the expand button tracks streamed content.
        if textChanged {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                coordinator.notifyLineCountIfNeeded(textView)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: PastableUITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? textView.bounds.width
        let fallbackWidth = textView.window?.windowScene?.screen.bounds.width ?? 320
        let safeFallbackWidth = fallbackWidth.isFinite && fallbackWidth > 0 ? fallbackWidth : 320
        let candidateWidth = proposedWidth > 0 ? proposedWidth : safeFallbackWidth

        let width: CGFloat
        if candidateWidth.isFinite && candidateWidth > 0 && candidateWidth < 10_000 {
            width = candidateWidth
        } else {
            width = safeFallbackWidth
        }

        let lineHeight = textView.font?.lineHeight ?? font.lineHeight
        let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let horizontalInsets = textView.textContainerInset.left
            + textView.textContainerInset.right
            + (textView.textContainer.lineFragmentPadding * 2)

        let containerWidth = max(width - horizontalInsets, 1)
        if inlineComposerShouldFastPathToMaxHeight(
            textLength: textView.textStorage.length,
            containerWidth: containerWidth,
            lineHeight: lineHeight,
            maxLines: maxLines
        ) {
            let maxInlineHeight = inlineComposerHeight(
                rawContentHeight: .greatestFiniteMagnitude,
                lineHeight: lineHeight,
                verticalInsets: verticalInsets,
                maxLines: maxLines
            )
            return CGSize(width: width, height: maxInlineHeight)
        }

        textView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        textView.layoutManager.ensureLayout(for: textView.textContainer)

        let usedTextHeight = textView.layoutManager.usedRect(for: textView.textContainer).height + verticalInsets
        let rawContentHeight = max(usedTextHeight, textView.contentSize.height)
        let inlineHeight = inlineComposerHeight(
            rawContentHeight: rawContentHeight,
            lineHeight: lineHeight,
            verticalInsets: verticalInsets,
            maxLines: maxLines
        )

        return CGSize(width: width, height: inlineHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            keyboardLanguage: $keyboardLanguage,
            maxLines: maxLines,
            onOverflowChange: onOverflowChange,
            onLineCountChange: onLineCountChange,
            onFocusChange: onFocusChange,
            onDictationStateChange: onDictationStateChange
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var keyboardLanguage: String?
        let maxLines: Int
        let onOverflowChange: ((Bool) -> Void)?
        let onLineCountChange: ((Int) -> Void)?
        let onFocusChange: ((Bool) -> Void)?
        let onDictationStateChange: ((Bool) -> Void)?

        var lastFocusRequestID = 0
        var lastBlurRequestID = 0
        var lastDictationRequestID = 0
        var lastAutocorrectionEnabled: Bool?
        private var lastOverflowState = false
        private var lastDictationState = false
        private var lastReportedLineCount = 1
        nonisolated(unsafe) private var inputModeObserver: NSObjectProtocol?

        init(
            text: Binding<String>,
            keyboardLanguage: Binding<String?>,
            maxLines: Int,
            onOverflowChange: ((Bool) -> Void)?,
            onLineCountChange: ((Int) -> Void)?,
            onFocusChange: ((Bool) -> Void)?,
            onDictationStateChange: ((Bool) -> Void)?
        ) {
            _text = text
            _keyboardLanguage = keyboardLanguage
            self.maxLines = maxLines
            self.onOverflowChange = onOverflowChange
            self.onLineCountChange = onLineCountChange
            self.onFocusChange = onFocusChange
            self.onDictationStateChange = onDictationStateChange
            super.init()

            // Track keyboard language changes via notification.
            // The textView's textInputMode.primaryLanguage gives the actual
            // active keyboard for THIS text view — not a global list.
            inputModeObserver = NotificationCenter.default.addObserver(
                forName: UITextInputMode.currentInputModeDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateKeyboardLanguage()
            }
        }

        deinit {
            if let observer = inputModeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Read the keyboard language from the actual text view via responder chain.
        func updateKeyboardLanguage() {
            // Walk responder chain to find our text view
            guard let textView = findFirstResponderTextView() else { return }
            let lang = textView.textInputMode?.primaryLanguage
            keyboardLanguage = lang
            KeyboardLanguageStore.save(lang)
        }

        private func findFirstResponderTextView() -> UITextView? {
            // The notification fires globally — find the active text view
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0.isKeyWindow })
            else { return nil }
            return findFirstResponder(in: window) as? UITextView
        }

        private func findFirstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for sub in view.subviews {
                if let found = findFirstResponder(in: sub) { return found }
            }
            return nil
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onFocusChange?(true)
            let lang = textView.textInputMode?.primaryLanguage
            keyboardLanguage = lang
            KeyboardLanguageStore.save(lang)
            notifyLineCountIfNeeded(textView)
            notifyDictationStateIfNeeded(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onFocusChange?(false)
            if lastDictationState {
                lastDictationState = false
                onDictationStateChange?(false)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            notifyDictationStateIfNeeded(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text

            let lineHeight = textView.font?.lineHeight ?? 17
            let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
            let maxHeight = ceil((lineHeight * CGFloat(max(maxLines, 1))) + verticalInsets)
            let isOverflowing = textView.contentSize.height > (maxHeight + 0.5)

            if isOverflowing != lastOverflowState {
                lastOverflowState = isOverflowing
                onOverflowChange?(isOverflowing)
            }

            notifyLineCountIfNeeded(textView)
            notifyDictationStateIfNeeded(textView)
        }

        func notifyLineCountIfNeeded(_ textView: UITextView) {
            let lineHeight = max(textView.font?.lineHeight ?? 17, 1)
            let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
            let textHeight = max(textView.contentSize.height - verticalInsets, lineHeight)
            let lineCount = max(1, Int(ceil(textHeight / lineHeight)))

            if lineCount != lastReportedLineCount {
                lastReportedLineCount = lineCount
                onLineCountChange?(lineCount)
            }
        }

        private func notifyDictationStateIfNeeded(_ textView: UITextView) {
            let isDictating = textView.textInputMode?.primaryLanguage == "dictation"
            if isDictating != lastDictationState {
                lastDictationState = isDictating
                onDictationStateChange?(isDictating)
            }
        }
    }
}

// MARK: - Full Size Text View

/// A pastable text view that fills all available space. Used in the expanded composer.
///
/// Unlike inline `PastableTextView` (auto-expands up to max lines), this variant
/// always scrolls and fills its container. Keyboard dismiss is interactive
/// (drag to dismiss). Can optionally auto-focus on appear.
struct FullSizeTextView: UIViewRepresentable {
    @Binding var text: String
    let font: UIFont
    let textColor: UIColor
    let tintColor: UIColor
    let autocorrectionEnabled: Bool
    let onPasteImages: ([UIImage]) -> Void
    let onCommandEnter: (() -> Void)?
    let autoFocusOnAppear: Bool

    func makeUIView(context: Context) -> PastableUITextView {
        let textView = PastableUITextView()
        textView.delegate = context.coordinator
        textView.onPasteImages = onPasteImages
        textView.onCommandEnter = onCommandEnter
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true

        applyComposerInputTraits(to: textView, autocorrectionEnabled: autocorrectionEnabled)
        context.coordinator.lastAutocorrectionEnabled = autocorrectionEnabled

        if autoFocusOnAppear {
            // Auto-focus after sheet animation settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                textView.becomeFirstResponder()
                // Place cursor at end
                if let end = textView.textRange(
                    from: textView.endOfDocument,
                    to: textView.endOfDocument
                ) {
                    textView.selectedTextRange = end
                }
            }
        }

        return textView
    }

    func updateUIView(_ textView: PastableUITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.onPasteImages = onPasteImages
        textView.onCommandEnter = onCommandEnter
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor

        let traitsChanged = context.coordinator.lastAutocorrectionEnabled != autocorrectionEnabled
        context.coordinator.lastAutocorrectionEnabled = autocorrectionEnabled
        applyComposerInputTraits(to: textView, autocorrectionEnabled: autocorrectionEnabled)
        if traitsChanged {
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                textView.reloadInputViews()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        var lastAutocorrectionEnabled: Bool?

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

// MARK: - Custom UITextView

/// UITextView subclass that intercepts paste to extract images.
final class PastableUITextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?
    var onCommandEnter: (() -> Void)?
    var onKeyboardRestoreRequest: (() -> Void)?

    /// When true, keyboard is hidden but cursor remains visible via empty `inputView`.
    private(set) var isKeyboardSuppressed = false

    private var cachedPasteboardChangeCount: Int = -1
    private var cachedPasteboardHasImages = false

    /// Tap gesture that restores the keyboard when the user taps the text view
    /// while keyboard is suppressed (e.g. during voice recording).
    /// Exposed as internal for `@testable import` — do not use outside tests.
    private(set) lazy var keyboardRestoreTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleKeyboardRestoreTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    override var intrinsicContentSize: CGSize {
        // Return noIntrinsicMetric — sizeThatFits is the authoritative source
        // for SwiftUI layout. Having intrinsicContentSize compete with
        // sizeThatFits causes layout oscillation.
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: "\r",
                modifierFlags: .command,
                action: #selector(handleCommandReturn),
                discoverabilityTitle: "Send"
            ),
        ]
    }

    @objc private func handleCommandReturn() {
        onCommandEnter?()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard action == #selector(paste(_:)) else {
            return super.canPerformAction(action, withSender: sender)
        }

        if super.canPerformAction(action, withSender: sender) {
            return true
        }

        // Selection gestures invoke canPerformAction frequently.
        // Cache by pasteboard changeCount to avoid repeated expensive probes.
        return pasteboardHasImages()
    }

    private func pasteboardHasImages() -> Bool {
        let pb = UIPasteboard.general
        let changeCount = pb.changeCount
        if changeCount != cachedPasteboardChangeCount {
            cachedPasteboardChangeCount = changeCount
            cachedPasteboardHasImages = pb.hasImages
        }
        return cachedPasteboardHasImages
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general

        // Check for images first
        if pb.hasImages, let images = pb.images, !images.isEmpty {
            onPasteImages?(images)
            // If clipboard also has text, paste that too
            if pb.hasStrings {
                super.paste(sender)
            }
            return
        }

        // Normal text paste
        super.paste(sender)
    }

    // MARK: - Keyboard Suppression

    /// Install the tap gesture that restores the keyboard when the user taps
    /// the text view while keyboard is suppressed.
    func installKeyboardRestoreGesture() {
        keyboardRestoreTap.isEnabled = false
        addGestureRecognizer(keyboardRestoreTap)
    }

    /// Toggle keyboard suppression. When suppressed, the cursor remains visible
    /// but the system keyboard is hidden via an empty `inputView`.
    func setKeyboardSuppressed(_ suppressed: Bool) {
        isKeyboardSuppressed = suppressed
        inputView = suppressed ? UIView() : nil
        keyboardRestoreTap.isEnabled = suppressed
        if window != nil {
            reloadInputViews()
        }
    }

    @objc private func handleKeyboardRestoreTap() {
        guard isKeyboardSuppressed else { return }
        // Immediately restore keyboard for responsiveness
        isKeyboardSuppressed = false
        inputView = nil
        keyboardRestoreTap.isEnabled = false
        reloadInputViews()
        onKeyboardRestoreRequest?()
    }
}

// MARK: - PastableUITextView + UIGestureRecognizerDelegate

extension PastableUITextView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === keyboardRestoreTap
    }
}
