import UIKit

@MainActor
func applyComposerInputTraits(
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
        textView.writingToolsBehavior = .complete
        textView.allowedWritingToolsResultOptions = .plainText
    } else {
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContentType = .none
        textView.writingToolsBehavior = .none
        textView.allowedWritingToolsResultOptions = .plainText
    }

    // Hide iPadOS shortcut-bar items such as "Write with Siri".
    // Empty leading/trailing groups hide shortcuts only; typing suggestions,
    // dictation, and Writing Tools stay under the traits above.
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

func composerVolatileTranscriptBackgroundColor() -> UIColor {
    // Needs to read clearly against the darker glass composer background
    // without looking like a full text selection.
    UIColor.themeBlue.withAlphaComponent(0.20)
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

// MARK: - Custom UITextView

/// UITextView subclass that intercepts paste to extract images.
extension PastableUITextView {
    /// App Lock: SwiftUI's `.accessibilityHidden` on the root does not reach
    /// this UIKit view, so the composer hides itself while Oppi is locked.
    func hideFromAccessibility(whileLocked locked: Bool) {
        accessibilityElementsHidden = locked
        isAccessibilityElement = !locked
    }
}

class PastableUITextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?
    var onCommandEnter: (() -> Void)?
    var onAlternateEnter: (() -> Void)?
    var onKeyboardRestoreRequest: (() -> Void)?

    #if DEBUG
    enum SelectionProbePhase: Equatable {
        case immediate
        case deferred
    }

    typealias SelectionProbe = (SelectionProbePhase, NSRange, Int) -> Void

    /// Test-only hooks for IME and streamed-caret regression coverage.
    /// Kept out of Release builds so the production type surface stays clean.
    var markedTextRangeOverrideForTesting: UITextRange?
    var selectionProbeForTesting: SelectionProbe?
    #endif

    private var renderedTextCache = ""
    private var renderedVolatileSuffixLengthCache = -1
    private var renderedCorrectionRangesCache: [NSRange] = []
    private var renderedFontCache: UIFont?
    private var renderedBaseColorCache: UIColor?
    private var renderedVolatileColorCache: UIColor?
    private var renderedVolatileBackgroundColorCache: UIColor?
    private var renderedCorrectionUnderlineColorCache: UIColor?
    private var programmaticTextDepth = 0
    var isApplyingProgrammaticText: Bool { programmaticTextDepth > 0 }
    private var programmaticClearEcho: String?
    private var programmaticClearEchoDeadline: Date?

    /// When true, keyboard is hidden but cursor remains visible via empty `inputView`.
    private(set) var isKeyboardSuppressed = false

    /// When false, taps on the text view do not restore the keyboard even if
    /// suppression is active (used during active voice recording).
    private(set) var allowsKeyboardRestoreOnTap = true

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

    func applyStyledText(
        _ text: String,
        font: UIFont,
        baseColor: UIColor,
        volatileSuffixLength: Int,
        volatileColor: UIColor,
        volatileBackgroundColor: UIColor = .clear,
        correctionRanges: [NSRange] = [],
        correctionUnderlineColor: UIColor = .clear,
        scrollCaretToVisible: Bool = false
    ) {
        let clampedVolatileSuffixLength = max(0, min(volatileSuffixLength, text.count))
        let totalLength = (text as NSString).length
        let clampedCorrectionRanges = correctionRanges.compactMap { range in
            let clampedRange = NSIntersectionRange(range, NSRange(location: 0, length: totalLength))
            return clampedRange.length > 0 ? clampedRange : nil
        }
        let styleUnchanged = Self.hasExactUTF16Representation(renderedTextCache, text)
            && renderedVolatileSuffixLengthCache == clampedVolatileSuffixLength
            && renderedCorrectionRangesCache == clampedCorrectionRanges
            && (renderedFontCache?.isEqual(font) ?? false)
            && (renderedBaseColorCache?.isEqual(baseColor) ?? false)
            && (renderedVolatileColorCache?.isEqual(volatileColor) ?? false)
            && (renderedVolatileBackgroundColorCache?.isEqual(volatileBackgroundColor) ?? false)
            && (renderedCorrectionUnderlineColorCache?.isEqual(correctionUnderlineColor) ?? false)

        guard !styleUnchanged else { return }

        // Do not replace attributedText while an IME composition is active
        // (e.g. Chinese Pinyin preedit text). Reassigning attributedText here
        // commits the marked text prematurely, which turns the candidate buffer
        // into raw latin letters like "jiugongge" instead of keeping the
        // composition open for selection.
        if Self.shouldDeferStyledTextUpdateWhileComposing(
            hasMarkedText: effectiveMarkedTextRange != nil,
            currentText: self.text,
            incomingText: text
        ) {
            return
        }

        let incomingTextHasInlineStyling = clampedVolatileSuffixLength > 0 || !clampedCorrectionRanges.isEmpty
        let renderedPlainBaseStyleMatches = renderedVolatileSuffixLengthCache == 0
            && renderedCorrectionRangesCache.isEmpty
            && (renderedFontCache?.isEqual(font) ?? false)
            && (renderedBaseColorCache?.isEqual(baseColor) ?? false)

        if !incomingTextHasInlineStyling,
           renderedPlainBaseStyleMatches,
           Self.hasExactUTF16Representation(self.text, text) {
            typingAttributes = [
                .font: font,
                .foregroundColor: baseColor,
            ]
            renderedTextCache = text
            renderedVolatileSuffixLengthCache = 0
            renderedCorrectionRangesCache = []
            renderedFontCache = font
            renderedBaseColorCache = baseColor
            renderedVolatileColorCache = volatileColor
            renderedVolatileBackgroundColorCache = volatileBackgroundColor
            renderedCorrectionUnderlineColorCache = correctionUnderlineColor
            return
        }

        let previousSelection = self.selectedRange
        let previousTextLength = textStorage.length
        let previousPlain = textStorage.string
        let keepCaretPinnedToEnd = previousSelection.length == 0 && previousSelection.location >= previousTextLength
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: baseColor,
        ]
        let replacement = Self.minimalTextReplacement(current: previousPlain, incoming: text)
        let clearingSentDraft = text.isEmpty && !previousPlain.isEmpty
        if clearingSentDraft {
            // The keyboard and autocorrect can replay the draft we just sent.
            // Remember it so that echo is not committed as a new edit.
            programmaticClearEcho = previousPlain
            programmaticClearEchoDeadline = Date().addingTimeInterval(1)
        }
        beginProgrammaticTextEdit()
        defer { endProgrammaticTextEdit() }
        if clearingSentDraft {
            if effectiveMarkedTextRange != nil {
                unmarkText()
            }
            inputDelegate?.selectionWillChange(self)
            inputDelegate?.textWillChange(self)
        }

        // `attributedText` assignment replaces the text view's entire value and
        // resets UIKit's editing state before we can restore the selection. During
        // streamed dictation that briefly paints the caret at the replacement
        // location, then at the end, which looks like a cursor flicker. Mutate the
        // existing NSTextStorage in one edit batch instead; Apple exposes it as the
        // mutable TextKit backing store specifically for styled text updates.
        textStorage.beginEditing()
        if replacement.current.length > 0 || replacement.incoming.length > 0 {
            let replacementText = (text as NSString).substring(with: replacement.incoming)
            textStorage.replaceCharacters(in: replacement.current, with: replacementText)
        }

        // Swift String equality is canonically equivalent, but TextKit ranges
        // address the exact UTF-16 storage. Verify the intended representation
        // before applying any incoming ranges, and recover with a full replacement
        // rather than ever styling a mismatched backing store.
        if !Self.hasExactUTF16Representation(textStorage.string, text) {
            textStorage.replaceCharacters(
                in: NSRange(location: 0, length: textStorage.length),
                with: text
            )
        }
        assert(
            Self.hasExactUTF16Representation(textStorage.string, text),
            "Styled text storage must exactly match the incoming UTF-16 representation"
        )

        let fullRange = NSRange(location: 0, length: textStorage.length)
        if fullRange.length > 0 {
            textStorage.setAttributes(baseAttributes, range: fullRange)

            if clampedVolatileSuffixLength > 0 {
                let volatileStart = text.index(text.endIndex, offsetBy: -clampedVolatileSuffixLength)
                let volatileRange = NSRange(volatileStart..<text.endIndex, in: text)
                textStorage.addAttributes(
                    [
                        .foregroundColor: volatileColor,
                        .backgroundColor: volatileBackgroundColor,
                    ],
                    range: volatileRange
                )
            }

            for range in clampedCorrectionRanges {
                textStorage.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: correctionUnderlineColor,
                    ],
                    range: range
                )
            }
        }
        textStorage.endEditing()
        typingAttributes = baseAttributes
        if clearingSentDraft {
            inputDelegate?.textDidChange(self)
            inputDelegate?.selectionDidChange(self)
            undoManager?.removeAllActions()
        }

        let maxSelectionLocation = totalLength
        let restoredSelection: NSRange
        if keepCaretPinnedToEnd {
            restoredSelection = NSRange(location: maxSelectionLocation, length: 0)
        } else {
            let clampedLocation = min(previousSelection.location, maxSelectionLocation)
            restoredSelection = NSRange(
                location: clampedLocation,
                length: min(previousSelection.length, max(0, maxSelectionLocation - clampedLocation))
            )
        }
        if !NSEqualRanges(self.selectedRange, restoredSelection) {
            self.selectedRange = restoredSelection
        }
        if scrollCaretToVisible {
            scrollRangeToVisible(restoredSelection)
        }
        #if DEBUG
        if keepCaretPinnedToEnd {
            selectionProbeForTesting?(.immediate, selectedRange, textStorage.length)
        }
        #endif

        if keepCaretPinnedToEnd {
            // TextKit can apply its own selection adjustment after the storage
            // edit returns, moving the caret back to the old transcript boundary.
            // Reassert the terminal insertion point on the next main-queue turn,
            // but only if this exact transcript is still current.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      Self.hasExactUTF16Representation(self.textStorage.string, text)
                else { return }
                let terminalSelection = NSRange(location: self.textStorage.length, length: 0)
                if !NSEqualRanges(self.selectedRange, terminalSelection) {
                    self.selectedRange = terminalSelection
                }
                if scrollCaretToVisible {
                    self.scrollRangeToVisible(terminalSelection)
                }
                #if DEBUG
                self.selectionProbeForTesting?(.deferred, self.selectedRange, self.textStorage.length)
                #endif
            }
        }

        renderedTextCache = text
        renderedVolatileSuffixLengthCache = clampedVolatileSuffixLength
        renderedCorrectionRangesCache = clampedCorrectionRanges
        renderedFontCache = font
        renderedBaseColorCache = baseColor
        renderedVolatileColorCache = volatileColor
        renderedVolatileBackgroundColorCache = volatileBackgroundColor
        renderedCorrectionUnderlineColorCache = correctionUnderlineColor
    }

    /// False while a programmatic replace is in flight, and false when `incoming`
    /// is the draft a send-clear just removed. The latter is reverted so the
    /// keyboard cannot put the sent message back in the field.
    func shouldCommitUserEdit(_ incoming: String) -> Bool {
        if isApplyingProgrammaticText { return false }
        if rejectProgrammaticClearEcho(incoming) { return false }
        // Empty is the clear itself. Disarming on it lets a later keyboard
        // replay of the sent draft through.
        if !incoming.isEmpty {
            programmaticClearEcho = nil
            programmaticClearEchoDeadline = nil
        }
        return true
    }

    func rejectProgrammaticClearEcho(_ incoming: String) -> Bool {
        guard let echo = programmaticClearEcho,
              let deadline = programmaticClearEchoDeadline,
              Date() < deadline,
              !echo.isEmpty,
              Self.hasExactUTF16Representation(echo, incoming) else {
            return false
        }
        restoreProgrammaticClear()
        return true
    }

    private func beginProgrammaticTextEdit() {
        programmaticTextDepth += 1
    }

    private func endProgrammaticTextEdit() {
        programmaticTextDepth = max(0, programmaticTextDepth - 1)
    }

    private func restoreProgrammaticClear() {
        guard !Self.hasExactUTF16Representation(textStorage.string, "") else { return }
        beginProgrammaticTextEdit()
        defer { endProgrammaticTextEdit() }
        textStorage.beginEditing()
        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: textStorage.length),
            with: ""
        )
        textStorage.endEditing()
        selectedRange = NSRange(location: 0, length: 0)
        renderedTextCache = ""
        renderedVolatileSuffixLengthCache = 0
        renderedCorrectionRangesCache = []
    }

    static func minimalTextReplacement(
        current: String,
        incoming: String
    ) -> (current: NSRange, incoming: NSRange) {
        let currentScalars = current.unicodeScalars
        let incomingScalars = incoming.unicodeScalars
        var currentStart = currentScalars.startIndex
        var incomingStart = incomingScalars.startIndex
        let currentEnd = currentScalars.endIndex
        let incomingEnd = incomingScalars.endIndex

        // Compare exact scalars, not Swift Characters. Character equality treats
        // precomposed and decomposed forms as equal even though TextKit sees
        // different UTF-16 lengths.
        while currentStart != currentEnd,
              incomingStart != incomingEnd,
              currentScalars[currentStart].value == incomingScalars[incomingStart].value {
            currentScalars.formIndex(after: &currentStart)
            incomingScalars.formIndex(after: &incomingStart)
        }

        var currentSuffixStart = currentEnd
        var incomingSuffixStart = incomingEnd
        while currentSuffixStart != currentStart,
              incomingSuffixStart != incomingStart {
            let previousCurrent = currentScalars.index(before: currentSuffixStart)
            let previousIncoming = incomingScalars.index(before: incomingSuffixStart)
            guard currentScalars[previousCurrent].value == incomingScalars[previousIncoming].value else { break }
            currentSuffixStart = previousCurrent
            incomingSuffixStart = previousIncoming
        }

        return (
            current: NSRange(currentStart..<currentSuffixStart, in: current),
            incoming: NSRange(incomingStart..<incomingSuffixStart, in: incoming)
        )
    }

    static func hasExactUTF16Representation(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private var effectiveMarkedTextRange: UITextRange? {
        #if DEBUG
        if let markedTextRangeOverrideForTesting {
            return markedTextRangeOverrideForTesting
        }
        #endif
        return markedTextRange
    }

    static func shouldDeferStyledTextUpdateWhileComposing(
        hasMarkedText: Bool,
        currentText: String,
        incomingText: String
    ) -> Bool {
        guard hasMarkedText else { return false }
        return currentText == incomingText
    }

    override var intrinsicContentSize: CGSize {
        // Return noIntrinsicMetric — sizeThatFits is the authoritative source
        // for SwiftUI layout. Having intrinsicContentSize compete with
        // sizeThatFits causes layout oscillation.
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(handleCommandReturn))
        send.discoverabilityTitle = "Send"

        let queueFollowUp = UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(handleAlternateReturn))
        queueFollowUp.discoverabilityTitle = "Queue Follow-up"

        return [send, queueFollowUp]
    }

    @objc private func handleCommandReturn() {
        onCommandEnter?()
    }

    @objc private func handleAlternateReturn() {
        onAlternateEnter?()
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

    func moveCaretToEnd() {
        let end = textStorage.length
        selectedRange = NSRange(location: end, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    /// Toggle keyboard suppression. When suppressed, the cursor remains visible
    /// but the system keyboard is hidden via an empty `inputView`.
    func setKeyboardSuppressed(_ suppressed: Bool) {
        isKeyboardSuppressed = suppressed
        inputView = suppressed ? UIView() : nil
        keyboardRestoreTap.isEnabled = suppressed && allowsKeyboardRestoreOnTap
        if isOnVisibleWindow {
            reloadInputViews()
        }
    }

    /// Enable/disable restoring the keyboard via text-view tap while suppressed.
    func setAllowKeyboardRestoreOnTap(_ allow: Bool) {
        allowsKeyboardRestoreOnTap = allow
        keyboardRestoreTap.isEnabled = isKeyboardSuppressed && allow
    }

    @objc private func handleKeyboardRestoreTap() {
        guard isKeyboardSuppressed, allowsKeyboardRestoreOnTap else { return }
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
